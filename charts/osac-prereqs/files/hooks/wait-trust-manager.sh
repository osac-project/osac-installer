#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for trust-manager deployment to be Available (up to 5 min)..."
oc wait --for=condition=Available deploy/trust-manager -n cert-manager --timeout=300s

echo "trust-manager is ready. Applying ca-bundle Bundle CR..."
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
        - "${OSAC_NAMESPACE}"
EOF

echo "ca-bundle Bundle CR applied successfully."
