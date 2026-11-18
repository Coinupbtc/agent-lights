"""agent-lights: the Hermes light on the Agent Lights pill.

State files share the format written by host/status_hook.py (Claude / Grok):
  <state_dir>/hermes-<session_id>.json      {"agent","state","event","where","ts"}
  <state_dir>/hermes-ask-<request_id>.json  while a human prompt is open (red)
Cron runs and subagents never create a file, so overnight jobs don't light the pill.
Observer only: every callback returns None and swallows its own errors.
"""
from __future__ import annotations

import json
import os
import time

SKIP_PLATFORMS = frozenset({"cron"})


def _dir() -> str:
    return os.environ.get("AGENT_LIGHTS_STATE_DIR") or os.path.expanduser("~/.local/state/agent-lights/sessions")


def _path(key: str) -> str:
    return os.path.join(_dir(), "hermes-" + str(key).replace("/", "_")[:80] + ".json")


def _self_proc(platform: str) -> dict:
    """This Hermes process: pid + start time (so a closed tab drops its dot) and whether it is a
    terminal session. Gateways (Telegram etc.) have no tty, so they never get a dot."""
    try:
        with open("/proc/self/stat") as f:
            s = f.read()
        rest = s[s.rindex(")") + 2:].split()
        return {"pid": os.getpid(), "start": rest[19],
                "term": int(rest[4]) != 0 and (platform or "cli") == "cli"}
    except Exception:
        return {}


def _write(key: str, state: str, event: str, where: str, platform: str = "") -> None:
    os.makedirs(_dir(), exist_ok=True)
    p = _path(key)
    now = time.time()
    first = now
    try:
        with open(p) as f:
            first = json.load(f).get("first_ts", now)
    except Exception:
        pass
    rec = {"agent": "hermes", "state": state, "event": event, "where": where, "ts": now, "first_ts": first,
           "platform": platform or "cli"}
    rec.update(_self_proc(platform))
    tmp = f"{p}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, p)


def _where(platform: str) -> str:
    if (platform or "cli") == "cli":
        return os.path.basename(os.getcwd().rstrip("/")) or "~"
    profile = os.path.basename(os.environ.get("HERMES_HOME", "").rstrip("/")) or "hermes"
    return f"{profile} ({platform})"


def _pre_llm_call(session_id: str = "", platform: str = "", parent_session_id: str = "", **_kw):
    try:
        if session_id and platform not in SKIP_PLATFORMS and not parent_session_id:
            _write(session_id, "working", "turn_start", _where(platform), platform)
    except Exception:
        pass
    return None


def _pre_tool_call(session_id: str = "", **_kw):
    # No platform here, so only refresh sessions that pre_llm_call already admitted.
    try:
        if session_id and os.path.exists(_path(session_id)):
            with open(_path(session_id)) as f:
                prev = json.load(f)
            _write(session_id, "working", "tool", prev.get("where", ""), prev.get("platform", ""))
    except Exception:
        pass
    return None


def _on_session_end(session_id: str = "", failed: bool = False, platform: str = "", **_kw):
    # Hermes fires this at the end of every turn (and at CLI exit), not only when a session closes.
    try:
        if session_id and os.path.exists(_path(session_id)):
            _write(session_id, "error" if failed else "done", "turn_end", _where(platform), platform)
    except Exception:
        pass
    return None


_asks: dict[str, str] = {}  # request_id -> session_id whose dot is red while the prompt is open


def _on_human_input_request(request_id: str = "", session_id: str = "", platform: str = "", kind: str = "", **_kw):
    # The session's own dot turns red (no extra dot); a prompt with no known session gets its own.
    try:
        if not request_id or platform in SKIP_PLATFORMS:
            return None
        if session_id and os.path.exists(_path(session_id)):
            with open(_path(session_id)) as f:
                prev = json.load(f)
            _asks[request_id] = session_id
            _write(session_id, "needs_you", kind or "prompt", prev.get("where", ""), prev.get("platform", ""))
        else:
            _write("ask-" + request_id, "needs_you", kind or "prompt", _where(platform), platform)
    except Exception:
        pass
    return None


def _on_human_input_resolved(request_id: str = "", **_kw):
    try:
        sid = _asks.pop(request_id, "")
        if sid and os.path.exists(_path(sid)):
            with open(_path(sid)) as f:
                prev = json.load(f)
            _write(sid, "working", "answered", prev.get("where", ""), prev.get("platform", ""))
        elif request_id:
            os.remove(_path("ask-" + request_id))
    except Exception:
        pass
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_llm_call", _pre_llm_call)
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    ctx.register_hook("on_session_end", _on_session_end)
    ctx.register_hook("on_human_input_request", _on_human_input_request)
    ctx.register_hook("on_human_input_resolved", _on_human_input_resolved)
