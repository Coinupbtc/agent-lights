#!/usr/bin/env bash
# Removes everything host/install.sh added. Your other hooks and settings stay. Backs up settings.json first.
# Keeps ~/.config/agent-lights/ (token + config.json; delete it yourself if you're done for good).
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user disable --now agent-lights.service >/dev/null 2>&1 || true
fi
rm -f "$UNIT_DIR/agent-lights.service" "$UNIT_DIR/agent-lights-fail.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
echo "status server: stopped and removed"

# take our hook out of an agent's JSON hooks file (backed up first); everything else in it stays
strip_hooks() {
  local file="$1" label="$2"
  [ -f "$file" ] || return 0
  cp -a "$file" "$file.bak-agent-lights-$STAMP"
  python3 - "$file" "$label" <<'PY'
import json, sys
path, label = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
n = 0
def ours(h):
    return "/host/status_hook.py --agent " in h.get("command", "")
for ev, groups in list(d.get("hooks", {}).items()):
    keep = []
    for g in groups:
        if "hooks" in g:            # Claude Code / Codex: groups of hooks
            inner = [h for h in g["hooks"] if not ours(h)]
            n += len(g["hooks"]) - len(inner)
            if inner:
                keep.append(dict(g, hooks=inner))
        elif ours(g):               # Cursor: plain list of hooks
            n += 1
        else:
            keep.append(g)
    if keep:
        d["hooks"][ev] = keep
    else:
        del d["hooks"][ev]
with open(path, "w") as f:
    json.dump(d, f, indent=2)
print(f"{label}: removed {n} hook entries")
PY
}
strip_hooks "$HOME/.claude/settings.json" "Claude Code"
strip_hooks "${CODEX_HOME:-$HOME/.codex}/hooks.json" "Codex"
strip_hooks "$HOME/.cursor/hooks.json" "Cursor CLI"

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
