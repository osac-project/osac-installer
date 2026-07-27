# AGENTS.md

## Overview

Helm-based deployment system for the OSAC platform. Component repos (osac-operator, osac-fulfillment-service, osac-aap, bare-metal-fulfillment-operator, osac-ui) are aggregated as Git submodules under `base/` for version tracking. Deployment uses three Helm charts in sequence: `charts/osac-operators/` (Phase 1), `charts/osac-prereqs/` (Phase 2), `charts/osac/` (Phase 3).

## Common Commands

```bash
# Initialize submodules (required before sync-image-tags)
git submodule update --init --recursive

# Helm lint (all three charts)
make helm-lint

# Helm template render (dry-run validation against all values files)
make helm-validate

# Sync submodules and rebuild chart dependencies
make sync-charts

# Deploy to OpenShift (three-phase Helm install)
make install VALUES_FILE=values/<env>/values.yaml

# Individual install phases
make install-operators VALUES_FILE=values/<env>/values.yaml
make install-prereqs VALUES_FILE=values/<env>/values.yaml
make install-osac VALUES_FILE=values/<env>/values.yaml

# Uninstall
make uninstall

# Run pre-commit hooks
pre-commit run --all-files

# YAML lint only
yamllint --strict .
```

## Architecture

### Helm Charts (Three-Phase Deployment)

```text
Phase 1: charts/osac-operators/         # OLM operator subscriptions
  Installs: cert-manager, AAP, LVMS, CNV, MCE, MetalLB
  Hook scripts wait for operators to be ready before proceeding

Phase 2: charts/osac-prereqs/           # Cluster prerequisites
  Configures: certificates (CA issuer, trust-manager), Keycloak,
  operator CRs (HyperConverged, LVMCluster, MetalLB, MCE)
  Hook scripts configure each operator after its CRD is ready

Phase 3: charts/osac/                   # OSAC platform (umbrella chart)
  Dependencies (from submodules via file:// references):
    osac-operator-crds, osac-operator, fulfillment-service,
    osac-aap, bare-metal-fulfillment-operator-crds,
    bare-metal-fulfillment-operator (conditional: bmf.enabled),
    osac-ui (conditional: ui.enabled)
  Templates: bundled-postgres, hub-access, hooks (create-hub,
    pre-install-validate, publish-templates, seed-cluster-versions)
  values.schema.json validates all configuration
```

### Values Environments

```text
values/
  development/values.yaml              # All controllers, latest images
  vmaas-ci/values.yaml                 # VMaaS CI: computeInstance + tenant + networking
  caas-ci/values.yaml                  # CaaS CI: clusterOrder + tenant + networking
  bmaas-ci/values.yaml                 # BM-as-a-Service CI: bmf + storage + bareMetalInstance
```

### Submodules

Submodules under `base/` (osac-operator, osac-fulfillment-service, osac-aap, bare-metal-fulfillment-operator, osac-ui) are pinned snapshots used for version tracking. `scripts/sync-image-tags.sh` syncs image tags in `values/*/values.yaml` to match submodule commit SHAs. With `--fix`, it rewrites `sha-`, stable `vX.Y.Z`, and `latest` tags; default (check) mode reports `sha-` mismatches and skips non-SHA pins.

### Image Tag Lifecycle

Two automated workflows manage image tags in overlay values files (`values/*/values.yaml`):

1. **Between releases** -- `bump-submodules.yaml` (every 3 hours) advances overlays to `sha-` tags tracking each component's latest main commit. It runs `sync-image-tags.sh --fix`, which rewrites `sha-`, stable `vX.Y.Z`, and `latest` (not digests, prerelease tags, or arbitrary strings). This keeps CI/dev environments testing the newest code.
2. **At release time** -- `publish-charts.yaml` calls `scripts/pin-release-tags.sh` to replace `sha-`, stable `vX.Y.Z`, and `latest` with released version tags (e.g. `v0.0.8`), then opens a PR to merge the pins into main. This reconciles overlays with the official chart release.

After a release PR is merged, overlays match the released versions exactly. As new commits land on component repos, `bump-submodules.yaml` advances them again until the next release pins them.

