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

aap_commit=$(git -C "${REPO_ROOT}" submodule status "base/osac-aap" | awk '{print $1}' | tr -d '+')
aap_short="${aap_commit:0:7}"
aap_tag="sha-${aap_short}"

CI_OVERLAYS=("vmaas-ci" "caas-ci")

for overlay in "${CI_OVERLAYS[@]}"; do
  overlay_file="${REPO_ROOT}/overlays/${overlay}/kustomization.yaml"
  [[ ! -f "${overlay_file}" ]] && continue

  current_ee=$(grep "AAP_EE_IMAGE=" "${overlay_file}" | sed 's/.*AAP_EE_IMAGE=//' | tr -d ' ')
  expected_ee="ghcr.io/osac-project/osac-aap:${aap_tag}"

  current_branch=$(grep "AAP_PROJECT_GIT_BRANCH=" "${overlay_file}" | sed 's/.*AAP_PROJECT_GIT_BRANCH=//' | tr -d ' ')
  expected_branch="${aap_commit}"

  current_image_tag=$(grep -A2 "name: osac-aap$" "${overlay_file}" | grep "newTag:" | awk '{print $2}')

  for pair in "AAP_EE_IMAGE ${current_ee} ${expected_ee}" "AAP_PROJECT_GIT_BRANCH ${current_branch} ${expected_branch}"; do
    read -r key current expected <<< "${pair}"
    if [[ "${current}" == "${expected}" ]]; then
      echo "${overlay} ${key}: OK"
    elif [[ "${1:-}" == "--fix" ]]; then
      sed -i "s|${key}=${current}|${key}=${expected}|" "${overlay_file}"
      echo "${overlay} ${key}: FIXED ${current} -> ${expected}"
    else
      echo "${overlay} ${key}: MISMATCH current=${current} expected=${expected}"
      errors=$((errors + 1))
    fi
  done

  if [[ "${current_image_tag}" == "${aap_tag}" ]]; then
    echo "${overlay} osac-aap image: OK"
  elif [[ "${1:-}" == "--fix" ]]; then
    sed -i "/name: osac-aap$/,/newTag:/{s|newTag:.*|newTag: ${aap_tag}|}" "${overlay_file}"
    echo "${overlay} osac-aap image: FIXED ${current_image_tag} -> ${aap_tag}"
  else
    echo "${overlay} osac-aap image: MISMATCH current=${current_image_tag} expected=${aap_tag}"
    errors=$((errors + 1))
  fi
done

if [[ ${errors} -gt 0 ]]; then
  echo ""
  echo "Run '$0 --fix' to update the tags automatically."
  exit 1
fi
