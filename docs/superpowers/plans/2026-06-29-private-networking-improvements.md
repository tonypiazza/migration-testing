# Private-Networking Improvements (migration-testing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the self-managed PSC producers (`elasticsearch-gke`, `opensearch-gke`) meet the Migration Assistant consumer cleanly — TLS-clean hostnames, consistent PSC wiring, a first-class service-attachment output, and documented producer→consumer handoff.

**Architecture:** Both producers are GKE clusters whose Helm charts already publish a GKE `ServiceAttachment` when `enable_psc=true`. We thread a new `psc_dns_name` through Terraform → Helm values → the operator cert config (OpenSearch `tls.http.customFQDN`; ECK `http.tls.selfSignedCertificate.subjectAltNames`) so the served cert carries that hostname as a SAN. We standardize the PSC subnet/natSubnet Helm inputs to self-links, surface the attachment URI as a `psc_service_attachment` Terraform output, expose two hardcoded knobs as variables, and document the handoff.

**Tech Stack:** Terraform/OpenTofu (`hashicorp/google`, `hashicorp/kubernetes ~> 2.25`, `hashicorp/helm`), Helm charts, opensearch-k8s-operator, ECK (Elastic Cloud on Kubernetes).

---

## Conventions for this plan

- **All work is in:** `/Users/tony.piazza/repos/migration-testing` on branch `main` (no feature branch in use for this repo; confirm with `git -C /Users/tony.piazza/repos/migration-testing status -sb`).
- **CLI:** `terraform` is aliased to `tofu` interactively; in non-interactive shells use **`tofu`** directly. `helm` is required for render checks.
- **Do NOT run `git commit`.** Stage with `git add` only; the human commits. After each task, report what is staged.
- **Verification without live infra:** chart changes are verified with `helm template ... --set ...` and grep; terraform changes with `tofu validate` (after `tofu init`). No `apply` is run in this plan.
- Default values for every new variable preserve current behavior (empty string / current constant). Confirm "no diff when unset" at each step.

## File structure

| File | Change |
|------|--------|
| `targets/gcp/opensearch-gke/charts/opensearch/values.yaml` | add `http.psc.dnsName: ""`, `http.psc.connectionLimit: 10` |
| `targets/gcp/opensearch-gke/charts/opensearch/templates/opensearch-cluster.yaml` | conditional `tls.http.customFQDN`; use `$.Values.http.psc.connectionLimit` |
| `sources/gcp/elasticsearch-gke/charts/elasticsearch/values.yaml` | add `http.psc.dnsName: ""`, `http.psc.connectionLimit: 10` |
| `sources/gcp/elasticsearch-gke/charts/elasticsearch/templates/elasticsearch.yaml` | conditional `http.tls.selfSignedCertificate.subjectAltNames`; use `$.Values.http.psc.connectionLimit` |
| `targets/gcp/opensearch-gke/terraform/variables.tf` | add `psc_dns_name`, `connection_limit`, `psc_nat_cidr` |
| `targets/gcp/opensearch-gke/terraform/main.tf` | wire new vars into helm `set`; use `psc_nat_cidr`; add `kubernetes_resource` data lookup |
| `targets/gcp/opensearch-gke/terraform/outputs.tf` | add `psc_service_attachment` |
| `sources/gcp/elasticsearch-gke/terraform/variables.tf` | add `psc_dns_name`, `connection_limit`, `psc_nat_cidr` |
| `sources/gcp/elasticsearch-gke/terraform/main.tf` | wire new vars; **fix wiring to self-links**; use `psc_nat_cidr`; add data lookup |
| `sources/gcp/elasticsearch-gke/terraform/outputs.tf` | add `psc_service_attachment` |
| `README.md` | producer→consumer handoff section + mapping table |

---

## Task 1: OpenSearch chart — TLS customFQDN + connectionLimit knob

