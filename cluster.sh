#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prerequisites() {
  local missing=0

  if ! command -v terraform >/dev/null 2>&1; then
    echo "Error: terraform CLI not found. Install from https://www.terraform.io/downloads"
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

usage() {
  echo "Usage: $0 <action> <config-path>"
  echo ""
  echo "Actions:"
  echo "  up     Create the cluster and print connection details"
  echo "  down   Destroy the cluster"
  echo "  info   Print connection details for an existing cluster"
  echo ""
  echo "Config path: <sources|targets>/<platform>/<config>"
  echo ""
  echo "Examples:"
  echo "  $0 up sources/gcp/elasticsearch-gke"
  echo "  $0 up targets/gcp/opensearch-gke"
  echo "  $0 info targets/gcp/opensearch-gke"
  echo "  $0 down sources/gcp/elasticsearch-gke"
  echo ""
  echo "Available configs:"
  find "${SCRIPT_DIR}/sources" "${SCRIPT_DIR}/targets" -name "terraform.tfvars.example" 2>/dev/null | while read -r f; do
    dir="$(dirname "$(dirname "$f")")"
    echo "  ${dir#"${SCRIPT_DIR}/"}"
  done
  exit 1
}

[[ $# -lt 2 ]] && usage

ACTION="$1"
CONFIG_PATH="$2"
CONFIG_DIR="${SCRIPT_DIR}/${CONFIG_PATH}"
TF_DIR="${CONFIG_DIR}/terraform"
PLATFORM="$(echo "$CONFIG_PATH" | cut -d/ -f2)"

if [[ ! -d "$TF_DIR" ]]; then
  echo "Error: terraform directory not found at ${TF_DIR}"
  exit 1
fi

disconnect() {
  case "$PLATFORM" in
    gcp)
      local cluster_name location project_id context
      cluster_name="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null)" || return 0
      location="$(terraform -chdir="$TF_DIR" output -raw location 2>/dev/null)" || return 0
      project_id="$(terraform -chdir="$TF_DIR" output -raw project_id 2>/dev/null)" || return 0
      context="gke_${project_id}_${location}_${cluster_name}"
      echo "Removing kubectl context: ${context}"
      kubectl config delete-context "$context" 2>/dev/null || true
      ;;
    aws)
      local cluster_name region context
      cluster_name="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null)" || return 0
      region="$(terraform -chdir="$TF_DIR" output -raw region 2>/dev/null)" || return 0
      context="arn:aws:eks:${region}:*:cluster/${cluster_name}"
      echo "Removing kubectl context: ${context}"
      kubectl config delete-context "$context" 2>/dev/null || true
      ;;
  esac
}

print_info() {
  echo ""
  echo "============================================"
  echo " Cluster Details"
  echo "============================================"
  terraform -chdir="$TF_DIR" output
  echo ""
  echo "To get connection credentials, run:"
  echo "  eval \"\$(terraform -chdir=${TF_DIR} output -raw connection_info)\""
  echo "============================================"
}

do_up() {
  echo "Initializing Terraform..."
  terraform -chdir="$TF_DIR" init

  echo ""
  echo "Creating cluster..."
  terraform -chdir="$TF_DIR" apply -auto-approve

  print_info
}

do_down() {
  disconnect

  echo "Destroying cluster..."
  terraform -chdir="$TF_DIR" destroy -auto-approve

  echo ""
  echo "Cluster destroyed."
}

do_info() {
  print_info
}

case "$ACTION" in
  up)   do_up ;;
  down) do_down ;;
  info) do_info ;;
  *)    usage ;;
esac
