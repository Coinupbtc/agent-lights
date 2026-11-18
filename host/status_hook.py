#!/usr/bin/env python3
"""Claude Code / Grok hook -> per-session light state for the Agent Lights pill.

usage (from a hooks config):  python3 status_hook.py --agent claude|grok
Writes $AGENT_LIGHTS_STATE_DIR (default ~/.local/state/agent-lights/sessions)/<agent>-<session>.json.
Never blocks the agent: every error is swallowed, no stdout, always exit 0.

Each record carries the agent's own process (pid + start time) so the server can drop a session
the moment its process is gone (tab closed, ssh dropped), and `term`: true only when that process
sits in a terminal (a tab) rather than a background session or a headless/cron run.

Grok also runs the hooks in ~/.claude/settings.json (Claude Code compatibility), so the
claude-tagged copy steps aside when it sees Grok's GROK_HOOK_EVENT env; Grok's own
~/.grok/hooks/agent-lights.json (--agent grok) records it instead.
"""
import json
import os
import sys
import time

STATE_DIR = os.environ.get("AGENT_LIGHTS_STATE_DIR") or os.path.expanduser("~/.local/state/agent-lights/sessions")

WORKING = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"}
DONE = {"Stop", "StopCancelled"}
ERROR = {"StopFailure"}
# processes between the agent and this hook (hook shells, interpreters, wrappers)
WRAPPERS = {"sh", "bash", "dash", "zsh", "fish", "python3", "python", "env", "timeout", "nice", "nohup", "uv"}


def _stat(pid: int):
    """-> (comm, ppid, tty_nr, starttime) from /proc/<pid>/stat."""
    with open(f"/proc/{pid}/stat") as f:
        s = f.read()
    comm = s[s.index("(") + 1:s.rindex(")")]
    rest = s[s.rindex(")") + 2:].split()
    return comm, int(rest[1]), int(rest[4]), rest[19]


def _agent_proc():
    """Nearest ancestor that isn't a shell/interpreter = the agent. -> dict or {}."""
    pid = os.getppid()
    for _ in range(8):
        if pid <= 1:
            return {}
        comm, ppid, tty, start = _stat(pid)
        if comm not in WRAPPERS:
            out = {"pid": pid, "start": start, "term": tty != 0 and not _background(pid)}
            try:
                out["proc_cwd"] = os.readlink(f"/proc/{pid}/cwd")   # where `claude --resume` must run
            except OSError:
                pass
            return out
        pid = ppid
    return {}


def _background(pid: int) -> bool:
    """Claude background sessions run under a `bg-pty-host` (it has a pty, but it isn't a tab)."""
    for _ in range(8):
        if pid <= 1:
            return False
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            return False
        if b"bg-pty-host" in cmd or b"bg-spare" in cmd or b"daemon\0run" in cmd:
            return True
        pid = _stat(pid)[1]
    return False


def _current(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def main() -> None:
    agent = "claude"
    if "--agent" in sys.argv:
        agent = sys.argv[sys.argv.index("--agent") + 1]
    if agent == "claude" and os.environ.get("GROK_HOOK_EVENT"):
        return  # Grok replaying Claude's settings; the grok-tagged hook handles it
    data = json.load(sys.stdin)
    sid = str(data.get("session_id") or data.get("sessionId") or "unknown").replace("/", "_")[:80]
    event = data.get("hook_event_name", "")
    path = os.path.join(STATE_DIR, f"{agent}-{sid}.json")
    prev = _current(path)

    # Grok fires one more Stop at session teardown (reason channel_closed / shutdown), at the same
    # time as SessionEnd and sometimes after it. SessionEnd leaves an "ended" tombstone (the server
    # hides it and sweeps it after a minute) so that late Stop can't resurrect the session as done.
    reason = str(data.get("reason") or data.get("stop_reason") or data.get("stopReason") or "")
    if event == "SessionEnd" or (event == "Stop" and reason in ("channel_closed", "shutdown")):
        state = "ended"
    elif event == "Stop" and prev.get("state") == "ended":
        return
    elif event in WORKING:
        state = "working"
    elif event in DONE:
        state = "done"
    elif event in ERROR:
        state = "error"
    elif event == "Notification":
        ntype = data.get("notification_type") or data.get("notificationType") or ""
        msg = (data.get("message") or "").lower()
        # idle_prompt ("waiting for your input") fires ~60 s after every finish: still just "done".
        if ntype == "permission_prompt" or (not ntype and ("permission" in msg or "approve" in msg)):
            state = "needs_you"
        else:
            return
    else:
        return

    now = time.time()
    rec = {
        "agent": agent,
        "state": state,
        "event": event,
        "where": os.path.basename((data.get("cwd") or "").rstrip("/")) or "~",
        "ts": now,
        "first_ts": prev.get("first_ts", now),
    }
    # Claude writes "[Request interrupted by user]" to the transcript but fires no hook when you press
    # Esc, so the server reads the transcript tail to turn a stuck "working" back into "done".
    if data.get("transcript_path"):
        rec["transcript"] = str(data["transcript_path"])
    try:
        rec.update(_agent_proc())
    except Exception:
        pass
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