**To check drift:** compare image tags in `values/*/values.yaml` against the latest [GitHub release](https://github.com/osac-project/osac-installer/releases). If tags are `sha-` prefixed, the environment is running ahead of the last release. If tags are `v`-prefixed, compare each component's exact version against the release notes to confirm alignment. If tags are `latest`, the overlay is tracking an unpinned moving tag — check the release PR or the last GitHub release to determine the expected pinned version.

### Prerequisites

Prerequisites are installed automatically by Phase 1 (`make install-operators`) and configured by Phase 2 (`make install-prereqs`). Each prerequisite is gated by a values toggle. `prerequisites/` contains reference manifests for manual installation if needed.

### Scripts

- **teardown.sh** -- Full teardown: uninstalls Helm releases, removes operators and CRDs
- **sync-image-tags.sh** -- Syncs image tags in Helm values files to match submodule commits
- **pin-release-tags.sh** -- Pins overlay values files to released versioned image tags (called by `publish-charts.yaml` at release time)
- **setup-remote-cluster.sh** -- CI-only: prepares a fresh remote cluster (LVMS, CNV, service accounts)
- **create-hub-access-kubeconfig.sh** -- Generates `kubeconfig.hub-access` from the hub-access ServiceAccount token
- **generate-chart-versions.sh** -- Computes nightly chart versions from latest release tags
- **get-chart-version.sh** -- Looks up a field (version/source_tag/source_sha) from chart-versions.txt
- **oc.sh** -- Wraps `oc` with `--as` impersonation when `OC_IMPERSONATE` is set
- **refresh-after-snapshot.py** -- Refreshes Helm-deployed cluster after booting from cold snapshot
- **setup-caas-agents.sh** -- Sets up CaaS agent infrastructure (InfraEnv + agent VM + label + approve)
- **lib.sh** -- Shared shell functions: `retry_until`, `wait_for_resource`, `wait_for_namespace_cleanup`, `retry_command`, `http_retry`, `http_json`, `resolve_release_tag`, `check_postgres_prerequisites`

### CI Workflows

| Workflow | Purpose |
|----------|---------|
| `bump-submodules.yaml` | Automated submodule updates |
| `check-image-tags.yaml` | Verifies image tags match submodule SHAs |
| `cleanup-nightly-branches.yaml` | Cleans up old nightly branches |
| `e2e-bmaas-full-install.yml` | BM-as-a-Service E2E tests |
| `e2e-vmaas-full-install.yml` | VMaaS E2E tests |
| `helm-lint.yaml` | Helm chart linting |
| `integration-tests.yml` | Integration test suite |
| `mirror-envoy.yaml` | Mirrors Envoy images |
| `nightly-build.yaml` | Nightly chart build and publish |
| `ok-to-test-label-cleanup.yml` | Removes ok-to-test label on new pushes |
| `pre-commit.yaml` | Pre-commit hook checks |
| `publish-charts.yaml` | Publishes Helm charts on release |
| `secret-scanning.yaml` | Scans for leaked secrets |
| `slash-command.yml` | Handles PR slash commands |

## Submodules and Local Development

Submodules under `base/` are pinned snapshots of the real working repos. They do not auto-sync -- to test local changes, synchronize modified files from the working repo into the submodule directory, without committing. During active development the submodule pointers are often dirty; this is expected.

Do not `cd` into submodule directories and run git commands there -- you will operate on the submodule repo, not the installer. Always run git commands from the installer root.

After updating a submodule pointer, update the corresponding image tag via `./scripts/sync-image-tags.sh --fix`.

## Helm Chart Conventions

- **Every new value must have a matching schema entry** -- when adding or modifying keys in `charts/osac/values.yaml`, always add the corresponding property definition to `charts/osac/values.schema.json`. Use `enum` constraints for fields with a known set of valid values (e.g., network/DNS backend classes). The schema is both validation and documentation -- incomplete schemas allow silent misconfiguration.

## Key Conventions

- Values files are organized per environment under `values/<env>/values.yaml`.
- Pull secrets and AAP license files are stored alongside values files (e.g., `values/<env>/pull-secret.json`, `values/<env>/license.zip`).
- `ca-bundle` Bundle is cluster-scoped and managed by the `osac-prereqs` chart via trust-manager.
