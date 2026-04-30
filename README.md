# OSAC Installer

This repository contains Kubernetes/OpenShift deployment configurations for the OSAC
platform, providing a fulfillment service framework for clusters and virtual machines.

> **Note:** Throughout this guide, `<project-name>` refers to your unique OSAC installation
> name, which is used as both the namespace and resource prefix. Replace it with your chosen
> project name (e.g., `user1`, `team-a`, etc.).

## Overview

OSAC (Open Sovereign AI Cloud) provides a streamlined, self-service
framework for provisioning and managing OpenShift clusters and virtual machines. This
installer repository contains the Kubernetes/OpenShift deployment configurations needed
to deploy OSAC components on your infrastructure.

For detailed architecture, workflows, and design documentation, please refer to the
[OSAC documentation repository](https://github.com/osac/docs).

The OSAC platform provides:
- **Self-service provisioning** for clusters and virtual machines through a governed API
- **Template-based automation** using Red Hat Ansible Automation Platform
- **Multi-hub support** allowing multiple infrastructure hubs to be managed by a single fulfillment service
- **API access** via both gRPC and REST interfaces for integration with custom tools

This installer uses Kustomize to manage deployments, making it easy to customize for
different environments.

## OSAC Components

The OSAC platform relies on three core components to deliver governed self-service:

1. **Fulfillment Service:**
   The API and frontend entry point used to manage user requests and map them to specific
   templates.

2. **OSAC Operator:**
   An OpenShift operator residing on the Hub cluster (ACM/OCP-Virt). It orchestrates the
   lifecycle of clusters and VMs by coordinating between the Fulfillment Service and the
   automation backend.

3. **Automation Backend (AAP):**
   Leverages the **Red Hat Ansible Automation Platform** to store and execute the custom
   template logic required for provisioning.

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

> **⚠️ Important: Cluster-Wide Impact** If you are using a shared cluster or are not the
> primary administrator, **do not apply these manifests without consultation.** These
> files modify cluster-wide settings. Please coordinate with the appropriate cluster
> administrators before proceeding.


### 📋 Prerequisites Summary

| **Category** | **Requirement** | **Notes / Details** |
|---------------|-----------------|----------------------|
| **Platform** | Red Hat OpenShift Container Platform (OCP) 4.17 or later | Must have cluster admin access to the hub cluster. |
| **Operators** | Red Hat Advanced Cluster Management (RHACM) 2.18+<br>Red Hat OpenShift Virtualization (OCP-Virt) 4.17+<br>Red Hat Ansible Automation Platform (AAP) 2.5+ | These must be installed and running prior to OSAC installation. |
| **CLI Tools** | `oc` (OpenShift CLI) v4.17+<br>`kubectl` (optional)<br>`kustomize` v5.x<br>`git` | Ensure all CLIs are available in your `PATH`. |
| **Container Registry Access** | `registry.redhat.io` and `quay.io` | Verify credentials and pull secrets are valid in the target cluster namespace. |
| **Network / DNS** | Ingress route configured for OSAC services | Required for external access to fulfillment API and AAP UI. |
| **Authentication / IDM** | Organization Identity Provider (e.g., Keycloak, LDAP, RH-SSO) | Used for tenant and user identity mapping. |
| **Storage** | Dynamic storage class available (e.g., `ocs-storagecluster-cephfs`, `lvms-storage`) | Required for persistence of operator and AAP components. |
| **Permissions** | Cluster-admin access to deploy operators and create CRDs | Limited access users can only deploy into namespaces configured by the admin. |
| **License Files** | `license.zip` (AAP subscription) | Must be placed under `overlays/<your-overlay>/files/license.zip`. |
| **Internet Access** | Outbound access to GitHub (for fetching submodules, releases) | Required during installation and updates. |


## Installation Strategy

OSAC uses Kustomize for installation. This approach allows you to easily override and
customize your deployment to meet specific needs. Multiple OSAC installations can be
deployed on the same cluster, each in its own project namespace.

To manage dependencies, the OSAC-installer repository uses Git submodules to import the
required manifests from each component. This ensures component versions are pinned and
compatible with the installer.

### Customizing Your Installation

Although the development overlay will work out of the box, we recommend customizing your
overlay by creating a new project-specific configuration. This is especially important
when deploying on shared clusters to avoid resource name collisions.

Use Kustomize to manage your environment-specific configurations.

1. **Choose a Project Name:**
   Select a unique name for your OSAC installation (e.g., `user1`, `team-a`, `dev-env`).
   This will be used as your namespace and resource prefix. In the examples below, we'll
   use `<project-name>` as a placeholder.

2. **Initialize the Overlay:**
   Duplicate the development template with your project name:

   ```bash
   $ cp -r overlays/development overlays/<project-name>
   ```

3. **Populate Required Files:**
   Ensure your new directory structure matches the following:

   ```
   overlays/<project-name>/
   ├── kustomization.yaml      # Edit this to configure your deployment
   ├── prefixTransformer.yaml  # Edit this to set resource name prefix
   └── files/
       └── license.zip         # REQUIRED: Your AAP license file
   ```

4. **Update Critical Configuration:**
   You **must** update these configuration values to match your environment:

   - In `kustomization.yaml`: Update the `namespace` field to `<project-name>`
   - In `prefixTransformer.yaml`: Update the `prefix` field to `<project-name>-`
   - In `ca-trust-bundle.yaml`: Update the `values` field element
     to `<project-name>`.
   - In `kustomization.yaml`: Replace `<cluster-name>.<base-domain>` in the `OSAC_AAP_URL`
     value with your cluster's actual domain (e.g., `mgmt.example.devcluster.openshift.com`).
     You can find it by running: `oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'`

   These changes ensure your installation uses a unique namespace and prevents resource
   name conflicts with other OSAC installations.

5. **Apply Additional Customizations:**
   Modify other settings in your overlay folder as needed (images, patches, etc.).


> For more information on structuring overlays and patches, please consult the [official
> Kustomize documentation.](https://kubectl.docs.kubernetes.io/references/kustomize/)


### Using Custom Component Versions

By default, the installer uses the latest commit from each submodule (via
`git submodule update --init --recursive --remote`) and the latest container images
defined in `base/kustomization.yaml`.

To test a specific revision of a component, you need to:

1. **Check out the desired code in the submodule:**

   ```bash
   cd base/<submodule>
   git checkout <branch-or-commit>
   cd ../..
   ```

2. **Build and push a custom container image:**

   Build the image from the checked-out code and push it to a registry accessible by
   your cluster.

3. **Override the image in your overlay's `kustomization.yaml`:**

   ```yaml
   images:
     - name: <component-image-name>
       newName: <your-registry>/<your-image>
       newTag: <your-tag>
   ```

   The component image names used in the base are:

   | Component | Image name |
   |-----------|-----------|
   | Fulfillment Service | `fulfillment-service` |
   | OSAC Operator | `osac-operator` |
   | OSAC AAP | `osac-aap` |

#### OSAC AAP Customization

For osac-aap, in addition to the image override, you must also update the AAP
configuration secrets in your overlay's `kustomization.yaml`:

```yaml
secretGenerator:
- name: config-as-code-ig
  options:
    disableNameSuffixHash: true
  literals:
    - AAP_EE_IMAGE=<your-registry>/osac-aap:<your-tag>
    - AAP_PROJECT_GIT_URI=<your-git-repo-url>
    - AAP_PROJECT_GIT_BRANCH=<your-branch>
```

- `AAP_EE_IMAGE`: The Execution Environment image used by AAP to run automation jobs.
  This should match the container image override above.
- `AAP_PROJECT_GIT_URI`: The Git repository URL for the AAP project (playbooks and
  configuration).
- `AAP_PROJECT_GIT_BRANCH`: The Git branch to use for the AAP project.

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

Place the downloaded `license.zip` file in `overlays/<project-name>/files/`. You will
also upload this manifest into the AAP controller UI after deployment.

## Pre-Installation Steps

Before deploying OSAC, complete the following steps to prepare your environment.

### 1. Initialize Submodules

The OSAC installer relies on external components managed as Git submodules. Before
running Kustomize, you must pull the manifest files into your local directory:

```bash
$ git submodule update --init --recursive --remote
```

### 2. Populate Local Secrets

Ensure your overlay contains the necessary secret files that are excluded from Git:

- **AAP License:** Place `license.zip` in `overlays/<project-name>/files/`.
- **Quay Pull Secret:** Place `quay-pull-secret.json` in `overlays/<project-name>/files/`.

## Deploying OSAC Components

### Option A: Automated Setup (Recommended)

The `scripts/setup.sh` script automates the entire installation process, including:

- Installing prerequisite operators (cert-manager, trust-manager, Authorino, Keycloak, AAP)
- Optionally installing LVMS (storage service), MetalLB (ingress service), Multicluster Engine (MCE + infrastructure operator), and OpenShift Virtualization (CNV)
- Setting up the CA issuer and network attachment definitions
- Applying the Kustomize overlay
- Waiting for the AAP bootstrap job to complete
- Creating the hub access kubeconfig and registering the hub with the fulfillment service

To run the automated setup:

```bash
# Using defaults (namespace: osac-devel, overlay: development)
$ ./scripts/setup.sh

# Or customize the namespace and overlay
$ INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/setup.sh

# Install with all optional services (storage, ingress, virtualization, MCE)
$ EXTRA_SERVICES=true \
    INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/setup.sh

# Or selectively enable specific services
$ INGRESS_SERVICE=true STORAGE_SERVICE=true \
    INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/setup.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `KUBECONFIG` | `~/.kube/config` | Path to the target cluster's kubeconfig file |
| `INSTALLER_NAMESPACE` | from overlay | Target namespace for the OSAC deployment |
| `INSTALLER_KUSTOMIZE_OVERLAY` | `development` | Kustomize overlay directory to use |
| `EXTRA_SERVICES` | `false` | Enable all optional services (sets all below to `true`) |
| `INGRESS_SERVICE` | `false` | Install MetalLB as the ingress/LoadBalancer service |
| `STORAGE_SERVICE` | `false` | Install LVMS and create a default StorageClass (`lvms-vg1`) |
| `VIRT_SERVICE` | `false` | Install OpenShift Virtualization |
| `MCE_SERVICE` | `false` | Install Multicluster Engine and infrastructure operator |

#### AAP Configuration

The automation backend (AAP) is configured via two env files in your overlay's
`files/` directory:

- **`osac-aap-configuration.env`** — non-sensitive settings (network class, domains,
  connection details). Tracked in git with ESI defaults; customize for your
  environment.
- **`osac-aap-secrets.env`** — sensitive credentials (passwords, SSH keys, AWS keys).
  Gitignored, you create this file.

Edit these files to match your environment, then run `setup.sh` — the script
applies them automatically via `scripts/aap-configuration.sh`.

See [docs/aap-configuration.md](docs/aap-configuration.md) for the full variable
reference.

#### Network Backend Configuration (CaaS)

By default the network backend is **ESI**. To switch to **Netris**, set
`NETWORK_CLASS=netris` in your overlay's `osac-aap-configuration.env` and fill in
the Netris-specific connection details and credentials.

See [docs/network-backend.md](docs/network-backend.md) for Netris-specific
variables and the `NETRIS_RESOURCE_CLASS_MAP` format.

#### DNS Backend Configuration (CaaS)

DNS record management uses a pluggable backend. The default is **AWS Route 53**
(`DNS_CLASS=dns.route53.dns`), which requires AWS credentials in
`osac-aap-secrets.env`. No changes are needed for existing deployments.

To use a different DNS provider, set `DNS_CLASS` to a custom backend driver
role in your overlay's `osac-aap-configuration.env`.

See [docs/dns-backend.md](docs/dns-backend.md) for backend details, the
interface contract, and how to add a new provider.

> **Note:** The script requires `osac` to be installed and available in your
> `PATH` (see [OSAC CLI: Setup & Usage](#osac-cli-setup--usage) below for
> installation instructions).

The script will wait for all components to be ready before proceeding to the next step.
Once it completes successfully, OSAC is fully operational.

### Option B: Manual Installation

If you prefer to install step-by-step, or need to install individual prerequisites,
follow the manual process below.

#### Install Required Operators

OSAC requires several operators to be present on the cluster. The prerequisite manifests
are located in the `prerequisites/` directory. You can check if an operator is already
installed by running `oc get crd <crd-name>`.

```bash
# Install cert-manager
$ oc apply -k prerequisites/cert-manager

# Install trust-manager
$ oc apply -f prerequisites/trust-manager.yaml

# Install CA issuer
$ oc apply -f prerequisites/ca-issuer.yaml

# Install Authorino operator
$ oc apply -f prerequisites/authorino-operator.yaml

# Install Keycloak
$ oc apply -k prerequisites/keycloak/

# Install AAP operator
$ oc apply -f prerequisites/aap-installation.yaml

# Install MetalLB (optional - ingress/LoadBalancer service)
$ oc apply -f prerequisites/metallb/metallb-operator.yaml
# Wait for MetalLB operator to be ready, then apply config:
$ oc apply -f prerequisites/metallb/metallb-config.yaml

# Install LVMS (optional - storage service)
$ oc apply -f prerequisites/lvms/lvms-operator.yaml
# Wait for LVMS operator to be ready, then apply config:
$ oc apply -f prerequisites/lvms/lvms-config.yaml
# Set lvms-vg1 as default StorageClass:
$ oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

# Install Multicluster Engine (optional - MCE + infrastructure operator)
$ oc apply -f prerequisites/mce/mce-operator.yaml
# Wait for MCE operator to be ready, then create MultiClusterEngine and AgentServiceConfig:
$ oc apply -f prerequisites/mce/mce-config.yaml

# Install OpenShift Virtualization (optional - CNV/KubeVirt)
$ oc apply -f prerequisites/cnv/cnv-operator.yaml
# Wait for CNV operator to be ready, then apply HyperConverged config:
$ oc apply -f prerequisites/cnv/cnv-config.yaml
```

> **Tip:** Wait for each operator deployment to become available before proceeding to
> the next. For example: `oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s`

#### Apply the Kustomize Overlay

Once all prerequisites are ready, deploy OSAC:

```bash
$ oc apply -k overlays/<project-name>
```

### Monitor Progress

```bash
# Monitor pod creation and startup
$ watch oc get -n <project-name> pods
```

Several pods restart during initialization. The OpenShift job named `aap-bootstrap`
restarts several times before completing. This is expected behavior.

Once the `aap-bootstrap` job completes, OSAC is ready for use.

**Alternative: Install with Wait Option**

```bash
# Wait for all deployments to be ready (blocking command)
$ oc wait --for=condition=Available deployment --all -n <project-name> --timeout=600s
```

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

> **Note:** Refer to `base/fulfillment-service/hub-access/README.md` for more information

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

AAP routes will contain 'osac-aap' in the name.

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

This script will:
- Retrieve the AAP admin password from the `osac-aap-admin-password` secret
- Create an API token via the AAP gateway (`/api/gateway/v1/tokens/`)
- Store the token in a `osac-aap-api-token` secret
- Set the correct `OSAC_AAP_URL` on the operator deployment

### Using AAP Interface

From the AAP web interface, you can:
- Monitor cluster provisioning jobs and their status
- View automation execution logs and troubleshoot failures
- Manage job templates and automation workflows
- Configure additional automation tasks
- View inventory and host information

## Tearing Down OSAC

To completely remove an OSAC deployment and all its prerequisites, use the teardown script:

```bash
# Using defaults (namespace: osac-devel, overlay: development)
$ ./scripts/teardown.sh

# Or specify your namespace and overlay
$ INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/teardown.sh

# Include all optional services in teardown (must match what was used during setup)
$ EXTRA_SERVICES=true \
    INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/teardown.sh

# Or selectively match what was used during setup
$ INGRESS_SERVICE=true STORAGE_SERVICE=true \
    INSTALLER_NAMESPACE=<project-name> INSTALLER_KUSTOMIZE_OVERLAY=<project-name> ./scripts/teardown.sh
```

The script removes resources in reverse order:
1. StorageClass OSAC labels
2. Kustomize overlay resources and project namespace
3. Keycloak (before storage, since its PVCs depend on the storage class)
4. AAP operator
5. Multicluster Engine and AgentServiceConfig (if `MCE_SERVICE=true`)
6. LVMS storage service (if `STORAGE_SERVICE=true`)
7. MetalLB ingress service (if `INGRESS_SERVICE=true`)
8. OpenShift Virtualization (if `VIRT_SERVICE=true`)
9. Authorino operator
10. CA issuer, trust-manager, and cert-manager
11. Stale API services cleanup
12. NetworkAttachmentDefinition
13. Local `kubeconfig.hub-access` file

The script waits for all namespaces to be fully deleted before completing.

> **Warning:** This removes **all** prerequisite operators and their namespaces. If other
> workloads on the cluster depend on these operators (e.g., cert-manager, MetalLB), do not
> run this script. Instead, manually delete only the OSAC-specific resources:
> ```bash
> $ oc delete -k overlays/<project-name>
> $ oc delete namespace <project-name>
> ```

## Troubleshooting

### Common Issues

1. **cert-manager not ready**: Ensure cert-manager operator is installed and running
2. **Certificate issues**: Check cert-manager logs and certificate status
3. **ImagePullBackOff errors**: Verify registry credentials in `files/quay-pull-secret.json` and image string

### Debug Commands

```bash
# Check certificate status
$ oc describe certificate -n <project-name>

# Check certificate issuer status
$ oc describe issuer -n <project-name>

# Check pod events
$ oc describe pod -n <project-name> <pod-name>

# Check service endpoints
$ oc get endpoints -n <project-name>

# Check secrets
$ oc get secrets -n <project-name>

# View component logs
$ oc logs -n <project-name> deployment/fulfillment-service -c server --tail=100
$ oc logs -n <project-name> deployment/<project-name>-controller-manager --tail=100

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
