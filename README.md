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
[OSAC documentation repository](https://github.com/innabox/docs).

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
> * ESI (Elastic System Infrastructure) - Required for bare metal provisioning

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
   You **must** update these two configuration values to match your `<project-name>`:

   - In `kustomization.yaml`: Update the `namespace` field to `<project-name>`
   - In `prefixTransformer.yaml`: Update the `prefix` field to `<project-name>-`

   These changes ensure your installation uses a unique namespace and prevents resource
   name conflicts with other OSAC installations.

5. **Apply Additional Customizations:**
   Modify other settings in your overlay folder as needed (images, patches, etc.).


> For more information on structuring overlays and patches, please consult the [official
> Kustomize documentation.](https://kubectl.docs.kubernetes.io/references/kustomize/)


### Obtaining an AAP License

Download AAP license manifest from [Red Hat Customer
Portal](https://access.redhat.com/downloads/content/480/ver=2.5/rhel---9/2.5/x86_64/product-software)

## Deploying OSAC Components

Once you have customized your overlay, deploy the OSAC components to your cluster.

### Install and Monitor Progress

```bash
# Deploy using your project-specific overlay
$ oc apply -k overlays/<project-name>

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

## Fulfillment CLI: Setup & Usage

To install the CLI and register a hub, follow these steps:

### 1. Install the Binary

Download the latest release and make it executable.

```bash
# Adjust URL for the latest version as needed
$ curl -L -o fulfillment-cli \
    https://github.com/innabox/fulfillment-cli/releases/latest/download/fulfillment-cli-linux-amd64
$ chmod +x fulfillment-cli

# Optional: Move to your path
$ sudo mv fulfillment-cli /usr/local/bin/
```

### 2. Log in to the Service

Authenticate with the fulfillment API. You will need the route address and a valid
token generation script.

```bash
$ fulfillment-cli login \
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
$ fulfillment-cli create hub \
    --kubeconfig=kubeconfig.hub-access \
    --id <hub-name> \
    --namespace <project-name>
```

> **Note:** Refer to `base/fulfillment-service/hub-access/README.md` for more information

### 4. Use the CLI

Once configured, you can use the fulfillment CLI to manage clusters and virtual machines.
For detailed usage instructions and command reference, see the
[fulfillment-cli documentation](https://github.com/innabox/fulfillment-cli).

## Accessing Ansible Automation Platform

After deployment, you can access the AAP web interface to monitor jobs and manage automation:

### Get the AAP URL

```bash
$ oc get route -n <project-name> | grep innabox-aap
```

AAP routes will contain 'innabox-aap' in the name.

> **Note:** The main AAP URL will be something like: `https://innabox-aap-<project-name>.apps.your-cluster.com`

### Get the AAP Admin Password

```bash
# Extract the admin password
$ oc extract secret/innabox-aap-admin-password -n <project-name> --to -
```

### Login to AAP

- Open the AAP controller URL in your browser
- Username: `admin`
- Password: (from the previous step)

### Using AAP Interface

From the AAP web interface, you can:
- Monitor cluster provisioning jobs and their status
- View automation execution logs and troubleshoot failures
- Manage job templates and automation workflows
- Configure additional automation tasks
- View inventory and host information

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