**Files:**
- Modify: `targets/gcp/opensearch-gke/charts/opensearch/values.yaml`
- Modify: `targets/gcp/opensearch-gke/charts/opensearch/templates/opensearch-cluster.yaml`

- [ ] **Step 1: Add the two new keys to the `http.psc` block in values.yaml**

Change the `psc:` block so it reads:

```yaml
  psc:
    enabled: false
    subnet: ""
    natSubnet: ""
    consumerProjectIds: []
    dnsName: ""
    connectionLimit: 10
```

- [ ] **Step 2: Add conditional `customFQDN` to the http TLS block**

In `opensearch-cluster.yaml`, find:

```yaml
    tls:
      transport:
        generate: true
      http:
        generate: true
```

Replace the `http:` portion with:

```yaml
      http:
        generate: true
        {{- if .Values.http.psc.dnsName }}
        customFQDN: {{ .Values.http.psc.dnsName | quote }}
        {{- end }}
```

- [ ] **Step 3: Use the connectionLimit knob in the ServiceAttachment**

In the same file, find (inside the `consumerAllowList` range — note `.` is the project string here, so the value must be referenced with `$.`):

```yaml
  consumerAllowList:
    {{- range .Values.http.psc.consumerProjectIds }}
    - project: {{ . }}
      connectionLimit: 10
    {{- end }}
```

Replace `connectionLimit: 10` with `connectionLimit: {{ $.Values.http.psc.connectionLimit }}`.

- [ ] **Step 4: Render-check — SAN present when dnsName set**

Run:
```bash
cd /Users/tony.piazza/repos/migration-testing
helm template os targets/gcp/opensearch-gke/charts/opensearch \
  --set http.psc.enabled=true \
  --set http.psc.dnsName=os-target.example.com \
  --set http.psc.connectionLimit=5 \
  --set 'http.psc.consumerProjectIds={proj-a}'
```
Expected: output contains `customFQDN: "os-target.example.com"` and `connectionLimit: 5`.

- [ ] **Step 5: Render-check — no SAN, default limit when unset (backward compat)**

Run:
```bash
helm template os targets/gcp/opensearch-gke/charts/opensearch \
  --set http.psc.enabled=true \
  --set 'http.psc.consumerProjectIds={proj-a}'
```
Expected: output contains NO `customFQDN` line, and `connectionLimit: 10`.

- [ ] **Step 6: Stage**

```bash
git add targets/gcp/opensearch-gke/charts/opensearch/values.yaml targets/gcp/opensearch-gke/charts/opensearch/templates/opensearch-cluster.yaml
```
Report staged files; do not commit.

---

## Task 2: Elasticsearch chart — TLS subjectAltNames + connectionLimit knob

**Files:**
- Modify: `sources/gcp/elasticsearch-gke/charts/elasticsearch/values.yaml`
- Modify: `sources/gcp/elasticsearch-gke/charts/elasticsearch/templates/elasticsearch.yaml`

- [ ] **Step 1: Add the two new keys to the `http.psc` block in values.yaml**

Change the `psc:` block so it reads:

```yaml
  psc:
    enabled: false
    subnet: ""
    natSubnet: ""
    consumerProjectIds: []
    dnsName: ""
    connectionLimit: 10
```

- [ ] **Step 2: Add conditional `subjectAltNames` under `spec.http`**

In `elasticsearch.yaml`, find:

```yaml
spec:
  version: {{ .Values.version }}
  http:
    service:
```

Insert a `tls` block between `http:` and `service:` so it reads:

```yaml
spec:
  version: {{ .Values.version }}
  http:
    {{- if .Values.http.psc.dnsName }}
    tls:
      selfSignedCertificate:
        subjectAltNames:
        - dns: {{ .Values.http.psc.dnsName | quote }}
    {{- end }}
    service:
```

- [ ] **Step 3: Use the connectionLimit knob in the ServiceAttachment**

Find (inside the `consumerAllowList` range):

