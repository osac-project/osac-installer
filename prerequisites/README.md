# Prerequisites for OSAC Installation

## Overview

The OSAC solution requires several components to be installed on the cluster before deployment.
Your administrator may have set up some of these components already. Check with them first
before installing.

The manifests in this directory are examples for development and testing environments.

## Directory Structure

```
prerequisites/
├── cert-manager/
│   └── cert-manager.yaml
├── keycloak/
│   ├── namespace.yaml
│   ├── database/
│   └── service/
├── ca-issuer.yaml
├── trust-manager.yaml
├── aap-installation.yaml
├── cnv/
├── lvms/
├── mce/
└── metallb/
```

## Required Components

| Component | Purpose | Manifest |
|-----------|---------|----------|
| Cert Manager | TLS certificate management | `cert-manager/cert-manager.yaml` |
| Trust Manager | CA certificate distribution | `trust-manager.yaml` |
| CA Issuer | ClusterIssuer for signing certificates | `ca-issuer.yaml` |
| Keycloak | Identity provider (OIDC) | `keycloak/` |
| Red Hat AAP Operator | Ansible Automation Platform | `aap-installation.yaml` |

## Optional Components

| Component | Purpose | Manifest |
|-----------|---------|----------|
| LVMS | Storage service (StorageClass) | `lvms/` |
| MetalLB | LoadBalancer service for bare metal | `metallb/` |
| MCE | Multicluster Engine for CaaS | `mce/` |
| OpenShift Virtualization | VM as a Service support | `cnv/` |

**Note:** Red Hat Advanced Cluster Management (ACM) is assumed to be already installed.

## Installation

Install components in order — some depend on earlier ones.

### Step 1: Cert Manager

```bash
oc apply -f prerequisites/cert-manager/cert-manager.yaml

# Wait for the operator to be ready
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
```

### Step 2: Trust Manager

Requires cert-manager to be running.

```bash
oc apply -f prerequisites/trust-manager.yaml
oc wait --for=condition=Available deployment/trust-manager -n cert-manager --timeout=300s
```

### Step 3: CA Issuer

Creates a self-signed ClusterIssuer for signing certificates.

```bash
oc apply -f prerequisites/ca-issuer.yaml
oc wait clusterissuer/default-ca --for=condition=Ready --timeout=300s
```

### Step 4: Keycloak

Identity provider for OIDC authentication. Deployed via the Keycloak operator
(OLM subscription in `charts/osac-operators/`, instance CR in `charts/osac-prereqs/`).

```bash
# Install via Helm charts (recommended):
helm install osac-operators charts/osac-operators/
helm install osac-prereqs charts/osac-prereqs/

# The Keycloak operator manages the instance lifecycle. Wait for readiness:
oc wait keycloak/osac-keycloak -n keycloak \
    --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=600s
```

### Step 5: Red Hat AAP Operator

Ansible Automation Platform for provisioning workflows.

```bash
oc apply -f prerequisites/aap-installation.yaml

# Wait for the operator to be installed
oc get csv -n ansible-aap | grep ansible-automation-platform
```

### Step 6: Optional Components

LVMS, MetalLB, MCE, and OpenShift Virtualization are installed automatically
by `make install-operators` (Phase 1) when enabled in values. Each is gated
by a toggle (e.g., `lvms.enabled: true`). The manifests below are reference
files for manual installation if needed.

## Verification

After installing all prerequisites, verify the components are running:

```bash
# Cert Manager
oc get pods -n cert-manager

# Keycloak
oc get pods -n keycloak

# AAP
oc get pods -n ansible-aap
```

## Notes

- These manifests are provided as examples for development environments
- Production deployments may require additional configuration
- Consult your cluster administrator before installing operators
- Some resources depend on CRDs that are created by operators; if an apply fails, wait for the operator to finish installing and try again
