#!/bin/bash

# k3d K8s Cluster

# Check if docker is running
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running."
  exit 0
fi

if [ "$1" != "example.com" ]; then
  LETS_ENCRYPT_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
  if [ "$#" -ne 3 ]; then
  echo "Usage: ./install_k3d_kubernetes_cluster.sh domain [email]"
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
        echo "Usage: ./install_k3d_kubernetes_cluster.sh [domain] [env] [email]"
        exit 0
    fi
  fi
else
  DOMAIN_NAME=$1
fi

# Install the latest version of k3d
echo "**** Installing k3d Kubernetes"
if ! command -v k3d &> /dev/null; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "**** Deleting old cluster, if it already exists"
k3d cluster delete --all

echo "**** Deleting old registry, if it already exists"
k3d registry delete --all

# Check if HTTP and HTTPS ports are in use
if [ ! -z "$(ss -tulpn | grep LISTEN | grep '0.0.0.0' | grep -E '80|443')" ];
then
    echo "Ports HTTP/HTTPS in use. Please check."
fi

# Setting variables
echo "**** Exporting CLUSTER_NAME=cluster"
export CLUSTER_NAME=cluster

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
if ! command -v kubectl &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl 2> /dev/null && sudo chmod +x /usr/local/bin/kubectl
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    brew install kubernetes-cli
  fi
fi

echo "**** Creating new k3d cluster"
k3d cluster create $CLUSTER_NAME \
    --agents 2 \
    -p "80:80@loadbalancer" \
    -p "443:443@loadbalancer" \
    --registry-create local.registry:0.0.0.0:5001 \
    --kubeconfig-update-default \
    --kubeconfig-switch-context \
    --api-port 0.0.0.0:4040

echo "**** Adding local.registry to /etc/hosts"
if grep -q "local.registry" /etc/hosts; then
    echo "Host local.registry already exists on /etc/hosts"
else
  sudo sh -c "echo '127.0.0.1 local.registry' >> /etc/hosts"
fi

echo "**** Wait for control-plane node to be ready"
kubectl wait \
  --for=condition=ready node \
  --selector=kubernetes.io/hostname=k3d-cluster-server-0 \
  --timeout=300s

echo "**** Sleep for 5 secs"
sleep 5

echo "**** Wait for traefik to be installed"
kubectl wait --namespace kube-system \
  --for=condition=complete job \
  --selector=helmcharts.helm.cattle.io/chart=traefik \
  --timeout=300s

echo "**** Sleep for 5 secs"
sleep 5

echo "**** Wait for traefik to be ready"
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=traefik-kube-system \
  --timeout=300s

echo "**** Install local certificate"
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
else
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
          class: traefik
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
docker tag docker.io/nginxdemos/hello:plain-text local.registry:5001/hello:latest
docker push local.registry:5001/hello:latest

echo "**** Test registry - create deployment"
kubectl create deployment hello --image=local.registry:5001/hello:latest

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

if [ "$DOMAIN_NAME" == "example.com" ]; then
  echo "**** Adding hello.$DOMAIN_NAME and dashboard.$DOMAIN_NAME to /etc/hosts"
  if grep -q "dashboard.$DOMAIN_NAME" /etc/hosts; then
      echo "Host entries already exists on /etc/hosts"
  else
    sudo sh -c "echo '127.0.0.1 hello.$DOMAIN_NAME dashboard.$DOMAIN_NAME' >> /etc/hosts"
  fi
fi

echo "**** k3d k8s cluster created"
echo "kubectl cluster-info"
