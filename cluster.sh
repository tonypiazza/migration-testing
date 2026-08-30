#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prerequisites() {
  local missing=0

  if command -v terraform >/dev/null 2>&1; then
    TF_CMD="terraform"
  elif command -v tofu >/dev/null 2>&1; then
    TF_CMD="tofu"
  else
    echo "Error: Neither terraform nor tofu CLI found."
    echo "Install terraform from https://www.terraform.io/downloads"
    echo "  or tofu from https://opentofu.org/docs/intro/install"
    missing=1
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Install from https://kubernetes.io/docs/tasks/tools/"
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

# Platform-specific cloud CLI + credentials checks. Called from the actions that touch a
# real cluster (up/info/down) after PLATFORM is known. NOT called by 'specs', which works
# offline with no credentials.
check_cloud_prerequisites() {
  local missing=0
  case "$PLATFORM" in
    gcp)
      if ! command -v gcloud >/dev/null 2>&1; then
        echo "Error: gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
        missing=1
      fi
      if [[ $missing -eq 0 ]] && ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        echo "Error: Application Default Credentials not configured."
        echo "Run: gcloud auth application-default login"
        missing=1
      fi
      ;;
    aws)
      if ! command -v aws >/dev/null 2>&1; then
        echo "Error: aws CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        missing=1
      fi
      if [[ $missing -eq 0 ]] && ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo "Error: AWS credentials not configured or invalid."
        echo "Configure via 'aws configure' or environment variables / SSO."
        missing=1
      fi
      ;;
  esac
  [[ $missing -ne 0 ]] && exit 1
  return 0
}

# Terraform reaches both the GKE and Kubernetes APIs via Application Default Credentials,
# but 'gcloud container clusters get-credentials' and 'gcloud compute' use the separate
# gcloud user credential store. ADC can be valid while the user session has expired, so
# the callers that shell out to gcloud must check for themselves.
check_gcloud_user_auth() {
  local err
  if ! err="$(gcloud auth print-access-token 2>&1 >/dev/null)"; then
    echo "Error: gcloud could not obtain a user access token."
    if [[ "$err" == *"non-interactive"* || "$err" == *Reauth* ]]; then
      echo "Google is requiring re-verification of your session, which needs a terminal"
      echo "to prompt (2FA / security key). Run 'gcloud auth login' interactively, then retry."
    else
      echo "Run: gcloud auth login"
    fi
    echo "(Application Default Credentials are separate and may still be valid.)"
    exit 1
  fi
}

check_prerequisites

TF_VARS=()
if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
  TF_VARS+=(-var "project_id=${GCP_PROJECT_ID}")
fi

usage() {
  echo "Usage: $0 <action> <config-path> [--private-networking]"
  echo ""
  echo "Actions:"
  echo "  up      Create the cluster"
  echo "  down    Destroy the cluster"
  echo "  info    Print connection details for an existing cluster"
  echo "  specs   Print effective cluster specs (no running cluster required)"
  echo ""
  echo "Options:"
  echo "  --private-networking  Enable private networking (PSC on GCP, equivalent on other platforms)"
  echo ""
  echo "Config path: <sources|targets>/<platform>/<config>"
  echo ""
  echo "Examples:"
  echo "  $0 up sources/gcp/elasticsearch-gke"
  echo "  $0 up targets/gcp/opensearch-gke --private-networking"
  echo "  $0 up targets/aws/opensearch-managed"
  echo "  $0 up targets/aws/opensearch-eks"
  echo "  $0 info targets/gcp/opensearch-gke"
  echo "  $0 down sources/gcp/elasticsearch-gke"
  echo ""
  echo "Available source configs:"
  find "${SCRIPT_DIR}/sources" -name "terraform.tfvars.example" 2>/dev/null | while read -r f; do
    dir="$(dirname "$(dirname "$f")")"
    echo "  ${dir#"${SCRIPT_DIR}/"}"
  done
  echo ""
  echo "Available target configs:"
  find "${SCRIPT_DIR}/targets" -name "terraform.tfvars.example" 2>/dev/null | while read -r f; do
    dir="$(dirname "$(dirname "$f")")"
    echo "  ${dir#"${SCRIPT_DIR}/"}"
  done
  echo ""
  exit 1
}

