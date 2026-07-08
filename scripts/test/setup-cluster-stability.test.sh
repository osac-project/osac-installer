#!/usr/bin/env bash
# Behavioral tests for cluster stability gate environment detection.
set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

assert_skip() {
    local label="$1"
    if _should_skip_mcp_stability_check; then
        pass "${label} skips MCP stability check"
    else
        fail "${label} should skip MCP stability check"
    fi
}

assert_no_skip() {
    local label="$1"
    if _should_skip_mcp_stability_check; then
        fail "${label} should not skip MCP stability check"
    else
        pass "${label} runs MCP stability check"
    fi
}

# CI E2E: prerequisites step after workflow MCP gate
(
    CI=true GITHUB_ACTIONS=true SETUP_PHASE=prerequisites SKIP_MCP_STABILITY_CHECK=
    assert_skip "CI prerequisites phase"
)

# CI hypothetical full install: still run MCP gate
(
    CI=true GITHUB_ACTIONS=true SETUP_PHASE=all SKIP_MCP_STABILITY_CHECK=
    assert_no_skip "CI full install (SETUP_PHASE=all)"
)

# Manual production / developer install via setup.sh
(
    unset CI GITHUB_ACTIONS
    SETUP_PHASE=all SKIP_MCP_STABILITY_CHECK=
    assert_no_skip "manual SETUP_PHASE=all"
)

(
    unset CI GITHUB_ACTIONS
    SETUP_PHASE=prerequisites SKIP_MCP_STABILITY_CHECK=
    assert_no_skip "manual SETUP_PHASE=prerequisites only"
)

# Explicit override for custom automation
(
    unset CI GITHUB_ACTIONS
    SETUP_PHASE=all SKIP_MCP_STABILITY_CHECK=true
    assert_skip "SKIP_MCP_STABILITY_CHECK override"
)

echo "All cluster stability environment checks passed."
