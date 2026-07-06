# migration-testing

Spin up and tear down Elasticsearch (source) and OpenSearch (target) clusters for testing migration scenarios.

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) with Application Default Credentials configured (`gcloud auth application-default login`)
- [terraform](https://www.terraform.io/downloads) or [tofu](https://opentofu.org/docs/intro/install)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Quick Start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` in the config you want to use and set your `project_id`:

```bash
cp sources/gcp/elasticsearch-gke/terraform/terraform.tfvars.example \
   sources/gcp/elasticsearch-gke/terraform/terraform.tfvars
```

2. Spin up a cluster:

```bash
./cluster.sh up sources/gcp/elasticsearch-gke
./cluster.sh up targets/gcp/opensearch-gke
```

3. Use the printed connection details to configure the migration assistant.

4. Tear down when done:

```bash
./cluster.sh down sources/gcp/elasticsearch-gke
./cluster.sh down targets/gcp/opensearch-gke
```

## Commands

Run `./cluster.sh` with no arguments to see all available paths.

| Command | Description |
|---------|-------------|
| `./cluster.sh up <path>` | Create cluster |
| `./cluster.sh up <path> --private-networking` | Create cluster with private networking enabled |
| `./cluster.sh down <path>` | Destroy cluster |
| `./cluster.sh info <path>` | Re-print connection details for a running cluster |
| `./cluster.sh specs <path>` | Print effective cluster specs without a running cluster |

## Private Networking (GCP)

By default clusters use external LoadBalancers reachable over the public internet. Two opt-in modes make migration traffic private:

### Private Service Connect (recommended for GCP-resident sources and targets)

1. Optionally add `psc_consumer_project_ids = ["<migration-project-id>"]` to `terraform.tfvars` to pre-authorize the migration project. If omitted, `cluster.sh` will warn and you can authorize the consumer separately after deploy.
2. Run `./cluster.sh up <config> --private-networking`.
3. After apply, `cluster.sh` prints a `PSC URI` — supply this as `source_connectivity.service_attachment` or `target_connectivity.service_attachment` in the migration console.

The cluster owner must accept the PSC connection from the migration project before the link becomes `ACTIVE`.

### Connecting to the Migration Assistant (PSC)

The Migration Assistant (`opensearch-migrations`, GCP Terraform deployment) is the PSC
**consumer**. After bringing a producer up with `--private-networking`, hand these values
to the consumer's `source_connectivity` / `target_connectivity` config:

| Producer output (this repo) | Consumer variable (opensearch-migrations) |
|-----------------------------|--------------------------------------------|
| `psc_service_attachment`    | `*_connectivity.service_attachment`        |
| the `psc_dns_name` you set  | `*_connectivity.dns_name`                  |
| `vpc_network_self_link`     | `*_connectivity.peer_vpc_self_link` (VPC peering only) |

**TLS by hostname:** set `psc_dns_name` to the hostname the consumer will use. The cluster's
HTTP certificate is then issued with that name as a Subject Alternative Name, so the
consumer (which maps the hostname to the PSC endpoint IP via a private DNS zone) validates
TLS normally. If you leave `psc_dns_name` empty, the consumer must connect by IP with
relaxed TLS verification.

> **Requires OpenSearch operator >= 2.8.0** (the `operator_version` default). 2.8.0 is the
> first release whose CRD defines `tls.http.customFQDN`, the field the OpenSearch chart uses
> to carry `psc_dns_name` into the cert ([opensearch-k8s-operator#1147](https://github.com/opensearch-project/opensearch-k8s-operator/pull/1147)).
> On older operators (e.g. 2.7.0) the Kubernetes API **silently prunes** the field — no error —
> and the served cert carries only the default cluster DNS names, so hostname TLS will fail.
> (The ECK-based ES source uses `subjectAltNames` instead, a long-standing ECK field, so it is
> not subject to this floor.)

> `psc_service_attachment` is published asynchronously by GKE; it may be empty immediately
> after apply and populate on a later `terraform refresh`. `cluster.sh info` polls for it.

### VPC Peering (for self-managed clusters in another GCP VPC)

Set the `vpc_peering` block in `terraform.tfvars`. After apply, the migration cluster must create the reciprocal peering targeting the `vpc_network_self_link` Terraform output. CIDRs must not overlap with `10.0.0.0/20` (nodes), `10.4.0.0/14` (pods), or `10.8.0.0/20` (services).

See `terraform.tfvars.example` in each config for full examples.

## How It Works

`cluster.sh` is a thin wrapper around Terraform. Each config under `sources/` or `targets/` has a `terraform/` directory that provisions everything — GKE cluster, VPC, and workloads (via the Helm provider).

- `up` runs `terraform init` + `terraform apply -auto-approve`, then connects to the cluster via `gcloud` and queries kubectl for the LoadBalancer IP and credentials.
- `down` removes the kubectl context and runs `terraform destroy -auto-approve`.
- `info` connects and prints the cluster details without modifying anything.

A shared module at `modules/gke-cluster/` provides the common GKE infrastructure (VPC, subnet, cluster, node pool). Each config's `main.tf` calls this module and adds its own Helm releases.

## Adding a New Config

1. Create a new directory under `sources/<platform>/` or `targets/<platform>/` (e.g. `targets/gcp/opensearch-aiven/`)
2. Add a `terraform/` directory with `main.tf`, `variables.tf`, `versions.tf`, `outputs.tf`, and `terraform.tfvars.example`
3. Call the shared `modules/gke-cluster` module for GKE-based configs, or write platform-specific infra
4. Add a `software` output (e.g. `"OpenSearch v2.19.0"`) and a `cluster_password` output if the password is managed by Terraform
5. Update the `print_info` case statement in `cluster.sh` with the kubectl commands to retrieve the IP and credentials for your config
