#!/bin/sh
# Install the claude remote-state hook on a remote box.
#
# Copies herdr-remote-state.sh to ~/.claude/hooks/ and registers it in
# ~/.claude/settings.json for the lifecycle events it handles. Idempotent;
# re-running updates the script in place. Pass --uninstall to remove both
# the hook registrations and the script.
#
# usage:
#   ./install.sh
#   ./install.sh --uninstall

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hook_src="$script_dir/herdr-remote-state.sh"
hooks_dir="${HOME}/.claude/hooks"
hook_dst="$hooks_dir/herdr-remote-state.sh"
settings="${HOME}/.claude/settings.json"

command -v python3 >/dev/null 2>&1 || {
    echo "install.sh: python3 is required" >&2
    exit 1
}

mode="install"
[ "${1:-}" = "--uninstall" ] && mode="uninstall"

if [ "$mode" = "install" ]; then
    [ -f "$hook_src" ] || { echo "install.sh: $hook_src not found" >&2; exit 1; }
    mkdir -p "$hooks_dir"
    cp "$hook_src" "$hook_dst"
    chmod +x "$hook_dst"
fi

HOOK_PATH="$hook_dst" SETTINGS_PATH="$settings" MODE="$mode" python3 - <<'PY'
import json
import os

hook_path = os.environ["HOOK_PATH"]
settings_path = os.environ["SETTINGS_PATH"]
mode = os.environ["MODE"]

EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "Notification",
    "Stop",
    "SessionEnd",
]

settings = {}
if os.path.isfile(settings_path):
    with open(settings_path, encoding="utf-8") as handle:
        content = handle.read().strip()
    if content:
        settings = json.loads(content)

hooks = settings.setdefault("hooks", {})
changed = False

for event in EVENTS:
    entries = hooks.setdefault(event, [])
    if mode == "uninstall":
        for entry in entries:
            kept = [h for h in entry.get("hooks", []) if h.get("command") != hook_path]
            if len(kept) != len(entry.get("hooks", [])):
                entry["hooks"] = kept
                changed = True
        pruned = [e for e in entries if e.get("hooks")]
        if len(pruned) != len(entries):
            hooks[event] = pruned
            changed = True
        if not hooks[event]:
            del hooks[event]
            changed = True
        continue

    already = any(
        hook.get("command") == hook_path
        for entry in entries
        for hook in entry.get("hooks", [])
    )
    if already:
        continue
    entry = {"hooks": [{"type": "command", "command": hook_path, "timeout": 10}]}
    if event in ("SessionStart", "PreToolUse"):
        entry["matcher"] = "*"
    entries.append(entry)
    changed = True

if mode == "uninstall" and not settings.get("hooks"):
    settings.pop("hooks", None)

if changed or not os.path.isfile(settings_path):
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")
    print(f"{'updated' if changed else 'wrote'} {settings_path}")
else:
    print(f"{settings_path} already up to date")
PY

if [ "$mode" = "uninstall" ]; then
    rm -f "$hook_dst"
    echo "removed $hook_dst"
else
    echo "installed $hook_dst"
fi
