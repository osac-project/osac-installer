#!/usr/bin/env bash
# Look up a single field for a chart from chart-versions.txt, produced by
# generate-chart-versions.sh (format: "<name>=<version>|<source_tag>|<source_sha>").
#
# Usage: get-chart-version.sh <name> [field] [file]
#   field: 1=version (default), 2=source_tag, 3=source_sha
#   file:  path to chart-versions.txt (default: ./chart-versions.txt)

set -euo pipefail

name="${1:?chart name required}"
field="${2:-1}"
file="${3:-chart-versions.txt}"

grep "^${name}=" "${file}" | cut -d= -f2- | cut -d'|' -f"${field}"
