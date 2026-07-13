# OSAC Installer

This repository contains Kubernetes/OpenShift deployment configurations for the OSAC
platform, providing a fulfillment service framework for clusters and virtual machines.

> **Note:** Throughout this guide, `<project-name>` refers to your unique OSAC installation
> name, which is used as the namespace. Replace it with your chosen project name
> (e.g., `user1`, `team-a`, etc.).

## Overview

OSAC (Open Sovereign AI Cloud) provides a streamlined, self-service
framework for provisioning and managing OpenShift clusters and virtual machines. This
installer repository contains the Kubernetes/OpenShift deployment configurations needed
to deploy OSAC components on your infrastructure.

For detailed architecture, workflows, and design documentation, please refer to the
[OSAC documentation repository](https://github.com/osac-project/docs).

The OSAC platform provides:
- **Self-service provisioning** for clusters and virtual machines through a governed API
- **Template-based automation** using Red Hat Ansible Automation Platform
- **Multi-hub support** allowing multiple infrastructure hubs to be managed by a single fulfillment service
- **API access** via both gRPC and REST interfaces for integration with custom tools

This installer uses Helm to manage deployments via an umbrella chart (`charts/osac/`)
with per-environment values files under `values/`.

## OSAC Components

The OSAC platform relies on four core components to deliver governed self-service:

1. **Fulfillment Service:**
   The API and frontend entry point used to manage user requests and map them to specific
   templates.

2. **OSAC Operator:**
   An OpenShift operator residing on the Hub cluster (ACM/OCP-Virt). It orchestrates the
   lifecycle of clusters and VMs by coordinating between the Fulfillment Service and the
   automation backend.

3. **Console Proxy:**
   A Kubernetes aggregated API server that provides serial and VNC console access to
   ComputeInstance VMs. Deployed alongside the operator on each hub.

4. **Automation Backend (AAP):**
   Leverages the **Red Hat Ansible Automation Platform** to store and execute the custom
   template logic required for provisioning.

5. **Bare Metal Fulfillment Operator:**
   Kubernetes operator for managing bare-metal host pools. It watches **BareMetalPool**
   custom resources and reconciles them to their desired state by provisioning pools of
   bare-metal hosts organized by host type (e.g., GPU nodes, worker nodes). Uses profile
   templates to configure workflows and apply configuration parameters to selected hosts.
   It also contains a Kubernetes controller that manages bare-metal hosts via OpenStack
   Ironic. It watches **BareMetalInstance** CRs (defined by the Bare Metal Fulfillment Operator)
   and reconciles power state with Ironic.

### Prerequisites & Setup

> **System Requirements** This solution requires the following platforms to be installed
> and operational:
> * Red Hat OpenShift Advanced Cluster Management (RHACM)
> * Red Hat OpenShift Virtualization (OCP-Virt) - **Optional**: Only required for VM as a Service (VMaaS) support
> * Red Hat Ansible Automation Platform (AAP)
> * A network backend for bare metal provisioning: either **ESI** (Elastic System Infrastructure) or **Netris** (see [Network Backend Configuration](#network-backend-configuration-caas))

**Configuration Manifests**

The `/prerequisites` directory contains additional manifests required to configure the
target Hub cluster.

> **Warning: Cluster-Wide Impact** If you are using a shared cluster or are not the
> primary administrator, **do not apply these manifests without consultation.** These
> files modify cluster-wide settings. Please coordinate with the appropriate cluster
> administrators before proceeding.


### Prerequisites Summary

| **Category** | **Requirement** | **Notes / Details** |
|---------------|-----------------|----------------------|
| **Platform** | Red Hat OpenShift Container Platform (OCP) 4.17 or later | Must have cluster admin access to the hub cluster. |
| **Operators** | Red Hat Advanced Cluster Management (RHACM) 2.18+<br>Red Hat OpenShift Virtualization (OCP-Virt) 4.17+<br>Red Hat Ansible Automation Platform (AAP) 2.5+ | These must be installed and running prior to OSAC installation. |
| **CLI Tools** | `oc` (OpenShift CLI) v4.17+<br>`helm` v3.x<br>`git` | Ensure all CLIs are available in your `PATH`. |
| **Container Registry Access** | `registry.redhat.io` and `quay.io` | Verify credentials and pull secrets are valid in the target cluster namespace. |
| **Network / DNS** | Ingress route configured for OSAC services | Required for external access to fulfillment API and AAP UI. |
| **Authentication / IDM** | Organization Identity Provider (e.g., Keycloak, LDAP, RH-SSO) | Used for tenant and user identity mapping. |
| **Storage** | Dynamic storage class available (e.g., `ocs-storagecluster-cephfs`, `lvms-storage`) | Required for persistence of operator and AAP components. |
| **Permissions** | Cluster-admin access to deploy operators and create CRDs | Limited access users can only deploy into namespaces configured by the admin. |
| **License Files** | `license.zip` (AAP subscription) | Must be placed in your values directory (e.g., `values/<env>/license.zip`). |
| **Internet Access** | Outbound access to GitHub (for fetching submodules, releases) | Required during installation and updates. |


## Installation

### Obtaining an AAP License (Subscription Manifest)

The AAP license is a **Subscription Manifest** (a `.zip` file), not a key file. To
obtain it:

1. **Log in** to the [Red Hat Customer Portal](https://access.redhat.com/).
2. **Navigate** to **Subscriptions** > **Subscription Allocations**.
3. **Create or select an allocation:** If you haven't created one, click
   "New Subscription Allocation" and set the type (usually "Satellite 6.x").
4. **Add entitlements:** Click on your allocation, go to the **Subscriptions** tab,
   and add your Ansible Automation Platform subscriptions.
5. **Download:** Click **Export Manifest** to download the `.zip` file.

Place the downloaded `license.zip` file in your values directory (e.g., `values/development/license.zip`).

### Pre-Installation Steps

#### 1. Initialize Submodules

The OSAC installer uses Git submodules for version tracking:

```bash
$ git submodule update --init --recursive
```

#### 2. Populate Local Secrets

Ensure your values directory contains the necessary secret files:

- **AAP License:** Place `license.zip` in `values/<env>/`
- **Pull Secret:** Place `pull-secret.json` in `values/<env>/`

### Option A: Automated Setup (Recommended)

The `scripts/setup.sh` script automates the entire installation process, including:

- Installing prerequisite operators (cert-manager, trust-manager, Keycloak, AAP)
- Optionally installing LVMS (storage service), MetalLB (ingress service), Multicluster Engine (MCE + infrastructure operator), and OpenShift Virtualization (CNV)
- Setting up the CA issuer and network attachment definitions
- Deploying OSAC components via Helm
- Waiting for the AAP bootstrap job to complete
- Creating the hub access kubeconfig and registering the hub with the fulfillment service

To run the automated setup:

```bash
# Using defaults (namespace: osac, values: values/development/values.yaml)
$ ./scripts/setup.sh

# Or customize the namespace and values file
$ INSTALLER_NAMESPACE=<project-name> VALUES_FILE=values/development/values.yaml ./scripts/setup.sh

# Install with all optional services (storage, ingress, virtualization, MCE)
$ EXTRA_SERVICES=true INSTALLER_NAMESPACE=<project-name> ./scripts/setup.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `KUBECONFIG` | `~/.kube/config` | Path to the target cluster's kubeconfig file |
| `INSTALLER_NAMESPACE` | `osac` | Target namespace for the OSAC deployment |
| `VALUES_FILE` | `values/development/values.yaml` | Helm values file to use |
| `EXTRA_SERVICES` | `false` | Enable all optional services (sets all below to `true`) |
| `INGRESS_SERVICE` | `false` | Install MetalLB as the ingress/LoadBalancer service |
| `STORAGE_SERVICE` | `false` | Install LVMS and create a default StorageClass (`lvms-vg1`) |
| `VIRT_SERVICE` | `false` | Install OpenShift Virtualization |
| `MCE_SERVICE` | `false` | Install Multicluster Engine and infrastructure operator |

#### AAP Configuration

The automation backend (AAP) is configured via environment variables passed to
`scripts/aap-configuration.sh`. Set the relevant variables before running `setup.sh`.

See [docs/aap-configuration.md](docs/aap-configuration.md) for the full variable
reference.

#### Network Backend Configuration (CaaS)

By default the network backend is **ESI**. To switch to **Netris**, set
`NETWORK_CLASS=netris` and fill in the Netris-specific connection details and credentials
as environment variables.

See [docs/network-backend.md](docs/network-backend.md) for Netris-specific
variables and the `NETRIS_RESOURCE_CLASS_MAP` format.

#### DNS Backend Configuration (CaaS)

DNS record management uses a pluggable backend. The default is **AWS Route 53**
(`DNS_CLASS=dns.route53.dns`), which requires AWS credentials. No changes are needed for existing deployments.

See [docs/dns-backend.md](docs/dns-backend.md) for backend details, the
interface contract, and how to add a new provider.

> **Note:** The script requires `osac` to be installed and available in your
> `PATH` (see [OSAC CLI: Setup & Usage](#osac-cli-setup--usage) below for
> installation instructions).

The script will wait for all components to be ready before proceeding to the next step.
Once it completes successfully, OSAC is fully operational.

### Option B: Manual Helm Installation

If you prefer to install step-by-step:

#### 1. Install Prerequisites

OSAC requires several operators to be present on the cluster. The prerequisite manifests
are located in the `prerequisites/` directory. Install them in order:

```bash
# cert-manager
oc apply -f prerequisites/cert-manager/cert-manager.yaml
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

# trust-manager
oc apply -f prerequisites/trust-manager.yaml
oc wait --for=condition=Available deployment/trust-manager -n cert-manager --timeout=300s

# CA issuer
oc apply -f prerequisites/ca-issuer.yaml

# Keycloak
oc apply -f prerequisites/keycloak/namespace.yaml
oc create configmap keycloak-db-server-config \
    --from-file=server.conf=prerequisites/keycloak/database/files/server.conf \
    -n keycloak --dry-run=client -o yaml | oc apply -f -
oc create configmap keycloak-db-access-config \
    --from-file=access.conf=prerequisites/keycloak/database/files/access.conf \
    -n keycloak --dry-run=client -o yaml | oc apply -f -
oc create configmap keycloak-realm \
    --from-file=realm.json=prerequisites/keycloak/service/files/realm.json \
    -n keycloak --dry-run=client -o yaml | oc apply -f -
oc apply -f prerequisites/keycloak/database/ -n keycloak
oc apply -f prerequisites/keycloak/service/ -n keycloak
oc wait --for=condition=Available deployment/keycloak-service -n keycloak --timeout=600s

# AAP operator
oc apply -f prerequisites/aap-installation.yaml
```

Wait for each operator to be ready before proceeding. See
[prerequisites/README.md](prerequisites/README.md) for details on optional
components (LVMS, MetalLB, MCE, OpenShift Virtualization).

#### 2. Initialize Submodules

```bash
git submodule update --init --recursive --remote
```

#### 3. Build Chart Dependencies

```bash
helm dependency build charts/osac/
```

#### 4. Configure Values

Copy and customize a values file for your environment:

```bash
mkdir -p values/<project-name>
cp values/development/values.yaml values/<project-name>/values.yaml
# Edit values/<project-name>/values.yaml to set:
#   - operator.aap.url: your AAP controller URL
#   - service.auth.issuerUrl: your Keycloak realm URL
#   - service.idp.url: your Keycloak base URL
#   - service.database.connection: your PostgreSQL connection details
```

#### 5. Validate (Dry-Run)

```bash
# Lint the chart
helm lint charts/osac/

# Render templates without deploying
helm template osac charts/osac/ --values values/<project-name>/values.yaml > /dev/null
```

#### 6. Deploy

```bash
helm upgrade --install osac charts/osac/ \
  --namespace <project-name> \
  --create-namespace \
  --values values/<project-name>/values.yaml \
  --set service.externalHostname=${EXTERNAL_HOSTNAME} \
  --set service.internalHostname=${INTERNAL_HOSTNAME} \
  --timeout 40m \
  --wait
```

#### 7. Verify

```bash
# Check deployment status
helm status osac -n <project-name>

# Check running pods
kubectl get pods -n <project-name>

# Monitor the AAP bootstrap job (runs as a post-install hook)
kubectl logs -f job/osac-aap-bootstrap -n <project-name>
```

#### 8. Post-Install

After the AAP bootstrap job completes, run the post-install scripts:

```bash
INSTALLER_NAMESPACE=<project-name> ./scripts/prepare-aap.sh
INSTALLER_NAMESPACE=<project-name> ./scripts/prepare-fulfillment-service.sh
INSTALLER_NAMESPACE=<project-name> ./scripts/prepare-tenant.sh
```

#### Upgrading

```bash
helm upgrade osac charts/osac/ \
  --namespace <project-name> \
  --values values/<project-name>/values.yaml \
  --timeout 40m \
  --wait
```

#### Uninstalling

```bash
helm uninstall osac -n <project-name>
```

> **Note:** CRDs are preserved after uninstall (they have the
> `helm.sh/resource-policy: keep` annotation). To remove them manually:
> `oc delete crd -l app.kubernetes.io/part-of=osac`

#### Makefile Targets

For convenience, the `Makefile` provides developer targets:

```bash
make helm-deps       # Build chart dependencies
make helm-lint       # Lint the umbrella chart
make helm-template   # Dry-run render all templates
make helm-validate   # Lint + template (full validation)
make helm-deploy     # Deploy to current cluster
make helm-undeploy   # Uninstall from current cluster
make sync-charts     # Update submodules + rebuild dependencies
make setup           # Run setup.sh
```

### Monitor Progress

```bash
# Monitor pod creation and startup
$ watch oc get -n <project-name> pods
```

Once the `osac-aap-bootstrap` job completes, OSAC is ready for use.

## OSAC CLI: Setup & Usage

To install the CLI and register a hub, follow these steps:

### 1. Install the Binary

Download the latest release and make it executable.

```bash
# Adjust URL for the latest version as needed
$ curl -L -o osac \
    https://github.com/osac-project/fulfillment-service/releases/latest/download/osac_Linux_x86_64
$ chmod +x osac

# Optional: Move to your path
$ sudo mv osac /usr/local/bin/
```

### 2. Log in to the Service

Authenticate with the fulfillment API. You will need the route address and a valid
token generation script.

```bash
$ osac login \
    --address <your-fulfillment-route-url> \
    --token-script "oc create token fulfillment-controller -n <project-name> \
    --duration 1h --as system:admin" \
    --insecure
```

> **Tip:** Retrieve your route URL using: `oc get routes -n <project-name>`

### 3. Register the Hub

To allow the OSAC operator to communicate with the fulfillment service, you must
obtain the kubeconfig and register the hub. The script located at
`scripts/create-hub-access-kubeconfig.sh` demonstrates how to generate the kubeconfig
for a hub.

```bash
# Generate the kubeconfig
$ ./scripts/create-hub-access-kubeconfig.sh

# Register the Hub
$ osac create hub \
    --kubeconfig=kubeconfig.hub-access \
    --id <hub-name> \
    --namespace <project-name>
```

### 4. Use the CLI

Once configured, you can use the OSAC CLI to manage clusters and virtual machines.
For detailed usage instructions and command reference, see the
[OSAC CLI documentation](https://github.com/osac-project/fulfillment-service).

## Accessing Ansible Automation Platform

After deployment, you can access the AAP web interface to monitor jobs and manage automation:

### Get the AAP URL

```bash
$ oc get route -n <project-name> | grep osac-aap
```

> **Note:** The main AAP URL will be something like: `https://osac-aap-<project-name>.apps.your-cluster.com`

### Get the AAP Admin Password

```bash
# Extract the admin password
$ oc extract secret/osac-aap-admin-password -n <project-name> --to -
```

### Login to AAP

- Open the AAP controller URL in your browser
- Username: `admin`
- Password: (from the previous step)

### Create an AAP API Token for the OSAC Operator

The OSAC operator requires an API token to communicate with AAP. The `scripts/prepare-aap.sh`
script automates this by authenticating with the AAP gateway using the admin password and
creating a write-scoped token. The automated setup script (`setup.sh`) calls this automatically.

For manual deployments, run it after the AAP bootstrap job completes:

```bash
$ INSTALLER_NAMESPACE=<project-name> ./scripts/prepare-aap.sh
```

## Tearing Down OSAC

To completely remove an OSAC deployment and all its prerequisites, use the teardown script:

```bash
# Using defaults (namespace: osac)
$ ./scripts/teardown.sh

# Or specify your namespace
$ INSTALLER_NAMESPACE=<project-name> ./scripts/teardown.sh

# Include all optional services in teardown (must match what was used during setup)
$ EXTRA_SERVICES=true INSTALLER_NAMESPACE=<project-name> ./scripts/teardown.sh
```

The script removes resources in reverse order:
1. OSAC CRs (while operator is running for finalizer processing)
2. Helm release and project namespace
3. Keycloak
4. AAP operator
5. Multicluster Engine and AgentServiceConfig (if `MCE_SERVICE=true`)
6. OpenShift Virtualization (if `VIRT_SERVICE=true`)
7. LVMS storage service (if `STORAGE_SERVICE=true`)
8. MetalLB ingress service (if `INGRESS_SERVICE=true`)
9. CA issuer, trust-manager, and cert-manager
10. Stale API services and CRD cleanup

> **Warning:** This removes **all** prerequisite operators and their namespaces. If other
> workloads on the cluster depend on these operators (e.g., cert-manager, MetalLB), do not
> run this script. Instead, manually uninstall:
> ```bash
> $ helm uninstall osac -n <project-name>
> $ oc delete namespace <project-name>
> ```

## Troubleshooting

### Common Issues

1. **cert-manager not ready**: Ensure cert-manager operator is installed and running
2. **Certificate issues**: Check cert-manager logs and certificate status
3. **ImagePullBackOff errors**: Verify registry credentials and image string

### Debug Commands

```bash
# Check certificate status
$ oc describe certificate -n <project-name>

# Check pod events
$ oc describe pod -n <project-name> <pod-name>

# Check service endpoints
$ oc get endpoints -n <project-name>

# View component logs
$ oc logs -n <project-name> deployment/fulfillment-service -c server --tail=100

# Get all events in namespace
$ oc get events -n <project-name> --sort-by=.metadata.creationTimestamp
```

## Support

For issues and questions:
- Check the troubleshooting section above
- Review component logs for error messages
- Verify prerequisites are properly installed
- Open issues in the respective component repositories

## License

This project is licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
