#!/usr/bin/env bash
#
# Rewrite umbrella Chart.yaml dependencies from file:// to OCI references.
#
# Usage:
#   OCI_REPO=oci://ghcr.io/osac-project/charts \
#   OPERATOR_CRDS_VER=0.0.1 OPERATOR_VER=0.0.1 \
#   SERVICE_VER=0.0.1 AAP_VER=0.0.1 \
#   BMF_CRDS_VER=0.0.1 BMF_VER=0.0.1 \
#     ./scripts/rewrite-chart-deps.sh
#
set -euo pipefail

: "${OCI_REPO:?OCI_REPO is required}"
: "${OPERATOR_CRDS_VER:?OPERATOR_CRDS_VER is required}"
: "${OPERATOR_VER:?OPERATOR_VER is required}"
: "${SERVICE_VER:?SERVICE_VER is required}"
: "${AAP_VER:?AAP_VER is required}"
: "${BMF_CRDS_VER:?BMF_CRDS_VER is required}"
: "${BMF_VER:?BMF_VER is required}"

CHART_YAML="${1:-charts/osac/Chart.yaml}"

yq -i "
  (.dependencies[] | select(.name == \"osac-operator-crds\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"osac-operator-crds\")) .version = \"${OPERATOR_CRDS_VER}\" |
  (.dependencies[] | select(.name == \"osac-operator\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"osac-operator\")) .version = \"${OPERATOR_VER}\" |
  (.dependencies[] | select(.name == \"fulfillment-service\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"fulfillment-service\")) .version = \"${SERVICE_VER}\" |
  (.dependencies[] | select(.name == \"osac-aap\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"osac-aap\")) .version = \"${AAP_VER}\" |
  (.dependencies[] | select(.name == \"bare-metal-fulfillment-operator-crds\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"bare-metal-fulfillment-operator-crds\")) .version = \"${BMF_CRDS_VER}\" |
  (.dependencies[] | select(.name == \"bare-metal-fulfillment-operator\")) .repository = \"${OCI_REPO}\" |
  (.dependencies[] | select(.name == \"bare-metal-fulfillment-operator\")) .version = \"${BMF_VER}\"
" "${CHART_YAML}"

rm -f "$(dirname "${CHART_YAML}")/Chart.lock"

echo "--- Updated ${CHART_YAML} ---"
cat "${CHART_YAML}"
