#!/usr/bin/env bash

# Retry a condition until it succeeds or times out, optionally running a command each iteration
# Usage: retry_until <timeout_seconds> <interval_seconds> <condition_command> [loop_command]
# Returns: 0 on success, 1 on timeout
retry_until() {
    local timeout="$1"
    local interval="$2"
    local condition="$3"
    local loop_cmd="${4:-}"

    local start=${SECONDS}
    until eval "${condition}"; do
        if (( SECONDS - start >= timeout )); then
            return 1
        fi
        [[ -n "${loop_cmd}" ]] && eval "${loop_cmd}" || true
        sleep "${interval}"
    done
}

# Returns 0 when every MCP with machines has Updated=True.
_machineconfigpools_updated() {
    local mcp status machine_count
    for mcp in $(oc get mcp --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        machine_count=$(oc get mcp "${mcp}" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo 0)
        (( machine_count > 0 )) || continue
        status=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || true)
        [[ "${status}" == "True" ]] || return 1
    done
}

# Dump MCP state to aid CI triage when the stability gate times out.
_dump_machineconfigpool_diagnostics() {
    echo "=== MachineConfigPool diagnostics ==="
    oc get mcp -o wide || true
    for mcp in $(oc get mcp --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        oc describe mcp "${mcp}" || true
    done
}

# Wait for MachineConfigPools to finish applying pending changes.
# On HyperShift or custom control-plane topologies, mcp/master may be absent or
# non-representative; wait for all present MCPs, or skip when none exist.
# Usage: wait_for_machineconfigpools_stable [timeout_seconds]
wait_for_machineconfigpools_stable() {
    local timeout="${1:-600}"

    if ! oc get mcp &>/dev/null || [[ -z "$(oc get mcp --no-headers 2>/dev/null)" ]]; then
        echo "No MachineConfigPools found; skipping MCP stability check (typical for HyperShift or custom CP topologies)"
        return 0
    fi

    echo "Waiting for MachineConfigPools to be Updated..."
    retry_until "${timeout}" 10 '_machineconfigpools_updated' || {
        echo "Timed out waiting for MachineConfigPools to reach Updated state"
        _dump_machineconfigpool_diagnostics
        return 1
    }
}

# Wait for stable API server connectivity (healthz + namespace list).
# Usage: wait_for_api_connectivity [timeout_seconds]
wait_for_api_connectivity() {
    local timeout="${1:-120}"

    echo "Waiting for API server connectivity..."
    retry_until "${timeout}" 5 'oc get --raw /healthz &>/dev/null && oc get ns default &>/dev/null' || {
        echo "Timed out waiting for API server connectivity"
        return 1
    }
}

# Returns 0 when MCP stability wait should be skipped.
# CI E2E runs "Prepare cluster prerequisites" (mcp/master wait + settle) before
# SETUP_PHASE=prerequisites setup.sh. Manual installs (SETUP_PHASE=all, no CI) still
# need the MCP gate when KubeletConfig or other MCO changes may be in flight.
# Override with SKIP_MCP_STABILITY_CHECK=true if needed.
_should_skip_mcp_stability_check() {
    if [[ "${SKIP_MCP_STABILITY_CHECK:-}" == "true" ]]; then
        return 0
    fi
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
        [[ "${SETUP_PHASE:-all}" == "prerequisites" ]]
        return $?
    fi
    return 1
}

# Combined gate before operator installs that need a responsive API after MCP rollouts.
# Skips MCP wait only in CI prerequisites phase (workflow already gated MCP).
# Usage: wait_for_cluster_stability [mcp_timeout_seconds] [api_timeout_seconds]
wait_for_cluster_stability() {
    local mcp_timeout="${1:-600}"
    local api_timeout="${2:-120}"

    if _should_skip_mcp_stability_check; then
        echo "Skipping MCP stability check (CI prerequisites phase; workflow already gated MCP rollout)"
    else
        wait_for_machineconfigpools_stable "${mcp_timeout}" || return 1
    fi
    wait_for_api_connectivity "${api_timeout}" || return 1
}

# Wait for a namespace to finish terminating if it exists in Terminating state
# Usage: wait_for_namespace_cleanup <namespace> [timeout_seconds]
wait_for_namespace_cleanup() {
    local namespace="$1"
    local timeout="${2:-300}"

    if oc get namespace "${namespace}" &>/dev/null && \
       [[ "$(oc get namespace "${namespace}" -o jsonpath='{.status.phase}')" == "Terminating" ]]; then
        echo "Waiting for namespace ${namespace} to finish terminating..."
        oc wait --for=delete "namespace/${namespace}" --timeout="${timeout}s" || {
            echo "ERROR: namespace ${namespace} stuck in Terminating state. You may need to manually remove finalizers."
            exit 1
        }
    fi
}

# Wait for a namespace to exist and a resource within it to match a condition
# Usage: wait_for_resource <resource> <condition> [timeout_seconds] [namespace]
wait_for_resource() {
    local resource="$1"
    local condition="$2"
    local timeout="${3:-300}"
    local namespace="${4:-}"
    local ns_args=()

    if [[ -n "${namespace}" ]]; then
        ns_args=(-n "${namespace}")

        retry_until 300 5 '[[ -n "$(oc get namespace --ignore-not-found "${namespace}")" ]]' || {
            echo "Timed out waiting for namespace ${namespace} to exist"
            exit 1
        }
    fi

    retry_until 300 5 '[[ -n "$(oc get "${resource}" --ignore-not-found ${ns_args[@]+"${ns_args[@]}"})" ]]' || {
        echo "Timed out waiting for ${resource} to exist"
        exit 1
    }

    oc wait --for="${condition}" "${resource}" ${ns_args[@]+"${ns_args[@]}"} --timeout="${timeout}s"
}

# Retry a command until it succeeds or times out.
# All output (stdout/stderr) is preserved on every attempt.
# Usage: retry_command <timeout_seconds> <interval_seconds> <command> [args...]
retry_command() {
    local timeout="$1"
    local interval="$2"
    shift 2
    local start=${SECONDS}
    local attempt=1
    while true; do
        local elapsed=$(( SECONDS - start ))
        echo "  retry_command[attempt=${attempt} elapsed=${elapsed}s timeout=${timeout}s]: $*"
        local rc=0
        "$@" || rc=$?
        if (( rc == 0 )); then
            echo "  retry_command: succeeded on attempt ${attempt} after $(( SECONDS - start ))s"
            return 0
        fi
        if (( SECONDS - start >= timeout )); then
            echo "  retry_command: FAILED after ${attempt} attempts, $(( SECONDS - start ))s elapsed (exit code ${rc})"
            return "${rc}"
        fi
        echo "  retry_command: exit code ${rc}, retrying in ${interval}s..."
        sleep "${interval}"
        attempt=$(( attempt + 1 ))
    done
}

# HTTP request with retry. Outputs response body on success.
# Returns 1 and prints ERROR to stderr on persistent failure.
# Usage: http_retry <error_msg> <retries> <interval> [curl_args...]
http_retry() {
    local err_msg="$1" retries="$2" interval="$3"
    shift 3
    for attempt in $(seq 1 "$retries"); do
        curl -ksS --fail-with-body "$@" && return 0
        if (( attempt < retries )); then
            echo "  http_retry: attempt ${attempt}/${retries} failed, retrying in ${interval}s..." >&2
            sleep "$interval"
        fi
    done
    echo "ERROR: ${err_msg}" >&2
    return 1
}

# HTTP request with retry + jq parsing. Outputs parsed value on success.
# Returns 1 and prints ERROR to stderr on persistent failure.
# Usage: http_json <error_msg> <retries> <interval> <jq_filter> [curl_args...]
http_json() {
    local err_msg="$1" retries="$2" interval="$3" filter="$4"
    shift 4
    local result
    for attempt in $(seq 1 "$retries"); do
        if result=$(curl -ksS --fail-with-body "$@" | jq -r "$filter"); then
            printf '%s\n' "$result"
            return 0
        fi
        if (( attempt < retries )); then
            echo "  http_json: attempt ${attempt}/${retries} failed, retrying in ${interval}s..." >&2
            sleep "$interval"
        fi
    done
    echo "ERROR: ${err_msg}" >&2
    return 1
}

readonly POSTGRES_INSTALL_DOC="base/osac-fulfillment-service/docs/INSTALL.md"

# PostgreSQL prerequisite helpers (production install via setup.sh).
# Snapshot CI refresh mirrors host/endpoint resolution in
# scripts/refresh-after-snapshot.py (_postgres_target and related helpers).
# Keep both in sync when changing URL parsing or endpoint checks.

_postgres_prereq_error() {
    echo "ERROR: $1" >&2
    echo "Deploy in-cluster PostgreSQL via an operator per ${POSTGRES_INSTALL_DOC}" >&2
    exit 1
}

_bundled_postgres_enabled() {
    local values_file="$1"
    [[ -r "${values_file}" ]] || return 2
    awk '
        /^bundledPostgres:/ { bp=1; next }
        bp && /^[^[:space:]#]/ { bp=0 }
        bp && /^[[:space:]]+enabled:[[:space:]]*true([[:space:]]*#.*)?$/ { found=1 }
        END { exit !found }
    ' "$values_file"
}

_parse_db_host_from_url() {
    local url="$1"
    case "${url}" in
        postgres://*) ;;
        postgresql://*) url="postgres://${url#postgresql://}" ;;
        *) return 1 ;;
    esac
    local hostport="${url#postgres://}"
    hostport="${hostport#*@}"
    hostport="${hostport%%/*}"
    hostport="${hostport%%\?*}"
    echo "${hostport%%:*}"
}

# Resolve a PostgreSQL host from fulfillment-db URL to service and namespace.
# Prints "service target_namespace" on stdout; returns 1 if unrecognized.
_resolve_postgres_service() {
    local host="$1"
    local install_namespace="$2"
    local -a parts
    local i

    if [[ -z "${host}" ]]; then
        return 1
    fi

    if [[ "${host}" != *.* ]]; then
        printf '%s %s\n' "${host}" "${install_namespace}"
        return 0
    fi

    IFS='.' read -ra parts <<< "${host}"
    for i in "${!parts[@]}"; do
        if [[ "${parts[$i]}" == "svc" ]] && (( i >= 2 )); then
            printf '%s %s\n' "${parts[0]}" "${parts[1]}"
            return 0
        fi
    done

    if ((${#parts[@]} == 2)); then
        printf '%s %s\n' "${parts[0]}" "${parts[1]}"
        return 0
    fi

    return 1
}

_verify_postgres_endpoints() {
    local service="$1"
    local target_namespace="$2"

    oc get endpoints "${service}" -n "${target_namespace}" \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

readonly POSTGRES_IT_CHART="base/osac-fulfillment-service/it/charts/postgres/"

# CI-only: deploy the integration-test postgres chart when bundledPostgres is enabled
# but the postgres Service has no ready endpoints (e.g. e2e-full-install from a bare
# OpenShift flavor). Mirrors maybe_upgrade_fulfillment_db() in refresh-after-snapshot.py.
# Production installs with bundledPostgres disabled use operator-managed Postgres per
# INSTALL.md; snapshot refresh uses the Python helper instead of this function.
maybe_deploy_ci_postgres() {
    local namespace="$1"
    local values_file="$2"
    local repo_root bundled_status

    repo_root="$(cd "${_LIB_DIR}/.." && pwd)"
    _bundled_postgres_enabled "${values_file}"
    bundled_status=$?
    if [[ ${bundled_status} -eq 2 ]]; then
        _postgres_prereq_error "Values file ${values_file} not found or unreadable."
    elif [[ ${bundled_status} -ne 0 ]]; then
        return 0
    fi

    if _verify_postgres_endpoints "postgres" "${namespace}"; then
        echo "PostgreSQL already available, skipping CI postgres deploy"
        return 0
    fi

    echo "Deploying CI PostgreSQL (${POSTGRES_IT_CHART}) for bundledPostgres..."
    helm upgrade --install fulfillment-db "${repo_root}/${POSTGRES_IT_CHART}" \
        --namespace "${namespace}" \
        --set certs.issuerRef.name=default-ca \
        --set certs.caBundle.configMap=ca-bundle \
        --set "databases[0].name=service" \
        --set "databases[0].user=service" \
        --timeout 5m \
        --wait
}

# Verify in-cluster PostgreSQL is deployed before Helm install.
# Usage: check_postgres_prerequisites <namespace> <values_file>
check_postgres_prerequisites() {
    local namespace="$1"
    local values_file="$2"
    local service target_namespace db_url db_host resolved bundled_status

    _bundled_postgres_enabled "${values_file}"
    bundled_status=$?
    if [[ ${bundled_status} -eq 2 ]]; then
        _postgres_prereq_error "Values file ${values_file} not found or unreadable."
    elif [[ ${bundled_status} -eq 0 ]]; then
        echo "Checking in-cluster PostgreSQL prerequisites (bundledPostgres)..."
        service="postgres"
        target_namespace="${namespace}"
    else
        echo "Checking in-cluster PostgreSQL prerequisites..."
        oc get secret fulfillment-db -n "${namespace}" &>/dev/null || \
            _postgres_prereq_error "Secret fulfillment-db not found in namespace ${namespace}."
        oc get secret postgres-client-cert-service -n "${namespace}" &>/dev/null || \
            _postgres_prereq_error "Secret postgres-client-cert-service not found in namespace ${namespace}."

        db_url=$(oc get secret fulfillment-db -n "${namespace}" \
            -o jsonpath='{.data.url}' | base64 -d 2>/dev/null || true)
        [[ -n "${db_url}" ]] || \
            _postgres_prereq_error "Secret fulfillment-db in ${namespace} has an empty url key."

        db_host=$(_parse_db_host_from_url "${db_url}") || \
            _postgres_prereq_error "Secret fulfillment-db in ${namespace} has an invalid PostgreSQL url."
        resolved=$(_resolve_postgres_service "${db_host}" "${namespace}") || \
            _postgres_prereq_error "Unrecognized database hostname in fulfillment-db url."
        read -r service target_namespace <<< "${resolved}"
    fi

    if ! _verify_postgres_endpoints "${service}" "${target_namespace}"; then
        _postgres_prereq_error "PostgreSQL Service referenced by fulfillment-db has no ready endpoints."
    fi

    echo "PostgreSQL prerequisites satisfied."
}

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LIB_DIR}/oc.sh"
