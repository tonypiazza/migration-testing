# Contributing

Thanks for improving migration-testing. This repo provisions Elasticsearch (source)
and OpenSearch (target) clusters for migration testing, driven by `cluster.sh`.

## Local setup

```bash
pre-commit install    # installs the commit hooks (fmt, shellcheck, hygiene)
```

Required tools: `tofu` (or `terraform`), `kubectl`, `helm`, and the cloud CLI for your
platform (`gcloud` for GCP). See the README for install links.

## Adding a new source or target config

Configs live under `sources/<platform>/<name>/` or `targets/<platform>/<name>/`, each with:

```
terraform/   # main.tf, variables.tf, versions.tf, outputs.tf, terraform.tfvars.example
charts/      # Helm chart for the workload (Elasticsearch/OpenSearch)
```

1. Call the shared `modules/gke-cluster` module for GKE-based configs (it provisions the
   VPC, subnet, cluster, and node pool). Register the snapshot repository via the shared
   `modules/snapshot-repo` module.
2. Provide these Terraform outputs — `cluster.sh` depends on them:
   - `software` (e.g. `"Elasticsearch v8.19.15"`)
   - `cluster_name`, `location`, `project_id` (GCP)
   - `psc_enabled` (bool)
   - `cluster_password` when the password is Terraform-managed (otherwise `cluster.sh`
     reads it from the workload's Kubernetes secret).
3. Extend `cluster.sh`:
   - add a `case` in `print_info` with the kubectl commands to fetch the address and
     credentials for your workload;
   - add a `case` in `do_specs` for the software label/version.
4. Add a `terraform.tfvars.example` documenting the config's variables.

## Conventions

- **Never commit `terraform.tfvars`** — it is gitignored and may hold environment specifics.
- **Keep source/target configs diffable** — mirror structure across platforms so differences
  are meaningful, not incidental.
- **Runtime cluster reads belong in `cluster.sh`**, not in Terraform Kubernetes data sources.
  Terraform provisions infra and Helm releases; the script reads live state (IPs, passwords)
  after connecting. This keeps kubectl concerns out of Terraform.
- **Formatting:** run `tofu fmt` (the pre-commit hook enforces it).

## Before you push

The pre-commit hooks run `terraform fmt`, `shellcheck`, and basic hygiene automatically.
`terraform validate` is NOT a hook (it needs each config initialized). Run it manually for
any config you changed:

```bash
tofu -chdir=<path>/terraform init -backend=false
tofu -chdir=<path>/terraform validate
```
