# Helm Chart Build Modes

The OSAC umbrella chart (`charts/osac/`) assembles six component subcharts into a single deployable unit. There are four distinct modes for building and consuming these charts, each serving a different stage of the development lifecycle.

All published charts live in the OCI registry at `oci://ghcr.io/osac-project/charts`.

## Overview

| Mode | Subchart source | Umbrella version | Trigger | Use case |
|------|----------------|-----------------|---------|----------|
| **Local dev** | Local submodules (`file://`) | N/A (not published) | `make dev-deps` | Iterating on uncommitted subchart changes |
| **Dev** | OCI, pinned to submodule SHAs | `0.0.0-dev.<sha>` | Push to `main` | CI environments tracking latest main |
| **Nightly** | OCI, floating `0.0.0-dev` tags | `0.0.0-nightly.<date>` | Daily at 03:23 UTC | Nightly integration testing |
| **Release** | OCI, pinned to tagged versions | `<semver>` (e.g. `0.1.0`) | `v*` tag or manual dispatch | Production deployments |

## Local Development

**Purpose:** Iterate on subchart changes before they're merged or published.

The committed `Chart.yaml` points to pinned OCI versions for most subcharts. The `make dev-deps` target temporarily rewrites those to `file://` references against local git submodules, builds dependencies, then restores `Chart.yaml`.

```bash
# Sync submodules to latest main
make sync-charts

# Build from local submodules
make dev-deps
```

**What happens under the hood:**

1. `git submodule update --init --recursive` ensures submodules are checked out
2. `scripts/rewrite-chart-deps-local.sh` replaces OCI refs with `file://` paths
3. `helm dependency build charts/osac/` resolves charts from submodule directories
4. `Chart.yaml` is restored to its committed state (OCI refs)

**Resulting chart versions:**

```
osac-operator-crds          0.0.0   (from base/osac-operator/charts/operator-crds)
osac-operator               0.0.0   (from base/osac-operator/charts/operator)
fulfillment-service         0.0.0   (from base/osac-fulfillment-service/charts/service)
osac-aap                    0.0.0   (from base/osac-aap/charts/aap)
bmf-crds                    0.0.0   (from base/bare-metal-fulfillment-operator/charts/operator-crds)
bmf                         0.0.0   (from base/bare-metal-fulfillment-operator/charts/operator)
```

All versions are `0.0.0` because that's what the component `Chart.yaml` files have hardcoded — real versions are assigned at publish time.

**When to use:** You're changing a subchart template or values and want to test the umbrella chart locally before pushing.

## Dev Builds

**Purpose:** Provide a traceable, per-commit build of every chart from the latest `main` of each component.

**Trigger:** Every push to `main` on `osac-installer` (workflow: `publish-dev-charts.yaml`).

**How it works:**

1. Checks out `osac-installer` with all submodules at their pinned commits
2. Computes short SHAs for each submodule (e.g. `8220502` for osac-operator)
3. Publishes each subchart from its submodule directory with version `0.0.0-dev.<sha>` and a floating `0.0.0-dev` tag
4. Rewrites the umbrella `Chart.yaml` to reference each subchart at its `0.0.0-dev.<sha>` version
5. Publishes the umbrella chart as `0.0.0-dev.<installer-sha>` with a floating `0.0.0-dev` tag

**Resulting chart versions (example):**

```
osac (umbrella)             0.0.0-dev.925a351        (also tagged 0.0.0-dev)
├── osac-operator-crds      0.0.0-dev.8220502
├── osac-operator           0.0.0-dev.8220502
├── fulfillment-service     0.0.0-dev.6b1f439
├── osac-aap                0.0.0-dev.89f41e7
├── bmf-crds                0.0.0-dev.0a06955
└── bmf                     0.0.0-dev.0a06955
```

**Key properties:**

- **Traceable:** Each version embeds the exact submodule commit SHA — you can map any deployed chart back to a source commit
- **Floating tag:** `0.0.0-dev` always points to the latest dev build of each chart — use it when you want "whatever is latest" without tracking SHAs
- **Submodule-driven:** The subchart versions come from whatever commits the submodules are pinned to in `osac-installer`, not from the component repos directly. Bumping a submodule pointer and merging to `main` triggers new dev charts.

**To deploy the latest dev build:**

```bash
helm install osac oci://ghcr.io/osac-project/charts/osac --version 0.0.0-dev
```

**To deploy a specific dev build:**

```bash
helm install osac oci://ghcr.io/osac-project/charts/osac --version 0.0.0-dev.925a351
```

## Nightly Builds

**Purpose:** Assemble the umbrella chart from the latest floating `0.0.0-dev` subcharts — a single daily snapshot that always picks up the most recent component merges without submodule management.

**Trigger:** Daily at 03:23 UTC (workflow: `publish-nightly-charts.yaml`). Also available via manual dispatch.

**How it works:**

1. Checks out `osac-installer` (no submodules needed)
2. Rewrites the umbrella `Chart.yaml` to reference all subcharts at the `0.0.0-dev` floating tag
3. `helm dependency build` pulls whatever `0.0.0-dev` resolves to at that moment
4. Publishes the umbrella chart as `0.0.0-nightly.<YYYYMMDD>` with a floating `0.0.0-nightly` tag

**Resulting chart versions (example for 2026-06-26):**