[[ $# -lt 2 ]] && usage

ACTION="$1"
CONFIG_PATH="$2"

PRIVATE_NETWORKING=false
for arg in "${@:3}"; do
  case "$arg" in
    --private-networking) PRIVATE_NETWORKING=true ;;
    *) echo "Error: unknown option: $arg"; usage ;;
  esac
done

if [[ "$PRIVATE_NETWORKING" == "true" ]]; then
  TF_VARS+=(-var "enable_psc=true")
fi
CONFIG_DIR="${SCRIPT_DIR}/${CONFIG_PATH}"
TF_DIR="${CONFIG_DIR}/terraform"
CLUSTER_ROLE="$(echo "$CONFIG_PATH" | cut -d/ -f1)"
PLATFORM="$(echo "$CONFIG_PATH" | cut -d/ -f2)"
CONFIG_NAME="$(echo "$CONFIG_PATH" | cut -d/ -f3)"

# Managed-service configs have no Kubernetes cluster: connect/disconnect are no-ops and
# print_info reads everything from Terraform outputs.
USES_KUBECTL=true
case "$CONFIG_NAME" in
  opensearch-managed) USES_KUBECTL=false ;;
esac

if [[ ! -d "$TF_DIR" ]]; then
  echo "Error: terraform directory not found at ${TF_DIR}"
  exit 1
fi

has_outputs() {
  local json
  json="$($TF_CMD -chdir="$TF_DIR" output -json 2>/dev/null)" || return 1
  [[ -n "$json" && "$json" != "{}" ]]
}

# 'down' must gate on tracked resources, not outputs: a partially-failed destroy leaves
# resources in state while the outputs that depended on them are already gone.
has_state_resources() {
  local n
  n="$($TF_CMD -chdir="$TF_DIR" state list 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]]
}

disconnect() {
  [[ "$USES_KUBECTL" == "true" ]] || return 0
  case "$PLATFORM" in
    gcp)
      local cluster_name location project_id context
      cluster_name="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null)" || return 0
      location="$($TF_CMD -chdir="$TF_DIR" output -raw location 2>/dev/null)" || return 0
      project_id="$($TF_CMD -chdir="$TF_DIR" output -raw project_id 2>/dev/null)" || return 0
      context="gke_${project_id}_${location}_${cluster_name}"
      echo "Removing kubectl context: ${context}"
      kubectl config delete-context "$context" 2>/dev/null || true
      ;;
    aws)
      local cluster_name region context
      cluster_name="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null)" || return 0
      region="$($TF_CMD -chdir="$TF_DIR" output -raw region 2>/dev/null)" || return 0
      context="arn:aws:eks:${region}:*:cluster/${cluster_name}"
      echo "Removing kubectl context: ${context}"
      kubectl config delete-context "$context" 2>/dev/null || true
      ;;
  esac
}

connect() {
  [[ "$USES_KUBECTL" == "true" ]] || return 0
  local cluster_name location
  cluster_name="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_name)"
  location="$($TF_CMD -chdir="$TF_DIR" output -raw location)"

  case "$PLATFORM" in
    gcp)
      local project_id
      check_gcloud_user_auth
      project_id="$($TF_CMD -chdir="$TF_DIR" output -raw project_id)"
      gcloud container clusters get-credentials "$cluster_name" \
        --location "$location" --project "$project_id" --quiet
      ;;
    aws)
      aws eks update-kubeconfig --name "$cluster_name" --region "$location" >/dev/null
      ;;
  esac
}

