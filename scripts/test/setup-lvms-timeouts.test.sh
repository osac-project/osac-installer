#!/usr/bin/env bash
# Regression tests for OSAC-1964 LVMS install wait timeouts in setup.sh.
#
# OSAC-1964: CSV Succeeded and deployment Available waits (300s -> 600s/900s).
# OSAC-1964-csv-exist: CSV-existence retry_until (300s -> 900s), split apply vs wait,
# and cluster stability gate before LVMS when MCP/API may still be settling.
set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="${SCRIPT_DIR}/../setup.sh"
LIB_SH="${SCRIPT_DIR}/../lib.sh"

readonly MIN_CSV_EXISTENCE_TIMEOUT=900
readonly MIN_CSV_SUCCEEDED_TIMEOUT=600
readonly MIN_DEPLOYMENT_AVAILABLE_TIMEOUT=900
readonly LEGACY_TIMEOUT=300

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

[[ -f "${SETUP_SH}" ]] || fail "setup.sh not found at ${SETUP_SH}"
[[ -f "${LIB_SH}" ]] || fail "lib.sh not found at ${LIB_SH}"

grep -q 'wait_for_cluster_stability' "${SETUP_SH}" || \
    fail "setup.sh must call wait_for_cluster_stability before LVMS install (OSAC-1964-csv-exist)"
pass "setup.sh calls wait_for_cluster_stability before LVMS install"

grep -q 'wait_for_cluster_stability()' "${LIB_SH}" || \
    fail "lib.sh must define wait_for_cluster_stability (OSAC-1964-csv-exist)"
pass "lib.sh defines wait_for_cluster_stability"

grep -q 'wait_for_machineconfigpools_stable()' "${LIB_SH}" || \
    fail "lib.sh must define wait_for_machineconfigpools_stable for portable MCP checks"
pass "lib.sh defines wait_for_machineconfigpools_stable"

grep -q '_machineconfigpools_updated()' "${LIB_SH}" || \
    fail "lib.sh must define _machineconfigpools_updated helper"
pass "lib.sh defines _machineconfigpools_updated helper"

if grep -E 'oc get mcp/master|mcp/master -o' "${LIB_SH}"; then
    fail "lib.sh must not hardcode mcp/master; use wait_for_machineconfigpools_stable for HyperShift/custom CP topologies"
fi
pass "lib.sh does not hardcode mcp/master"

grep -q 'retry_command 600 5 oc apply -f prerequisites/lvms/lvms-operator.yaml' "${SETUP_SH}" || \
    fail "setup.sh must apply lvms-operator.yaml via retry_command, separate from CSV wait (OSAC-1964-csv-exist)"
pass "setup.sh applies LVMS manifest via dedicated retry_command"

csv_exist_line=$(grep -F "retry_until ${MIN_CSV_EXISTENCE_TIMEOUT} 3" "${SETUP_SH}" | \
    grep -F 'oc get csv --no-headers -n openshift-storage | grep lvms' | head -1 || true)
[[ -n "${csv_exist_line}" ]] || fail "LVMS CSV-existence retry_until ${MIN_CSV_EXISTENCE_TIMEOUT}s line not found in setup.sh"

csv_exist_timeout=$(echo "${csv_exist_line}" | grep -oE 'retry_until [0-9]+' | awk '{print $2}')
[[ -n "${csv_exist_timeout}" ]] || fail "Could not parse LVMS CSV-existence timeout from: ${csv_exist_line}"

if (( csv_exist_timeout < MIN_CSV_EXISTENCE_TIMEOUT )); then
    fail "LVMS CSV-existence timeout is ${csv_exist_timeout}s; expected >= ${MIN_CSV_EXISTENCE_TIMEOUT}s (OSAC-1964-csv-exist)"
fi
pass "LVMS CSV-existence timeout is ${csv_exist_timeout}s (>= ${MIN_CSV_EXISTENCE_TIMEOUT}s)"

if echo "${csv_exist_line}" | grep -q 'oc apply -f prerequisites/lvms/lvms-operator.yaml'; then
    fail "LVMS CSV-existence retry_until must not re-apply manifest in the wait loop (OSAC-1964-csv-exist)"
fi
pass "LVMS CSV-existence wait does not re-apply manifest in loop"

csv_line=$(grep -F 'clusterserviceversion/${LVMS_CSV}' "${SETUP_SH}" || true)
deploy_line=$(grep -F 'deployment/lvms-operator condition=Available' "${SETUP_SH}" || true)

[[ -n "${csv_line}" ]] || fail "LVMS CSV wait_for_resource line not found in setup.sh"
[[ -n "${deploy_line}" ]] || fail "LVMS deployment wait_for_resource line not found in setup.sh"

csv_timeout=$(echo "${csv_line}" | grep -oE '[0-9]+ openshift-storage' | awk '{print $1}')
deploy_timeout=$(echo "${deploy_line}" | grep -oE '[0-9]+ openshift-storage' | awk '{print $1}')

[[ -n "${csv_timeout}" ]] || fail "Could not parse LVMS CSV timeout from: ${csv_line}"
[[ -n "${deploy_timeout}" ]] || fail "Could not parse LVMS deployment timeout from: ${deploy_line}"

if (( csv_timeout < MIN_CSV_SUCCEEDED_TIMEOUT )); then
    fail "LVMS CSV Succeeded timeout is ${csv_timeout}s; expected >= ${MIN_CSV_SUCCEEDED_TIMEOUT}s (OSAC-1964)"
fi
pass "LVMS CSV Succeeded timeout is ${csv_timeout}s (>= ${MIN_CSV_SUCCEEDED_TIMEOUT}s)"

if (( deploy_timeout < MIN_DEPLOYMENT_AVAILABLE_TIMEOUT )); then
    fail "LVMS deployment Available timeout is ${deploy_timeout}s; expected >= ${MIN_DEPLOYMENT_AVAILABLE_TIMEOUT}s (OSAC-1964)"
fi
pass "LVMS deployment Available timeout is ${deploy_timeout}s (>= ${MIN_DEPLOYMENT_AVAILABLE_TIMEOUT}s)"

if (( csv_exist_timeout == LEGACY_TIMEOUT || csv_timeout == LEGACY_TIMEOUT || deploy_timeout == LEGACY_TIMEOUT )); then
    fail "LVMS waits still use legacy ${LEGACY_TIMEOUT}s timeout that caused CI flakes"
fi
pass "LVMS waits no longer use legacy ${LEGACY_TIMEOUT}s timeout"

grep -q 'LVMS OLM diagnostics' "${SETUP_SH}" || \
    fail "setup.sh should dump OLM diagnostics on CSV-existence timeout (OSAC-1964-csv-exist)"
pass "setup.sh dumps OLM diagnostics on CSV-existence timeout"

echo "All LVMS timeout regression checks passed."
