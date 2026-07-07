#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure the shared ca-bundle Bundle exists and includes the given namespace.
#
# The Bundle is cluster-scoped and shared across deployments. This script
# creates the Bundle on first deploy and additively patches the selector on
# subsequent deploys.
#
# Usage: ensure-ca-bundle.sh <namespace>

NAMESPACE="${1:?Usage: ensure-ca-bundle.sh <namespace>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/oc.sh"

if oc get bundle ca-bundle &>/dev/null; then
    EXISTING=$(oc get bundle ca-bundle -o jsonpath='{.spec.target.namespaceSelector.matchExpressions[0].values}')
    if ! echo "${EXISTING}" | grep -q "\"${NAMESPACE}\""; then
        echo "Adding ${NAMESPACE} to ca-bundle namespace selector..."
        oc patch bundle ca-bundle --type=json -p \
            "[{\"op\":\"add\",\"path\":\"/spec/target/namespaceSelector/matchExpressions/0/values/-\",\"value\":\"${NAMESPACE}\"}]"
    fi
else
    echo "Creating ca-bundle Bundle targeting ${NAMESPACE}..."
    oc apply -f - <<EOF
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: ca-bundle
spec:
  sources:
  - secret:
      name: "default-ca"
      key: "ca.crt"
  target:
    configMap:
      key: bundle.pem
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values:
        - ${NAMESPACE}
EOF
fi
