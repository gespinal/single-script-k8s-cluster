Create and switch to namespace
```
create namespace metallb
kubectl config set-context --current --namespace=metallb
```

Create values.yaml
```
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-ip
  namespace: metallb
spec:
  ipAddressPools:
  - default-pool
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb
spec:
  addresses:
  - 172.18.18.150-172.18.18.200
```

Add the helm repo
```
helm repo add metallb https://metallb.github.io/metallb
```

Install metallb
```
helm install metallb metallb/metallb -f values.yaml
```
