#!/bin/bash
# Install the agent-neutral notify runtime, then enable integrations available
# on this machine. Idempotent and self-migrating from the v4 Claude-only layout.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PROJECT_DIR/release"
RUNTIME_ROOT="${NOTIFY_RUNTIME_DIR:-$HOME/opt/notify}"
DEST="$RUNTIME_ROOT/app"
CONFIG_DIR="$RUNTIME_ROOT/config"
BIN_LINK="$HOME/.local/bin/notify"

MARKETPLACE_ROOT="$HOME/.claude-templates-dev/components"
PLUGIN_LINK="$MARKETPLACE_ROOT/plugins/notify"
INSTALL_CLAUDE="${NOTIFY_INSTALL_CLAUDE:-auto}"
CODEX_MARKETPLACE_ROOT="$RUNTIME_ROOT/codex-marketplace"
CODEX_PLUGIN_LINK="$CODEX_MARKETPLACE_ROOT/plugins/notify"
INSTALL_CODEX="${NOTIFY_INSTALL_CODEX:-auto}"

stage_dir=""
cleanup() {
  [ -n "$stage_dir" ] && [ -d "$stage_dir" ] && rm -rf "$stage_dir"
}
trap cleanup EXIT

migrate_global_settings() {
  local old_root="$1"
  [ -d "$old_root/renderers.d" ] || return 0

  local old_file renderer default_file target
  for old_file in "$old_root"/renderers.d/*/settings.json; do
    [ -f "$old_file" ] || continue
    renderer="$(basename "$(dirname "$old_file")")"
    default_file="$SRC/renderers.d/$renderer/settings.json"
    target="$CONFIG_DIR/renderers.d/$renderer/settings.json"
    [ -f "$default_file" ] || continue
    [ -f "$target" ] && continue

    if ! cmp -s "$old_file" "$default_file"; then
      mkdir -p "$(dirname "$target")"
      cp "$old_file" "$target"
      echo "    migrated global settings: $renderer"
    fi
  done
}

replace_with_symlink() {
  local link_path="$1" target="$2"
  if [ -L "$link_path" ] && [ "$(readlink -f "$link_path" 2>/dev/null)" = "$(readlink -f "$target")" ]; then
    return 0
  fi

  local backup="${link_path}.pre-opt-migration"
  if [ -e "$link_path" ] || [ -L "$link_path" ]; then
    rm -rf "$backup"
    mv "$link_path" "$backup"
  fi
  if ln -s "$target" "$link_path"; then
    rm -rf "$backup"
  else
    [ -e "$backup" ] && mv "$backup" "$link_path"
    return 1
  fi
}

echo "==> Migrating persistent renderer settings"
mkdir -p "$CONFIG_DIR"
migrate_global_settings "$PLUGIN_LINK"
migrate_global_settings "$DEST"

echo "==> Deploying release/ to $DEST"
mkdir -p "$RUNTIME_ROOT"
stage_dir="$(mktemp -d "$RUNTIME_ROOT/.app-stage.XXXXXX")"
cp -R "$SRC"/. "$stage_dir"/
chmod +x "$stage_dir/notify"
chmod +x "$stage_dir/codex/notify"
for renderer_main in "$stage_dir"/renderers.d/*/main; do
  [ "$(basename "$(dirname "$renderer_main")")" = "template" ] && continue
  chmod +x "$renderer_main"
done
for renderer_install in "$stage_dir"/renderers.d/*/install.sh; do
  [ -f "$renderer_install" ] && chmod +x "$renderer_install"
done

previous_dir="$RUNTIME_ROOT/.app-previous"
rm -rf "$previous_dir"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  mv "$DEST" "$previous_dir"
fi
if mv "$stage_dir" "$DEST"; then
  stage_dir=""
  rm -rf "$previous_dir"
else
  [ -e "$previous_dir" ] && mv "$previous_dir" "$DEST"
  exit 1
fi

echo "==> Linking $BIN_LINK"
mkdir -p "$(dirname "$BIN_LINK")"
replace_with_symlink "$BIN_LINK" "$DEST/notify"

echo "==> Running platform-appropriate renderer installers"
for renderer_install in "$DEST"/renderers.d/*/install.sh; do
  [ -x "$renderer_install" ] || continue
  echo "    -> $(basename "$(dirname "$renderer_install")")/install.sh"
  "$renderer_install"
done

install_claude=false
case "$INSTALL_CLAUDE" in
  true) install_claude=true ;;
  false) ;;
  auto) command -v claude >/dev/null 2>&1 && install_claude=true ;;
  *) echo "NOTIFY_INSTALL_CLAUDE must be auto, true, or false." >&2; exit 1 ;;
