# Elasticsearch on GKE

Deploy any supported version of Elasticsearch on GKE using [ECK (Elastic Cloud on Kubernetes)](https://www.elastic.co/guide/en/cloud-on-k8s/current/index.html). Each deployment gets its own VPC for network isolation, making it safe for multiple users to share a single GCP project.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated to your GCP project
- `kubectl`

## Quick Start

```bash
cd terraform
terraform init

terraform apply -var="project_id=YOUR_PROJECT" -var="name_prefix=es-tony"
```

After apply, configure kubectl and retrieve credentials:

```bash
# Connect to the cluster (use cluster_name from terraform output)
$(terraform output -raw kubeconfig_command)

# Get elastic user password
ES_PASSWORD=$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Get external endpoint IP
ES_HOST=$(kubectl get svc es-source-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test connectivity (self-signed TLS)
curl -k -u elastic:$ES_PASSWORD https://$ES_HOST:9200
```

## Tear Down

```bash
cd terraform
terraform destroy
```

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | GCP project ID | (required) |
| `name_prefix` | Prefix for resource names (e.g., your name) | `es` |
| `elasticsearch_version` | Elasticsearch version to deploy | `8.17.0` |
| `eck_version` | ECK operator Helm chart version | `2.14.0` |
| `region` | GCP region | `us-central1` |
| `zone` | GCP zone (set to `null` for regional HA) | `us-central1-c` |
| `machine_type` | GKE node machine type | `e2-standard-4` |
| `node_count` | Number of GKE nodes | `3` |
| `disk_size_gb` | Boot disk size per node | `50` |
| `allowed_cidrs` | CIDRs allowed to reach the LoadBalancer | `["0.0.0.0/0"]` |

## Architecture

```
Terraform
  ├── VPC + Subnet (per-deployment isolation)
  ├── GKE Cluster + Node Pool
  ├── Helm: ECK Operator
  └── Helm: Local chart (charts/elasticsearch/)
        └── Elasticsearch CR → ECK reconciles pods
              └── LoadBalancer Service (CIDR-restricted, TLS enabled)
```

## Security Notes

- TLS is enabled (ECK default self-signed certs) on the HTTP layer.
- Use `curl -k` or extract the CA from the `es-source-es-http-certs-public` secret.
- Restrict `allowed_cidrs` to known IPs for non-ephemeral deployments.
- `storage-rw` OAuth scope on nodes enables GCS snapshot repositories.