```yaml
  consumerAllowList:
    {{- range .Values.http.psc.consumerProjectIds }}
    - project: {{ . }}
      connectionLimit: 10
    {{- end }}
```

Replace `connectionLimit: 10` with `connectionLimit: {{ $.Values.http.psc.connectionLimit }}`.

- [ ] **Step 4: Render-check — SAN present when dnsName set**

Run:
```bash
cd /Users/tony.piazza/repos/migration-testing
helm template es sources/gcp/elasticsearch-gke/charts/elasticsearch \
  --set http.psc.enabled=true \
  --set http.psc.dnsName=es-source.example.com \
  --set http.psc.connectionLimit=5 \
  --set 'http.psc.consumerProjectIds={proj-a}'
```
Expected: output contains `subjectAltNames:` with `- dns: "es-source.example.com"`, and `connectionLimit: 5`. Confirm the `tls:` block renders as valid YAML nested under `http:` (correct indentation, appears before `service:`).

- [ ] **Step 5: Render-check — no SAN, default limit when unset**

Run:
```bash
helm template es sources/gcp/elasticsearch-gke/charts/elasticsearch \
  --set http.psc.enabled=true \
  --set 'http.psc.consumerProjectIds={proj-a}'
```
Expected: NO `subjectAltNames` / `selfSignedCertificate` lines; `connectionLimit: 10`.

- [ ] **Step 6: Stage**

```bash
git add sources/gcp/elasticsearch-gke/charts/elasticsearch/values.yaml sources/gcp/elasticsearch-gke/charts/elasticsearch/templates/elasticsearch.yaml
```
Report staged files; do not commit.

---

## Task 3: OpenSearch terraform — vars, helm wiring, NAT CIDR, attachment output

**Files:**
- Modify: `targets/gcp/opensearch-gke/terraform/variables.tf`
- Modify: `targets/gcp/opensearch-gke/terraform/main.tf`
- Modify: `targets/gcp/opensearch-gke/terraform/outputs.tf`

- [ ] **Step 1: Add three variables**

Append to `variables.tf`:

```hcl
variable "psc_dns_name" {
  description = "Optional hostname to add as a SAN on the OpenSearch HTTP cert (so a PSC consumer can connect by hostname with valid TLS). Only meaningful with enable_psc = true; empty leaves the operator's default cert unchanged."
  type        = string
  default     = ""
}

variable "connection_limit" {
  description = "Per-consumer-project connection limit on the PSC service attachment."
  type        = number
  default     = 10
}

variable "psc_nat_cidr" {
  description = "IP range for the PSC NAT subnet (PRIVATE_SERVICE_CONNECT purpose)."
  type        = string
  default     = "10.100.0.0/24"
}
```

- [ ] **Step 2: Use `psc_nat_cidr` for the PSC subnet**

In `main.tf`, in `resource "google_compute_subnetwork" "psc"`, change:

```hcl
  ip_cidr_range = "10.100.0.0/24"
```
to
```hcl
  ip_cidr_range = var.psc_nat_cidr
```

- [ ] **Step 3: Wire the new values into the opensearch helm_release**

In the `helm_release "opensearch"` resource, after the existing `http.psc.consumerProjectIds` `set` block, add two more `set` blocks:

```hcl
  set {
    name  = "http.psc.dnsName"
    value = var.psc_dns_name
  }

  set {
    name  = "http.psc.connectionLimit"
    value = var.connection_limit
  }
```

- [ ] **Step 4: Add the ServiceAttachment data lookup**

In `main.tf`, after the `helm_release "opensearch"` resource, add:

```hcl
# Reads the PSC ServiceAttachment URI the GKE controller publishes (populated
# asynchronously after the internal LB is provisioned; may be empty on first apply).
data "kubernetes_resource" "psc_attachment" {
  count       = var.enable_psc ? 1 : 0
  api_version = "networking.gke.io/v1"
  kind        = "ServiceAttachment"

  metadata {
    name      = "os-target-psc"
    namespace = "default"
  }

  depends_on = [helm_release.opensearch]
}
```

