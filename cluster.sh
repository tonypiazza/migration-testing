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

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "Error: gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
    missing=1
  fi

  if [[ $missing -eq 0 ]] && ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    echo "Error: Application Default Credentials not configured."
    echo "Run: gcloud auth application-default login"
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

check_prerequisites

TF_VARS=()
if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
  TF_VARS+=(-var "project_id=${GCP_PROJECT_ID}")
fi

usage() {
  echo "Usage: $0 <action> <config-path>"
  echo ""
  echo "Actions:"
  echo "  up      Create the cluster and print connection details"
  echo "  down    Destroy the cluster"
  echo "  info    Print connection details for an existing cluster"
  echo "  specs   Print effective cluster specs (no running cluster required)"
  echo ""
  echo "Config path: <sources|targets>/<platform>/<config>"
  echo ""
  echo "Examples:"
  echo "  $0 up sources/gcp/elasticsearch-gke"
  echo "  $0 up targets/gcp/opensearch-gke"
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
CONFIG_DIR="${SCRIPT_DIR}/${CONFIG_PATH}"
TF_DIR="${CONFIG_DIR}/terraform"
CLUSTER_ROLE="$(echo "$CONFIG_PATH" | cut -d/ -f1)"
PLATFORM="$(echo "$CONFIG_PATH" | cut -d/ -f2)"
CONFIG_NAME="$(echo "$CONFIG_PATH" | cut -d/ -f3)"

if [[ ! -d "$TF_DIR" ]]; then
  echo "Error: terraform directory not found at ${TF_DIR}"
  exit 1
fi

disconnect() {
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
  local cluster_name location project_id
  cluster_name="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_name)"
  location="$($TF_CMD -chdir="$TF_DIR" output -raw location)"
  project_id="$($TF_CMD -chdir="$TF_DIR" output -raw project_id)"

  case "$PLATFORM" in
    gcp)
      gcloud container clusters get-credentials "$cluster_name" \
        --location "$location" --project "$project_id" --quiet
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
  if ! $TF_CMD -chdir="$TF_DIR" output -raw cluster_name >/dev/null 2>&1; then
    echo ""
    echo "Cluster not found. No terraform state exists for this config."
    exit 1
  fi

  if ! connect 2>/dev/null; then
    echo ""
    echo "Cluster not found. It may have been torn down."
    exit 1
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
      ip="$(wait_for_lb_ip os-target-external)" || true
      user="admin"
      password="$($TF_CMD -chdir="$TF_DIR" output -raw cluster_password)"
      if [[ "$($TF_CMD -chdir="$TF_DIR" output -raw psc_enabled 2>/dev/null)" == "true" ]]; then
        psc_uri="$(wait_for_psc_uri os-target-psc)" || true
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

do_up() {
  echo "Initializing Terraform..."
  $TF_CMD -chdir="$TF_DIR" init

  echo ""
  echo "Creating cluster..."
  $TF_CMD -chdir="$TF_DIR" apply -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}

  print_info
}

do_down() {
  if ! $TF_CMD -chdir="$TF_DIR" output -raw cluster_name >/dev/null 2>&1; then
    echo ""
    echo "Nothing to destroy. No terraform state exists for this config."
    exit 0
  fi

  disconnect

  local network project_id
  network="$($TF_CMD -chdir="$TF_DIR" state show 'module.cluster.google_compute_network.main' 2>/dev/null | awk -F'"' '/^\s*name\s*=/{print $2}')"
  project_id="$($TF_CMD -chdir="$TF_DIR" state show 'module.cluster.google_compute_network.main' 2>/dev/null | awk -F'"' '/^\s*project\s*=/{print $2}')"

  if [[ -n "$network" && -n "$project_id" ]]; then
    echo "Cleaning up GKE-managed firewall rules for network ${network}..."
    gcloud compute firewall-rules list --filter="network=${network}" --format="value(name)" --project="$project_id" | \
      xargs -n1 gcloud compute firewall-rules delete --quiet --project="$project_id" || true
  fi

  echo "Destroying cluster..."
  $TF_CMD -chdir="$TF_DIR" destroy -auto-approve ${TF_VARS[@]+"${TF_VARS[@]}"}

  echo ""
  echo "Cluster destroyed."
}

do_info() {
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
