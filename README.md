# Single script Kubernetes cluster (Runs on Docker)

### K3d
```
./install_k3d_kubernetes_cluster.sh
```

### Kind
```
./install_kind_kubernetes_cluster.sh
```

### Requirements

- Docker service running

## How to

### For local tests

The script will create a single node k8s cluster for your local tests

```
./install_k3d_kubernetes_cluster.sh example.com
```

### If you have a `domain_name` you can run with Let's Encrypt SSL

The script will create a single node k8s cluster for your tests using Let's Encrypt certificates

```
# Use second parameter for let's encrypt staging and prd
./install_k3d_kubernetes_cluster.sh domain_name [stg|[prd]] ex@email.com
```

Note: email address must be valid.

### When running on local for `example.com` it creates...

- Single node kind k8s cluster running on docker containers
- Insecure docker registry running on `http://local.registry:5001`
- Dashboard running on `https://dashboard.example.com`
- Hello world deployment running on `https://hello.example.com`

### Kind mlti-node cluster

To change the configuration from single to multi-node k8s cluster, just add workers as you need around line 55-57.

Example on how to add two workers:

```
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  ...
  - role: worker
  - role: worker
```

### Certificate validation (for local `example.com`)

In order to get rid of the `certificate not trusted` error for your ingress and test URLs, this artifact is using https://github.com/gespinal/ssl-wildcard-certificate-self-ca to generate and install a wildcard certificate for the domain `*.example.com`.

I recommend using Edge or Safari to test certificate. Firefox gives some trouble with CACHE and cert validation when re-created. Haven't tested this on Chrome.

In case of Firefox:

Go to: about:config

Set: security.enterprise_roots.enabled to true

### *This is a powerful, compact, practical and simple solution to anyone that needs a totally functional k8s cluster on the fly.*
