#!/usr/bin/env bash
# Agent Lights, Linux side (the machine your agents run on): hooks for whichever of Claude Code,
# Grok CLI and Hermes Agent you have, plus the status server the pill polls.
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
found=0

# 1) Claude Code: hooks merged into ~/.claude/settings.json (your other hooks are left alone)
if [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; then
  found=1
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp -a "$SETTINGS" "$SETTINGS.bak-agent-lights-$STAMP"
  python3 - "$SETTINGS" "$HOOK --agent claude" <<'PY'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
added = []
for ev in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]:
    groups = hooks.setdefault(ev, [])
    # drop an agent-lights entry from an older checkout path so it isn't doubled
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", [])
                      if not ("/host/status_hook.py --agent claude" in h.get("command", "") and h.get("command") != cmd)]
    hooks[ev] = groups = [g for g in groups if g.get("hooks")]
    if any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
        continue
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 3}]})
    added.append(ev)
with open(path, "w") as f:
    json.dump(d, f, indent=2)
print("[1/4] Claude Code hooks:", ", ".join(added) or "already in place")
PY
else
  echo "[1/4] Claude Code: not found, skipped"
fi

# 2) Grok CLI: its own hooks file (Grok also replays Claude's hooks; the hook ignores that copy)
if [ -d "$HOME/.grok" ] || command -v grok >/dev/null 2>&1; then
  found=1
  mkdir -p "$HOME/.grok/hooks"
  sed "s#__REPO__#$REPO#g" "$REPO/grok/agent-lights.json" > "$HOME/.grok/hooks/agent-lights.json"
  echo "[2/4] Grok hooks: ~/.grok/hooks/agent-lights.json"
else
  echo "[2/4] Grok CLI: not found, skipped"
fi

# 3) Hermes Agent: plugin linked into the active profile and enabled
if command -v hermes >/dev/null 2>&1; then
  found=1
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
    echo "[3/4] Hermes plugin linked + enabled in $HH (a running Hermes gateway picks it up after a restart)"
  else
    echo "[3/4] Hermes plugin linked in $HH; enable it with:  hermes ${HP[*]} plugins enable agent-lights"
  fi
else
  echo "[3/4] Hermes Agent: not found, skipped"
fi
[ "$found" = 1 ] || echo "      No Claude Code, Grok CLI or Hermes found. Install one, then run this again."

# the pill's Open / Reopen runs this over ssh: a fixed path that works in a non-login ssh command
mkdir -p "$HOME/.local/bin"
ln -sfn "$REPO/host/agent-lights-open" "$HOME/.local/bin/agent-lights-open"

# 4) status server
if [ -n "${NO_SERVICE:-}" ]; then
  echo "[4/4] NO_SERVICE set: start it yourself:  python3 $REPO/host/status_server.py"
elif ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "[4/4] no systemd user session here (WSL without systemd?). Start the server yourself, e.g.:"
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
    echo "[4/4] status server running on $BIND:$PORT (agent-lights.service; logs: journalctl --user -u agent-lights)"
  else
    echo "[4/4] status server did not answer; see: journalctl --user -u agent-lights -n 30"
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
echo "Done. Claude Code and Grok light up from their next session; Hermes the next time you start it."
echo
echo "On the Windows PC, in this repo's folder, run in PowerShell (one line):"
echo
echo "  powershell -ExecutionPolicy Bypass -File .\\windows\\install.ps1 -Server $server -Token $TOKEN -SshHost $ssh_host"
echo
echo "-SshHost is what you'd type after 'ssh' to reach this machine (an ~/.ssh/config name works too)."
echo "Keep the token private: it lets the pill list and close your agent sessions."
