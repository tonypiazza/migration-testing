# Private-Networking Improvements for migration-testing — Design

**Date:** 2026-06-29
**Status:** Approved (brainstorming) → ready for implementation plan
**Context:** Companion to the consumer-side work in `opensearch-migrations`
(`feature/gcp-private-connectivity`), which taught the Migration Assistant to consume a
PSC service-attachment by hostname over TLS (`dns_name` → private Cloud DNS zone). This
spec improves the **producer** side (`migration-testing`) so self-managed source/target
clusters meet that consumer cleanly.

## Repositories

| Repo | Role |
|------|------|
| `migration-testing` (this repo, private) | PSC **producer**: stands up ES/OS GKE clusters that publish a `ServiceAttachment` |
| `opensearch-migrations` (public) | PSC **consumer**: Migration Assistant; reaches producers by `service_attachment` + `dns_name` |

The two repos hand off through data, not shared code: the producer's service-attachment
URI feeds the consumer's `target_connectivity.service_attachment` / `source_connectivity.service_attachment`,
and the producer's cert hostname feeds the consumer's `dns_name`.

## Scope

Four small, related changes applied **symmetrically to both producers** —
`sources/gcp/elasticsearch-gke` and `targets/gcp/opensearch-gke` — in one combined effort.

## Affected files

| File | Change |
|------|--------|
| `sources/gcp/elasticsearch-gke/terraform/variables.tf` | Add `psc_dns_name`, `connection_limit`, `psc_nat_cidr` vars |
| `sources/gcp/elasticsearch-gke/terraform/main.tf` | Thread new vars into Helm `set`; standardize PSC subnet/natSubnet to self-links; add ServiceAttachment data lookup |
| `sources/gcp/elasticsearch-gke/terraform/outputs.tf` | Add `psc_service_attachment` output |
| `sources/gcp/elasticsearch-gke/charts/elasticsearch/values.yaml` | Add `http.psc.dnsName`, `http.psc.connectionLimit` keys |
| `sources/gcp/elasticsearch-gke/charts/elasticsearch/templates/elasticsearch.yaml` | Add `subjectAltNames` to HTTP self-signed cert; use `connectionLimit` |
| `targets/gcp/opensearch-gke/terraform/variables.tf` | Add `psc_dns_name`, `connection_limit`, `psc_nat_cidr` vars |
| `targets/gcp/opensearch-gke/terraform/main.tf` | Thread new vars into Helm `set`; (already self-links) keep; add ServiceAttachment data lookup |
| `targets/gcp/opensearch-gke/terraform/outputs.tf` | Add `psc_service_attachment` output |
| `targets/gcp/opensearch-gke/charts/opensearch/values.yaml` | Add `http.psc.dnsName`, `http.psc.connectionLimit` keys |
| `targets/gcp/opensearch-gke/charts/opensearch/templates/opensearch-cluster.yaml` | Set `tls.http.customFQDN`; use `connectionLimit` |
| `README.md` | Document TLS hostname; add producer-output → consumer-variable mapping table |

## Component 1 — TLS hostname/SAN support

**What:** Add an optional `psc_dns_name` variable (default `""`) to both producers. When
set, the operator-generated HTTP cert includes that hostname as a Subject Alternative Name:

- **OpenSearch** (`opensearch-cluster.yaml`): set `spec.security.tls.http.customFQDN: <hostname>`.
  The opensearch-k8s-operator adds it to the generated cert's SANs alongside the default
  cluster DNS names. (Verified: `TlsConfigHttp.CustomFQDN`, json `customFQDN`.)
- **Elasticsearch / ECK** (`elasticsearch.yaml`): add
  `spec.http.tls.selfSignedCertificate.subjectAltNames: [{ dns: <hostname> }]`.

**Why:** The producer-side mirror of the consumer's `dns_name`. With it, a self-managed
cluster presents a cert matching the hostname the consumer's private DNS zone resolves to,
so self-managed source→target tests get the same TLS-clean hostname path that Aiven gets.
Without it, self-managed connections are stuck on IP + relaxed TLS verification.

