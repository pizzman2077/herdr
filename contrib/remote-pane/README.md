# Remote panes

Run coding agents on *other* machines inside herdr panes on a hub, with real
agent identity and state — instead of an anonymous `ssh` pane.

## The problem

Herdr identifies a pane's agent by walking the pane's **local** process tree
(`src/detect/mod.rs`, `identify_agent_in_job`). In a pane that ssh-es to
another box, the only local process is `ssh`, so the agent is `None` — and
screen-content detection never runs without a process-detected agent
(`detect_agent_with_osc` short-circuits to `Unknown`). Result: a remote
`claude` looks like a plain shell.

## The mechanism

Herdr already has everything needed to fix this from the outside:

- every pane gets `HERDR_PANE_ID`, `HERDR_ENV=1` and `HERDR_SOCKET_PATH` in
  its environment;
- the JSON socket API accepts `pane.report_agent` (agent label + state +
  message) from any process that can reach the socket, arbitrated as hook
  authority — and a hook report is only rejected when it conflicts with a
  *process-detected* agent, which a remote pane doesn't have.

So: forward the pane's control socket to the remote box over ssh
(unix socket → unix socket, native OpenSSH), re-export the pane identity
there, and let the remote agent's hooks phone home.

```
hub (herdr server)                      remote box
┌──────────────────────┐                ┌─────────────────────────┐
│ pane: herdrssh ─┼── ssh -t -R ──┼→ claude / opencode / …  │
│   $HERDR_SOCKET_PATH ←┼── forwarded ──┼─ agent hooks report     │
│                      │    unix sock   │  pane.report_agent      │
└──────────────────────┘                └─────────────────────────┘
```

## Setup

### Hub (the box running the herdr server)

Copy `herdrssh` somewhere on `PATH` and make it executable:

```sh
install -m 0755 contrib/remote-pane/herdrssh ~/.local/bin/
```

### Remote boxes

For **claude**, install the remote state hook (this directory's `claude/`):

```sh
./claude/install.sh          # registers hooks in ~/.claude/settings.json
./claude/install.sh --uninstall
```

For **opencode** (and pi / omp / hermes / kilo / kimi), the stock herdr
integration already reports the full lifecycle over the socket and reads
`HERDR_SOCKET_PATH` from the environment at hook time. Install the herdr
binary on the remote box and run its integration installer once — no server
needs to run there:

```sh
curl -fsSL https://herdr.dev/install.sh | sh
herdr integration install opencode
```

### Use it

Inside a herdr pane on the hub:

```sh
herdrssh workbox claude          # remote claude, shows state in herdr
herdrssh workbox opencode
herdrssh workbox                 # plain login shell, launch things by hand
HERDR_SSH_OPTS="-J bastion" herdrssh gpu-box claude
```

## Agent support matrix

| agent | remote state | how |
|---|---|---|
| opencode, pi, omp, hermes, kilo, kimi | full | stock integration reports lifecycle over the forwarded socket |
| claude | full | `claude/herdr-remote-state.sh` (this directory) — maps `UserPromptSubmit`/`PreToolUse` → working, `Notification` → blocked, `Stop`/`SessionStart`/`SessionEnd` → idle, source `custom:claude-remote` |
| codex, droid, devin, copilot, cursor, qodercli | session only | stock hooks report session ids, not state; a state hook set like claude's could be added the same way |
| amp and anything else | terminal only | works as a plain remote terminal; no herdr hook assets exist |

Claude's *managed* integration (`herdr:claude`) is session-only by upstream
design — state normally comes from screen scanning, which cannot see through
ssh. The custom hook here uses a distinct script and source so it never
collides with the managed integration; both can be installed side by side.

## Notes and caveats

- **sshd requirements:** streamlocal ("unix socket") remote forwarding must be
  allowed (`AllowStreamLocalForwarding yes`, the OpenSSH default). Socket
  names are unique per connection, so `StreamLocalBindUnlink` is not needed;
  the remote-side trap removes the socket on clean exit, and a leftover
  `/tmp/herdr-remote-*.sock` from a hard disconnect is inert.
- **Trust boundary:** the forwarded socket exposes the hub's full herdr API
  to your user on the remote box (send keys to any pane, read any pane, spawn
  panes). Only forward into machines you fully control.
- **The pane still runs ssh:** herdr's process-based niceties that need a
  local agent process (cwd tracking, process info) don't apply; identity and
  state come entirely from the hook reports.
- **Local double-fire is harmless:** if a remote box also runs its own herdr
  locally, the claude hook will report into whichever herdr owns the pane's
  env. Labels agree with detection, so nothing conflicts.
- **Windows hub:** a native Windows herdr server exposes a named pipe, which
  OpenSSH cannot forward — run the hub on Linux (or inside WSL, where this
  works unchanged).
