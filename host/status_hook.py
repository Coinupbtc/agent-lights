#!/usr/bin/env python3
"""Agent hook -> per-session light state for the Agent Lights pill.

Any agent that can run a command on its events can drive a dot:

  python3 status_hook.py --agent claude              # the event JSON arrives on stdin (Claude Code, Codex,
                                                     # Cursor CLI, Grok CLI, Gemini CLI ... command hooks)
  python3 status_hook.py --agent myagent --state working|done|needs_you|error|ended [--session ID] [--cwd DIR]
                                                     # anything else: say the state yourself (stdin is not read)

Writes $AGENT_LIGHTS_STATE_DIR (default ~/.local/state/agent-lights/sessions)/<agent>-<session>.json.
Never blocks the agent: every error is swallowed, no stdout, always exit 0.

Each record carries the agent's own process (pid + start time) so the server can drop a session
the moment its process is gone (tab closed, ssh dropped), and `term`: true only when that process
sits in a terminal (a tab) rather than a background session or a headless/cron run.

Some agents also run the hooks written for another one (Grok replays ~/.claude/settings.json). A hook
whose --agent doesn't match the process that ran it steps aside; that agent's own hook records it.
"""
import json
import os
import sys
import time

STATE_DIR = os.environ.get("AGENT_LIGHTS_STATE_DIR") or os.path.expanduser("~/.local/state/agent-lights/sessions")
STATES = ("working", "done", "needs_you", "error", "ended")

# event names, lower-cased, across agents (Claude Code / Codex / Grok: PascalCase; Cursor: camelCase;
# Gemini CLI: BeforeAgent ...)
START = {"userpromptsubmit", "beforesubmitprompt", "beforeagent", "pretooluse", "beforetool",
         "beforeshellexecution", "beforemcpexecution"}
# after-tool events keep a turn yellow (and clear a red permission prompt) but never start one: Cursor
# sends a late postToolUseFailure after the turn already stopped
AFTER = {"posttooluse", "posttoolusefailure", "aftertool", "aftershellexecution", "aftermcpexecution",
         "afterfileedit"}
DONE = {"stop", "stopcancelled", "afteragent", "interrupt"}   # Interrupt: Codex 0.150+, Esc
# the agent asks you something through a tool: red until the answer comes back (PostToolUse)
QUESTION_TOOLS = {"askuserquestion", "request_user_input"}
ERROR = {"stopfailure"}
ASK = {"permissionrequest"}            # Codex: its approval dialog is on screen
OPEN = {"sessionstart"}
END = {"sessionend"}
# processes between the agent and this hook (hook shells, interpreters, wrappers)
WRAPPERS = {"sh", "bash", "dash", "zsh", "fish", "python3", "python", "env", "timeout", "nice", "nohup", "uv"}
# how to tell which agent ran us, from the process (comm / program names / binary path)
SIGNS = (("claude", "claude"), ("codex", "codex"), ("cursor", "cursor-agent"), ("gemini", "gemini"),
         ("opencode", "opencode"), ("qwen", "qwen"), ("grok", "grok"), ("copilot", "copilot"))


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
            out = {"pid": pid, "start": start, "term": tty != 0 and not _background(pid), "_who": _who(pid, comm)}
            try:
                out["proc_cwd"] = os.readlink(f"/proc/{pid}/cwd")   # where a resume must run
            except OSError:
                pass   # Cursor hides its /proc entries; its events carry the folder instead
            argv0 = (_argv(pid) or [""])[0]
            if argv0.startswith("/"):
                out["argv0"] = argv0   # Reopen finds the agent here when it isn't on ssh's PATH (nvm etc.)
            return out
        pid = ppid
    return {}


def _who(pid: int, comm: str) -> str:
    """Which known agent this process is ('' = can't tell): its name, its program names, or a folder of
    its binary's path (~/.local/share/claude/versions/..., .../cursor-agent/versions/.../node)."""
    names = {comm.lower()}
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = f.read().split(b"\0")[:2]
        names |= {os.path.basename(a.decode(errors="replace")).lower() for a in argv}
    except OSError:
        pass
    try:
        names |= set(os.readlink(f"/proc/{pid}/exe").lower().split("/"))
    except OSError:
        pass
    for agent, sign in SIGNS:
        if sign in names:
            return agent
    return ""