wait_for_lb_ip() {
  local svc="$1"
  local timeout="${2:-300}"
  local elapsed=0
  local interval=5
  local ip=""

  while [[ $elapsed -lt $timeout ]]; do
    ip="$(kubectl get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    if [[ $elapsed -eq 0 ]]; then
      echo "Waiting for LoadBalancer IP on service ${svc}..." >&2
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "pending"
  return 1
}

wait_for_lb_hostname() {
  local svc="$1"
  local timeout="${2:-300}"
  local elapsed=0
  local interval=5
  local host=""

  while [[ $elapsed -lt $timeout ]]; do
    host="$(kubectl get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$host" ]]; then
      echo "$host"
      return 0
    fi
    if [[ $elapsed -eq 0 ]]; then
      echo "Waiting for LoadBalancer hostname on service ${svc}..." >&2
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "pending"
  return 1
}

wait_for_psc_uri() {
  local attachment_name="$1"
  local timeout="${2:-300}"
  local elapsed=0
  local interval=5
  local uri=""

  while [[ $elapsed -lt $timeout ]]; do
    uri="$(kubectl get serviceattachment "$attachment_name" -o jsonpath='{.status.serviceAttachmentURL}' 2>/dev/null || true)"
    if [[ -n "$uri" ]]; then
      echo "$uri"
      return 0
    fi
    if [[ $elapsed -eq 0 ]]; then
      echo "Waiting for PSC service attachment URI on ${attachment_name}..." >&2
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "pending"
  return 1
}

print_info() {
  # 'output -raw <name>' on a state with no outputs exits 0 and prints a warning banner to
  # stdout, so its exit code cannot be used to detect missing state. '-json' is reliable:
  # it emits '{}' when there are no outputs.
  if ! has_outputs; then
    echo ""
    echo "Cluster not found. No terraform state exists for this config."
    exit 1
  fi

  # Only opensearch-gke can report without a cluster connection (see below); every other
  # config reads the password out of an operator-generated secret via kubectl.
  if [[ "$CONFIG_NAME" != "opensearch-gke" ]]; then
    local connect_err
    connect_err="$(connect 2>&1 >/dev/null)" || {
      echo ""
      # GKE says 'Not found'/'NotFound'; EKS says 'ResourceNotFoundException'/'No cluster named'.
      if [[ "$connect_err" == *NotFound* || "$connect_err" == *"Not found"* || "$connect_err" == *"No cluster named"* ]]; then
        echo "Cluster not found. It may have been torn down."
      else
        echo "Error: could not connect to the cluster."
        echo "$connect_err"
      fi
      exit 1
    }
  fi

  local ip user password

  local psc_uri=""
  case "$CONFIG_NAME" in
    elasticsearch-gke)
      ip="$(wait_for_lb_ip es-source-es-http)" || true
      user="elastic"
      password="$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d)" || password="pending"
      [[ -z "$password" ]] && password="pending"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        psc_uri="$(wait_for_psc_uri es-source-psc)" || true
      fi
      ;;
    opensearch-gke)
      # Both values are already in terraform state (cluster_ip comes from the
      # kubernetes_service data source during apply), so no kubectl context is needed.
      ip="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_ip 2>/dev/null)" || ip="pending"
      [[ -z "$ip" ]] && ip="pending"
      user="admin"
      password="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_password)"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        psc_uri="$($TF_CMD -chdir="$TF_DIR" output -raw psc_service_attachment 2>/dev/null)" || true
      fi
      ;;
    elasticsearch-eks)
      ip="$(wait_for_lb_hostname es-source-es-http)" || true
      user="elastic"
      password="$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d)" || password="pending"
      [[ -z "$password" ]] && password="pending"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        psc_uri="$($TF_CMD -chdir="$TF_DIR" output -raw privatelink_service_name 2>/dev/null)" || true
      fi
      ;;
    opensearch-eks)
      ip="$(wait_for_lb_hostname os-target-external)" || true
      user="admin"
      password="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_password)"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        psc_uri="$($TF_CMD -chdir="$TF_DIR" output -raw privatelink_service_name 2>/dev/null)" || true
      fi
      ;;
    opensearch-managed)
      # Amazon OpenSearch Service domain: the endpoint is a hostname on port 443 (not 9200).
      ip="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_endpoint 2>/dev/null) (port 443)" || ip="pending"
      user="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_user)"
      password="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_password)"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        # The consumer creates an OpenSearch-managed VPC endpoint against this domain ARN.
        psc_uri="$($TF_CMD -chdir="$TF_DIR" output -raw domain_arn 2>/dev/null)" || true
      fi
      ;;
  esac

  local software
  software="$($TF_CMD -chdir="$TF_DIR" output -raw software)"

  echo ""
  echo "============================================"
  echo " Cluster Ready"
  echo "============================================"
  echo "Software: ${software}"
  echo "IP:       ${ip}"
  echo "User:     ${user}"
  echo "Password: ${password}"
  if [[ -n "$psc_uri" ]]; then
    echo "PSC URI:  ${psc_uri}"
  fi
  echo "============================================"
}