**Interface:**
- New tf var `psc_dns_name` (string, default `""`). Only meaningful with `enable_psc = true`;
  harmless otherwise. Threaded via the existing Helm `set` blocks into a new chart value
  `http.psc.dnsName`.
- The chart templates apply the SAN only when the value is non-empty (so default behavior
  is unchanged — operator generates its normal cert).

**Backward compatibility:** default `""` → templates emit no `customFQDN` / `subjectAltNames`,
identical to today.

## Component 2 — PSC wiring consistency fix

**What:** The two producers currently pass different forms for the same Helm inputs:
- `opensearch-gke`: `http.psc.subnet = subnet_self_link`, `http.psc.natSubnet = psc_subnet.self_link`
- `elasticsearch-gke`: `http.psc.subnet = subnet_name`, `http.psc.natSubnet = psc_subnet.id`

Standardize **both** on self-links (the form the GKE internal-LB subnet annotation and
`ServiceAttachment.natSubnets` expect). Update `elasticsearch-gke/terraform/main.tf` to use
`module.cluster.subnet_self_link` and `google_compute_subnetwork.psc[0].self_link`.

**Why:** Removes a latent correctness/consistency hazard; makes the two configs diffable
and behave identically.

## Component 3 — Service-attachment URI as a Terraform output

**What:** Add a `psc_service_attachment` output to both producers. Resolve it via a
`kubernetes_manifest`/`kubernetes_resource` data source reading the GKE `ServiceAttachment`
status field (`status.serviceAttachmentURL`), gated on `enable_psc`. Output `""` (or null)
when PSC is disabled.

**Why:** Today the URI is only obtainable by running `cluster.sh info` (which does a live
`kubectl get serviceattachment`). A first-class Terraform output composes directly with the
consumer's `service_attachment` variable, so the two repos hand off through declared outputs.

**Note:** the GKE controller populates `serviceAttachmentURL` asynchronously after apply, so
the output may be empty on the first apply and populate on a subsequent refresh. Document
this; `cluster.sh` already polls for it via `wait_for_psc_uri`.

## Component 4 — README + knob polish

- **README:** add a short "Connecting to the Migration Assistant" subsection that (a) notes
  the TLS-hostname behavior now solved by `psc_dns_name`, and (b) maps producer outputs to
  consumer variables:

  | Producer output | Consumer variable |
  |-----------------|-------------------|
  | `psc_service_attachment` | `*_connectivity.service_attachment` |
  | `psc_dns_name` (the value you set) | `*_connectivity.dns_name` |
  | `vpc_network_self_link` | reciprocal `*_connectivity.peer_vpc_self_link` (VPC peering) |

- **Knobs:** expose two currently-hardcoded values as variables with current defaults:
  - `connection_limit` (default `10`) → chart `http.psc.connectionLimit` → `consumerAllowList[].connectionLimit`.
  - `psc_nat_cidr` (default `"10.100.0.0/24"`) → the `google_compute_subnetwork.psc` range.

## Out of scope

- Bring-your-own-cert (custom cert secret / `generate:false`) — overkill for a test harness.
- Any change to the consumer repo (`opensearch-migrations`) — done separately.
- Auto-creating the consumer-side DNS or approving connections — that's the consumer/runbook.

## Success criteria

- Both producers accept `psc_dns_name`; when set with `enable_psc = true`, the generated
  HTTP cert carries that hostname as a SAN (verifiable by inspecting the rendered manifest /
  the served cert).
- Both producers pass identical-form (self-link) PSC subnet/natSubnet inputs.
- Both producers expose `psc_service_attachment` and the two new knobs; defaults preserve
  current behavior.
- README documents the producer→consumer handoff.
- `terraform validate` / `helm template` succeed for both configs with and without the new
  vars set.