def _argv(pid: int) -> list:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def _alive(rec: dict) -> bool:
    try:
        pid = int(rec["pid"])
        with open(f"/proc/{pid}/stat") as f:
            zombie = f.read().rsplit(")", 1)[1].split()[0] in ("Z", "X")
        return _stat(pid)[3] == str(rec.get("start")) and not zombie
    except Exception:
        return False


def _codex_window(sid: str, cwd: str, transcript: str, prev: dict) -> dict:
    """Codex 0.16x+ runs hooks in a background app-server shared by all its windows, not in the window
    you type in. Find that window: a codex process in a terminal whose command line names this session
    (codex resume <id>), else the newest one in the session's folder that no other live session holds.
    {} = no window (a thread from the Codex app or an IDE: it gets no dot)."""
    if prev.get("term") and _alive(prev):
        return {k: prev[k] for k in ("pid", "start", "term", "proc_cwd", "argv0") if k in prev}
    try:
        with open(transcript) as f:
            origin = str((json.loads(f.readline()).get("payload") or {}).get("originator") or "")
        if origin and origin != "codex-tui":
            return {}
    except Exception:
        pass
    home = os.environ.get("CODEX_HOME", "")
    taken = set()
    try:
        for name in os.listdir(STATE_DIR):
            if name.startswith("codex-") and name != f"codex-{sid}.json":
                rec = _current(os.path.join(STATE_DIR, name))
                if rec.get("term") and _alive(rec):
                    taken.add(int(rec["pid"]))
    except OSError:
        pass
    best = None
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            comm, _ppid, tty, start = _stat(pid)
            if comm != "codex" or tty == 0:
                continue
            argv = _argv(pid)
            if any(a == "app-server" for a in argv):
                continue
            with open(f"/proc/{pid}/environ", "rb") as f:
                env = dict(kv.split(b"=", 1) for kv in f.read().split(b"\0") if b"=" in kv)
            if env.get(b"CODEX_HOME", b"").decode(errors="replace") != home:
                continue
            pcwd = os.readlink(f"/proc/{pid}/cwd")
        except (OSError, ValueError):
            continue
        for flag in ("-C", "--cd"):
            if flag in argv[:-1]:
                pcwd = os.path.join(pcwd, argv[argv.index(flag) + 1])
        hit = {"pid": pid, "start": start, "term": not _background(pid), "proc_cwd": os.path.realpath(pcwd)}
        if argv and argv[0].startswith("/"):
            hit["argv0"] = argv[0]
        if sid in argv:
            return hit       # codex resume <this session>
        if os.path.realpath(pcwd) != os.path.realpath(cwd or "/nonexistent"):
            continue
        key = (pid not in taken, int(start))
        if best is None or key > best[0]:
            best = (key, hit)
    return best[1] if best else {}


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