validate_private_networking() {
  echo "Validating private networking configuration..."
  if ! $TF_CMD -chdir="$TF_DIR" validate -no-color ${TF_VARS[@]+"${TF_VARS[@]}"} >/dev/null; then
    echo "Error: Terraform validation failed. Check your terraform.tfvars."
    exit 1
  fi

  local consumer_var consumer_ids
  case "$CONFIG_NAME" in
    elasticsearch-eks|opensearch-eks) consumer_var="privatelink_allowed_principals" ;;
    opensearch-managed) consumer_var="privatelink_allowed_accounts" ;;
    *)                  consumer_var="psc_consumer_project_ids" ;;
  esac
  consumer_ids="$(get_tfvars_value "${TF_DIR}/terraform.tfvars" "$consumer_var" 2>/dev/null || true)"
  if [[ -z "$consumer_ids" ]]; then
    echo "Warning: ${consumer_var} is not set in terraform.tfvars."
    echo "         The service attachment will be created with no authorized consumers."
    echo "         You will need to authorize the migration project separately."
    echo ""
  fi
}

do_up() {
  check_cloud_prerequisites
  echo "Initializing Terraform..."
  $TF_CMD -chdir="$TF_DIR" init

  if [[ "$PRIVATE_NETWORKING" == "true" ]]; then
    echo ""
    validate_private_networking
  fi

  echo ""
  echo "Creating cluster..."
  $TF_CMD -chdir="$TF_DIR" apply -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}

  print_info
}

# PVC name prefixes our charts produce. The StatefulSet volumeClaimTemplate name and the
# chart's clusterName are both hardcoded (os-target / es-source), so these prefixes identify
# a disk as ours regardless of name_prefix, which is user-configurable.
OUR_PVC_PREFIXES=(
  "data-os-target-"                    # targets/gcp/opensearch-gke
  "elasticsearch-data-es-source-es-"   # sources/*/elasticsearch-*
)

