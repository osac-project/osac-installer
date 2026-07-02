# OSAC Helm Deployment Guide

Step-by-step guide for deploying OSAC on a clean connected OpenShift cluster
using the Helm umbrella chart. Covers VMaaS and CaaS profiles.

## Table of Contents

- [Before You Begin](#before-you-begin)
- [Phase 1: Cluster Prerequisites](#phase-1-cluster-prerequisites)
  - [1.1 Storage (LVMS)](#11-storage-lvms)
  - [1.2 Ingress (MetalLB)](#12-ingress-metallb)
  - [1.3 Multicluster Engine (MCE)](#13-multicluster-engine-mce)
  - [1.4 OpenShift Virtualization (CNV)](#14-openshift-virtualization-cnv)
  - [1.5 cert-manager and trust-manager](#15-cert-manager-and-trust-manager)
  - [1.6 CA Issuer](#16-ca-issuer)
  - [1.7 Keycloak](#17-keycloak)
  - [1.8 AAP Operator](#18-aap-operator)
  - [1.9 PostgreSQL (Fulfillment Database)](#19-postgresql-fulfillment-database)
- [Phase 2: Prepare Secrets and Configuration](#phase-2-prepare-secrets-and-configuration)
  - [2.1 CA Trust Bundle](#21-ca-trust-bundle)
  - [2.2 PostgreSQL Database](#22-postgresql-database)
  - [2.3 Fulfillment Controller Credentials](#23-fulfillment-controller-credentials)
  - [2.4 AAP License](#24-aap-license)
  - [2.5 AAP Config-as-Code Secret](#25-aap-config-as-code-secret)
  - [2.6 Instance Group Configuration (Optional)](#26-instance-group-configuration-optional)
- [Phase 3: Deploy OSAC via Helm](#phase-3-deploy-osac-via-helm)
  - [3.1 Initialize Submodules](#31-initialize-submodules)
  - [3.2 Choose a Values File](#32-choose-a-values-file)
  - [3.3 Validate](#33-validate)
  - [3.4 Deploy](#34-deploy)
  - [3.5 Verify](#35-verify)
- [Phase 4: Post-Install Configuration](#phase-4-post-install-configuration)
  - [4.1 Create AAP API Token](#41-create-aap-api-token)
  - [4.2 Install the OSAC CLI](#42-install-the-osac-cli)
  - [4.3 Register the Hub](#43-register-the-hub)
  - [4.4 Create Tenants](#44-create-tenants)
  - [4.5 Apply AAP Instance Group Overrides](#45-apply-aap-instance-group-overrides)
- [Profile Reference](#profile-reference)
- [Automated Alternative](#automated-alternative)
- [Troubleshooting](#troubleshooting)

---

## Before You Begin

### Requirements

| Requirement | Details |
|-------------|---------|
| OpenShift | 4.17+ with cluster-admin access |
| CLI tools | `oc`, `helm`, `git`, `jq` |
| Network | Outbound access to github.com, ghcr.io, quay.io, registry.redhat.io |
| Storage | A default StorageClass (or install LVMS below) |
| AAP license | Subscription manifest (`license.zip`) from [Red Hat Customer Portal](https://access.redhat.com/) |

### Clone and Verify

```bash
git clone https://github.com/osac-project/osac-installer.git
cd osac-installer

# Verify cluster access
oc whoami
oc whoami --show-server
```

### Choose Your Namespace

Pick a namespace for OSAC. All commands below use `NAMESPACE` — set it once:

```bash
export NAMESPACE=osac
```

---

## Phase 1: Cluster Prerequisites

Install in the order shown — some prerequisites depend on earlier ones
(e.g., Keycloak needs a StorageClass, AAP bootstrap needs cert-manager).

### Which Prerequisites Do I Need?

| Prerequisite | Required? | Notes |
|-------------|-----------|-------|
| cert-manager + trust-manager | **Yes** | TLS certificates for all OSAC services |
| CA Issuer | **Yes** | Self-signed CA for internal certificates |
| Keycloak | **Yes** | Identity provider for OAuth/OIDC |
| AAP Operator | **Yes** | Ansible Automation Platform for provisioning workflows |
| PostgreSQL (fulfillment DB) | **Yes** | In-cluster operator-managed database for fulfillment-service |
| LVMS | Only if no default StorageClass exists | Provides `lvms-vg1` StorageClass |
| MetalLB | Only if no LoadBalancer service exists | Provides bare-metal load balancing |
| MCE | Only for CaaS (cluster provisioning) | Multicluster Engine + infrastructure operator |
| CNV | Only for VMaaS (VM provisioning) | OpenShift Virtualization |

### 1.1 Storage (LVMS)

Skip if your cluster already has a default StorageClass (`oc get sc`).

```bash
oc apply -f prerequisites/lvms/lvms-operator.yaml

# Wait for the LVMS operator CSV to appear
until LVMS_CSV=$(oc get csv --no-headers -n openshift-storage 2>/dev/null \
  | awk '/lvms/ { print $1 }' | tail -1) && [[ -n "${LVMS_CSV}" ]]; do
  sleep 10
done
echo "Found CSV: ${LVMS_CSV}"
oc wait csv/${LVMS_CSV} -n openshift-storage \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s

# Apply LVMCluster configuration
oc apply -f prerequisites/lvms/lvms-config.yaml

# Wait for the StorageClass and set it as default
oc wait --for=jsonpath='{.metadata.name}'=lvms-vg1 sc/lvms-vg1 --timeout=300s
oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite
```

### 1.2 Ingress (MetalLB)

MetalLB provides a `LoadBalancer` service type implementation. Whether you
need it depends on your cluster:

- **Cloud clusters** (AWS, Azure, GCP) — the cloud provider handles
  LoadBalancer services automatically. **Skip MetalLB.**
- **Bare-metal / on-prem clusters** (e.g., MOC) — no built-in LoadBalancer.
  **Install MetalLB.**

To check, run:

```bash
oc get svc -A --field-selector spec.type=LoadBalancer
```

If existing LoadBalancer services have assigned IPs under `EXTERNAL-IP`, you
already have a LoadBalancer implementation. If they show `<pending>`, you need
MetalLB.

```bash
oc apply -f prerequisites/metallb/metallb-operator.yaml

# Wait for the MetalLB operator CSV to appear
until METALLB_CSV=$(oc get csv --no-headers -n metallb-system 2>/dev/null \
  | awk '/metallb/ { print $1 }' | tail -1) && [[ -n "${METALLB_CSV}" ]]; do
  sleep 10
done
echo "Found CSV: ${METALLB_CSV}"
oc wait csv/${METALLB_CSV} -n metallb-system \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
oc wait deployment/metallb-operator-controller-manager -n metallb-system \
  --for=condition=Available --timeout=300s

# Apply MetalLB configuration (IPAddressPool, L2Advertisement)
oc apply -f prerequisites/metallb/metallb-config.yaml
```

### 1.3 Multicluster Engine (MCE)

Required for **CaaS** (cluster provisioning). Skip for VMaaS-only.

```bash
oc apply -f prerequisites/mce/mce-operator.yaml

# Wait for the MCE operator CSV to appear
until MCE_CSV=$(oc get csv --no-headers -n multicluster-engine 2>/dev/null \
  | awk '/multicluster-engine/ { print $1 }' | tail -1) && [[ -n "${MCE_CSV}" ]]; do
  sleep 10
done
echo "Found CSV: ${MCE_CSV}"
oc wait csv/${MCE_CSV} -n multicluster-engine \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

# Create the MultiClusterEngine instance
cat <<EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine
spec: {}
EOF

# Wait for MCE to become Available (can take several minutes)
oc wait multiclusterengine/multiclusterengine \
  --for=jsonpath='{.status.phase}'=Available --timeout=600s

# Apply AgentServiceConfig
oc apply -f prerequisites/mce/mce-config.yaml

# Wait for the infrastructure operator
oc wait deployment/assisted-service -n multicluster-engine \
  --for=condition=Available --timeout=600s
```

### 1.4 OpenShift Virtualization (CNV)

Required for **VMaaS** (VM provisioning). Skip for CaaS-only.

```bash
oc apply -f prerequisites/cnv/cnv-operator.yaml

# Wait for the CNV operator CSV to appear
until CNV_CSV=$(oc get csv --no-headers -n openshift-cnv 2>/dev/null \
  | awk '/kubevirt-hyperconverged-operator/ { print $1 }' | tail -1) && [[ -n "${CNV_CSV}" ]]; do
  sleep 10
done
echo "Found CSV: ${CNV_CSV}"
oc wait csv/${CNV_CSV} -n openshift-cnv \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

# Apply HyperConverged CR
oc apply -f prerequisites/cnv/cnv-config.yaml

# Wait for HyperConverged to be Available (can take up to 10 minutes)
oc wait hyperconverged/kubevirt-hyperconverged -n openshift-cnv \
  --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True \
  --timeout=900s
```

### 1.5 cert-manager and trust-manager

The cert-manager prerequisite file contains both the operator Subscription and
the `CertManager` CR. The CR will fail on first apply because the CRD doesn't
exist yet — this is expected. Apply, wait for the operator, then apply again:

```bash
# First apply: creates Namespace, OperatorGroup, Subscription.
# The CertManager CR will fail — that's expected.
oc apply -k prerequisites/cert-manager/ || true

# Wait for the operator to install and register the CRD
oc wait crd/certmanagers.operator.openshift.io --for=condition=Established --timeout=300s

# Second apply: now the CertManager CR succeeds
oc apply -k prerequisites/cert-manager/

# Wait for cert-manager deployments
oc wait deployment/cert-manager -n cert-manager --for=condition=Available --timeout=300s
oc wait deployment/cert-manager-webhook -n cert-manager --for=condition=Available --timeout=300s
oc wait deployment/cert-manager-cainjector -n cert-manager --for=condition=Available --timeout=300s

# Install trust-manager
oc apply -f prerequisites/trust-manager.yaml
oc wait deployment/trust-manager -n cert-manager --for=condition=Available --timeout=300s
```

### 1.6 CA Issuer

```bash
oc apply -f prerequisites/ca-issuer.yaml
oc wait clusterissuer/default-ca --for=condition=Ready --timeout=300s
```

### 1.7 Keycloak

Keycloak provides identity management (OAuth/OIDC) for OSAC. It includes its
own PostgreSQL database.

```bash
oc apply -k prerequisites/keycloak/
oc wait deployment/keycloak-service -n keycloak --for=condition=Available --timeout=600s
```

### 1.8 AAP Operator

This installs the AAP operator only. The AAP instance itself (controller, EDA,
gateway) is created by the Helm chart.

> **Note:** Depending on the AAP version, the operator may install into the
> `ansible-aap` or `aap` namespace. The commands below use `ansible-aap`. If
> your AAP operator is already installed in a different namespace, adjust
> `AAP_NS` accordingly.

```bash
oc apply -f prerequisites/aap-installation.yaml

# Detect the AAP operator namespace
AAP_NS=""
for ns in aap ansible-aap openshift-operators; do
  if oc get deployment automation-controller-operator-controller-manager \
    -n "${ns}" &>/dev/null; then
    AAP_NS="${ns}"
    break
  fi
done
[[ -z "${AAP_NS}" ]] && AAP_NS="ansible-aap"
echo "AAP operator namespace: ${AAP_NS}"

# Wait for the AAP CSV to appear
until AAP_CSV=$(oc get csv --no-headers -n ${AAP_NS} 2>/dev/null \
  | awk '/aap/ { print $1 }' | tail -1) && [[ -n "${AAP_CSV}" ]]; do
  sleep 10
done
echo "Found CSV: ${AAP_CSV}"
oc wait csv/${AAP_CSV} -n ${AAP_NS} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
oc wait deployment/automation-controller-operator-controller-manager -n ${AAP_NS} \
  --for=condition=Available --timeout=300s
```

### 1.9 PostgreSQL (Fulfillment Database)

The fulfillment-service connects to PostgreSQL via the URL in the
`fulfillment-db` secret — any hostname routable from the pod network can work.
This guide documents the **osac-installer supported path**: in-cluster
PostgreSQL deployed via an operator (CloudNativePG, Crunchy PGO, or Zalando).
`setup.sh` validates that the hostname in `fulfillment-db` resolves to a
Kubernetes Service with ready endpoints; off-cluster databases (RDS, external
hosts) are not validated by the installer prerequisite check.

Deploy PostgreSQL **before Phase 2** using one of the operator paths documented
in [`base/osac-fulfillment-service/docs/INSTALL.md`](../base/osac-fulfillment-service/docs/INSTALL.md).
The operator creates Kubernetes Services (typically in a `postgres` namespace)
with cluster DNS hostnames such as `osac-rw.postgres.svc.cluster.local`.

Verify the database Service has ready endpoints before continuing:

```bash
# Example for CNPG — adjust service/namespace for your operator
oc get endpoints osac-rw -n postgres
```

Phase 2 covers creating the `fulfillment-db` and `postgres-client-cert-service`
secrets that point fulfillment-service at this database.

---

## Phase 2: Prepare Secrets and Configuration

The Helm chart deploys OSAC components but does **not** create all required
secrets and configmaps. Several must be created manually before or after the
Helm install.

Create the namespace first (Helm will reuse it with `--create-namespace`):

```bash
oc create namespace ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -
```

### 2.1 CA Trust Bundle

The fulfillment-service pods need a `ca-bundle` ConfigMap containing the
cluster's CA certificate. This is managed by trust-manager — you create a
`Bundle` resource that tells trust-manager to sync the CA from cert-manager
into your OSAC namespace:

```bash
cat <<EOF | oc apply -f -
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
```

Verify the configmap was created (trust-manager syncs it within seconds):

```bash
oc get configmap ca-bundle -n ${NAMESPACE}
```

### 2.2 PostgreSQL Database

For **osac-installer** deployments, use an in-cluster operator-managed
PostgreSQL cluster (see Phase 1.9). Connection details are provided via a
`fulfillment-db` secret and a `postgres-client-cert-service` secret for mutual
TLS client authentication.

> **Shortcut:** If `bundledPostgres.enabled: true` is set in your values file,
> the chart auto-creates the `fulfillment-db` secret and
> `postgres-client-cert-service` Certificate. You must still deploy an in-cluster
> PostgreSQL Service named `postgres` on port 5432 in the install namespace
> before Helm install — see [Phase 1.9](#19-postgresql-fulfillment-database).

**Deploy PostgreSQL via an in-cluster operator** (installer-supported path):

1. Follow [`base/osac-fulfillment-service/docs/INSTALL.md`](../base/osac-fulfillment-service/docs/INSTALL.md)
   to install CloudNativePG, Crunchy PGO, or Zalando and create a PostgreSQL
   cluster. The operator exposes a Kubernetes Service (e.g.
   `osac-rw.postgres.svc.cluster.local` for CNPG).
2. Create the `fulfillment-db` connection secret using the operator's hostname
   and credentials. Example for CNPG (set variables from your operator cluster;
   see INSTALL.md § "Create the service secrets"):

```bash
POSTGRES_USER=service
POSTGRES_HOST=<operator-service-host>   # e.g. osac-rw.postgres.svc.cluster.local
POSTGRES_PORT=5432
POSTGRES_DB=service

oc create secret generic fulfillment-db \
  --from-literal=url="postgres://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=verify-full&sslrootcert=/etc/fulfillment-grpc-server/db/sslrootcert&sslcert=/etc/fulfillment-grpc-server/db/sslcert&sslkey=/etc/fulfillment-grpc-server/db/sslkey" \
  -n ${NAMESPACE}
```

> **Note:** Replace `<operator-service-host>` with your operator's cluster DNS
> name — see INSTALL.md for PGO (`osac-primary.postgres.svc.cluster.local`) and
> Zalando (`osac.postgres.svc.cluster.local`) examples.

1. Create a cert-manager Certificate for the database user's client certificate
   (required for mutual TLS):

```bash
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: postgres-client-service
  namespace: ${NAMESPACE}
spec:
  issuerRef:
    kind: ClusterIssuer
    name: default-ca
  commonName: service
  usages:
  - client auth
  secretName: postgres-client-cert-service
  privateKey:
    rotationPolicy: Always
EOF

oc wait certificate/postgres-client-service -n ${NAMESPACE} \
  --for=condition=Ready --timeout=60s
```

> **Note:** The values files include a `database.connection` entry that mounts
> the `postgres-client-cert-service` secret into the projected volume at
> `/etc/fulfillment-grpc-server/db/`. This provides the `sslcert`, `sslkey`,
> and `sslrootcert` files referenced in the connection URL above.
> **Supported deployments:** The installer-supported production path is
> in-cluster operator-managed PostgreSQL per INSTALL.md. `setup.sh` validates
> that the resolved Kubernetes Service has ready endpoints; unrecognized or
> off-cluster hostnames fail with a pointer to INSTALL.md.

### 2.3 Fulfillment Controller Credentials

OAuth client credentials for the fulfillment controller, extracted from the
Keycloak realm configuration. The Keycloak client is named `osac-controller`
and the OPA authorization policy expects JWT username
`service-account-osac-controller`:

```bash
FC_CLIENT_SECRET=$(jq -r \
  '.clients[] | select(.clientId == "osac-controller") | .secret' \
  prerequisites/keycloak/service/files/realm.json)

oc create secret generic fulfillment-controller-credentials \
  --from-literal=client-id=osac-controller \
  --from-literal=client-secret="${FC_CLIENT_SECRET}" \
  -n ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -
```

### 2.4 AAP License

The AAP bootstrap job requires a subscription manifest (license.zip). Obtain
it from the [Red Hat Customer Portal](https://access.redhat.com/) under
**Subscriptions > Subscription Allocations > Export Manifest**.

> **Note:** `scripts/setup.sh` creates this secret automatically when
> `DEPLOY_MODE=helm`. Place `license.zip` in
> `overlays/<overlay>/files/license.zip` or set the `AAP_LICENSE_FILE`
> environment variable to its path. The manual command below is only needed
> if you are not using `setup.sh`.

```bash
# Create the license secret (manual method)
oc create secret generic config-as-code-manifest-ig \
  --from-file=license.zip=/path/to/your/license.zip \
  -n ${NAMESPACE}
```

### 2.5 AAP Config-as-Code Secret

This tells the AAP bootstrap job which execution environment image and git
repository to use for configuration playbooks.

> **Note:** `scripts/setup.sh` creates this secret automatically when
> `DEPLOY_MODE=helm`, using sensible defaults. Override via `AAP_EE_IMAGE`,
> `AAP_PROJECT_GIT_URI`, and `AAP_PROJECT_GIT_BRANCH` environment variables.
> The manual command below is only needed if you are not using `setup.sh`.

```bash
# Create the config-as-code secret (manual method)
oc create secret generic config-as-code-ig \
  --from-literal=AAP_EE_IMAGE=ghcr.io/osac-project/osac-aap:latest \
  --from-literal=AAP_PROJECT_GIT_URI=https://github.com/osac-project/osac-aap \
  --from-literal=AAP_PROJECT_GIT_BRANCH=main \
  -n ${NAMESPACE}
```

> **Tip:** If using a custom osac-aap image or branch, update these values
> accordingly. The `AAP_EE_IMAGE` is the Execution Environment image that AAP
> uses to run automation jobs.

### 2.6 Instance Group Configuration (Optional)

> **Skip this section** if you just want to test the OSAC deployment. These
> secrets are only needed when AAP actually provisions real infrastructure
> (creates clusters on ESI/Netris, VMs on KubeVirt, etc.). All instance group
> secrets are referenced as `optional: true` — OSAC will install and run
> without them.

AAP job templates run inside "instance groups" that receive environment
variables from ConfigMaps and Secrets. Create them only when you're ready to
provision real workloads against a specific backend.

<details>
<summary><strong>cluster-fulfillment-ig</strong> — CaaS backend credentials (click to expand)</summary>

Contains network backend settings, base domains, cloud credentials, and SSH
keys. See
[base/osac-aap/config/base/configmap-cluster-fulfillment-ig-example.yaml](../base/osac-aap/config/base/configmap-cluster-fulfillment-ig-example.yaml)
and
[base/osac-aap/config/base/secret-cluster-fulfillment-ig-example.yaml](../base/osac-aap/config/base/secret-cluster-fulfillment-ig-example.yaml)
for full examples.

```bash
# ConfigMap with non-sensitive settings
oc create configmap cluster-fulfillment-ig \
  --from-literal=NETWORK_CLASS=esi \
  --from-literal=NETWORK_STEPS_COLLECTION=osac.steps \
  --from-literal=EXTERNAL_ACCESS_BASE_DOMAIN=box.massopen.cloud \
  --from-literal=EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS=box.massopen.cloud \
  --from-literal=EXTERNAL_ACCESS_API_INTERNAL_NETWORK=hypershift \
  --from-literal=HOSTED_CLUSTER_BASE_DOMAIN=box.massopen.cloud \
  --from-literal=HOSTED_CLUSTER_CONTROLLER_AVAILABILITY_POLICY=HighlyAvailable \
  --from-literal=HOSTED_CLUSTER_INFRASTRUCTURE_AVAILABILITY_POLICY=HighlyAvailable \
  -n ${NAMESPACE}

# Secret with sensitive credentials (include only the keys you have)
oc create secret generic cluster-fulfillment-ig \
  --from-literal=NETRIS_PASSWORD=<your-netris-password> \
  --from-file=SERVER_SSH_KEY=/path/to/server-ssh-key \
  --from-file=SERVER_SSH_BASTION_KEY=/path/to/bastion-ssh-key \
  -n ${NAMESPACE}

# AWS credentials — only needed if using Route53 for DNS:
#   --from-literal=AWS_ACCESS_KEY_ID=<your-aws-key>
#   --from-literal=AWS_SECRET_ACCESS_KEY=<your-aws-secret>

# OpenStack credentials — only needed if using OpenStack backends:
#   --from-literal=OS_AUTH_URL=<your-openstack-auth-url>
#   --from-literal=OS_AUTH_TYPE=v3applicationcredential
#   --from-literal=OS_APPLICATION_CREDENTIAL_ID=<your-credential-id>
#   --from-literal=OS_APPLICATION_CREDENTIAL_SECRET=<your-credential-secret>
```

</details>

<details>
<summary><strong>network-fulfillment-ig</strong> — Netris networking credentials (click to expand)</summary>

```bash
oc create configmap network-fulfillment-ig \
  --from-literal=NETRIS_CONTROLLER_URL=https://redhat-ctl.netris.io \
  --from-literal=NETRIS_USERNAME=netris \
  --from-literal=NETRIS_SITE_ID=5 \
  --from-literal=NETRIS_TENANT_ID=1 \
  --from-literal=NETRIS_TENANT_NAME=Admin \
  -n ${NAMESPACE}

oc create secret generic network-fulfillment-ig \
  --from-literal=NETRIS_PASSWORD=<your-netris-password> \
  -n ${NAMESPACE}
```

</details>

<details>
<summary><strong>publish-templates-ig</strong> — Template publishing config (click to expand)</summary>

> **Note:** The Helm chart creates this ConfigMap automatically with sensible
> defaults (`publishTemplates.enabled: true`). You only need to create it
> manually if you disabled it in values or need to override the defaults.

Tells the template publishing job which collections to scan and which
fulfillment endpoint to register templates with.

```bash
oc create configmap publish-templates-ig \
  --from-literal=OSAC_TEMPLATE_COLLECTIONS=osac.templates \
  --from-literal=OSAC_FULFILLMENT_SERVICE_URI=https://fulfillment-internal-api:8001 \
  -n ${NAMESPACE}
```

</details>

#### Alternative: Use env files

Instead of creating each ConfigMap/Secret manually, you can use the
`scripts/aap-configuration.sh` script. Copy and edit the env files:

```bash
cp overlays/development/files/osac-aap-secrets.env.example \
   overlays/development/files/osac-aap-secrets.env
# Edit osac-aap-secrets.env with your credentials
# Edit overlays/development/files/osac-aap-configuration.env with your settings

# Apply after Helm deploy:
INSTALLER_NAMESPACE=${NAMESPACE} INSTALLER_KUSTOMIZE_OVERLAY=development \
  ./scripts/aap-configuration.sh
```

---

## Phase 3: Deploy OSAC via Helm

### 3.1 Initialize Submodules

The umbrella chart uses `file://` references to component charts via git
submodules.

```bash
git submodule update --init --recursive
```

### 3.2 Choose a Values File

| Profile | Values File | Operator Controllers | Notes |
|---------|-------------|---------------------|-------|
| Development (all) | `values/development/values.yaml` | clusterOrder, computeInstance, tenant, networking | All controllers, `latest` images |
| CaaS CI | `values/caas-ci/values.yaml` | clusterOrder, tenant, networking | Cluster provisioning only, pinned images |
| VMaaS CI | `values/vmaas-ci/values.yaml` | computeInstance, tenant, networking | VM provisioning only, pinned images |

To customize, copy and edit:

```bash
cp values/development/values.yaml values/my-env.yaml
```

Key settings to review in your values file:

| Setting | Description | Where to Find |
|---------|-------------|---------------|
| `service.externalHostname` | **Required.** Hostname for the external API Route | `fulfillment-api-${NAMESPACE}.apps.<cluster>.<domain>` |
| `service.internalHostname` | **Required.** Hostname for the internal API Route | `fulfillment-internal-api-${NAMESPACE}.apps.<cluster>.<domain>` |
| `operator.aap.url` | AAP controller API URL | Set post-install by `prepare-aap.sh` |
| `service.auth.issuerUrl` | Keycloak realm URL | `https://keycloak.keycloak.svc.cluster.local/realms/osac` (default works) |
| `service.idp.url` | Keycloak base URL | `https://keycloak.keycloak.svc.cluster.local` (default works) |
| `service.database.connection` | PostgreSQL connection | Referenced from `fulfillment-db` secret |
| `aap.aap.instance.enabled` | Create AAP instance CR | `true` (chart manages AAP instance) |
| `aap.bootstrap.enabled` | Run bootstrap job | `true` (configures AAP with job templates) |
| `hubAccess.enabled` | Create hub-access SA and RBAC | `true` (required for hub registration) |
| `publishTemplates.enabled` | Create publish-templates-ig ConfigMap | `true` (template publishing config) |

#### Determine API Hostnames

The fulfillment service requires explicit hostnames for the external and internal API
Routes. These are used in TLS certificate generation and cannot be auto-detected. On
OpenShift, determine your cluster's ingress domain and set the hostnames accordingly:

```bash
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export EXTERNAL_HOSTNAME="fulfillment-api-${NAMESPACE}.${DOMAIN}"
export INTERNAL_HOSTNAME="fulfillment-internal-api-${NAMESPACE}.${DOMAIN}"
```

Set these in your values file or pass them via `--set` at install time.

### 3.3 Validate

```bash
# Build dependencies
helm dependency build charts/osac/

# Lint
helm lint charts/osac/

# Dry-run render
helm template osac charts/osac/ \
  --namespace ${NAMESPACE} \
  --values values/development/values.yaml \
  --set service.externalHostname=${EXTERNAL_HOSTNAME} \
  --set service.internalHostname=${INTERNAL_HOSTNAME} \
  > /dev/null
```

### 3.4 Deploy

```bash
helm upgrade --install osac charts/osac/ \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --values values/development/values.yaml \
  --set service.externalHostname=${EXTERNAL_HOSTNAME} \
  --set service.internalHostname=${INTERNAL_HOSTNAME} \
  --timeout 40m \
  --wait
```

> **Note:** The database migration hook (`dbMigrate.enabled`) is disabled by
> default because the `fulfillment-service migrate` subcommand has not been
> released yet. Once it is released in a tagged image, enable it with
> `--set dbMigrate.enabled=true` to run migrations automatically on upgrade.

The `--wait` flag blocks until all Deployments, StatefulSets, and Jobs
(excluding Helm hooks) are ready. The AAP bootstrap job runs as a
post-install hook and may take 10-40 minutes.

### 3.5 Verify

```bash
# Helm release status
helm status osac -n ${NAMESPACE}

# Pod status
oc get pods -n ${NAMESPACE}

# Monitor the AAP bootstrap job
oc logs -f job/osac-aap-bootstrap -n ${NAMESPACE}

# Check key deployments
oc get deployment -n ${NAMESPACE}
```

Expected deployments:
- `osac-operator-controller-manager` — OSAC operator
- `fulfillment-grpc-server` — Fulfillment gRPC API
- `fulfillment-rest-gateway` — Fulfillment REST API
- `fulfillment-controller` — Fulfillment controller
- `fulfillment-ingress-proxy` — Envoy proxy

---

## Phase 4: Post-Install Configuration

After the Helm chart is deployed and the AAP bootstrap job completes, run
these steps to finish the setup.

### 4.1 Create AAP API Token

The operator needs an API token to communicate with AAP. This script
authenticates with the AAP gateway, creates a write-scoped token, and patches
the operator deployment with the AAP URL.

```bash
# Wait for AAP gateway to be ready
oc wait deployment/osac-aap-gateway -n ${NAMESPACE} \
  --for=condition=Available --timeout=600s

# Create the token
INSTALLER_NAMESPACE=${NAMESPACE} ./scripts/prepare-aap.sh
```

What this does:
1. Gets the AAP admin password from secret `osac-aap-admin-password`
2. Creates an API token via `POST /api/gateway/v1/tokens/`
3. Stores the token in secret `osac-aap-api-token`
4. Sets `OSAC_AAP_URL` on the operator deployment (triggers rollout)

### 4.2 Install the OSAC CLI

The hub registration step requires the `osac` CLI.

```bash
curl -L -o osac \
  https://github.com/osac-project/fulfillment-service/releases/latest/download/osac_Linux_x86_64
chmod +x osac
sudo mv osac /usr/local/bin/
```

### 4.3 Register the Hub

Register the current cluster as a management hub with the fulfillment service.

```bash
# Wait for fulfillment service
oc wait deployment/fulfillment-grpc-server -n ${NAMESPACE} \
  --for=condition=Available --timeout=300s
oc wait deployment/fulfillment-ingress-proxy -n ${NAMESPACE} \
  --for=condition=Available --timeout=300s

# Set project context
oc project ${NAMESPACE}

# Register the hub
INSTALLER_NAMESPACE=${NAMESPACE} ./scripts/prepare-fulfillment-service.sh
```

What this does:
1. Creates a hub-access kubeconfig using the `hub-access` ServiceAccount
   (created by the Helm chart when `hubAccess.enabled: true`, the default)
2. Logs into the fulfillment internal API
3. Registers the cluster as hub "hub" in the fulfillment service

### 4.4 Create Tenants

```bash
INSTALLER_NAMESPACE=${NAMESPACE} ./scripts/prepare-tenant.sh
```

What this does:
1. Labels the default StorageClass with OSAC tenant labels
2. Creates a namespace-scoped Tenant (`${NAMESPACE}`)
3. Creates a "shared" Tenant (used for admin operations)
4. Waits for both Tenants to reach `Ready` status

### 4.5 Apply AAP Instance Group Overrides

If you created the instance group ConfigMaps/Secrets in
[Phase 2.6](#26-instance-group-configuration-optional) before the Helm deploy, they
are already in place. If you need to apply overrides after deployment (e.g.,
from env files):

```bash
INSTALLER_NAMESPACE=${NAMESPACE} \
INSTALLER_KUSTOMIZE_OVERLAY=development \
  ./scripts/aap-configuration.sh
```

---

## Profile Reference

### VMaaS (VM as a Service)

Prerequisites needed: LVMS (if no SC), CNV, cert-manager,
Keycloak, AAP.

```bash
export NAMESPACE=osac
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
# Phase 1: Install LVMS (if needed), CNV, cert-manager, trust-manager,
#           CA issuer, Keycloak, AAP operator
# Phase 2: Create secrets (license, config-as-code, credentials)
# Phase 3: Deploy
helm upgrade --install osac charts/osac/ \
  --namespace ${NAMESPACE} --create-namespace \
  --values values/vmaas-ci/values.yaml \
  --set service.externalHostname=fulfillment-api-${NAMESPACE}.${DOMAIN} \
  --set service.internalHostname=fulfillment-internal-api-${NAMESPACE}.${DOMAIN} \
  --timeout 40m --wait
# Phase 4: Post-install scripts
```

### CaaS (Cluster as a Service)

Prerequisites needed: LVMS (if no SC), MCE, cert-manager,
Keycloak, AAP.

```bash
export NAMESPACE=osac
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
# Phase 1: Install LVMS (if needed), MCE, cert-manager, trust-manager,
#           CA issuer, Keycloak, AAP operator
# Phase 2: Create secrets (license, config-as-code, credentials)
# Phase 3: Deploy
helm upgrade --install osac charts/osac/ \
  --namespace ${NAMESPACE} --create-namespace \
  --values values/caas-ci/values.yaml \
  --set service.externalHostname=fulfillment-api-${NAMESPACE}.${DOMAIN} \
  --set service.internalHostname=fulfillment-internal-api-${NAMESPACE}.${DOMAIN} \
  --timeout 40m --wait
# Phase 4: Post-install scripts
```

### Both VMaaS + CaaS

Prerequisites needed: All of the above (LVMS, MCE, CNV, cert-manager,
Keycloak, AAP).

```bash
export NAMESPACE=osac
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
# Phase 1: Install all prerequisites
# Phase 2: Create secrets
# Phase 3: Deploy
helm upgrade --install osac charts/osac/ \
  --namespace ${NAMESPACE} --create-namespace \
  --values values/development/values.yaml \
  --set service.externalHostname=fulfillment-api-${NAMESPACE}.${DOMAIN} \
  --set service.internalHostname=fulfillment-internal-api-${NAMESPACE}.${DOMAIN} \
  --timeout 40m --wait
# Phase 4: Post-install scripts
```

---

## Automated Alternative

If you prefer a single command, `scripts/setup.sh` performs all phases
automatically:

```bash
# VMaaS + CaaS with all optional services
EXTRA_SERVICES=true \
INSTALLER_NAMESPACE=osac \
VALUES_FILE=values/development/values.yaml \
  ./scripts/setup.sh

# VMaaS only
VIRT_SERVICE=true \
INSTALLER_NAMESPACE=osac \
VALUES_FILE=values/vmaas-ci/values.yaml \
  ./scripts/setup.sh

# CaaS only
MCE_SERVICE=true \
INSTALLER_NAMESPACE=osac \
VALUES_FILE=values/caas-ci/values.yaml \
  ./scripts/setup.sh
```

The script handles prerequisite installation, secret creation, Helm deploy,
and all post-install steps. Set `DEPLOY_MODE=helm` (default) to use Helm.

For **osac-installer**, deploy in-cluster PostgreSQL via an operator **before**
running `setup.sh` (see [Phase 1.9](#19-postgresql-fulfillment-database)). The
script validates that the database Service has ready endpoints; it does not
deploy PostgreSQL.

**Shared cluster deployments:** If multiple developers share the same cluster
and you need to impersonate a different user, set `OC_IMPERSONATE`:

```bash
OC_IMPERSONATE=developer@example.com \
INSTALLER_NAMESPACE=my-osac \
VALUES_FILE=values/development/values.yaml \
  ./scripts/setup.sh
```

---

## Troubleshooting

### AAP Bootstrap Job Failing

```bash
# Check bootstrap job logs
oc logs -f job/osac-aap-bootstrap -n ${NAMESPACE}

# Check if the license secret exists
oc get secret config-as-code-manifest-ig -n ${NAMESPACE}

# Check if AAP instance is ready
oc get ansible-automation-platform -n ${NAMESPACE}
```

Common causes:
- Missing `config-as-code-manifest-ig` secret (no license.zip)
- Missing `config-as-code-ig` secret (no EE image configured)
- AAP instance not yet ready (init container still waiting)

### Fulfillment Service Pods CrashLooping

```bash
oc logs deployment/fulfillment-grpc-server -n ${NAMESPACE}
oc logs deployment/fulfillment-controller -n ${NAMESPACE}
```

Common causes:
- **`no pg_hba.conf entry ... no encryption`** — The `fulfillment-db` secret uses
  `sslmode=disable` but postgres requires mutual TLS. Use `sslmode=verify-full`
  with client cert paths (see [Phase 2.2](#22-postgresql-database))
- **`unable to read CA file: open .../sslrootcert: no such file or directory`** —
  The `postgres-client-cert-service` secret doesn't exist. Create the client
  certificate (see [Phase 2.2](#22-postgresql-database))
- **`failed to read client identifier from file`** — Missing
  `fulfillment-controller-credentials` secret or `auth.controllerCredentials`
  not set in values (see [Phase 2.3](#23-fulfillment-controller-credentials))
- **`PermissionDenied`** — The OPA policy expects JWT username
  `service-account-osac-controller`. Ensure the `fulfillment-controller-credentials`
  secret uses `client-id=osac-controller` (see [Phase 2.3](#23-fulfillment-controller-credentials))
- Missing `fulfillment-db` secret (database not configured)
- cert-manager certificates not issued (check `oc get certificate -n ${NAMESPACE}`)

### Fulfillment Controller PermissionDenied

The OPA policy in the expects JWT username `service-account-osac-controller`. This means the
`fulfillment-controller-credentials` secret must use `client-id=osac-controller` (matching the
Keycloak client name).

If you see `PermissionDenied` errors, check the credentials secret:

```bash
oc get secret fulfillment-controller-credentials -n ${NAMESPACE} \
  -o jsonpath='{.data.client-id}' | base64 -d
# Should output: osac-controller
```

If it shows a different value, recreate the secret:

```bash
FC_CLIENT_SECRET=$(jq -r \
  '.clients[] | select(.clientId == "osac-controller") | .secret' \
  prerequisites/keycloak/service/files/realm.json)

oc create secret generic fulfillment-controller-credentials \
  --from-literal=client-id=osac-controller \
  --from-literal=client-secret="${FC_CLIENT_SECRET}" \
  -n ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -

# Restart the controller to pick up the change
oc delete pod -l app=fulfillment-controller -n ${NAMESPACE}
```

### Operator Not Reconciling

```bash
oc logs deployment/osac-operator-controller-manager -n ${NAMESPACE}
```

Common causes:
- `OSAC_AAP_URL` not set (run `prepare-aap.sh`)
- `osac-aap-api-token` secret missing or token expired
- AAP controller not reachable from the operator pod

### Database Migration Hook Failing

The db-migrate hook is **disabled by default** (`dbMigrate.enabled: false`)
because the `fulfillment-service migrate` subcommand has not been released
yet. If you enable it and it fails with `BackoffLimitExceeded`:

```bash
# Check the error
oc logs job/osac-db-migrate -n ${NAMESPACE}

# Fix: delete the failed job and redeploy with the hook disabled
oc delete job osac-db-migrate -n ${NAMESPACE}
helm upgrade --install osac charts/osac/ \
  --namespace ${NAMESPACE} \
  --values values/development/values.yaml \
  --timeout 40m \
  --wait
```

### Helm Install Timeout

If `helm upgrade --install` times out at 40 minutes, the AAP bootstrap hook
is likely still running:

```bash
# Check hook status
oc get pods -n ${NAMESPACE} | grep bootstrap

# The hook has backoffLimit=15 — it retries on failure
# Monitor progress:
oc logs -f job/osac-aap-bootstrap -n ${NAMESPACE}
```

### Clean Reinstall

```bash
# Uninstall OSAC
helm uninstall osac -n ${NAMESPACE}

# Delete the namespace (waits for all resources to terminate).
# This also removes AAP operator-managed resources (postgres StatefulSet,
# PVCs) that are not part of any Helm release.
oc delete namespace ${NAMESPACE} --wait

# Operator-managed PostgreSQL (e.g. CNPG Cluster in the postgres namespace)
# is not removed by helm uninstall. Delete it separately if needed:
#   oc delete cluster -n postgres osac
# or delete the entire postgres namespace:
#   oc delete namespace postgres --wait

# CRDs are preserved. To remove them:
oc delete crd -l app.kubernetes.io/part-of=osac

# Cluster-scoped RBAC resources are removed by helm uninstall, but if
# they persist (e.g., after a failed install):
oc delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=osac
```
