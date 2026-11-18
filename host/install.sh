#!/usr/bin/env bash
# Agent Lights, Linux side (the machine your agents run on): hooks for whichever of Claude Code, Codex,
# Cursor CLI, Grok CLI and Hermes Agent you have, plus the status server the pill polls.
# Safe to re-run. Every config it edits is backed up first as <file>.bak-agent-lights-<time>.
#
#   bash host/install.sh                                # the usual
#   AGENT_LIGHTS_BIND=127.0.0.1 bash host/install.sh    # pill on this same PC (WSL) or over an ssh tunnel only
#   AGENT_LIGHTS_PORT=8790 bash host/install.sh         # another port
#   ALERT_CMD='notify-send "agent-lights died"' bash host/install.sh   # runs if the server ever fails
#   NO_SERVICE=1 bash host/install.sh                   # hooks only; start host/status_server.py yourself
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="python3 $REPO/host/status_hook.py"
STAMP="$(date +%Y%m%d-%H%M%S)"
PORT="${AGENT_LIGHTS_PORT:-8777}"
BIND="${AGENT_LIGHTS_BIND:-0.0.0.0}"
TOKEN_FILE="${AGENT_LIGHTS_TOKEN_FILE:-$HOME/.config/agent-lights/token}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
case "$REPO" in *" "*) echo "Move the repo to a folder without spaces in its path first."; exit 1 ;; esac

# merge our hook into an agent's JSON hooks file; your other hooks stay, an older checkout's copy is replaced
#   merge_hooks <file> <format claude|cursor> <agent> <Event[:matcher]>...
merge_hooks() {
  local file="$1" fmt="$2" agent="$3"; shift 3
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || echo '{}' > "$file"
  cp -a "$file" "$file.bak-agent-lights-$STAMP"
  python3 - "$file" "$fmt" "$HOOK --agent $agent 2>/dev/null || true" "/host/status_hook.py --agent $agent" "$@" <<'PY'
import json, sys
path, fmt, cmd, marker, events = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
with open(path) as f:
    d = json.load(f)
if fmt == "cursor":
    d.setdefault("version", 1)
hooks = d.setdefault("hooks", {})
added = []
def ours(h):
    return marker in h.get("command", "")
for spec in events:
    ev, _, matcher = spec.partition(":")
    groups = hooks.setdefault(ev, [])
    if fmt == "cursor":           # [{"command": ...}]
        groups[:] = [h for h in groups if not (ours(h) and h.get("command") != cmd)]
        if not any(h.get("command") == cmd for h in groups):
            groups.append({"command": cmd, "timeout": 3})
            added.append(ev)
        continue
    for g in groups:              # [{"matcher"?: ..., "hooks": [{"type": "command", "command": ...}]}]
        g["hooks"] = [h for h in g.get("hooks", []) if not (ours(h) and h.get("command") != cmd)]
    groups[:] = [g for g in groups if g.get("hooks")]
    if any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
        continue
    g = {"hooks": [{"type": "command", "command": cmd, "timeout": 3}]}
    if matcher:
        g = {"matcher": matcher, **g}
    groups.append(g)
    added.append(ev)
with open(path, "w") as f:
    json.dump(d, f, indent=2)
print(", ".join(added) or "already in place")
PY
}
agents=()
echo "Agent Lights: hooking the agents on this machine"