# Deleting a GKE/EKS cluster bypasses the StorageClass 'Delete' reclaim policy, so the
# PersistentVolume disks survive and keep billing.
#
# Two passes are needed, because neither identifier alone is sufficient:
#
#   1. By cluster label. GKE stamps goog-k8s-cluster-name on each PD, which catches every
#      disk the cluster owned including ones from charts we don't ship (Prometheus etc).
#   2. By PVC name in the disk description. Some disks carry NO cluster label at all, so
#      pass 1 misses them entirely -- a real leak that went unnoticed for weeks. The CSI
#      driver always records created-for/pvc/name, and our chart PVC prefixes are fixed,
#      so this identifies our disks without relying on the label.
#
# Pass 2 is deliberately restricted to unlabeled disks: a labeled disk belongs to a specific
# cluster, and deleting one whose cluster is still alive would destroy live data. Unlabeled
# disks have no cluster to check, so the PVC prefix is the only provenance available -- and
# it is decisive, since only our charts create those names.
cleanup_orphaned_disks() {
  local cluster_name="$1" location="$2" project_id="$3"

  [[ "$PLATFORM" == "gcp" ]] || return 0
  if [[ -z "$project_id" ]]; then
    echo ""
    echo "Warning: could not determine the project; skipping orphaned-disk cleanup."
    echo "         Check for leftover 'pvc-*' disks: gcloud compute disks list --filter=\"-users:*\""
    return 0
  fi

  local disks="" unlabeled=""

  # Pass 1 needs a cluster name, and that cluster must already be gone -- otherwise its
  # disks may still be legitimately in use. Pass 2 needs neither, so a missing cluster name
  # is not fatal here.
  if [[ -n "$cluster_name" ]] && ! gcloud container clusters describe "$cluster_name" \
       --location "$location" --project "$project_id" >/dev/null 2>&1; then
    disks="$(gcloud compute disks list \
      --filter="labels.goog-k8s-cluster-name=${cluster_name} AND -users:*" \
      --format="value(name,zone.basename())" --project="$project_id" 2>/dev/null)"
  elif [[ -z "$cluster_name" ]]; then
    echo ""
    echo "Warning: could not determine the cluster name; checking unlabeled disks only."
  fi

  # Pass 2: unattached AND unlabeled AND created for one of our chart PVCs. The description
  # is JSON, so match on the quoted key/value pair rather than the bare prefix -- a substring
  # match on the prefix alone could hit another field.
  local prefix
  for prefix in "${OUR_PVC_PREFIXES[@]}"; do
    unlabeled="$(gcloud compute disks list \
      --filter="-users:* AND -labels.goog-k8s-cluster-name:* AND description ~ \"created-for/pvc/name\\\":\\\"${prefix}\"" \
      --format="value(name,zone.basename())" --project="$project_id" 2>/dev/null)"
    # NOTE: plain concatenation with a real newline -- $'\n' is NOT expanded inside
    # ${var:+...}, which would splice in a literal '$\n' and corrupt the zone field.
    [[ -n "$unlabeled" ]] && disks="${disks}
${unlabeled}"
  done

  # Both passes can return the same disk only if it were labeled and unlabeled at once, which
  # is impossible -- but dedupe anyway so a second delete cannot report a spurious failure.
  disks="$(printf '%s\n' "$disks" | grep -v '^[[:space:]]*$' | sort -u || true)"
  [[ -z "$disks" ]] && return 0

  echo ""
  echo "Deleting orphaned persistent disks..."
  local name zone
  while read -r name zone; do
    [[ -z "$name" || -z "$zone" ]] && continue
    if gcloud compute disks delete "$name" --zone "$zone" --project="$project_id" --quiet 2>/dev/null; then
      echo "  deleted ${name} (${zone})"
    else
      echo "  WARNING: failed to delete ${name} (${zone}) -- delete it manually"
    fi
  done <<< "$disks"
}

# Returns 0 if any stale helm_release entries were dropped (so the caller should retry the
# destroy), 1 if there was nothing to do.
drop_orphaned_helm_releases() {
  local cluster_name="$1" location="$2" project_id="$3"

  local releases
  releases="$($TF_CMD -chdir="$TF_DIR" state list 2>/dev/null | grep '^helm_release\.' || true)"
  [[ -z "$releases" ]] && return 1

  # Only safe once the cluster is actually gone. While it still exists a refresh failure is
  # a real error worth surfacing, not a stale-state artifact.
  case "$PLATFORM" in
    gcp)
      [[ -n "$cluster_name" && -n "$project_id" ]] || return 1
      gcloud container clusters describe "$cluster_name" --location "$location" \
        --project "$project_id" >/dev/null 2>&1 && return 1
      ;;
    aws)
      [[ -n "$cluster_name" ]] || return 1
      aws eks describe-cluster --name "$cluster_name" --region "$location" \
        >/dev/null 2>&1 && return 1
      ;;
    *) return 1 ;;
  esac

  echo ""
  echo "Cluster ${cluster_name} is gone but helm releases remain in state."
  echo "Dropping the stale entries (the releases died with the cluster)..."
  local r
  while read -r r; do
    [[ -z "$r" ]] && continue
    $TF_CMD -chdir="$TF_DIR" state rm "$r" >/dev/null 2>&1 && echo "  removed ${r}"
  done <<< "$releases"
  return 0
}

