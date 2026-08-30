#!/bin/bash
# End-to-end install.sh scenarios (tests/AGENTS.md scenarios 12-13): fresh
# install, idempotent reinstall, config preserved across reinstall, a clean
# app/ replacement, old-plugin-dir migration, and Claude/Codex plugin
# registration against fake claude/codex binaries. Every case runs under its
# own throwaway $HOME via NOTIFY_INSTALL_CLAUDE/CODEX so the real machine's
# ~/opt, ~/.local/bin, and ~/.claude-templates-dev are never touched.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

test_install_idempotency() {
  local home="$TEST_ROOT/idem-home"
  mkdir -p "$home"
  run() { HOME="$home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false "$PROJECT_DIR/install.sh" >"$TEST_ROOT/idem-install.log" 2>&1; }

  run
  [ -L "$home/.local/bin/notify" ] || fail "install creates the notify symlink"
  [ -x "$home/opt/agent-notify/app/notify" ] || fail "install deploys an executable app/notify"
  [ ! -x "$home/opt/agent-notify/app/renderers.d/template/main" ] || \
    fail "the template renderer must stay non-executable after install"

  local symlink_target_before
  symlink_target_before="$(readlink -f "$home/.local/bin/notify")"

  # A hand-edited global setting must survive every future reinstall.
  mkdir -p "$home/opt/agent-notify/config/renderers.d/sound-bell"
  printf '{"Finished":9}' > "$home/opt/agent-notify/config/renderers.d/sound-bell/settings.json"

  # A stray leftover from a previously-removed component must not survive a
  # clean app/ replacement.
  touch "$home/opt/agent-notify/app/OLD_REMOVED_FILE"

  run
  [ "$(readlink -f "$home/.local/bin/notify")" = "$symlink_target_before" ] || \
    fail "a second install is idempotent about the symlink target"
  [ "$(cat "$home/opt/agent-notify/config/renderers.d/sound-bell/settings.json")" = '{"Finished":9}' ] || \
    fail "config/ must never be replaced by a plain reinstall"
  [ ! -e "$home/opt/agent-notify/app/OLD_REMOVED_FILE" ] || \
    fail "app/ replacement must be clean: a stray leftover file must not survive reinstall"
  pass "install: fresh install, idempotent reinstall, config preserved, app/ replaced cleanly"
}

test_install_migration() {
  local home="$TEST_ROOT/migrate-home"
  local plugin_dir="$home/.claude-templates-dev/components/plugins/notify"
  mkdir -p "$plugin_dir/renderers.d/sound-tts" "$plugin_dir/renderers.d/sound-bell"

  # sound-tts: an old settings file that DIFFERS from the shipped default -
  # must be migrated into config/.
  printf '{"Finished":0.3,"WaitingForUser":1.0,"name":"custom"}' \
    > "$plugin_dir/renderers.d/sound-tts/settings.json"
  # sound-bell: an old settings file byte-IDENTICAL to the shipped default -
  # must NOT be migrated (nothing to preserve).
  cp "$PROJECT_DIR/release/renderers.d/sound-bell/settings.json" \
    "$plugin_dir/renderers.d/sound-bell/settings.json"

  HOME="$home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false \
    "$PROJECT_DIR/install.sh" >"$TEST_ROOT/migrate-install.log" 2>&1

  local migrated="$home/opt/agent-notify/config/renderers.d/sound-tts/settings.json"
  [ -f "$migrated" ] || fail "a differing old settings file is migrated into config/"
  [ "$(cat "$migrated")" = '{"Finished":0.3,"WaitingForUser":1.0,"name":"custom"}' ] || \
    fail "the migrated content matches the old plugin's settings exactly"
  grep -qF "migrated global settings: sound-tts" "$TEST_ROOT/migrate-install.log" || \
    fail "the migration is logged"
  [ ! -e "$home/opt/agent-notify/config/renderers.d/sound-bell/settings.json" ] || \
    fail "an old settings file identical to the shipped default is not migrated"

  # A second install must not re-migrate or duplicate the log line, and must
  # not clobber the now-customized config even if the "old" source changes.
  printf '{"Finished":0.9}' > "$plugin_dir/renderers.d/sound-tts/settings.json"
  HOME="$home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false \
    "$PROJECT_DIR/install.sh" >"$TEST_ROOT/migrate-install-2.log" 2>&1
  [ "$(cat "$migrated")" = '{"Finished":0.3,"WaitingForUser":1.0,"name":"custom"}' ] || \
    fail "an already-migrated config file is never overwritten by a later install"
  assert_log_not_contains "$TEST_ROOT/migrate-install-2.log" "migrated global settings: sound-tts" \
    "a settings file that's already present under config/ is not re-migrated"
  pass "install: old plugin-dir settings are migrated once, never re-migrated or clobbered"
}

# Fake claude/codex binaries: exercise install.sh's actual registration
# commands and manifest writes without touching a real Claude/Codex install.
# Each records every invocation to a log file and tracks minimal state (has
# the marketplace been added? has the plugin been installed?) so repeated
# `list` calls behave like the real CLIs would across two installs.
make_fake_claude() {
  local bin_dir="$1" log="$2" state="$3"
  mkdir -p "$bin_dir" "$state"
  cat > "$bin_dir/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
case "\$1" in
  plugin)
    case "\$2" in
      marketplace)
        case "\$3" in
          list) [ -f "$state/marketplace_added" ] && echo "claude-templates-dev (local)"; exit 0 ;;
          add) touch "$state/marketplace_added"; exit 0 ;;
        esac ;;
      list) [ -f "$state/plugin_installed" ] && echo "notify@claude-templates-dev"; exit 0 ;;
      install) touch "$state/plugin_installed"; exit 0 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$bin_dir/claude"
}

