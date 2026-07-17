#!/usr/bin/env bash
# Sync image tags in Helm values files to match submodule commits.
# Each component repo publishes SHA-tagged images on every main merge.
# This script reads the submodule commits and updates the values files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

errors=0

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
      grep -q "repository: ghcr.io/osac-project/${component}$" "${values_file}" || continue
      current=$(grep -A1 "repository: ghcr.io/osac-project/${component}$" "${values_file}" | grep "tag:" | awk '{print $2}' || true)
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