do_down() {
  check_cloud_prerequisites
  # disconnect() and the post-failure firewall cleanup both shell out to gcloud.
  [[ "$PLATFORM" == "gcp" ]] && check_gcloud_user_auth
  if ! has_state_resources; then
    echo ""
    echo "Nothing to destroy. No terraform state exists for this config."
    exit 0
  fi

  # Read identifying details BEFORE destroy: a successful destroy empties the state, and
  # the PD cleanup below still needs to know which cluster's disks to look for.
  local doomed_cluster doomed_location doomed_project
  doomed_cluster="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null)" || doomed_cluster=""
  doomed_location="$($TF_CMD -chdir="$TF_DIR" output -raw location 2>/dev/null)" || doomed_location=""
  if [[ "$PLATFORM" == "gcp" ]]; then
    doomed_project="$($TF_CMD -chdir="$TF_DIR" output -raw project_id 2>/dev/null)" || doomed_project=""
  fi

  disconnect

  echo "Destroying cluster..."
  if $TF_CMD -chdir="$TF_DIR" destroy -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}; then
    cleanup_orphaned_disks "$doomed_cluster" "$doomed_location" "$doomed_project"
    echo ""
    echo "Cluster destroyed."
    return 0
  fi

  # A helm_release cannot be refreshed once its cluster is gone ("Kubernetes cluster
  # unreachable"), which blocks the rest of the destroy. The release died with the cluster,
  # so dropping the stale state entries is safe -- but only once the cluster really is gone.
  if drop_orphaned_helm_releases "$doomed_cluster" "$doomed_location" "$doomed_project"; then
    echo ""
    echo "Retrying destroy..."
    if $TF_CMD -chdir="$TF_DIR" destroy -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}; then
      cleanup_orphaned_disks "$doomed_cluster" "$doomed_location" "$doomed_project"
      echo ""
      echo "Cluster destroyed."
      return 0
    fi
  fi

  # The VPC delete fails while firewall rules still reference it. Terraform does not manage
  # those rules (GKE creates them for the cluster and for LoadBalancer services; other
  # tooling may add its own), so clean them up and retry.
  #
  # This runs ONLY after a failed destroy, never before. Deleting the rules up front breaks
  # control-plane -> node connectivity (kubelet 10250, webhook 9443), which wedges operator
  # finalizers and makes 'helm uninstall' fail with 'context deadline exceeded'. By this
  # point the k8s workloads are already gone, so removing the rules is safe.
  if [[ "$PLATFORM" != "gcp" ]]; then
    return 1
  fi

  # NOTE: patterns use [[:space:]], not \s -- BSD awk on macOS does not support \s.
  local net_state network project_id
  net_state="$($TF_CMD -chdir="$TF_DIR" state show 'module.cluster.google_compute_network.main' 2>/dev/null)" || net_state=""
  network="$(printf '%s\n' "$net_state" | awk -F'"' '/^[[:space:]]*name[[:space:]]*=/{print $2; exit}')"
  project_id="$(printf '%s\n' "$net_state" | awk -F'"' '/^[[:space:]]*project[[:space:]]*=/{print $2; exit}')"

  if [[ -z "$network" || -z "$project_id" ]]; then
    echo ""
    echo "Error: destroy failed and the VPC name/project could not be read from state."
    echo "       Inspect the error above and clean up manually."
    exit 1
  fi

  echo ""
  echo "Destroy failed. Cleaning up firewall rules on ${network} and retrying..."
  local rules
  rules="$(gcloud compute firewall-rules list --filter="network=${network}" \
    --format="value(name)" --project="$project_id" 2>/dev/null)"
  if [[ -n "$rules" ]]; then
    printf '%s\n' "$rules" | \
      xargs -n1 gcloud compute firewall-rules delete --quiet --project="$project_id" || true
  else
    echo "  (no firewall rules found -- the failure was something else)"
  fi

  echo ""
  echo "Retrying destroy..."
  $TF_CMD -chdir="$TF_DIR" destroy -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}

  cleanup_orphaned_disks "$doomed_cluster" "$doomed_location" "$doomed_project"

  echo ""
  echo "Cluster destroyed."
}

