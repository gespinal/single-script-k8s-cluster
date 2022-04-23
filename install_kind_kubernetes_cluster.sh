#!/bin/bash

# Kind K8s Cluster

echo "**** Deleting old cluster"
kind delete cluster 2> /dev/null

# Setting variables
echo "**** Exporting system variables"
export CLUSTER_NAME=kind

echo "**** Setting sysconfig"
sudo sysctl -w net.netfilter.nf_conntrack_max=131072

# Install kubectl
sudo curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl 2> /dev/null && sudo chmod +x /usr/local/bin/kubectl

# Install the latest version of KinD
if [[ ! -f /usr/local/bin/kind ]]; then
  echo "**** Installing KinD"
  curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.12.0/kind-linux-amd64
  # Make the binary executable
  chmod +x ./kind
  # Move the binary to your executable path
  sudo mv ./kind /usr/local/bin/
fi

echo "**** Create registry unless it exists"
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

echo "**** Creating new KinD cluster"
kind create cluster --name ${CLUSTER_NAME} --config - << EOF
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

echo "**** Wait"
sleep 20

echo "**** Wait for ingress controller to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s
  
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
EOF

# Waiting
echo "**** Wait"
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

if grep -q "dashboard.example.com" /etc/hosts; then
    echo "dashboard.example.com entry already exists"
else
   sudo sh -c "echo '127.0.0.1 hello.example.com dashboard.example.com' >> /etc/hosts"
fi

echo "**** Get token for kubernetes-dashboard"
kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin | awk '{print $1}')
