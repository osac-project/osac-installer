Execute the following workflow phases in order. This is an
infrastructure/deployment repo -- there are no unit tests. Validation
is structural (YAML lint, Helm lint, sync checks).

1. **Read and execute .ai-workflows/bugfix/skills/assess.md**
   The bug report is in `.ai-bot/issue.md`. Identify which files are
   affected (Helm charts, values files, scripts, prerequisites).
   Do not ask clarifying questions -- make reasonable assumptions.

2. **Read and execute .ai-workflows/bugfix/skills/diagnose.md**
   Write your root cause analysis to `.ai-bot/diagnosis.md`.

3. **Read and execute .ai-workflows/bugfix/skills/fix.md**
   Implement the minimal fix. Key constraints:
   - Never modify files inside submodule directories (`base/osac-operator/`,
     `base/osac-fulfillment-service/`, `base/osac-aap/`).
   - If the fix involves submodule pointer updates, also run
     `bash scripts/sync-image-tags.sh --fix`.

4. **Validate changes**
   Run all validation commands in sequence. If any fail, revise your
   fix and revalidate (up to 5 iterations):
   ```
   yamllint --strict .
   pre-commit run --all-files
   helm lint charts/osac/
   for f in values/*/values.yaml; do helm template osac charts/osac/ --values "$f" > /dev/null; done
   bash scripts/sync-image-tags.sh
   ```

5. **Read and execute .ai-workflows/bugfix/skills/review.md**
   Self-review your changes. Pay special attention to:
   - Values file consistency (if you changed one values file, check
     whether other values files need the same change)
   - Helm schema updates (new values must have matching schema entries)
   If issues are found, correct them, revalidate, and re-review
   (up to 4 iterations).

6. **Write PR description to `.ai-bot/pr.md`**
   Use the `## Title` heading format. Include:
   - A Root Cause section from `.ai-bot/diagnosis.md`
   - Which values files are affected