do_info() {
  check_cloud_prerequisites
  print_info
}

get_var_default() {
  local varfile="$1" varname="$2"
  awk -v name="$varname" '
    $0 ~ "variable \"" name "\"" { found=1 }
    found && /default[[:space:]]*=/ {
      sub(/.*default[[:space:]]*=[[:space:]]*/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
    found && /^\}/ { exit }
  ' "$varfile"
}

get_tfvars_value() {
  local tfvars="$1" varname="$2"
  awk -v name="$varname" '
    $0 ~ "^"name"[[:space:]]*=" {
      sub(/.*=[[:space:]]*/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  ' "$tfvars"
}

get_effective() {
  local varname="$1"
  local val=""
  if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    val="$(get_tfvars_value "${TF_DIR}/terraform.tfvars" "$varname")"
  fi
  if [[ -z "$val" ]]; then
    val="$(get_var_default "${TF_DIR}/variables.tf" "$varname")"
  fi
  echo "$val"
}

do_specs() {
  local region zone machine_type node_count disk_size_gb software_version

  region="$(get_effective region)"
  zone="$(get_effective zone)"
  machine_type="$(get_effective machine_type)"
  # AWS configs name the node size variable instance_type rather than machine_type.
  if [[ -z "$machine_type" ]]; then
    machine_type="$(get_effective instance_type)"
  fi
  node_count="$(get_effective node_count)"
  disk_size_gb="$(get_effective disk_size_gb)"

  local software_label software_version_var
  case "$CONFIG_NAME" in
    elasticsearch-gke)
      software_label="Elasticsearch"
      software_version="$(get_effective elasticsearch_version)"
      ;;
    opensearch-gke)
      software_label="OpenSearch"
      software_version="$(get_effective opensearch_version)"
      ;;
    elasticsearch-eks)
      software_label="Elasticsearch"
      software_version="$(get_effective elasticsearch_version)"
      ;;
    opensearch-eks)
      software_label="OpenSearch"
      software_version="$(get_effective opensearch_version)"
      ;;
    opensearch-managed)
      software_label="OpenSearch (Amazon OpenSearch Service)"
      software_version="$(get_effective opensearch_version)"
      ;;
    *)
      software_label="Unknown"
      software_version="n/a"
      ;;
  esac

  local location
  if [[ -n "$zone" && "$zone" != "null" ]]; then
    location="$zone (zonal)"
  else
    location="$region (regional)"
  fi

  echo ""
  echo "============================================"
  echo " Cluster Specs"
  echo "============================================"
  echo "Software:     ${software_label} ${software_version}"
  echo "Location:     ${location}"
  echo "Machine type: ${machine_type}"
  echo "Node count:   ${node_count}"
  echo "Disk size:    ${disk_size_gb} GB"
  echo "============================================"
}

case "$ACTION" in
  up)     do_up ;;
  down)   do_down ;;
  info)   do_info ;;
  specs)  do_specs ;;
  *)      usage ;;
esac
