#!/usr/bin/env bash

# Require a command to be available in PATH.
# Usage: require_command <command> [install_hint]
require_command() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: '${cmd}' not found in PATH."
        [[ -n "${hint}" ]] && echo "${hint}"
        exit 1
    fi
}

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

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LIB_DIR}/oc.sh"
