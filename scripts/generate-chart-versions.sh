#!/usr/bin/env bash
# Compute each component/CRD chart's own nightly version: its latest real
# (non-nightly) release tag plus the shared nightly suffix. Used by the
# nightly-build workflow so every chart's version reflects its actual
# release history instead of inheriting one invented umbrella version.
#
# Requires the following environment variables to be set:
#   NIGHTLY_SUFFIX  e.g. "nightly.20260709.0d44e56.3"
#   CRD_CHARTS      e.g. "chart_name:submodule_path:chart_path ..."
#   COMPONENTS      e.g. "component:image:submodule_path:mode:chart_path ..."
#
# Writes chart-versions.txt to the current working directory, one line per
# chart: "<name>=<version>|<source_tag>|<source_sha>". The source tag/sha
# are exposed (not just the final version) so callers like the images.txt
# step can reuse the already-resolved, shallow-clone-safe values instead
# of re-running `git describe` themselves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

: "${NIGHTLY_SUFFIX:?NIGHTLY_SUFFIX must be set}"
: "${CRD_CHARTS:?CRD_CHARTS must be set}"
: "${COMPONENTS:?COMPONENTS must be set}"

# Resolve a submodule's release tag and current SHA for chart-versions.txt.
# Usage: chart_info_for_path <submodule_path>; prints "<tag>|<sha>".
chart_info_for_path() {
  local path=$1
  local tag sha
  # actions/checkout clones submodules shallow (depth 1) even when the
  # superproject uses fetch-depth: 0. A shallow clone has no ancestor
  # history for `describe` to walk, so fetching tag refs alone isn't
  # enough — the submodule needs to be unshallowed too, or `describe`
  # silently fails. `--unshallow` errors on an already-complete repo,
  # so only use it when needed.
  if [[ "$(git -C "${path}" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    git -C "${path}" fetch --unshallow --tags --quiet 2>/dev/null || true
  else
    git -C "${path}" fetch --tags --quiet 2>/dev/null || true
  fi
  tag=$(resolve_release_tag "${path}") || exit 1
  sha=$(git -C "${path}" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
  echo "${tag}|${sha}"
}

: > chart-versions.txt
for entry in ${CRD_CHARTS}; do
  chart_name="${entry%%:*}"
  rest="${entry#*:}"
  submodule_path="${rest%%:*}"
  info=$(chart_info_for_path "${submodule_path}")
  src_tag="${info%|*}"
  src_sha="${info#*|}"
  version="${src_tag#v}-${NIGHTLY_SUFFIX}"
  echo "${chart_name}=${version}|${src_tag}|${src_sha}" >> chart-versions.txt
done
for entry in ${COMPONENTS}; do
  component="${entry%%:*}"
  rest="${entry#*:}"
  rest="${rest#*:}"
  submodule_path="${rest%%:*}"
  info=$(chart_info_for_path "${submodule_path}")
  src_tag="${info%|*}"
  src_sha="${info#*|}"
  version="${src_tag#v}-${NIGHTLY_SUFFIX}"
  echo "${component}=${version}|${src_tag}|${src_sha}" >> chart-versions.txt
done

echo "--- Per-chart versions ---"
cat chart-versions.txt
