#!/bin/sh
# herdr-remote-state.sh — Claude Code hook that reports agent state to a
# herdr hub over a forwarded control socket.
#
# The managed claude integration (herdr:claude) only reports session ids;
# claude *state* normally comes from herdr's screen scanning of the local
# process tree. In a remote pane (herdrssh) the hub only sees an ssh
# process, so screen scanning never runs. This hook fills the gap: it maps
# Claude Code lifecycle events to pane.report_agent calls with the source
# "custom:claude-remote", which herdr arbitrates as hook authority.
#
# Inert unless HERDR_ENV/HERDR_SOCKET_PATH/HERDR_PANE_ID are present, so it
# is safe to keep installed globally; it only fires inside remote panes
# (or local herdr panes, where the duplicate report is harmless).
#
# Install with contrib/remote-pane/claude/install.sh — it registers this
# script for SessionStart, UserPromptSubmit, PreToolUse, Notification,
# Stop and SessionEnd in ~/.claude/settings.json.

set -eu

hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-claude-remote.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY'
import json
import os
import random
import socket
import time

source = "custom:claude-remote"
pane_id = os.environ.get("HERDR_PANE_ID")
socket_path = os.environ.get("HERDR_SOCKET_PATH")
hook_input_file = os.environ.get("HERDR_HOOK_INPUT_FILE")

if not pane_id or not socket_path:
    raise SystemExit(0)

hook_input = {}
if hook_input_file:
    try:
        with open(hook_input_file, encoding="utf-8") as handle:
            content = handle.read()
        if content.strip():
            hook_input = json.loads(content)
    except Exception:
        hook_input = {}

# Subagent events describe inner work, not the pane's top-level state.
if hook_input.get("agent_id"):
    raise SystemExit(0)

event = str(hook_input.get("hook_event_name") or "")

STATE_BY_EVENT = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "Notification": "blocked",
    "Stop": "idle",
    "SessionEnd": "idle",
}

state = STATE_BY_EVENT.get(event)
if state is None:
    raise SystemExit(0)

params = {
    "pane_id": pane_id,
    "source": source,
    "agent": "claude",
    "state": state,
    "seq": time.time_ns(),
}

if event == "Notification":
    message = hook_input.get("message")
    if isinstance(message, str) and message:
        params["message"] = message

session_id = hook_input.get("session_id")
if isinstance(session_id, str) and session_id:
    params["agent_session_id"] = session_id
    transcript_path = hook_input.get("transcript_path")
    if isinstance(transcript_path, str) and transcript_path:
        params["agent_session_path"] = transcript_path

request = {
    "id": f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}",
    "method": "pane.report_agent",
    "params": params,
}

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(socket_path)
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        client.recv(4096)
    except Exception:
        pass
    client.close()
except Exception:
    pass
PY