def _arg(name: str, default: str = "") -> str:
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def _state(event: str, data: dict, prev: dict):
    """-> new state, or None to leave the record alone."""
    ev = event.lower()
    was = prev.get("state")
    # Grok fires one more Stop at session teardown (reason channel_closed / shutdown), at the same
    # time as SessionEnd and sometimes after it. SessionEnd leaves an "ended" tombstone (the server
    # hides it and sweeps it after a minute) so that late Stop can't resurrect the session as done.
    reason = str(data.get("reason") or data.get("stop_reason") or data.get("stopReason") or "")
    if ev in END or (ev == "stop" and reason in ("channel_closed", "shutdown")):
        return "ended"
    if was == "ended" and ev not in START | ASK | OPEN:
        return None   # Grok's late Stop; a new prompt or tool call from the live process revives it
    if ev in OPEN:
        # a fresh session shows up green (ready). SessionStart also fires after a compaction or /clear
        # mid-session: leave a session we already know alone.
        return "done" if was in (None, "ended") else None
    if ev in START:
        if ev == "pretooluse" and str(data.get("tool_name") or "").lower() in QUESTION_TOOLS:
            return "needs_you"
        return "working"
    if ev in AFTER:
        return "working" if was in ("working", "needs_you", None) else None
    if ev in ASK:
        return "needs_you"
    if ev in DONE:
        status = str(data.get("status") or "")
        if status == "error":
            # Cursor: Esc sends stop "aborted" and then stop "error" a moment later; that pair is just a stop
            if prev.get("event", "").lower() == "stop" and time.time() - float(prev.get("ts", 0)) < 10:
                return None
            return "error"
        return "done"
    if ev in ERROR:
        return "error"
    if ev == "notification":
        ntype = str(data.get("notification_type") or data.get("notificationType") or "").lower()
        msg = str(data.get("message") or "").lower()
        # idle_prompt ("waiting for your input") fires ~60 s after every finish: still just "done".
        if ntype in ("permission_prompt", "toolpermission", "tool_permission") or \
                (not ntype and ("permission" in msg or "approve" in msg)):
            return "needs_you"
    return None


def main() -> None:
    agent = "".join(c for c in _arg("--agent", "claude").lower() if c.isalnum() or c in "_.")[:24] or "agent"
    if agent != "grok" and os.environ.get("GROK_HOOK_EVENT"):
        return  # Grok replaying Claude's settings; the grok-tagged hook handles it
    given = _arg("--state")
    if given:
        data, event = {}, "state"
        if given not in STATES:
            return
    else:
        data = json.load(sys.stdin)
        event = str(data.get("hook_event_name") or data.get("hookEventName") or "")
    sid = _arg("--session") or data.get("session_id") or data.get("sessionId") or data.get("conversation_id")
    try:
        proc = _agent_proc()
    except Exception:
        proc = {}
    who = proc.pop("_who", "")
    if data.get("cursor_version"):
        who = "cursor"   # Cursor also runs Claude Code's hooks, with its own payload
    if who and who != agent and not given:
        return  # another agent replaying this one's hooks
    if not sid:
        # --state without --session: one dot per agent process
        sid = f"p{proc['pid']}" if proc.get("pid") else "unknown"
    sid = str(sid).replace("/", "_")[:80]
    path = os.path.join(STATE_DIR, f"{agent}-{sid}.json")
    prev = _current(path)
    roots = data.get("workspace_roots") or []
    cwd = _arg("--cwd") or data.get("cwd") or (roots[0] if roots and isinstance(roots, list) else "") or \
        proc.get("proc_cwd") or ""
    if agent == "codex" and proc.get("pid") and not proc.get("term") and "app-server" in _argv(proc["pid"]):
        try:
            proc = _codex_window(sid, cwd, str(data.get("transcript_path") or ""), prev) or {"term": False}
        except Exception:
            proc = {"term": False}
    if prev.get("pid") and proc.get("pid") and str(prev["pid"]) != str(proc["pid"]):
        if event.lower() in END and _alive(prev):
            return  # a late SessionEnd from the instance this session was resumed from
        prev = {}   # the same session id in a new process (resumed): start fresh
    state = given or _state(event, data, prev)
    if not state:
        return

    now = time.time()
    rec = {
        "agent": agent,
        "state": state,
        "event": event,
        "where": os.path.basename(str(cwd).rstrip("/")) or "~",
        "cwd": str(cwd),
        "ts": now,
        "first_ts": prev.get("first_ts", now),
    }
    # Claude and Codex fire no hook when you press Esc, so the server reads the transcript tail to turn
    # a stuck "working" back into "done".
    tx = data.get("transcript_path") or prev.get("transcript")
    if tx:
        rec["transcript"] = str(tx)
    rec.update(proc)
    for k in ("proc_cwd", "argv0"):   # an agent that is shutting down can't be read any more
        if k not in rec and prev.get(k):
            rec[k] = prev[k]
    if prev.get("term") and str(prev.get("pid")) == str(rec.get("pid")):
        rec["term"] = True   # a closed tab hangs up the terminal before the agent's last hook runs
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
