# Prerequisites for OSAC Installation

## Overview

The OSAC solution requires several components to be installed on the cluster before deployment.
Your administrator may have set up some of these components already. Check with them first
before installing.

The manifests in this directory are examples for development and testing environments.

This directory supports **kustomize-based deployment**, allowing you to install all prerequisites
with a single command or selectively install individual components.

## Directory Structure

```
prerequisites/
├── kustomization.yaml              # Root orchestrator for unified deployment
├── cert-manager/
│   ├── kustomization.yaml
│   └── cert-manager.yaml
├── keycloak/
│   ├── kustomization.yaml
│   ├── database/
│   └── service/
├── nfs-subdir-provisioner/
│   ├── base/
│   └── overlays/lab/
├── ca-issuer.yaml
├── trust-manager.yaml
├── authorino-operator.yaml
├── aap-installation.yaml
└── vmaas-components.yaml           # Not included in unified deployment
```

## Required Components

| Component | Purpose | Manifest |
|-----------|---------|----------|
| Cert Manager | TLS certificate management | `cert-manager/` |
| Trust Manager | CA certificate distribution | `trust-manager.yaml` |
| CA Issuer | ClusterIssuer for signing certificates | `ca-issuer.yaml` |
| Authorino Operator | API authorization | `authorino-operator.yaml` |
| Keycloak | Identity provider (OIDC) | `keycloak/` |
| Red Hat AAP Operator | Ansible Automation Platform | `aap-installation.yaml` |
| OpenShift Virtualization | VM as a Service support | `vmaas-components.yaml` |
| NFS Subdir Provisioner | Dynamic storage for VM migration | `nfs-subdir-provisioner/` |

**Note:** Red Hat Advanced Cluster Management (ACM) is assumed to be already installed.

## Installation Options

### Option A: Unified Kustomize Deployment (Recommended)

Deploy all prerequisites at once using the root `kustomization.yaml`.

#### Pre-configuration

Before deploying, configure your NFS server settings:

```bash
# Edit prerequisites/nfs-subdir-provisioner/overlays/lab/nfs-patch.yaml
# Set NFS_SERVER and NFS_PATH to match your environment
```

#### Apply-Wait-Reapply Pattern

The unified deployment uses an **apply-wait-reapply pattern** because operators create CRDs
that are immediately referenced by other resources. The first apply creates the CRDs,
but dependent resources fail until the CRDs are registered.

```bash
# First apply - expect some errors (CRDs not yet registered)
oc apply -k prerequisites/

# Wait for operators to install (check operator pods are running)
oc get pods -n cert-manager
oc get pods -n openshift-operators

# Re-apply - more resources will succeed
oc apply -k prerequisites/

# Repeat until no errors
oc apply -k prerequisites/
```

#### What's Included

The unified deployment includes:
- Cert Manager
- Trust Manager
- CA Issuer
- Authorino Operator
- Keycloak
- NFS Subdir Provisioner (lab overlay)
- Red Hat AAP Operator

**Not included:** OpenShift Virtualization (`vmaas-components.yaml`) - see Step 7 below.

### Option B: Individual Component Installation

Install components individually for selective installation or troubleshooting.

#### Step 1: Cert Manager

```bash
oc apply -k prerequisites/cert-manager/

# Wait for the operator to be ready
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
```

#### Step 2: Trust Manager

Requires cert-manager to be running.

```bash
oc apply -f prerequisites/trust-manager.yaml

# Verify installation
oc get pods -n cert-manager -l app.kubernetes.io/name=trust-manager
oc get crd bundles.trust.cert-manager.io
```

#### Step 3: CA Issuer

Creates a self-signed ClusterIssuer for signing certificates.

```bash
oc apply -f prerequisites/ca-issuer.yaml

# Verify the ClusterIssuer is ready
oc get clusterissuer default-ca
```

#### Step 4: Authorino Operator

Provides API authorization capabilities.

```bash
oc apply -f prerequisites/authorino-operator.yaml

# Wait for the operator to be installed
oc get csv -n openshift-operators | grep authorino
```

#### Step 5: Keycloak (Optional)

Identity provider for OIDC authentication. Skip if using an external identity provider.

```bash
oc apply -k prerequisites/keycloak/

# Wait for Keycloak to be ready
oc get pods -n keycloak
```

#### Step 6: Red Hat AAP Operator

Ansible Automation Platform for cluster provisioning workflows.

```bash
oc apply -f prerequisites/aap-installation.yaml

# Wait for the operator to be installed
oc get csv -n ansible-aap | grep ansible-automation-platform
```

#### Step 7: OpenShift Virtualization (Optional)

Required for VM as a Service (VMaaS) functionality.

**Note:** This component is NOT included in the unified deployment because it creates CRDs
and immediately references them, requiring the apply-wait-reapply pattern.

```bash
# First apply - creates CRDs
oc apply -f prerequisites/vmaas-components.yaml

# Wait for CRDs to be registered
oc get crd hyperconvergeds.hco.kubevirt.io

# Re-apply to create dependent resources
oc apply -f prerequisites/vmaas-components.yaml

# Wait for the HyperConverged operator to be ready
oc wait --for=condition=Available hco kubevirt-hyperconverged -n openshift-cnv --timeout=600s
```

#### Step 8: NFS Subdir Provisioner (Optional)

Required for VM live migration with shared storage.

Before applying, configure your NFS server settings in the overlay's `nfs-patch.yaml`:

```yaml
# Edit prerequisites/nfs-subdir-provisioner/overlays/lab/nfs-patch.yaml
env:
  - name: NFS_SERVER
    value: "your-nfs-server.example.com"  # Your NFS server address
  - name: NFS_PATH
    value: "/exported/path"               # Your NFS exported path
volumes:
  - name: nfs-client-root
    nfs:
      server: "your-nfs-server.example.com"
      path: "/exported/path"
```

Then apply the configuration:

```bash
oc apply -k prerequisites/nfs-subdir-provisioner/overlays/lab/

# Verify the storage class is created
oc get storageclass | grep nfs
```

## Verification

After installing all prerequisites, verify the components are running:

```bash
# Cert Manager
oc get pods -n cert-manager

# Authorino
oc get pods -n openshift-operators -l app=authorino-operator

# AAP
oc get pods -n ansible-aap

# OpenShift Virtualization (if installed)
oc get pods -n openshift-cnv
```

## Notes

- These manifests are provided as examples for development environments
- Production deployments may require additional configuration
- Consult your cluster administrator before installing operators
- Some resources depend on CRDs that are created by operators; if an apply fails, wait for the operator to finish installing and try again
