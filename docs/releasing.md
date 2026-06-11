# Releasing a New Version

This document describes how to publish new OSAC Helm chart versions to the OCI
registry at `oci://ghcr.io/osac-project/charts`.

## Overview

OSAC consists of four component charts and one umbrella chart:

| Chart | Source repo | Registry path |
|---|---|---|
| fulfillment-service | osac-project/fulfillment-service | `oci://ghcr.io/osac-project/charts/fulfillment-service` |
| osac-operator | osac-project/osac-operator | `oci://ghcr.io/osac-project/charts/osac-operator` |
| osac-operator-crds | osac-project/osac-operator | `oci://ghcr.io/osac-project/charts/osac-operator-crds` |
| osac-aap | osac-project/osac-aap | `oci://ghcr.io/osac-project/charts/osac-aap` |
| osac (umbrella) | osac-project/osac-installer | `oci://ghcr.io/osac-project/charts/osac` |

Each repo has a `publish-charts.yaml` GitHub Actions workflow triggered by `v*`
tag pushes. Chart.yaml files in component repos use `version: 0.0.0` as a
placeholder — the real version is injected at publish time from the git tag.

## Publishing component charts

### 1. Determine the next version

```bash
cd /path/to/<component-repo>
git fetch upstream --tags
git tag --sort=-v:refname | head -5
```

### 2. Tag and push

Tag `upstream/main` to ensure you're tagging the latest merged code:

```bash
git tag v<version> upstream/main
git push upstream v<version>
```

The `publish-charts.yaml` workflow triggers automatically.

> **Note:** osac-operator publishes **two** charts (osac-operator and
> osac-operator-crds) from a single tag push.

### 3. Verify

```bash
# Check workflow status
gh run list --repo osac-project/<repo> --limit 3

# Verify chart is pullable
helm pull oci://ghcr.io/osac-project/charts/<chart-name> --version <version>
```

For fulfillment-service, also verify the GitHub Release was created by
goreleaser:

```bash
gh release view v<version> --repo osac-project/fulfillment-service
```

## Publishing the umbrella chart

The umbrella chart bundles all component charts. Its publish workflow reads
component versions from `charts/osac/Chart.yaml` and rewrites the `file://`
dependency repositories to OCI references at publish time.

> **Note:** `Chart.yaml` uses `file://` repositories for local development and
> CI. Local builds (lint, integration, setup.sh) reset dependency versions to
> `0.0.0` before `helm dependency build` so they match the submodule charts.
> The publish workflow reads the real versions and rewrites to OCI.

### 1. Update dependency versions in Chart.yaml

Before publishing, update the dependency versions in `charts/osac/Chart.yaml`
to match the published component chart versions:

```yaml
dependencies:
  - name: osac-operator-crds
    version: "0.0.1"          # ← published component version
    repository: "file://../../base/osac-operator/charts/operator-crds"
    alias: operatorCrds
  # ... repeat for each dependency
```

Commit and merge this change before tagging.

### 2a. Publish via tag push

```bash
cd /path/to/osac-installer
git tag v<version> upstream/main
git push upstream v<version>
```

The umbrella chart version comes from the tag. Component versions are read from
`charts/osac/Chart.yaml`.

### 2b. Publish via workflow dispatch

All inputs are optional — omitted values fall back to `charts/osac/Chart.yaml`:

```bash
gh workflow run publish-charts.yaml \
  --repo osac-project/osac-installer \
  -f version=<umbrella-version> \
  -f operator_crds_version=<version> \
  -f operator_version=<version> \
  -f service_version=<version> \
  -f aap_version=<version>
```

This is useful for testing a new component version without committing to
`Chart.yaml` first.

### 3. Verify

```bash
helm pull oci://ghcr.io/osac-project/charts/osac --version <version>
```

## Tips

- Always tag `upstream/main`, not a local branch
- If a tag already exists, delete it first:
  `git tag -d v<version> && git push upstream :refs/tags/v<version>`
- The publish workflows replace `tag: latest` with `tag: v<version>` in
  values.yaml — this requires the source values.yaml to use `tag: latest`
- Keep `charts/osac/Chart.yaml` dependency versions up to date — they are the
  source of truth for tag-based umbrella releases
