#!/bin/bash
# Sync image tags in base/kustomization.yaml to match submodule commits.
# Each component repo publishes SHA-tagged images on every main merge.
# This script reads the submodule commits and updates the kustomization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUSTOMIZATION="${REPO_ROOT}/base/kustomization.yaml"

declare -A IMAGE_NAME=(
  [osac-operator]="ghcr.io/osac-project/osac-operator"
  [osac-fulfillment-service]="ghcr.io/osac-project/fulfillment-service"
  [osac-aap]="osac-aap"
)

errors=0

for submodule in osac-operator osac-fulfillment-service osac-aap; do
  commit=$(git -C "${REPO_ROOT}" submodule status "base/${submodule}" | awk '{print $1}' | tr -d '+')
  short="${commit:0:7}"
  tag="sha-${short}"
  image="${IMAGE_NAME[$submodule]}"

  current_tag=$(grep -A2 "name: ${image}$" "${KUSTOMIZATION}" | grep "newTag:" | awk '{print $2}')

  if [[ "${current_tag}" == "${tag}" ]]; then
    echo "${image}: OK (${tag})"
  elif [[ "${1:-}" == "--fix" ]]; then
    escaped_image=$(echo "${image}" | sed 's|/|\\/|g')
    sed -i "/name: ${escaped_image}$/,/newTag:/{s|newTag:.*|newTag: ${tag}|}" "${KUSTOMIZATION}"
    echo "${image}: FIXED ${current_tag} -> ${tag}"
  else
    echo "${image}: MISMATCH current=${current_tag} expected=${tag}"
    errors=$((errors + 1))
  fi
done

if [[ ${errors} -gt 0 ]]; then
  echo ""
  echo "Run '$0 --fix' to update the tags automatically."
  exit 1
fi
