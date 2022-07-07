#!/bin/bash

# kind K8s Cluster

echo "**** Deleting old cluster, if it already exists"
kind delete cluster 2> /dev/null

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
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
EOF

# Set cluster to never auto-start
echo "**** Update restart policy"
docker update --restart=no kind-control-plane

echo "**** Check nodes"
kubectl get nodes

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

echo "**** Wait 20 secs"
sleep 20

echo "**** Wait for ingress controller to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

echo "**** Clonning certificate repo"
git clone git@github.com:gespinal/ssl-wildcard-certificate-self-ca.git

echo "**** Creating certificate for example.com domain"
cd ssl-wildcard-certificate-self-ca
./create_certificate.sh example.com
cd ../

echo "**** Create certificate secret"
kubectl delete secret example 2>/dev/null
kubectl create secret generic example \
  --from-file=tls.crt=./ssl-wildcard-certificate-self-ca/certs/example.com-CERT.pem \
  --from-file=tls.key=./ssl-wildcard-certificate-self-ca/certs/example.com.key
  
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
  selector:
    app: hello
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF

echo "**** Create hello ingress"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
spec:
  rules:
    - host: hello.example.com
      http:
        paths:
          - pathType: ImplementationSpecific
            backend:
              service:
                name: hello 
                port:
                  number: 80
  tls:
  - hosts:
    - hello.example.com
    secretName: example
EOF

# Waiting
echo "**** Wait 20 secs"
sleep 20

echo "**** Get Ingress IP from host"
CONTROL_PLANE_IP=$(docker container inspect ${CLUSTER_NAME}-control-plane --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')

echo "**** Test hello service"
docker run \
  --add-host hello.example.com:${CONTROL_PLANE_IP} \
  --net kind --rm curlimages/curl:latest hello.example.com

echo "**** Install dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc6/aio/deploy/recommended.yaml

echo "**** Check dashboard"
kubectl get all -n kubernetes-dashboard

echo "**** Create dashboard service account"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin
  namespace: kubernetes-dashboard
EOF

echo "**** Create dashboard rolebinding"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin
  namespace: kubernetes-dashboard
EOF

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
spec:
  tls:
    - hosts:
      - serverdnsname
  rules:
    - host: dashboard.example.com
      http:
        paths:
          - pathType: ImplementationSpecific
            backend:
              service:
                name: kubernetes-dashboard
                port:
                  number: 443
EOF

echo "**** Adding hello.example.com and dashboard.example.com to /etc/hosts"
if grep -q "dashboard.example.com" /etc/hosts; then
    echo "Host entries already exists on /etc/hosts"
else
   sudo sh -c "echo '127.0.0.1 hello.example.com dashboard.example.com' >> /etc/hosts"
fi

# echo "**** Get token for kubernetes-dashboard"
# kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin | awk '{print $1}')

echo "**** Kind k8s cluster created"
echo ""
echo "  kubectl cluster-info --context kind-kind"
