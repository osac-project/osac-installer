# OSAC Installer

Helm-based deployment orchestrator for OSAC components. No Go code, no builds, no unit tests — only structural validation.

## Quick Start

```bash
# Initialize submodules
git -C /path/to/osac-installer submodule update --init --recursive

# Validate changes
yamllint --strict /path/to/osac-installer
(cd /path/to/osac-installer && pre-commit run --all-files)
make -C /path/to/osac-installer helm-lint
make -C /path/to/osac-installer VALUES_FILE=/path/to/osac-installer/values/development/values.yaml helm-validate

# Deploy (three-phase Helm install)
make -C /path/to/osac-installer install VALUES_FILE=/path/to/osac-installer/values/development/values.yaml

# Uninstall
make -C /path/to/osac-installer uninstall
```

## Critical Rules

**Submodules (READ ONLY):**
- Never modify any `base/*/` directories (discover submodules with: `git submodule status`)
- Changes belong in component repos
- All git commands must run from installer root — never `cd` into submodule directories or use `git -C base/...`

**Helm Schema:**
- Every value in `charts/osac/values.yaml` **must** have matching `values.schema.json` entry
- Use `enum` for fields with known valid values

**Shell Scripts:**
- Use `set -euo pipefail` in all `scripts/*.sh`
- Source `scripts/lib.sh` for: `retry_until`, `wait_for_resource`, `wait_for_namespace_cleanup`

**Git Workflow:**
- Push to `fork` remote, never `origin`
- PRs: `fork/<branch>` → `origin/main`
- Commits: DCO (`-s`) + `Assisted-by: Claude Code <noreply@anthropic.com>`

**Shared Clusters:**
- Always use `-n <namespace>` in `oc`/`kubectl` — never rely on context

## Architecture

See `docs/helm-deployment-guide.md` for complete architecture details, including:
- Helm chart structure and dependencies
- Submodule organization and version tracking
- Prerequisites and operator deployment patterns
- Values file organization per environment

```text
charts/osac/           # Helm umbrella chart (Chart.yaml, values.yaml, values.schema.json)
charts/osac-operators/ # Phase 1: OLM operator subscriptions
charts/osac-prereqs/   # Phase 2: CRD instances, certs, Keycloak
values/<env>/          # Environment values (development, vmaas-ci, caas-ci)
base/                  # Git submodules — discover with: git submodule status
prerequisites/         # Reference manifests for manual prerequisite installation
scripts/               # Automation scripts (see README.md for full list)
```

Submodules are pinned snapshots for version tracking. Image tags in `values/*/values.yaml`
must match submodule commits — CI enforces this via `scripts/sync-image-tags.sh`.
After updating a submodule pointer, run `./scripts/sync-image-tags.sh --fix`.

Prerequisites are installed via Phase 1 (`make install-operators`) and Phase 2
(`make install-prereqs`), each gated by values toggles. See `Makefile` for
underlying commands and `docs/helm-deployment-guide.md` for phase details.

## Key Scripts

See `README.md` for complete script documentation. Most commonly used:

- `teardown.sh` — Full teardown: uninstalls Helm releases, removes operators and CRDs
- `sync-image-tags.sh` — Syncs Helm values image tags to match submodule commits
- `refresh-after-snapshot.py` — Refresh after snapshot boot

## Workflows

AI-assisted workflows reference detailed phase instructions:

- **Bugfix workflow:** `.ai-bot/new-ticket-workflow.md` → phases in `.ai-workflows/bugfix/skills/`
- **Review feedback:** `.ai-bot/feedback-workflow.md` → phases in `.ai-workflows/bugfix/skills/feedback.md`

## Documentation

Detailed information moved from this file to specialized docs:

- **Bugfix workflow orchestrator:** `.ai-bot/new-ticket-workflow.md` (phases: assess → diagnose → fix → validate → review → pr)
- **Review feedback workflow:** `.ai-bot/feedback-workflow.md`
- **Validation commands & conventions:** `.ai-bot/instructions.md`
- **Architecture & deployment:** `docs/helm-deployment-guide.md`
- **Script reference:** `README.md`
- **CLI usage:** `OSAC-CLI-HOWTO.md`
- **Component repos:** `base/*/AGENTS.md` (discover with: `git submodule status`)
- **Design docs:** [osac-project/docs/architecture](https://github.com/osac-project/docs/tree/main/architecture)
