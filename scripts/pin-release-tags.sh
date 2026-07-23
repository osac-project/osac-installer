#!/usr/bin/env bash
# Pin overlay values files to released versioned image tags.
# Called by publish-charts.yaml after a chart release to reconcile
# CI/dev overlays with the officially released component versions.
#
# Usage: pin-release-tags.sh <operator_ver> <service_ver> <aap_ver> <bmf_ver> <ui_ver>
# Example: pin-release-tags.sh 0.0.8 0.0.64 0.0.3 0.0.1 0.0.1

set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <operator_ver> <service_ver> <aap_ver> <bmf_ver> <ui_ver>" >&2
  exit 1
fi

OPERATOR_VER="$1"
SERVICE_VER="$2"
AAP_VER="$3"
BMF_VER="$4"
UI_VER="$5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for values_file in "${REPO_ROOT}"/values/*/values.yaml; do
  [[ ! -f "${values_file}" ]] && continue
  name=$(basename "$(dirname "${values_file}")")

  # Skip files that have no OSAC component image references at all
  if ! grep -q "ghcr.io/osac-project/" "${values_file}"; then
    continue
  fi

  echo "--- Updating ${name} ---"

  # operator: tag field
  if grep -q "repository: ghcr.io/osac-project/osac-operator$" "${values_file}"; then
    sed -i "/repository: ghcr.io\/osac-project\/osac-operator$/{n;s|tag: .*|tag: v${OPERATOR_VER}|}" "${values_file}"
    echo "  osac-operator: v${OPERATOR_VER}"
  fi

  # fulfillment-service: inline image reference
  sed -i -E "s#fulfillment-service:(sha-[a-f0-9]{7}|v[0-9][0-9.]*|latest)#fulfillment-service:v${SERVICE_VER}#g" "${values_file}"
  echo "  fulfillment-service: v${SERVICE_VER}"

  # osac-aap: inline image reference
  sed -i -E "s#osac-aap:(sha-[a-f0-9]{7}|v[0-9][0-9.]*|latest)#osac-aap:v${AAP_VER}#g" "${values_file}"
  echo "  osac-aap: v${AAP_VER}"

  # bare-metal-fulfillment-operator: tag field
  if grep -q "repository: ghcr.io/osac-project/bare-metal-fulfillment-operator$" "${values_file}"; then
    sed -i "/repository: ghcr.io\/osac-project\/bare-metal-fulfillment-operator$/{n;s|tag: .*|tag: v${BMF_VER}|}" "${values_file}"
    echo "  bare-metal-fulfillment-operator: v${BMF_VER}"
  fi

  # osac-ui: inline image reference
  sed -i -E "s#osac-ui:(sha-[a-f0-9]{7}|v[0-9][0-9.]*|latest)#osac-ui:v${UI_VER}#g" "${values_file}"
  echo "  osac-ui: v${UI_VER}"

  # Pin projectGitBranch to the AAP release tag so git content matches the EE image
  if grep -q "projectGitBranch:" "${values_file}"; then
    sed -i "s|projectGitBranch: .*|projectGitBranch: \"v${AAP_VER}\"|" "${values_file}"
    echo "  projectGitBranch: v${AAP_VER}"
  fi
done

echo ""
echo "Overlay values files pinned to release versions."