- [ ] **Step 5: Add the `psc_service_attachment` output**

Append to `outputs.tf`:

```hcl
output "psc_service_attachment" {
  description = "PSC service-attachment URI to give the migration consumer as target_connectivity.service_attachment. Empty until the GKE controller publishes it (and when enable_psc = false)."
  value       = var.enable_psc ? try(data.kubernetes_resource.psc_attachment[0].object.status.serviceAttachmentURL, "") : ""
}
```

- [ ] **Step 6: Validate**

```bash
cd /Users/tony.piazza/repos/migration-testing/targets/gcp/opensearch-gke/terraform
tofu init -backend=false && tofu validate
```
Expected: "Success! The configuration is valid."

- [ ] **Step 7: Stage**

```bash
cd /Users/tony.piazza/repos/migration-testing
git add targets/gcp/opensearch-gke/terraform/variables.tf targets/gcp/opensearch-gke/terraform/main.tf targets/gcp/opensearch-gke/terraform/outputs.tf
```
Report staged files; do not commit.

---

## Task 4: Elasticsearch terraform — vars, helm wiring, **self-link fix**, NAT CIDR, output

**Files:**
- Modify: `sources/gcp/elasticsearch-gke/terraform/variables.tf`
- Modify: `sources/gcp/elasticsearch-gke/terraform/main.tf`
- Modify: `sources/gcp/elasticsearch-gke/terraform/outputs.tf`

- [ ] **Step 1: Add three variables**

Append to `variables.tf` (identical to Task 3 Step 1 but ES wording):

```hcl
variable "psc_dns_name" {
  description = "Optional hostname to add as a SAN on the Elasticsearch HTTP cert (so a PSC consumer can connect by hostname with valid TLS). Only meaningful with enable_psc = true; empty leaves the operator's default cert unchanged."
  type        = string
  default     = ""
}

variable "connection_limit" {
  description = "Per-consumer-project connection limit on the PSC service attachment."
  type        = number
  default     = 10
}

variable "psc_nat_cidr" {
  description = "IP range for the PSC NAT subnet (PRIVATE_SERVICE_CONNECT purpose)."
  type        = string
  default     = "10.100.0.0/24"
}
```

- [ ] **Step 2: Fix the PSC wiring to self-links (consistency with opensearch-gke)**

In `main.tf`, in the `helm_release "elasticsearch"` resource, change the two PSC `set` blocks:

```hcl
  set {
    name  = "http.psc.subnet"
    value = var.enable_psc ? module.cluster.subnet_name : ""
  }

  set {
    name  = "http.psc.natSubnet"
    value = var.enable_psc ? google_compute_subnetwork.psc[0].id : ""
  }
```
to:
```hcl
  set {
    name  = "http.psc.subnet"
    value = var.enable_psc ? module.cluster.subnet_self_link : ""
  }

  set {
    name  = "http.psc.natSubnet"
    value = var.enable_psc ? google_compute_subnetwork.psc[0].self_link : ""
  }
```

- [ ] **Step 3: Use `psc_nat_cidr` for the PSC subnet**

In `resource "google_compute_subnetwork" "psc"`, change `ip_cidr_range = "10.100.0.0/24"` to `ip_cidr_range = var.psc_nat_cidr`.

- [ ] **Step 4: Wire the new values into the elasticsearch helm_release**

After the existing `http.psc.consumerProjectIds` `set` block, add:

```hcl
  set {
    name  = "http.psc.dnsName"
    value = var.psc_dns_name
  }

  set {
    name  = "http.psc.connectionLimit"
    value = var.connection_limit
  }
```

- [ ] **Step 5: Add the ServiceAttachment data lookup**

After the `helm_release "elasticsearch"` resource, add:

