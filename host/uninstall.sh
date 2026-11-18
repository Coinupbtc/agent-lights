#!/usr/bin/env bash
# Removes everything host/install.sh added. Your other hooks and settings stay. Backs up settings.json first.
# Keeps ~/.config/agent-lights/token (delete it yourself if you're done for good).
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user disable --now agent-lights.service >/dev/null 2>&1 || true
fi
rm -f "$UNIT_DIR/agent-lights.service" "$UNIT_DIR/agent-lights-fail.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
echo "status server: stopped and removed"

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  cp -a "$SETTINGS" "$SETTINGS.bak-agent-lights-$STAMP"
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
n = 0
for ev, groups in list(d.get("hooks", {}).items()):
    for g in groups:
        keep = [h for h in g.get("hooks", []) if "/host/status_hook.py --agent claude" not in h.get("command", "")]
        n += len(g.get("hooks", [])) - len(keep)
        g["hooks"] = keep
    d["hooks"][ev] = [g for g in groups if g.get("hooks")]
    if not d["hooks"][ev]:
        del d["hooks"][ev]
with open(path, "w") as f:
    json.dump(d, f, indent=2)
print(f"Claude Code: removed {n} hook entries")
PY
fi

rm -f "$HOME/.grok/hooks/agent-lights.json" && echo "Grok: hooks file removed"

if command -v hermes >/dev/null 2>&1; then
  for d in "${HERMES_HOME:-$HOME/.hermes}" "$HOME"/.hermes/profiles/*; do
    if [ -L "$d/plugins/agent-lights" ]; then
      p="$(basename "$d")"; HP=(); [ "$d" != "$HOME/.hermes" ] && [ "$d" != "${HERMES_HOME:-}" ] && HP=(-p "$p")
      hermes "${HP[@]}" plugins disable agent-lights >/dev/null 2>&1 || true
      rm -f "$d/plugins/agent-lights"
      echo "Hermes: plugin removed from $d"
    fi
  done
fi

rm -f "$HOME/.local/bin/agent-lights-open"
echo "Done. Session records are in ~/.local/state/agent-lights/ (safe to delete)."
