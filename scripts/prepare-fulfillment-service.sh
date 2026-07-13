#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac"}
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}
INSTALLER_CLUSTER_TEMPLATE=${INSTALLER_CLUSTER_TEMPLATE:-}

create_hub() {
    ./scripts/create-hub-access-kubeconfig.sh

    local fulfillment_url
    fulfillment_url=https://$(oc get route -n "${INSTALLER_NAMESPACE}" fulfillment-internal-api -o jsonpath='{.status.ingress[0].host}')
    echo "Fulfillment internal API URL: ${fulfillment_url}"

    echo "Logging into fulfillment internal API..."
    retry_command 300 10 osac login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address "${fulfillment_url}"

    echo "Deleting existing hub..."
    retry_command 300 10 osac delete hub hub

    echo "Creating hub..."
    local _server_name
    _server_name=$(oc config view --minify --output jsonpath="{.clusters[*].cluster.server}")
    _server_name=${_server_name#*.}; _server_name=${_server_name%%.*}
    retry_command 300 10 osac create hub --kubeconfig="/tmp/kubeconfig.hub-access.${_server_name}" --id hub --namespace "${INSTALLER_NAMESPACE}"
}

sync_aap_project() {
    local AAP_ROUTE_HOST AAP_URL AAP_TOKEN JT_ID PROJECT_ID
    local EXPECTED_BRANCH EXPECTED_URI

    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    AAP_URL="https://${AAP_ROUTE_HOST}"
    AAP_TOKEN=$(oc get secret osac-aap-api-token -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

    echo "Waiting for AAP controller API..."
    JT_ID=$(http_json "Failed to find osac-publish-templates job template" 30 10 \
        '.results[0].id // empty' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/?name=osac-publish-templates") || exit 1
    [[ -z "${JT_ID}" ]] && { echo "ERROR: osac-publish-templates job template returned empty ID"; exit 1; }

    PROJECT_ID=$(http_json "Failed to read job template ${JT_ID}" 6 10 \
        '.project // empty' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/") || exit 1
    [[ -z "${PROJECT_ID}" ]] && { echo "ERROR: Could not determine project ID from job template ${JT_ID}"; exit 1; }

    EXPECTED_BRANCH=$(oc get secret config-as-code-ig -n "${INSTALLER_NAMESPACE}" \
        -o jsonpath='{.data.AAP_PROJECT_GIT_BRANCH}' | base64 -d)
    EXPECTED_URI=$(oc get secret config-as-code-ig -n "${INSTALLER_NAMESPACE}" \
        -o jsonpath='{.data.AAP_PROJECT_GIT_URI}' | base64 -d)
    [[ -z "${EXPECTED_BRANCH}" ]] && { echo "ERROR: AAP_PROJECT_GIT_BRANCH not set in config-as-code-ig secret"; exit 1; }
    [[ -z "${EXPECTED_URI}" ]] && { echo "ERROR: AAP_PROJECT_GIT_URI not set in config-as-code-ig secret"; exit 1; }
    echo "  Expected: ${EXPECTED_URI}@${EXPECTED_BRANCH}"

    local CURRENT CURRENT_URL CURRENT_BRANCH
    CURRENT=$(http_json "Failed to read project ${PROJECT_ID}" 6 10 \
        '.' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/") || exit 1
    CURRENT_URL=$(echo "${CURRENT}" | jq -r '.scm_url // empty')
    CURRENT_BRANCH=$(echo "${CURRENT}" | jq -r '.scm_branch // empty')

    if [[ "${CURRENT_URL}" != "${EXPECTED_URI}" || "${CURRENT_BRANCH}" != "${EXPECTED_BRANCH}" ]]; then
        echo "  Project stale: ${CURRENT_URL}@${CURRENT_BRANCH} → ${EXPECTED_URI}@${EXPECTED_BRANCH}"
        http_retry "Failed to patch project ${PROJECT_ID}" 12 10 \
            -X PATCH -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
            "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/" \
            -d "{\"scm_url\": \"${EXPECTED_URI}\", \"scm_branch\": \"${EXPECTED_BRANCH}\"}" || exit 1
    else
        echo "  Project already points to correct repo/branch"
    fi

    http_retry "Failed to trigger project update" 12 10 \
        -X POST -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/update/" || exit 1
    local _sync_start=${SECONDS} _proj_status=""
    while (( SECONDS - _sync_start < 300 )); do
        _proj_status=$(http_json "Failed to read project ${PROJECT_ID} status" 3 5 \
            '.status // empty' \
            -H "Authorization: Bearer ${AAP_TOKEN}" \
            "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/") || continue
        [[ "${_proj_status}" == "successful" ]] && break
        if [[ "${_proj_status}" == "failed" || "${_proj_status}" == "error" ]]; then
            echo "  Project sync failed (status: ${_proj_status}), forcing retry..."
            http_retry "Failed to re-trigger project update" 6 10 \
                -X POST -H "Authorization: Bearer ${AAP_TOKEN}" \
                "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/update/" || exit 1
        fi
        sleep 10
    done
    [[ "${_proj_status}" == "successful" ]] || { echo "ERROR: AAP project sync failed after 300s (last status: ${_proj_status})"; exit 1; }

    local SYNCED_REV
    SYNCED_REV=$(http_json "Failed to read project ${PROJECT_ID} after sync" 6 10 \
        '.scm_revision // empty' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/") || exit 1
    echo "  AAP project synced to ${SYNCED_REV}"
    if [[ "${EXPECTED_BRANCH}" =~ ^[0-9a-f]{40}$ && "${SYNCED_REV}" != "${EXPECTED_BRANCH}" ]]; then
        echo "ERROR: AAP project synced to ${SYNCED_REV} but expected ${EXPECTED_BRANCH}"
        exit 1
    fi
}

publish_templates() {
    local AAP_ROUTE_HOST AAP_URL AAP_TOKEN JT_ID PROJECT_ID

    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    AAP_URL="https://${AAP_ROUTE_HOST}"
    AAP_TOKEN=$(oc get secret osac-aap-api-token -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

    JT_ID=$(http_json "Failed to query osac-publish-templates job template" 6 10 \
        '.results[0].id // empty' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/?name=osac-publish-templates") || exit 1
    [[ -z "${JT_ID}" ]] && { echo "ERROR: osac-publish-templates job template not found"; exit 1; }

    PROJECT_ID=$(http_json "Failed to read job template ${JT_ID}" 6 10 \
        '.project // empty' \
        -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/") || exit 1
    [[ -z "${PROJECT_ID}" ]] && { echo "ERROR: Could not determine project ID from job template ${JT_ID}"; exit 1; }

    echo "Launching publish-templates AAP job (template ID: ${JT_ID})..."
    local JOB_SUCCEEDED=false JOB_ID JOB_STATUS
    for job_attempt in $(seq 1 3); do
        JOB_ID=$(http_json "Failed to launch publish-templates job" 10 10 \
            '.id // empty' \
            -X POST -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
            "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/launch/") || exit 1
        [[ -z "${JOB_ID}" ]] && { echo "ERROR: publish-templates job launch returned empty ID"; exit 1; }
        echo "  Job ${JOB_ID} launched, waiting for completion..."

        local _job_start=${SECONDS}
        JOB_STATUS=""
        while (( SECONDS - _job_start < 300 )); do
            JOB_STATUS=$(http_json "Failed to poll job ${JOB_ID} status" 1 0 '.status // empty' \
                -H "Authorization: Bearer ${AAP_TOKEN}" \
                "${AAP_URL}/api/controller/v2/jobs/${JOB_ID}/") || true
            [[ "${JOB_STATUS}" =~ ^(successful|failed|error|canceled)$ ]] && break
            sleep 10
        done
        [[ ! "${JOB_STATUS}" =~ ^(successful|failed|error|canceled)$ ]] && {
            echo "ERROR: Timed out waiting for publish-templates job ${JOB_ID}"
            exit 1
        }

        if [[ "${JOB_STATUS}" == "successful" ]]; then
            JOB_SUCCEEDED=true
            break
        fi
        echo "  Job ${JOB_ID} finished with status: ${JOB_STATUS} (attempt ${job_attempt}/3)"
        curl -ksS -H "Authorization: Bearer ${AAP_TOKEN}" \
            "${AAP_URL}/api/controller/v2/jobs/${JOB_ID}/stdout/?format=txt" 2>/dev/null | tail -10 || true
        echo "  Forcing project update before retry..."
        http_retry "Failed to trigger project update before retry" 6 10 \
            -X POST -H "Authorization: Bearer ${AAP_TOKEN}" \
            "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/update/" || exit 1
        local _proj_start=${SECONDS} _proj_status=""
        while (( SECONDS - _proj_start < 60 )); do
            _proj_status=$(http_json "Failed to poll project ${PROJECT_ID} status" 1 0 '.status // empty' \
                -H "Authorization: Bearer ${AAP_TOKEN}" \
                "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/") || true
            [[ "${_proj_status}" == "successful" ]] && break
            sleep 5
        done
        [[ "${_proj_status}" != "successful" ]] && { echo "ERROR: Project sync failed before retry"; exit 1; }
    done
    if [[ "${JOB_SUCCEEDED}" != "true" ]]; then
        echo "ERROR: publish-templates job failed after 3 attempts"
        exit 1
    fi
}

patch_token_config() {
    local api_route_host issuer_url
    # The route ingress host may take a moment to populate after apply.
    retry_until 60 5 \
        '[[ -n "$(oc get route -n "${INSTALLER_NAMESPACE}" fulfillment-api -o jsonpath="{.status.ingress[0].host}" 2>/dev/null)" ]]' || {
        echo "ERROR: fulfillment-api route has no ingress host after 60s"
        exit 1
    }
    api_route_host=$(oc get route -n "${INSTALLER_NAMESPACE}" fulfillment-api -o jsonpath='{.status.ingress[0].host}')
    issuer_url="https://${api_route_host}"

    echo "Patching token-issuer and CORS to ${issuer_url}..."

    patch_command_arg() {
        local deploy="$1" prefix="$2" value="$3"
        local idx
        idx=$(oc get "deployment/${deploy}" -n "${INSTALLER_NAMESPACE}" -o json \
            | jq --arg p "${prefix}" '[.spec.template.spec.containers[0].command | to_entries[] | select(.value | startswith($p)) | .key] | first')
        [[ -z "${idx}" || "${idx}" == "null" ]] && { echo "ERROR: ${prefix} not found in ${deploy} command"; exit 1; }
        oc patch "deployment/${deploy}" -n "${INSTALLER_NAMESPACE}" --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command/${idx}\",\"value\":\"${value}\"}]"
    }

    # Add external FQDN to certificate SANs BEFORE patching deployments.
    # Deployments patch triggers a rollout — the new pods fetch JWKS via the
    # external URL and need the certificate to cover it.
    if ! oc get certificate/fulfillment-api -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.dnsNames}' | grep -qF "${api_route_host}"; then
        oc patch certificate/fulfillment-api -n "${INSTALLER_NAMESPACE}" --type=json \
            -p "[{\"op\":\"add\",\"path\":\"/spec/dnsNames/-\",\"value\":\"${api_route_host}\"}]"
        echo "Waiting for certificate reissue..."
        oc wait certificate/fulfillment-api -n "${INSTALLER_NAMESPACE}" \
            --for=condition=Ready --timeout=120s
        # Envoy does not hot-reload TLS certs — restart so it serves the new cert
        # before console-proxy tries to fetch JWKS via the external URL.
        oc rollout restart deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}"
        oc rollout status deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}" --timeout=120s
    fi

    patch_command_arg fulfillment-grpc-server "--token-issuer=" "--token-issuer=${issuer_url}"
    patch_command_arg fulfillment-console-proxy "--token-issuer=" "--token-issuer=${issuer_url}"
    patch_command_arg fulfillment-console-proxy "--console-cors-allowed-origins=" "--console-cors-allowed-origins=${issuer_url}"
}

if [[ "${SKIP_TOKEN_CONFIG_PATCH:-}" != "1" ]]; then
    patch_token_config
fi

create_hub &
pid_hub=$!
sync_aap_project &
pid_sync=$!

hub_rc=0; sync_rc=0
wait ${pid_hub} || hub_rc=$?
wait ${pid_sync} || sync_rc=$?
(( hub_rc )) && echo "ERROR: Hub creation failed (exit ${hub_rc})"
(( sync_rc )) && echo "ERROR: AAP project sync failed (exit ${sync_rc})"
(( hub_rc || sync_rc )) && exit 1

if [[ -n "${INSTALLER_VM_TEMPLATE}" || -n "${INSTALLER_CLUSTER_TEMPLATE}" ]]; then
    # Project sync can trigger AAP reconciliation that restarts the gateway.
    # Wait for it to recover before launching publish-templates.
    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    retry_until 300 10 '[[ "$(curl -sk -o /dev/null -w %{http_code} "https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/")" == "200" ]]' || {
        echo "ERROR: AAP gateway not responding after project sync"
        exit 1
    }
    publish_templates

    if [[ -n "${INSTALLER_VM_TEMPLATE}" ]]; then
        echo "Waiting for computeinstancetemplate ${INSTALLER_VM_TEMPLATE} to be published..."
        retry_until 300 5 'osac get computeinstancetemplate "${INSTALLER_VM_TEMPLATE}" -o json >/dev/null 2>&1' || {
            echo "ERROR: Timed out waiting for computeinstancetemplate ${INSTALLER_VM_TEMPLATE}"
            exit 1
        }
    fi

    if [[ -n "${INSTALLER_CLUSTER_TEMPLATE}" ]]; then
        echo "Waiting for clustertemplate ${INSTALLER_CLUSTER_TEMPLATE} to be published..."
        retry_until 300 5 'osac get clustertemplate "${INSTALLER_CLUSTER_TEMPLATE}" -o json >/dev/null 2>&1' || {
            echo "ERROR: Timed out waiting for clustertemplate ${INSTALLER_CLUSTER_TEMPLATE}"
            exit 1
        }
    fi
fi
