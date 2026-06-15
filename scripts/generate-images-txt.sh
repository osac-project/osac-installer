#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/osac"
CI_VALUES="${CHART_DIR}/ci/full-values.yaml"
OUTPUT="${1:-${REPO_ROOT}/images.txt}"

if ! ls "${CHART_DIR}/charts/"*.tgz &>/dev/null; then
  echo "Building chart dependencies..."
  helm dependency build "${CHART_DIR}"
fi

echo "Rendering templates with full-values.yaml..."
helm template osac "${CHART_DIR}" --values "${CI_VALUES}" \
  | grep -E '^\s+image:\s' \
  | sed -E 's/^\s+image:\s+["'"'"']?([^"'"'"' ]+)["'"'"']?\s*$/\1/' \
  | sort -u \
  > "${OUTPUT}"

count=$(wc -l < "${OUTPUT}")
echo "Generated ${OUTPUT} with ${count} image(s):"
cat "${OUTPUT}"
