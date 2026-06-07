#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}
INSTALLER_CLUSTER_TEMPLATE=${INSTALLER_CLUSTER_TEMPLATE:-}

# Create hub access kubeconfig
./scripts/create-hub-access-kubeconfig.sh

# Login to fulfillment internal API and ensure hub exists with current kubeconfig.
# The private API (osac.private.v1.*) is only available via the internal listener
# (fulfillment-internal-api route, port 8001). The external listener
# (fulfillment-api route, port 8000) only routes public API methods.
FULFILLMENT_INTERNAL_API_URL=https://$(oc get route -n "${INSTALLER_NAMESPACE}" fulfillment-internal-api -o jsonpath='{.status.ingress[0].host}')
echo "Fulfillment internal API URL: ${FULFILLMENT_INTERNAL_API_URL}"

echo "Logging into fulfillment internal API..."
retry_command 300 10 osac login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address "${FULFILLMENT_INTERNAL_API_URL}"

echo "Deleting existing hub..."
retry_command 300 10 osac delete hub hub

echo "Creating hub..."
retry_command 300 10 osac create hub --kubeconfig=/tmp/kubeconfig.hub-access --id hub --namespace "${INSTALLER_NAMESPACE}"

if [[ -n "${INSTALLER_VM_TEMPLATE}" || -n "${INSTALLER_CLUSTER_TEMPLATE}" ]]; then
    # Trigger a one-time publish-templates AAP job
    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    AAP_URL="https://${AAP_ROUTE_HOST}"
    AAP_TOKEN=$(oc get secret osac-aap-api-token -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)
    echo "Waiting for AAP controller API and project sync..."
    for attempt in $(seq 1 30); do
        JT_ID=$(curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
            "${AAP_URL}/api/controller/v2/job_templates/?name=osac-publish-templates" 2>/dev/null | jq -er '.results[0].id // empty' 2>/dev/null) && break
        echo "  attempt ${attempt}/30 - AAP controller API not ready, retrying in 10s..."
        sleep 10
    done
    [[ -z "${JT_ID:-}" ]] && { echo "Failed to find osac-publish-templates AAP job template after 30 attempts"; exit 1; }
    PROJECT_ID=$(curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/" 2>/dev/null | jq -r '.project // empty') || PROJECT_ID=""
    if [[ -n "${PROJECT_ID}" ]]; then
        echo "  Waiting for AAP project ${PROJECT_ID} to sync..."
        retry_until 300 10 '[[ "$(curl -kfsS -H "Authorization: Bearer '"${AAP_TOKEN}"'" \
            "'"${AAP_URL}"'/api/controller/v2/projects/'"${PROJECT_ID}"'/" 2>/dev/null \
            | jq -r ".status // empty")" == "successful" ]]' || {
            echo "WARNING: AAP project sync may not be complete"
        }
    fi
    echo "Launching publish-templates AAP job (template ID: ${JT_ID})..."
    JOB_ID=""
    for attempt in $(seq 1 10); do
        LAUNCH_ERR=$(mktemp)
        JOB_RESPONSE=$(curl -kfsS -X POST -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
            "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/launch/" 2>"${LAUNCH_ERR}") && {
            JOB_ID=$(echo "${JOB_RESPONSE}" | jq -r '.id // empty')
            [[ -n "${JOB_ID}" && "${JOB_ID}" != "null" ]] && break
        }
        echo "  launch attempt ${attempt}/10 - retrying in 10s..."
        HTTP_BODY=$(echo "${JOB_RESPONSE}" | jq -r '.playbook[0] // .detail // empty' 2>/dev/null)
        [[ -n "${HTTP_BODY}" ]] && echo "    reason: ${HTTP_BODY}"
        sleep 10
    done
    [[ -z "${JOB_ID}" || "${JOB_ID}" == "null" ]] && { echo "ERROR: Failed to launch publish-templates job after 10 attempts"; exit 1; }
    echo "  Job ${JOB_ID} launched, waiting for completion..."
    retry_until 300 10 '[[ "$(curl -kfsS -H "Authorization: Bearer '"${AAP_TOKEN}"'" \
        "'"${AAP_URL}"'/api/controller/v2/jobs/'"${JOB_ID}"'/" 2>/dev/null \
        | jq -r ".status // empty")" =~ ^(successful|failed|error|canceled)$ ]]' || true
    JOB_STATUS=$(curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/jobs/${JOB_ID}/" 2>/dev/null | jq -r '.status // empty') || JOB_STATUS=""
    if [[ "${JOB_STATUS}" != "successful" ]]; then
        echo "WARNING: publish-templates job ${JOB_ID} finished with status: ${JOB_STATUS}"
        curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
            "${AAP_URL}/api/controller/v2/jobs/${JOB_ID}/stdout/?format=txt" 2>/dev/null | tail -30 || true
    fi

    if [[ -n "${INSTALLER_VM_TEMPLATE}" ]]; then
        echo "Waiting for computeinstancetemplate ${INSTALLER_VM_TEMPLATE} to be published..."
        retry_until 300 5 'osac get computeinstancetemplate "${INSTALLER_VM_TEMPLATE}" -o json >/dev/null 2>&1' || {
            echo "Timed out waiting for computeinstancetemplate to exist"
            exit 1
        }
    fi

    if [[ -n "${INSTALLER_CLUSTER_TEMPLATE}" ]]; then
        echo "Waiting for clustertemplate ${INSTALLER_CLUSTER_TEMPLATE} to be published..."
        retry_until 300 5 'osac get clustertemplate "${INSTALLER_CLUSTER_TEMPLATE}" -o json >/dev/null 2>&1' || {
            echo "Timed out waiting for clustertemplate to exist"
            exit 1
        }
    fi
fi
