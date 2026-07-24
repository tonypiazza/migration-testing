# migration-testing

Provision throwaway Elasticsearch (source) and OpenSearch (target) clusters on Kubernetes
for testing search-cluster migrations. A single script, `cluster.sh`, wraps Terraform/OpenTofu
and Helm to bring clusters up, print their connection details, and tear them down.

## What's here

| Path | Purpose |
|------|---------|
| `cluster.sh` | Entry point: `up` / `down` / `info` / `specs` for any config |
| `sources/<platform>/<name>/` | Source-cluster configs (e.g. Elasticsearch on GKE) |
| `targets/<platform>/<name>/` | Target-cluster configs (e.g. OpenSearch on GKE) |
| `modules/` | Shared Terraform modules (GKE cluster, snapshot repo) |

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install) or [Terraform](https://www.terraform.io/downloads)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- **For GCP configs:** the [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated with
  Application Default Credentials:
  ```bash
  gcloud auth application-default login
  ```
  You also need a GCP project you can create GKE clusters in, and (for snapshots) a
  pre-existing storage bucket. The examples below use the project and bucket baked into the
  config defaults; override them via `terraform.tfvars` for your own environment.

## Quick start

```bash
# 1. Bring up a source cluster (Elasticsearch on GKE)
./cluster.sh up sources/gcp/elasticsearch-gke

# 2. Bring up a target cluster (OpenSearch on GKE)
./cluster.sh up targets/gcp/opensearch-gke

# 3. Re-print connection details any time
./cluster.sh info sources/gcp/elasticsearch-gke

# 4. Tear everything down when finished
./cluster.sh down sources/gcp/elasticsearch-gke
./cluster.sh down targets/gcp/opensearch-gke
```

`up` prints a summary box with the cluster's address, username, and password once the
workload is ready.

## Commands

Run `./cluster.sh` with no arguments to list available config paths.

| Command | Description |
|---------|-------------|
| `./cluster.sh up <path>` | Create the cluster |
| `./cluster.sh up <path> --private-networking` | Create it with private networking (see below) |
| `./cluster.sh down <path>` | Destroy the cluster |
| `./cluster.sh info <path>` | Re-print connection details for a running cluster |
| `./cluster.sh specs <path>` | Print effective specs without a running cluster |

## Configs

Each config under `sources/` or `targets/` is self-contained: a `terraform/` directory that
provisions the cluster and its workload (via the Helm provider), and a `charts/` directory
with the workload's Helm chart. `cluster.sh` is a thin wrapper:

- **up** runs `tofu init` + `tofu apply`, connects with the platform CLI, and reads the
  workload's address and credentials.
- **down** removes the kubectl context and runs `tofu destroy`.
- **info** connects and prints details without changing anything.
- **specs** reads effective variable values only — no cluster or credentials required.

Shared modules keep configs DRY: `modules/gke-cluster` provisions the GKE VPC/cluster/node
pool, and `modules/snapshot-repo` registers a snapshot repository (GCS or S3) from inside
the cluster.

## Private networking

By default clusters are reachable over a public LoadBalancer. Pass `--private-networking`
to expose the cluster privately instead (on GCP, via Private Service Connect): the workload
is fronted by an internal load balancer and a service attachment rather than a public IP.
After apply, `cluster.sh` prints the private service-attachment identifier alongside the
usual details.

See each config's `terraform.tfvars.example` for the private-networking variables.

## Troubleshooting

- **`tofu`/`terraform` finds no state:** state is stored per-config under
  `<path>/terraform/`. Always operate through `cluster.sh` (which passes `-chdir`), not by
  running `tofu` at the repo root.
- **`info` didn't print the summary box right after `up`:** the kubectl context can be cold
  immediately after apply. Re-run `./cluster.sh info <path>` after a few seconds.
- **Address looks like a hostname, not an IP:** AWS load balancers expose a DNS hostname
  while GCP exposes an IP. Both are correct — connect to whichever is printed.
- **An `apply` stalls when running several clusters at once:** check your cloud quota
  (in-use IP addresses, CPUs, firewall rules) before suspecting a config error.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new source/target config, repo
conventions, and local checks. Licensed under [Apache-2.0](LICENSE).
