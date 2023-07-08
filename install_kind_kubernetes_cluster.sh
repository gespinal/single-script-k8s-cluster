#!/bin/bash

# kind K8s Cluster

# Check if docker is running
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running."
  exit 0
fi

if [ "$1" != "example.com" ]; then
  LETS_ENCRYPT_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
  if [ "$#" -ne 3 ]; then
  echo "Usage: ./install_kind_kubernetes_cluster.sh domain [email]"
  exit 0
  else
    DOMAIN_NAME=$1
    LESERVER=$2
    regex="^[a-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[a-z0-9!#$%&'*+/=?^_\`{|}~-]+)*@([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?\$"
    EMAIL=$3
    if [[ $LESERVER == "prd" ]] ; then
        LETS_ENCRYPT_SERVER="https://acme-v02.api.letsencrypt.org/directory"
    fi
    if ! [[ $EMAIL =~ $regex ]] ; then
        echo "Usage: ./install_kind_kubernetes_cluster.sh [domain] [env] [email]"
        exit 0
    fi
  fi
else
  DOMAIN_NAME=$1
fi

echo "**** Deleting old cluster, if it already exists"
kind delete cluster 2> /dev/null

# Check if HTTP and HTTPS ports are in use
if [ ! -z "$(ss -tulpn | grep LISTEN | grep '0.0.0.0' | grep -E '80|443')" ];
then
    echo "Ports HTTP/HTTPS in use. Please check."
fi

# Setting variables
echo "**** Exporting CLUSTER_NAME=kind"
export CLUSTER_NAME=kind

# Installation
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  echo "**** Setting sysconfig for linux system"
  sudo sysctl -w net.netfilter.nf_conntrack_max=131072
elif [[ "$OSTYPE" == "darwin"* ]]; then
  echo "**** Proceeding with macOS setup"
else
  echo "**** Configuration for this OS is not available"
  exit 0;
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
  if ! command -v brew &> /dev/null; then
    ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  fi
fi

# Install kubectl
if ! command -v kind &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl 2> /dev/null && sudo chmod +x /usr/local/bin/kubectl
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    brew install kubernetes-cli
  fi
fi

# Install the latest version of kind
echo "**** Installing kind Kubernetes"
if ! command -v kind &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo curl -L https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 -o /usr/local/bin/kind 2> /dev/null && sudo chmod +x /usr/local/bin/kind
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    if ! command -v go &> /dev/null; then
      brew update && brew install go
      mkdir $HOME/go
      echo export GOPATH=$HOME/go | tee -a $HOME/.zshrc > /dev/null
      echo export PATH=$PATH:$HOME/go/bin | tee -a $HOME/.zshrc > /dev/null
    fi
    brew install kind
  fi
fi

echo "**** Create docker insecure registry"
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

echo "**** Creating new kind cluster"
kind create cluster --retain -v 1 --name ${CLUSTER_NAME} --config - << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 80
        hostPort: 80
        protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
EOF

# Set cluster to never auto-start
echo "**** Update restart policy"
docker update --restart=no kind-control-plane

echo "**** Wait for control-plane node to be ready"
kubectl wait \
  --for=condition=ready node \
  --selector=kubernetes.io/hostname=kind-control-plane \
  --timeout=300s

echo "**** Connect to registry"
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

echo "**** Apply registry configmap"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "**** Install nginx ingress controller"
kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml

echo "**** Sleep for 5 secs"
sleep 5

echo "**** Wait for ingress controller to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

if [ "$DOMAIN_NAME" == "example.com" ]; then
  echo "**** Clonning certificate repo"
  git clone https://github.com/gespinal/ssl-wildcard-certificate-self-ca.git

  echo "**** Creating certificate for $DOMAIN_NAME domain"
  cd ssl-wildcard-certificate-self-ca
  ./create_certificate.sh $DOMAIN_NAME
  cd ../

  echo "**** Create certificate secret for default namespace"
  kubectl create secret generic example \
    --from-file=tls.crt=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME-CERT.pem \
    --from-file=tls.key=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME.key
fi

if [ "$DOMAIN_NAME" != "example.com" ]; then
echo "**** Install cert-manager"
kubectl create namespace cert-manager
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.12.2/cert-manager.yaml

echo "**** Sleep for 5 secs"
sleep 5

echo "**** Wait for certificate manager controller to be ready"
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

echo "**** Wait for certificate manager webhook to be ready"
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=webhook \
  --timeout=300s

kubectl -n cert-manager get po

echo "**** Certificate manager - create issuer"
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cluster-issuer
spec:
  acme:
    server: $LETS_ENCRYPT_SERVER
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-cluster-issuer-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
fi

echo "**** Install MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml

echo "**** Sleep for 5 secs"
sleep 5

echo "**** Wait fot metallb load balancer to be ready"
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

echo "**** Get metal lb cidr range"
cluster_cidr=$(docker inspect --format '{{(index .IPAM.Config 0).Subnet}}' kind)
metal_lb_first_ip=$(echo $cluster_cidr | awk -F. '{print $1 FS $2}').255.200
metal_lb_last_ip=$(echo $cluster_cidr | awk -F. '{print $1 FS $2}').255.250

echo "**** Configure IP address pool for metallb load balancer"
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallbipaddresspool
  namespace: metallb-system
spec:
  addresses:
  - $metal_lb_first_ip-$metal_lb_last_ip
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

echo "**** Test registry"
docker pull docker.io/nginxdemos/hello:plain-text
docker tag docker.io/nginxdemos/hello:plain-text localhost:5001/hello:latest
docker push localhost:5001/hello:latest

