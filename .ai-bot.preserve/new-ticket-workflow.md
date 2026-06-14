Execute the following workflow phases in order. This is an
infrastructure/deployment repo -- there are no unit tests. Validation
is structural (YAML lint, kustomize build, sync checks).

1. **Read and execute .ai-workflows/bugfix/skills/assess.md**
   The bug report is in `.ai-bot/issue.md`. Identify which files are
   affected (overlays, base kustomization, scripts, prerequisites).
   Do not ask clarifying questions -- make reasonable assumptions.

2. **Read and execute .ai-workflows/bugfix/skills/diagnose.md**
   Write your root cause analysis to `.ai-bot/diagnosis.md`.
   For Kustomize issues, capture the full `kustomize build` output of
   affected overlays before and after to isolate the problem.

3. **Read and execute .ai-workflows/bugfix/skills/fix.md**
   Implement the minimal fix. Key constraints:
   - Never modify files inside submodule directories (`base/osac-operator/`,
     `base/osac-fulfillment-service/`, `base/osac-aap/`).
   - If the fix involves submodule pointer updates, also run
     `bash scripts/sync-image-tags.sh --fix`.
   - If the fix touches overlay AuthConfig Rego patches, also run
     `python3 scripts/sync-authconfig-rego.py --fix`.

4. **Validate changes**
   Run all validation commands in sequence. If any fail, revise your
   fix and revalidate (up to 5 iterations):
   ```
   yamllint --strict .
   pre-commit run --all-files
   bash scripts/kustomize-build-all.sh
   bash scripts/sync-image-tags.sh
   python3 scripts/sync-authconfig-rego.py
   ```
   Additionally, diff kustomize build output for affected overlays
   against the baseline to confirm only intended changes appear.

5. **Read and execute .ai-workflows/bugfix/skills/review.md**
   Self-review your changes. Pay special attention to:
   - Namespace references embedded in YAML strings (APIService,
     cert-manager annotations, Certificate dnsNames)
   - Cluster-scoped resources that need prefixTransformer coverage
   - Overlay consistency (if you changed one overlay, check whether
     parallel overlays need the same change)
   If issues are found, correct them, revalidate, and re-review
   (up to 4 iterations).

6. **Write PR description to `.ai-bot/pr.md`**
   Use the `## Title` heading format. Include:
   - A Root Cause section from `.ai-bot/diagnosis.md`
   - Which overlays are affected
   - The kustomize build diff (before/after) for affected overlays
