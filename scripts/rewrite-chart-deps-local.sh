#!/usr/bin/env bash
#
# Rewrite umbrella Chart.yaml OCI dependencies back to file:// for local dev.
# Counterpart to rewrite-chart-deps.sh.
#
# Usage:
#   ./scripts/rewrite-chart-deps-local.sh [charts/osac/Chart.yaml]
#
set -euo pipefail

CHART_YAML="${1:-charts/osac/Chart.yaml}"

yq -i '
  (.dependencies[] | select(.name == "osac-operator-crds")) .repository = "file://../../base/osac-operator/charts/operator-crds" |
  (.dependencies[] | select(.name == "osac-operator-crds")) .version = ">=0.0.0" |
  (.dependencies[] | select(.name == "osac-operator")) .repository = "file://../../base/osac-operator/charts/operator" |
  (.dependencies[] | select(.name == "osac-operator")) .version = ">=0.0.0" |
  (.dependencies[] | select(.name == "fulfillment-service")) .repository = "file://../../base/osac-fulfillment-service/charts/service" |
  (.dependencies[] | select(.name == "fulfillment-service")) .version = ">=0.0.0" |
  (.dependencies[] | select(.name == "osac-aap")) .repository = "file://../../base/osac-aap/charts/aap" |
  (.dependencies[] | select(.name == "osac-aap")) .version = ">=0.0.0"
' "${CHART_YAML}"

rm -f "$(dirname "${CHART_YAML}")/Chart.lock"

echo "--- Rewrote ${CHART_YAML} to local file:// deps ---"