esac

if $install_claude; then
  command -v claude >/dev/null 2>&1 || {
    echo "NOTIFY_INSTALL_CLAUDE=true, but claude is not installed." >&2
    exit 1
  }

  echo "==> Linking the Claude Code plugin"
  mkdir -p "$(dirname "$PLUGIN_LINK")"
  replace_with_symlink "$PLUGIN_LINK" "$DEST"

  echo "==> Updating the shared Claude marketplace manifest"
  manifest="$MARKETPLACE_ROOT/.claude-plugin/marketplace.json"
  mkdir -p "$(dirname "$manifest")"
  [ -f "$manifest" ] || printf '%s\n' '{}' > "$manifest"
  manifest_tmp="$(mktemp "${manifest}.tmp.XXXXXX")"
  jq '
    .name = (.name // "claude-templates-dev")
    | .owner = (.owner // {"name": "Jean Lescut-Muller"})
    | .plugins = (
        (.plugins // [] | map(select(.name != "notify")))
        + [{
            "name": "notify",
            "source": "./plugins/notify",
            "description": "Agent-neutral session notifications with a Claude Code integration. Configure with: ! notify"
          }]
      )
  ' "$manifest" > "$manifest_tmp"
  mv "$manifest_tmp" "$manifest"

  echo "==> Registering and enabling the Claude integration"
  if ! claude plugin marketplace list 2>/dev/null | grep -q "claude-templates-dev"; then
    claude plugin marketplace add "$MARKETPLACE_ROOT"
  fi
  if ! claude plugin list 2>/dev/null | grep -q "notify@claude-templates-dev"; then
    claude plugin install notify@claude-templates-dev --scope user
  fi
else
  echo "==> Claude integration skipped (NOTIFY_INSTALL_CLAUDE=$INSTALL_CLAUDE)"
fi

install_codex=false
case "$INSTALL_CODEX" in
  true) install_codex=true ;;
  false) ;;
  auto) command -v codex >/dev/null 2>&1 && install_codex=true ;;
  *) echo "NOTIFY_INSTALL_CODEX must be auto, true, or false." >&2; exit 1 ;;
esac

if $install_codex; then
  command -v codex >/dev/null 2>&1 || {
    echo "NOTIFY_INSTALL_CODEX=true, but codex is not installed." >&2
    exit 1
  }

  echo "==> Linking the Codex plugin"
  mkdir -p "$(dirname "$CODEX_PLUGIN_LINK")"
  replace_with_symlink "$CODEX_PLUGIN_LINK" "$DEST/codex"

  echo "==> Writing the local Codex marketplace manifest"
  mkdir -p "$CODEX_MARKETPLACE_ROOT/.agents/plugins"
  printf '%s\n' \
    '{' \
    '  "name": "notify-local",' \
    '  "interface": { "displayName": "Notify local" },' \
    '  "plugins": [' \
    '    {' \
    '      "name": "notify",' \
    '      "source": { "source": "local", "path": "./plugins/notify" },' \
    '      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },' \
    '      "category": "Productivity"' \
    '    }' \
    '  ]' \
    '}' > "$CODEX_MARKETPLACE_ROOT/.agents/plugins/marketplace.json"

  echo "==> Registering and enabling the Codex integration"
  if ! codex plugin marketplace list 2>/dev/null | grep -q "notify-local"; then
    codex plugin marketplace add "$CODEX_MARKETPLACE_ROOT"
  fi
  codex plugin add notify@notify-local
else
  echo "==> Codex integration skipped (NOTIFY_INSTALL_CODEX=$INSTALL_CODEX)"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARNING: add $HOME/.local/bin to PATH to use the notify CLI." >&2 ;;
esac

echo "==> Done: runtime=$DEST config=$CONFIG_DIR"
if $install_claude; then
  echo "    Restart active Claude Code sessions so they load the updated hooks."
fi
if $install_codex; then
  echo "    Start a new Codex session so it loads the notify hooks."
fi
