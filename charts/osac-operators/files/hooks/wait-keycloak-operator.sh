#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for Keycloak operator Subscription..."
for i in $(seq 1 60); do
  oc get subscription keycloak-operator -n keycloak -o jsonpath='{.status.currentCSV}' 2>/dev/null | grep -q . && break
  [[ $i -eq 60 ]] && { echo "ERROR: Subscription CSV not resolved after 300s"; exit 1; }
  sleep 5
done

CSV=$(oc get subscription keycloak-operator -n keycloak -o jsonpath='{.status.currentCSV}')
echo "Subscription resolved to CSV: ${CSV}"

echo "Approving InstallPlan..."
for i in $(seq 1 60); do
  INSTALL_PLAN=$(oc get installplan -n keycloak -o jsonpath="{.items[?(@.spec.clusterServiceVersionNames[0]=='${CSV}')].metadata.name}" 2>/dev/null || true)
  if [[ -n "${INSTALL_PLAN}" ]]; then
    oc patch installplan "${INSTALL_PLAN}" -n keycloak --type=merge -p '{"spec":{"approved":true}}'
    echo "InstallPlan ${INSTALL_PLAN} approved"
    break
  fi
  [[ $i -eq 60 ]] && { echo "ERROR: InstallPlan not found after 300s"; exit 1; }
  sleep 5
done

echo "Waiting for CSV ${CSV} to exist..."
oc wait csv "${CSV}" -n keycloak --for=create --timeout=120s

echo "Waiting for CSV ${CSV} to reach Succeeded..."
oc wait csv "${CSV}" -n keycloak --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

echo "Waiting for Keycloak CRD to exist..."
for i in $(seq 1 60); do
  oc get crd keycloaks.k8s.keycloak.org 2>/dev/null && break
  [[ $i -eq 60 ]] && { echo "ERROR: Keycloak CRD not found after 300s"; exit 1; }
  sleep 5
done

echo "Keycloak operator is ready."
