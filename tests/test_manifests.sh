#!/bin/bash
# Static shape checks for the Claude and Codex plugin manifests
# (tests/AGENTS.md scenario 14). Pure jq/grep, no runtime at all.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"

CLAUDE_PLUGIN="$PROJECT_DIR/release/.claude-plugin/plugin.json"
CODEX_PLUGIN="$PROJECT_DIR/release/codex/.codex-plugin/plugin.json"
CODEX_HOOKS="$PROJECT_DIR/release/codex/hooks/hooks.json"

test_claude_plugin_manifest() {
  jq empty "$CLAUDE_PLUGIN" || fail "claude plugin.json is valid JSON"

  # tmux run-shell's non-login-shell PATH pitfall has a Claude-side
  # equivalent: every hook command must use the plugin-root-relative path,
  # never a bare `notify` that depends on the hook's own PATH.
  local commands bad_commands
  commands=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$CLAUDE_PLUGIN")
  bad_commands=$(printf '%s\n' "$commands" | grep -v '^\${CLAUDE_PLUGIN_ROOT}/notify ' || true)
  [ -z "$bad_commands" ] || fail "every claude hook command must start with \${CLAUDE_PLUGIN_ROOT}/notify (found: $bad_commands)"

  local timeouts bad_timeouts
  timeouts=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .timeout' "$CLAUDE_PLUGIN")
  bad_timeouts=$(printf '%s\n' "$timeouts" | awk '$1 < 1 || $1 > 3' || true)
  [ -z "$bad_timeouts" ] || fail "every claude hook timeout should stay within the documented 1-3s bound (found: $bad_timeouts)"

  # This overlap is the known, currently-accepted T4/TODO race (both the
  # AskUserQuestion-specific and the catch-all PreToolUse hook fire for that
  # tool). This assertion is a tripwire for either direction of drift, not a
  # claim that the overlap is correct.
  [ "$(jq '.hooks.PreToolUse | length' "$CLAUDE_PLUGIN")" = "2" ] || \
    fail "PreToolUse must have exactly 2 entries (the AskUserQuestion-specific one and the catch-all)"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$CLAUDE_PLUGIN")" = "AskUserQuestion" ] || \
    fail "the first PreToolUse entry matches AskUserQuestion"
  [ "$(jq '.hooks.PreToolUse[1] | has("matcher")' "$CLAUDE_PLUGIN")" = "false" ] || \
    fail "the second PreToolUse entry is the catch-all (no matcher) that overlaps with AskUserQuestion"

  pass "claude plugin.json: valid, absolute paths, sane timeouts, documented PreToolUse overlap present"
}

test_codex_plugin_manifest() {
  jq empty "$CODEX_PLUGIN" || fail "codex plugin.json is valid JSON"
  jq -e '.version | test("\\+codex\\.[0-9]+$")' "$CODEX_PLUGIN" >/dev/null || \
    fail "codex plugin.json version carries the +codex.<timestamp> build suffix"
  pass "codex plugin.json: valid JSON with the expected version suffix"
}

test_codex_hooks_manifest() {
  jq empty "$CODEX_HOOKS" || fail "codex hooks.json is valid JSON"

  # Codex never sets CLAUDE_CODE_SESSION_ID, so NOTIFY_AGENT_TYPE=codex is
  # the ONLY thing that keeps these invocations from silently falling
  # through to the generic adapter.
  local commands bad_commands
  commands=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$CODEX_HOOKS")
  bad_commands=$(printf '%s\n' "$commands" | grep -v 'NOTIFY_AGENT_TYPE=codex' || true)
  [ -z "$bad_commands" ] || fail "every codex hook command must set NOTIFY_AGENT_TYPE=codex (found: $bad_commands)"

  local expected_keys actual_keys
  expected_keys=$(printf '%s\n' Interrupt PermissionRequest PostToolUse PreToolUse SessionEnd SessionStart Stop UserPromptSubmit | sort)
  actual_keys=$(jq -r '.hooks | keys[]' "$CODEX_HOOKS" | sort)
  [ "$expected_keys" = "$actual_keys" ] || \
    fail "codex hooks.json event coverage changed - expected [$expected_keys], got [$actual_keys]"

  local timeouts bad_timeouts
  timeouts=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .timeout' "$CODEX_HOOKS")
  bad_timeouts=$(printf '%s\n' "$timeouts" | awk '$1 < 1 || $1 > 3' || true)
  [ -z "$bad_timeouts" ] || fail "every codex hook timeout should stay within the documented 1-3s bound (found: $bad_timeouts)"

  # TODO.md ("Distinguish auto-approved Codex permission requests from real
  # waits", resolved 2026-09-03): PostToolUse must map to `event Working` -
  # it's what clears a WaitingForUser the instant an auto-approved tool
  # actually finishes, instead of leaving it rendered until some unrelated
  # later PreToolUse (observed lingering minutes in production). A silent
  # rewiring or removal here would reintroduce that regression with no
  # other test able to catch it, since test_framework.sh's lifecycle
  # scenario exercises the same `notify event` calls this hook fires but
  # never touches hooks.json itself.
  jq -e '.hooks.PostToolUse[0].hooks[0].command | test(" event Working$")' "$CODEX_HOOKS" >/dev/null || \
    fail "codex hooks.json PostToolUse must map to 'event Working' (see TODO.md's resolved auto-review flap entry)"

  pass "codex hooks.json: valid, always tags NOTIFY_AGENT_TYPE=codex, sane timeouts, matches TESTING.md's event table, PostToolUse resolves Working"
}

test_claude_plugin_manifest
test_codex_plugin_manifest
test_codex_hooks_manifest
printf '\nAll %s manifest scenarios passed.\n' "$pass_count"