```hcl
# Reads the PSC ServiceAttachment URI the GKE controller publishes (populated
# asynchronously after the internal LB is provisioned; may be empty on first apply).
data "kubernetes_resource" "psc_attachment" {
  count       = var.enable_psc ? 1 : 0
  api_version = "networking.gke.io/v1"
  kind        = "ServiceAttachment"

  metadata {
    name      = "es-source-psc"
    namespace = "default"
  }

  depends_on = [helm_release.elasticsearch]
}
```

- [ ] **Step 6: Add the `psc_service_attachment` output**

Append to `outputs.tf`:

```hcl
output "psc_service_attachment" {
  description = "PSC service-attachment URI to give the migration consumer as source_connectivity.service_attachment. Empty until the GKE controller publishes it (and when enable_psc = false)."
  value       = var.enable_psc ? try(data.kubernetes_resource.psc_attachment[0].object.status.serviceAttachmentURL, "") : ""
}
```

- [ ] **Step 7: Validate**

```bash
cd /Users/tony.piazza/repos/migration-testing/sources/gcp/elasticsearch-gke/terraform
tofu init -backend=false && tofu validate
```
Expected: "Success! The configuration is valid."

- [ ] **Step 8: Stage**

```bash
cd /Users/tony.piazza/repos/migration-testing
git add sources/gcp/elasticsearch-gke/terraform/variables.tf sources/gcp/elasticsearch-gke/terraform/main.tf sources/gcp/elasticsearch-gke/terraform/outputs.tf
```
Report staged files; do not commit.

---

## Task 5: README — producer→consumer handoff

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a handoff subsection under the "Private Networking (GCP)" section**

After the existing "Private Service Connect" subsection, add:

```markdown
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

> `psc_service_attachment` is published asynchronously by GKE; it may be empty immediately
> after apply and populate on a later `terraform refresh`. `cluster.sh info` polls for it.
```

- [ ] **Step 2: Verify markdown**

Run: `grep -n "Connecting to the Migration Assistant" README.md`
Expected: one match. Visually confirm the table renders and the surrounding sections are intact.

- [ ] **Step 3: Stage**

```bash
git add README.md
```
Report staged file; do not commit.

---

## Final verification (after all tasks)

- [ ] **Both charts render with SAN when dnsName set:**
  ```bash
  cd /Users/tony.piazza/repos/migration-testing
  helm template os targets/gcp/opensearch-gke/charts/opensearch --set http.psc.enabled=true --set http.psc.dnsName=h.example.com --set 'http.psc.consumerProjectIds={p}' | grep -E "customFQDN|connectionLimit"
  helm template es sources/gcp/elasticsearch-gke/charts/elasticsearch --set http.psc.enabled=true --set http.psc.dnsName=h.example.com --set 'http.psc.consumerProjectIds={p}' | grep -E "subjectAltNames|dns:|connectionLimit"
  ```
  Expected: customFQDN/subjectAltNames present; connectionLimit shown.

- [ ] **Both charts render unchanged when dnsName unset** (diff against current behavior — no SAN lines, connectionLimit 10).

- [ ] **Both terraform configs validate:**
  ```bash
  (cd targets/gcp/opensearch-gke/terraform && tofu init -backend=false >/dev/null && tofu validate)
  (cd sources/gcp/elasticsearch-gke/terraform && tofu init -backend=false >/dev/null && tofu validate)
  ```
  Expected: both "Success! The configuration is valid."

- [ ] **Wiring symmetry:** confirm both producers now pass `subnet_self_link` and `psc[0].self_link` for `http.psc.subnet` / `http.psc.natSubnet`:
  ```bash
  grep -n "http.psc.subnet\|http.psc.natSubnet" -A1 targets/gcp/opensearch-gke/terraform/main.tf sources/gcp/elasticsearch-gke/terraform/main.tf
  ```
  Expected: both use `subnet_self_link` and `self_link`.
