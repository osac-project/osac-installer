#!/usr/bin/env bash
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
  [bare-metal-fulfillment-operator]="ghcr.io/osac-project/bare-metal-fulfillment-operator"
  [osac-ui]="osac-ui"
)

errors=0

for submodule in osac-operator osac-fulfillment-service osac-aap bare-metal-fulfillment-operator osac-ui; do
  commit=$(git -C "${REPO_ROOT}" submodule status "base/${submodule}" | awk '{print $1}' | tr -d ' +-')
  short="${commit:0:7}"
  tag="sha-${short}"
  image="${IMAGE_NAME[$submodule]}"

  # Skip components not referenced in kustomization.yaml (e.g. osac-ui is Helm-only).
  grep -q "name: ${image}$" "${KUSTOMIZATION}" || continue
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

aap_commit=$(git -C "${REPO_ROOT}" submodule status "base/osac-aap" | awk '{print $1}' | tr -d ' +-')
aap_short="${aap_commit:0:7}"
aap_tag="sha-${aap_short}"

CI_OVERLAYS=("vmaas-ci" "caas-ci" "osac-integration")

for overlay in "${CI_OVERLAYS[@]}"; do
  overlay_file="${REPO_ROOT}/overlays/${overlay}/kustomization.yaml"
  [[ ! -f "${overlay_file}" ]] && continue

  current_ee=$(grep "AAP_EE_IMAGE=" "${overlay_file}" | sed 's/.*AAP_EE_IMAGE=//' | tr -d ' ')
  expected_ee="ghcr.io/osac-project/osac-aap:${aap_tag}"

  current_branch=$(grep "AAP_PROJECT_GIT_BRANCH=" "${overlay_file}" | sed 's/.*AAP_PROJECT_GIT_BRANCH=//' | tr -d ' ')
  expected_branch="${aap_commit}"

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
done

# --- Helm values files ---
# Sync image tags in values/*.yaml with submodule commits.
# Skips files that use :latest (e.g. development.yaml).

operator_tag="sha-$(git -C "${REPO_ROOT}" submodule status base/osac-operator | awk '{print $1}' | tr -d ' +-' | cut -c1-7)"
fulfillment_tag="sha-$(git -C "${REPO_ROOT}" submodule status base/osac-fulfillment-service | awk '{print $1}' | tr -d ' +-' | cut -c1-7)"
aap_tag="sha-$(git -C "${REPO_ROOT}" submodule status base/osac-aap | awk '{print $1}' | tr -d ' +-' | cut -c1-7)"
bmf_tag="sha-$(git -C "${REPO_ROOT}" submodule status base/bare-metal-fulfillment-operator | awk '{print $1}' | tr -d ' +-' | cut -c1-7)"
ui_tag="sha-$(git -C "${REPO_ROOT}" submodule status base/osac-ui | awk '{print $1}' | tr -d ' +-' | cut -c1-7)"

for values_file in "${REPO_ROOT}"/values/*/values.yaml; do
  [[ ! -f "${values_file}" ]] && continue
  name=$(basename "$(dirname "${values_file}")")
  grep -q "sha-" "${values_file}" || continue

  for pair in \
    "osac-operator:tag ${operator_tag}" \
    "fulfillment-service:inline ${fulfillment_tag}" \
    "osac-aap:inline ${aap_tag}" \
    "bare-metal-fulfillment-operator:tag ${bmf_tag}" \
    "osac-ui:inline ${ui_tag}"; do
    component="${pair%%:*}"
    rest="${pair#*:}"
    mode="${rest%% *}"
    expected="${rest#* }"

    if [[ "${mode}" == "tag" ]]; then
      # Skip components not configured in this values file (e.g. BMF disabled in vmaas-ci).
      # Must check before the pipeline below — pipefail would abort on grep returning 1.
      grep -q "repository: ghcr.io/osac-project/${component}$" "${values_file}" || continue
      current=$(grep -A1 "repository: ghcr.io/osac-project/${component}$" "${values_file}" | grep "tag:" | awk '{print $2}')
      [[ -z "${current}" ]] && continue
      if [[ "${current}" == "${expected}" ]]; then
        echo "${name} ${component}: OK (${expected})"
      elif [[ "${1:-}" == "--fix" ]]; then
        sed -i "/repository: ghcr.io\/osac-project\/${component}$/{n;s|tag: .*|tag: ${expected}|}" "${values_file}"
        echo "${name} ${component}: FIXED ${current} -> ${expected}"
      else
        echo "${name} ${component}: MISMATCH current=${current} expected=${expected}"
        errors=$((errors + 1))
      fi
    else
      current=$(grep -o "${component}:sha-[a-f0-9]\{7\}" "${values_file}" | head -1 | sed "s/${component}://" || true)
      [[ -z "${current}" ]] && continue
      if [[ "${current}" == "${expected}" ]]; then
        echo "${name} ${component}: OK (${expected})"
      elif [[ "${1:-}" == "--fix" ]]; then
        sed -i "s|${component}:sha-[a-f0-9]\{7\}|${component}:${expected}|g" "${values_file}"
        echo "${name} ${component}: FIXED ${current} -> ${expected}"
      else
        echo "${name} ${component}: MISMATCH current=${current} expected=${expected}"
        errors=$((errors + 1))
      fi
    fi
  done

  # Sync projectGitBranch (full 40-char commit) with osac-aap submodule.
  aap_full_commit=$(git -C "${REPO_ROOT}" submodule status base/osac-aap | awk '{print $1}' | tr -d ' +-')
  grep -q "projectGitBranch:" "${values_file}" || continue
  current_branch=$(grep "projectGitBranch:" "${values_file}" | head -1 | sed 's/.*projectGitBranch: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
  [[ -z "${current_branch}" ]] && continue
  if [[ "${current_branch}" == "${aap_full_commit}" ]]; then
    echo "${name} projectGitBranch: OK"
  elif [[ "${1:-}" == "--fix" ]]; then
    sed -i "s|projectGitBranch: .*|projectGitBranch: \"${aap_full_commit}\"|" "${values_file}"
    echo "${name} projectGitBranch: FIXED ${current_branch} -> ${aap_full_commit}"
  else
    echo "${name} projectGitBranch: MISMATCH current=${current_branch} expected=${aap_full_commit}"
    errors=$((errors + 1))
  fi
done

if [[ ${errors} -gt 0 ]]; then
  echo ""
  echo "Run '$0 --fix' to update the tags automatically."
  exit 1
fi