echo "**** Test registry - create deployment"
kubectl create deployment hello --image=localhost:5001/hello:latest

echo "**** Create hello service"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  type: LoadBalancer
  selector:
    app: hello
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF

if [ "$DOMAIN_NAME" != "example.com" ]; then
echo "**** Create hello certificate"
SECRET_NAME=hello.$DOMAIN_NAME-tls
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hello-cert
  namespace: default
spec:
  dnsNames:
    - hello.$DOMAIN_NAME
  secretName: $SECRET_NAME
  issuerRef:
    name: letsencrypt-cluster-issuer
    kind: ClusterIssuer
EOF
else
  SECRET_NAME=example
fi

echo "**** Create hello ingress"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-cluster-issuer
spec:
  tls:
    - hosts:
      - hello.$DOMAIN_NAME
      secretName: $SECRET_NAME
  rules:
    - host: hello.$DOMAIN_NAME
      http:
        paths:
          - pathType: ImplementationSpecific
            backend:
              service:
                name: hello
                port:
                  number: 80
EOF

echo "**** Wait for hello pod to be ready"
kubectl wait \
  --for=condition=ready pod \
  --selector=app=hello\
  --timeout=300s

echo "**** Get Ingress IP from host"
CONTROL_PLANE_IP=$(docker container inspect ${CLUSTER_NAME}-control-plane --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')

echo "**** Test hello service"
docker run \
  --add-host hello.$DOMAIN_NAME:${CONTROL_PLANE_IP} \
  --net kind --rm curlimages/curl:latest hello.$DOMAIN_NAME

echo "**** Install dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.5.0/aio/deploy/recommended.yaml

echo "**** Check dashboard"
kubectl get all -n kubernetes-dashboard

if [ "$DOMAIN_NAME" == "example.com" ]; then
  echo "**** Create certificate secret for dashboard namespace"
  kubectl -n kubernetes-dashboard create secret generic example \
    --from-file=tls.crt=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME-CERT.pem \
    --from-file=tls.key=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME.key
fi

echo "**** Create dashboard service account"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF

echo "**** Create dashboard rolebinding"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

if [ "$DOMAIN_NAME" != "example.com" ]; then
echo "**** Create dashboard certificate"
SECRET_NAME=dashboard.$DOMAIN_NAME-tls
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dashboard-cert
  namespace: kubernetes-dashboard
spec:
  dnsNames:
    - dashboard.$DOMAIN_NAME
  secretName: $SECRET_NAME
  issuerRef:
    name: letsencrypt-cluster-issuer
    kind: ClusterIssuer
EOF
else
  SECRET_NAME=example
fi

echo "**** Create dashboard ingress"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    cert-manager.io/cluster-issuer: letsencrypt-cluster-issuer
spec:
  tls:
    - hosts:
      - dashboard.$DOMAIN_NAME
      secretName: $SECRET_NAME
  rules:
    - host: dashboard.$DOMAIN_NAME
      http:
        paths:
          - pathType: ImplementationSpecific
            backend:
              service:
                name: kubernetes-dashboard
                port:
                  number: 443
EOF

echo "**** Wait for dashboard pod to be ready"
kubectl wait -n kubernetes-dashboard \
  --for=condition=ready pod \
  --selector=k8s-app=kubernetes-dashboard \
  --timeout=300s



echo "**** Install Argo CD"
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

echo "**** Wait for Argo CD server to be ready"
kubectl wait --namespace argocd\
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=300s

if [ "$DOMAIN_NAME" == "example.com" ]; then
  echo "**** Create certificate secret for dashboard namespace"
  kubectl -n argocd create secret generic example \
    --from-file=tls.crt=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME-CERT.pem \
    --from-file=tls.key=./ssl-wildcard-certificate-self-ca/certs/$DOMAIN_NAME.key
fi

echo "**** Create Argo CD certificate"
if [ "$DOMAIN_NAME" != "example.com" ]; then
SECRET_NAME=argo.$DOMAIN_NAME-tls
kubectl apply -f - <<EOF
apiVersion: argo-manager.io/v1
kind: Certificate
metadata:
  name: argo-cert
  namespace: argocd
spec:
  dnsNames:
    - argo.$DOMAIN_NAME
  secretName: $SECRET_NAME
  issuerRef:
    name: letsencrypt-cluster-issuer
    kind: ClusterIssuer
EOF
else
  SECRET_NAME=example
fi

echo "**** Create Argo CD ingress"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argo
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-cluster-issuer
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  tls:
    - hosts:
      - argo.$DOMAIN_NAME
      secretName: $SECRET_NAME
  rules:
    - host: argo.$DOMAIN_NAME
      http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: argocd-server
              port:
                name: https
EOF

echo "**** Update Argo CD password"
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "$2a$10$rRyBsGSHK6.uc8fntPwVIuLVHgsAhAX7TcdrqW/RADU0uh7CaChLa",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'

if [ "$DOMAIN_NAME" == "example.com" ]; then
  echo "**** Adding hello.$DOMAIN_NAME and argo.$DOMAIN_NAME to /etc/hosts"
  if grep -q "argo.$DOMAIN_NAME" /etc/hosts; then
      echo "Host entries already exists on /etc/hosts"
  else
    sudo sh -c "echo '127.0.0.1 hello.$DOMAIN_NAME argo.$DOMAIN_NAME dashboard.$DOMAIN_NAME' >> /etc/hosts"
  fi
fi

echo "**** Token for kubernetes-dashboard"
kubectl -n kubernetes-dashboard create token admin-user

echo "**** Kind k8s cluster created"
echo "kubectl cluster-info --context kind-kind"
