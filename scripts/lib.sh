#!/bin/bash

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

    retry_until 300 5 '[[ -n "$(oc get "${resource}" --ignore-not-found "${ns_args[@]}")" ]]' || {
        echo "Timed out waiting for ${resource} to exist"
        exit 1
    }

    oc wait --for="${condition}" "${resource}" "${ns_args[@]}" --timeout="${timeout}s"
}