# Claude Code: hooks merged into ~/.claude/settings.json
if [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; then
  agents+=(claude)
  r="$(merge_hooks "$HOME/.claude/settings.json" claude claude \
        SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SessionEnd)"
  echo "  Claude Code   hooks in ~/.claude/settings.json: $r"
fi

# Codex CLI: ~/.codex/hooks.json (Codex asks you to trust new hooks once, at its next start)
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
if command -v codex >/dev/null 2>&1 || [ -d "$CODEX_DIR" ]; then
  agents+=(codex)
  cev=(SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop)
  # Interrupt (Esc) exists from Codex 0.150; older versions may refuse unknown event names. No SessionEnd:
  # Codex's shared daemon fires it when it unloads a conversation (even right after you resume it); a
  # closed window is caught by its process exiting instead.
  cver="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
  if [ -n "$cver" ] && { [ "${cver%%.*}" -ge 1 ] || [ "${cver#*.}" -ge 150 ]; } 2>/dev/null; then
    cev+=(Interrupt)
  fi
  r="$(merge_hooks "$CODEX_DIR/hooks.json" claude codex "${cev[@]}")"
  echo "  Codex         hooks in ${CODEX_DIR/#$HOME/\~}/hooks.json: $r"
  [ "$r" = "already in place" ] || codex_trust=1
fi

# Cursor CLI (cursor-agent): ~/.cursor/hooks.json. It has no hook for its approval prompt, so no red.
if command -v cursor-agent >/dev/null 2>&1; then
  agents+=(cursor)
  r="$(merge_hooks "$HOME/.cursor/hooks.json" cursor cursor \
        sessionStart beforeSubmitPrompt preToolUse postToolUse postToolUseFailure stop sessionEnd)"
  echo "  Cursor CLI    hooks in ~/.cursor/hooks.json: $r"
fi

# Grok CLI: its own hooks file (Grok also replays Claude's hooks; the hook ignores that copy)
if [ -d "$HOME/.grok" ] || command -v grok >/dev/null 2>&1; then
  agents+=(grok)
  mkdir -p "$HOME/.grok/hooks"
  sed "s#__REPO__#$REPO#g" "$REPO/grok/agent-lights.json" > "$HOME/.grok/hooks/agent-lights.json"
  echo "  Grok CLI      hooks in ~/.grok/hooks/agent-lights.json"
fi

# Hermes Agent: plugin linked into the active profile and enabled
if command -v hermes >/dev/null 2>&1; then
  agents+=(hermes)
  HP=()
  if [ -n "${HERMES_HOME:-}" ]; then
    HH="$HERMES_HOME"
  else
    prof="$(cat "$HOME/.hermes/active_profile" 2>/dev/null || true)"
    if [ -n "$prof" ] && [ "$prof" != default ] && [ -d "$HOME/.hermes/profiles/$prof" ]; then
      HH="$HOME/.hermes/profiles/$prof"; HP=(-p "$prof")
    else
      HH="$HOME/.hermes"
    fi
  fi
  mkdir -p "$HH/plugins"
  [ -f "$HH/config.yaml" ] && cp -a "$HH/config.yaml" "$HH/config.yaml.bak-agent-lights-$STAMP"
  ln -sfn "$REPO/hermes/agent-lights" "$HH/plugins/agent-lights"
  if hermes "${HP[@]}" plugins enable --no-allow-tool-override agent-lights >/dev/null 2>&1 \
     || hermes "${HP[@]}" plugins enable agent-lights >/dev/null 2>&1; then
    echo "  Hermes Agent  plugin linked + enabled in $HH (a running Hermes gateway picks it up after a restart)"
  else
    echo "  Hermes Agent  plugin linked in $HH; enable it with:  hermes ${HP[*]} plugins enable agent-lights"
  fi
fi
if [ ${#agents[@]} -eq 0 ]; then
  echo "  No Claude Code, Codex, Cursor CLI, Grok CLI or Hermes found. Install one and run this again,"
  echo "  or wire any other agent by hand (README: Any other agent)."
fi

# which agents get a slot on the pill (~/.config/agent-lights/config.json; your tags and other settings stay)
CONFIG="${AGENT_LIGHTS_CONFIG:-$HOME/.config/agent-lights/config.json}"
mkdir -p "$(dirname "$CONFIG")"
python3 - "$CONFIG" "${agents[@]}" <<'PY'
import json, sys
path, found = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
have = [a for a in cfg.get("agents", []) if isinstance(a, str)]
cfg["agents"] = have + [a for a in found if a not in have]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("  pill shows    " + (", ".join(cfg["agents"]) or "nothing yet") + f"  ({path})")
PY

# the pill's Open / Reopen runs this over ssh: a fixed path that works in a non-login ssh command
mkdir -p "$HOME/.local/bin"
ln -sfn "$REPO/host/agent-lights-open" "$HOME/.local/bin/agent-lights-open"

# status server
if [ -n "${NO_SERVICE:-}" ]; then
  echo "  NO_SERVICE set: start it yourself:  python3 $REPO/host/status_server.py"
elif ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "  No systemd user session here (WSL without systemd?). Start the server yourself, e.g.:"
  echo "      nohup python3 $REPO/host/status_server.py >/dev/null 2>&1 &"
else
  mkdir -p "$UNIT_DIR"
  onfail=""
  if [ -n "${ALERT_CMD:-}" ]; then
    onfail="OnFailure=agent-lights-fail.service"
    cat > "$UNIT_DIR/agent-lights-fail.service" <<EOF
[Unit]
Description=Agent Lights status server failed

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$ALERT_CMD'
EOF
  fi
  cat > "$UNIT_DIR/agent-lights.service" <<EOF
[Unit]
Description=Agent Lights status server (:$PORT)
After=network-online.target
$onfail
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Environment=AGENT_LIGHTS_PORT=$PORT AGENT_LIGHTS_BIND=$BIND AGENT_LIGHTS_TOKEN_FILE=$TOKEN_FILE
ExecStart=/usr/bin/env python3 $REPO/host/status_server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable agent-lights.service >/dev/null 2>&1
  systemctl --user restart agent-lights.service
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "  status server running on $BIND:$PORT (agent-lights.service; logs: journalctl --user -u agent-lights)"
  else
    echo "  status server did not answer; see: journalctl --user -u agent-lights -n 30"
    exit 1
  fi
  if [ "$BIND" = 0.0.0.0 ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "      ufw is on: allow the pill in, e.g.  sudo ufw allow from 192.168.0.0/16 to any port $PORT proto tcp"
    echo "      (Tailscale traffic usually bypasses ufw)"
  fi
fi

# what to paste on the Windows PC
for _ in 1 2 3 4 5 6; do [ -s "$TOKEN_FILE" ] && break; sleep 0.5; done
TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || echo '<start the server once: it writes ~/.config/agent-lights/token>')"
addrs=()
if command -v tailscale >/dev/null 2>&1; then
  ts="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$ts" ] && addrs+=("$ts")
fi
lan="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1 || true)"
[ -n "$lan" ] && addrs+=("$lan")
[ "$BIND" = 127.0.0.1 ] && addrs=(localhost)
[ ${#addrs[@]} -gt 0 ] || addrs=("<this machine's address>")
server="$(IFS=,; echo "${addrs[*]/%/:$PORT}")"
ssh_host="$USER@${addrs[0]}"
[ "$BIND" = 127.0.0.1 ] && ssh_host="$USER@localhost"
echo
echo "Done. Each agent lights up from its next session (Hermes: the next time you start it)."
if [ -n "${codex_trust:-}" ]; then
  echo "Codex: the next time you start it, it asks you to review the new hooks. Pick \"Trust all and continue\""
  echo "       (they only write the light state). Until you do, Codex sessions get no dot."
fi
echo
echo "On the Windows PC, in this repo's folder, run in PowerShell (one line):"
echo
echo "  powershell -ExecutionPolicy Bypass -File .\\windows\\install.ps1 -Server \"$server\" -Token $TOKEN -SshHost $ssh_host"
echo
echo "-SshHost is what you'd type after 'ssh' to reach this machine (an ~/.ssh/config name works too)."
echo "Keep the token private: it lets the pill list and close your agent sessions."
