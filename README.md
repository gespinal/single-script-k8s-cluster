## Single script kind Kubernetes cluster -- Running on Docker

Just run `./install_kind_kubernetes_cluster.sh` and the script will create a single node k8s cluster for your local tests.

Can easily be modified to run as a multi-node cluster.

*This is a powerful, compact, practical and simple solution to anyone that needs a totally functional k8s cluster on the fly.*

### Requires:

- Docker service running

### What does this create:

- Single node kind k8s cluster running on docker containers
- Insecure docker registry running on `http://localhost:5001`
- Dashboard running on `https://dashboard.example.com`
- Hello world deployment running on `https://hello.example.com`

### Notes:

- If ran multiple times it will delete the old cluster and re-create a new one.
- Default cluster name is `kind-kind`, but can be customized updating the `${CLUSTER_NAME}` variable on line 10 of the script.

### Multi-node cluster

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

### Certificate validation

In order to get rid of the `certificate not trusted` error for your ingress and test URLs, this artifact is using https://github.com/gespinal/ssl-wildcard-certificate-self-ca to generate and install a wildcard certificate for the domain `*.example.com`.