make_fake_codex() {
  local bin_dir="$1" log="$2" state="$3"
  mkdir -p "$bin_dir" "$state"
  cat > "$bin_dir/codex" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
case "\$1" in
  plugin)
    case "\$2" in
      marketplace)
        case "\$3" in
          list) [ -f "$state/marketplace_added" ] && echo "notify-local"; exit 0 ;;
          add) touch "$state/marketplace_added"; exit 0 ;;
        esac ;;
      add) touch "$state/plugin_added"; exit 0 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$bin_dir/codex"
}

test_plugin_registration() {
  local home="$TEST_ROOT/plugin-home" bin="$TEST_ROOT/plugin-bin"
  local claude_log="$TEST_ROOT/claude.log" claude_state="$TEST_ROOT/claude-state"
  local codex_log="$TEST_ROOT/codex.log" codex_state="$TEST_ROOT/codex-state"
  mkdir -p "$home"
  : > "$claude_log"
  : > "$codex_log"
  make_fake_claude "$bin" "$claude_log" "$claude_state"
  make_fake_codex "$bin" "$codex_log" "$codex_state"

  run() {
    HOME="$home" PATH="$bin:$PATH" NOTIFY_INSTALL_CLAUDE=true NOTIFY_INSTALL_CODEX=true \
      "$PROJECT_DIR/install.sh" >"$TEST_ROOT/plugin-install.log" 2>&1
  }

  run
  local manifest="$home/.claude-templates-dev/components/.claude-plugin/marketplace.json"
  [ "$(jq '[.plugins[] | select(.name=="notify")] | length' "$manifest")" = "1" ] || \
    fail "the claude marketplace manifest has exactly one notify entry after the first install"
  [ "$(count_log_occurrences "$claude_log" "plugin marketplace add")" = "1" ] || \
    fail "claude plugin marketplace add is called exactly once"
  [ "$(count_log_occurrences "$claude_log" "plugin install notify@claude-templates-dev")" = "1" ] || \
    fail "claude plugin install is called exactly once"

  local codex_manifest="$home/opt/agent-notify/codex-marketplace/.agents/plugins/marketplace.json"
  jq empty "$codex_manifest" || fail "the codex marketplace manifest is valid JSON"
  [ "$(jq '[.plugins[] | select(.name=="notify")] | length' "$codex_manifest")" = "1" ] || \
    fail "the codex marketplace manifest has exactly one notify entry"
  [ "$(count_log_occurrences "$codex_log" "plugin marketplace add")" = "1" ] || \
    fail "codex plugin marketplace add is called exactly once"
  [ "$(count_log_occurrences "$codex_log" "plugin add notify@notify-local")" = "1" ] || \
    fail "codex plugin add is called exactly once after the first install"

  # Second install: claude's own registration is idempotent (it consults
  # `list` first), so neither call repeats.
  run
  [ "$(jq '[.plugins[] | select(.name=="notify")] | length' "$manifest")" = "1" ] || \
    fail "a second install never duplicates the notify marketplace entry"
  [ "$(count_log_occurrences "$claude_log" "plugin marketplace add")" = "1" ] || \
    fail "claude plugin marketplace add is not repeated once already registered"
  [ "$(count_log_occurrences "$claude_log" "plugin install notify@claude-templates-dev")" = "1" ] || \
    fail "claude plugin install is not repeated once already installed"

  # install.sh's Codex branch has no equivalent `list`-based guard - it calls
  # `codex plugin add` unconditionally on every install. This is a real
  # asymmetry with the Claude branch, not a test bug: lock it down as today's
  # actual behavior.
  [ "$(count_log_occurrences "$codex_log" "plugin add notify@notify-local")" = "2" ] || \
    fail "codex plugin add is invoked again on every install, unlike claude's guarded path"
  pass "install: claude/codex plugin registration is idempotent for claude, unguarded for codex"
}

test_install_idempotency
test_install_migration
test_plugin_registration
printf '\nAll %s install scenarios passed.\n' "$pass_count"
