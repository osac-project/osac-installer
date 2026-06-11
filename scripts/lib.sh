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

# Fail with a clear message if a hostname does not resolve.
# Usage: require_host_resolvable <hostname>
require_host_resolvable() {
    local host="$1"
    if ! getent ahosts "${host}" &>/dev/null; then
        echo "ERROR: Cannot resolve hostname '${host}'." >&2
        echo "Add it to /etc/hosts pointing at your cluster ingress IP." >&2
        echo "  oc get routes -n <namespace> -o jsonpath='{range .items[*]}{.spec.host}{\"\\n\"}{end}'" >&2
        exit 1
    fi
}

# Require an OpenShift Route to exist and return its host.
# Usage: get_route_host <namespace> <route-name>
get_route_host() {
    local namespace="$1" route_name="$2" host="" rc=0
    host=$(oc get route "${route_name}" -n "${namespace}" -o jsonpath='{.spec.host}' 2>&1) || rc=$?
    if (( rc != 0 )); then
        echo "ERROR: failed to get route '${route_name}' in namespace '${namespace}':" >&2
        echo "${host}" >&2
        exit 1
    fi
    if [[ -z "${host}" ]]; then
        echo "ERROR: Route '${route_name}' not found in namespace '${namespace}'." >&2
        exit 1
    fi
    echo "${host}"
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
        if (( rc == 127 )); then
            echo "  retry_command: command not found — install it and ensure it is on PATH" >&2
            return 127
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

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LIB_DIR}/oc.sh"