```
osac (umbrella)             0.0.0-nightly.20260626   (also tagged 0.0.0-nightly)
├── osac-operator-crds      0.0.0-dev               (floating, resolves to latest)
├── osac-operator           0.0.0-dev
├── fulfillment-service     0.0.0-dev
├── osac-aap                0.0.0-dev
├── bmf-crds                0.0.0-dev
└── bmf                     0.0.0-dev
```

**Key properties:**

- **All-latest:** Every subchart is the most recent `0.0.0-dev` version — no submodule pinning involved
- **Date-stamped:** Nightly versions include the date for easy identification
- **No submodules required:** Unlike dev builds, the nightly workflow doesn't check out submodules — it relies entirely on previously published `0.0.0-dev` charts in the OCI registry
- **Less traceable:** Subcharts are pinned to the floating `0.0.0-dev` tag, so you can't determine exact component commits from the chart metadata alone

**To deploy the latest nightly:**

```bash
helm install osac oci://ghcr.io/osac-project/charts/osac --version 0.0.0-nightly
```

**To deploy a specific nightly:**

```bash
helm install osac oci://ghcr.io/osac-project/charts/osac --version 0.0.0-nightly.20260626
```

## Release Builds

**Purpose:** Produce a versioned, production-grade umbrella chart with each subchart pinned to a specific tagged release.

**Trigger:** Pushing a `v*` tag on `osac-installer`, or manual dispatch with explicit version inputs.

**How it works:**

1. Resolves component versions from workflow inputs (manual dispatch) or defaults to the umbrella version (tag push)
2. Rewrites the umbrella `Chart.yaml` to reference each subchart at its specified version
3. `helm dependency build` pulls the exact tagged versions from the OCI registry
4. Replaces `tag: latest` in `values.yaml` with `tag: v<version>` for container images
5. Publishes the umbrella chart at the specified version

**Inputs (manual dispatch):**

| Input | Example | Description |
|-------|---------|-------------|
| `version` | `0.1.0` | Umbrella chart version (defaults to git tag) |
| `operator_crds_version` | `0.0.2` | osac-operator-crds chart version |
| `operator_version` | `0.0.2` | osac-operator chart version |
| `service_version` | `0.0.67` | fulfillment-service chart version |
| `aap_version` | `0.0.4` | osac-aap chart version |

**Resulting chart versions (example):**

```
osac (umbrella)             0.1.0
├── osac-operator-crds      0.0.2
├── osac-operator           0.0.2
├── fulfillment-service     0.0.67
├── osac-aap                0.0.4
├── bmf-crds                0.1.0                    (defaults to umbrella version)
└── bmf                     0.1.0
```

**Key properties:**

- **Fully pinned:** Every subchart version is explicit and immutable
- **Requires pre-published subcharts:** Each component must have its chart published at the specified version before the umbrella release can succeed
- **Image tags updated:** Container image references in `values.yaml` are rewritten to match the release version

**To deploy a release:**

```bash
helm install osac oci://ghcr.io/osac-project/charts/osac --version 0.1.0
```

## The Committed Chart.yaml

The `Chart.yaml` checked into `main` represents the **dev build baseline** — it uses hardcoded OCI versions that track the latest known-good releases:

```yaml
dependencies:
  - name: osac-operator-crds
    version: "0.0.2"
    repository: "oci://ghcr.io/osac-project/charts"
  - name: osac-operator
    version: "0.0.2"
    repository: "oci://ghcr.io/osac-project/charts"
  - name: fulfillment-service
    version: "0.0.67"
    repository: "oci://ghcr.io/osac-project/charts"
  - name: osac-aap
    version: "0.0.4"
    repository: "oci://ghcr.io/osac-project/charts"
```

These versions are updated manually when a component publishes a new release:

```bash
make bump-chart BUMP_CHART=fulfillment-service BUMP_VERSION=0.0.68
```

All three publish workflows (`dev`, `nightly`, `release`) override these versions at build time via `scripts/rewrite-chart-deps.sh`. The committed versions serve two purposes:

1. **`make helm-deps` works out of the box** — anyone can `helm dependency build charts/osac/` without submodules or special tooling
2. **PR validation uses real published charts** — the CI lint workflow pulls from the OCI registry, catching version reference errors before merge

## Version Lifecycle and Cleanup

Chart versions accumulate in the OCI registry. The `cleanup-charts.yaml` workflow runs weekly (Mondays at 04:41 UTC) and deletes `0.0.0-dev.*` and `0.0.0-nightly.*` versions older than 4 weeks. The floating tags (`0.0.0-dev`, `0.0.0-nightly`) and tagged releases are preserved indefinitely.

```
Kept forever:      0.0.0-dev, 0.0.0-nightly, 0.0.2, 0.0.67, 0.1.0, ...
Cleaned after 4w:  0.0.0-dev.8220502, 0.0.0-nightly.20260601, ...
```

## Quick Reference

```bash
# Local development (uncommitted subchart changes)
make sync-charts      # update submodules
make dev-deps         # build from local submodules

# Default OCI build (uses committed pinned versions)
make helm-deps        # pull from registry

# Bump a subchart after a new component release
make bump-chart BUMP_CHART=osac-operator BUMP_VERSION=0.0.3

# Lint and validate
make helm-lint        # lint with OCI deps
make helm-validate    # lint + template

# Deploy
make helm-deploy      # deploy to current cluster

# Run targets in a container (has helm, yq, make, git)
make container-build
make container-run TARGET=helm-lint
```
