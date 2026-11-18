#!/usr/bin/env python3
"""Status endpoint for the Agent Lights pill (+ close a session from the pill's right-click menu).

One dot per agent session running in a terminal tab. Two Claude tabs = two Claude dots. An agent
with no tab shows one empty ring. Each agent gets a short tag drawn next to its dots: its first
letter, or two capitals when another agent on this machine starts with the same one (Claude and
Codex -> CL, CX; capitals because a small lowercase l looks like an I). ~/.config/agent-lights/config.json lists the agents to show and can set your own:
  {"agents": ["claude", "codex", "hermes"], "tags": {"codex": "X"}}

GET /status ->
  {"dotstr": "C:green,C:yellow,G:off,H:red",      # what old pills draw, left to right
   "rows": "<one line per dot, tab-separated: tag color window id label text open-target>",
   "lights": {"claude": "yellow", ...},             # worst state per agent
   "light": "<worst overall>", "tip": "<hover text, same order>", "sessions": [...], "ts": ...}

"closed": recently ended terminal sessions, one line each: tag TAB id TAB text (the pill's Reopen menu).

POST /close  (body id=<session id>) -> ends that agent session:
  a tmux pane that only runs the agent is killed (its tmux session goes with it); otherwise the agent
  gets SIGTERM, then SIGKILL after 5 s. Only live terminal sessions recorded by our own hooks qualify.

Dot colors: red = needs you (permission / question) or the last turn errored · yellow = working ·
green = finished / interrupted, waiting for you · off = no session.
window = 0 when the session runs in a tmux session nobody is attached to (no window shows it anywhere);
the pill draws those as a hollow ring and offers Open (attach it in a new tab) or Close.
A session disappears as soon as its process exits (pid + start time recorded by the hook);
background sessions and headless/cron runs (term=false) are never shown.

Auth: /status and /close need the header X-Agent-Lights-Token: <token> and a loopback, Tailscale or
private-network source address. The token lives in ~/.config/agent-lights/token (created on first start,
mode 600); the pill reads its copy from %APPDATA%\\AgentLights\\config.json. /health is open.

Env: AGENT_LIGHTS_PORT (8777), AGENT_LIGHTS_BIND (0.0.0.0; 127.0.0.1 = same machine / ssh tunnel only),
AGENT_LIGHTS_STATE_DIR (~/.local/state/agent-lights/sessions), AGENT_LIGHTS_TOKEN_FILE, AGENT_LIGHTS_CONFIG.
"""
import glob
import hmac
import ipaddress
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

STATE_DIR = os.environ.get("AGENT_LIGHTS_STATE_DIR") or os.path.expanduser("~/.local/state/agent-lights/sessions")
CLOSED_DIR = os.path.join(os.path.dirname(STATE_DIR.rstrip("/")), "closed")   # recently ended, for Reopen
CLOSED_KEEP, CLOSED_MAX_S = 10, 24 * 3600
PORT = int(os.environ.get("AGENT_LIGHTS_PORT", "8777"))
BIND = os.environ.get("AGENT_LIGHTS_BIND", "0.0.0.0")
TOKEN_FILE = os.environ.get("AGENT_LIGHTS_TOKEN_FILE") or os.path.expanduser("~/.config/agent-lights/token")
CONFIG_FILE = os.environ.get("AGENT_LIGHTS_CONFIG") or os.path.expanduser("~/.config/agent-lights/config.json")
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
# agent key (the --agent name its hook uses) -> (name, tag when another agent here shares its first letter)
KNOWN = {
    "claude": ("Claude", "CL"), "codex": ("Codex", "CX"), "cursor": ("Cursor", "CU"), "copilot": ("Copilot", "CO"),
    "crush": ("Crush", "CR"), "gemini": ("Gemini", "GE"), "grok": ("Grok", "GK"), "goose": ("Goose", "GO"),
    "hermes": ("Hermes", "HE"), "opencode": ("opencode", "OP"), "openclaw": ("OpenClaw", "OC"),
    "qwen": ("Qwen", "QW"), "kiro": ("Kiro", "KI"), "droid": ("Droid", "DR"), "amp": ("Amp", "AM"),
    "aider": ("Aider", "AD"),
}
WORKING_STALE_S = 30 * 60   # "working" with no event for 30 min -> show green, it's probably idle
DROP_S = {"done": 24 * 3600, "working": 24 * 3600, "needs_you": 24 * 3600, "error": 24 * 3600, "ended": 60}
COLOR = {"working": "yellow", "stale": "green", "done": "green", "interrupted": "green",
         "needs_you": "red", "error": "red"}
RANK = {"red": 3, "yellow": 2, "green": 1, "off": 0}
WORDS = {"working": "working", "done": "done", "needs_you": "NEEDS YOU", "error": "ERROR", "stale": "quiet",
         "interrupted": "interrupted"}
ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")
TMUX_TARGET_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,120}$")   # the pill only attaches to names like this
# loopback, Tailscale (CGNAT + its IPv6 ULA), private LANs, WSL/docker bridges
ALLOWED_NETS = [ipaddress.ip_network(n) for n in
                ("127.0.0.0/8", "::1/128", "100.64.0.0/10", "fc00::/7",
                 "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12")]
CLK_TCK = os.sysconf("SC_CLK_TCK")
_cache = {"tmux_t": 0.0, "tmux": {}, "tx": {}, "cfg_key": None, "cfg": {}}


# ---------- which agents, and their tags ----------
def _config() -> dict:
    """~/.config/agent-lights/config.json (re-read when it changes). Bad or missing file = {}."""
    try:
        st = os.stat(CONFIG_FILE)
        key = (st.st_size, st.st_mtime_ns)
    except OSError:
        return {}
    if _cache["cfg_key"] != key:
        try:
            with open(CONFIG_FILE) as f:
                cfg = json.load(f)
            _cache["cfg"] = cfg if isinstance(cfg, dict) else {}
        except Exception:
            _cache["cfg"] = {}
        _cache["cfg_key"] = key
    return _cache["cfg"]


def _name(agent: str) -> str:
    return KNOWN.get(agent, (agent.title(),))[0]


def _clean_tag(t) -> str:
    return re.sub(r"[\s,:]", "", str(t))[:3]


def _tags(agents: list, cfg: dict) -> dict:
    """agent -> short tag: the first letter, two letters when two agents here share it, or your own."""
    mine = {a: _clean_tag(t) for a, t in (cfg.get("tags") or {}).items() if _clean_tag(t)}
    first = {}
    for a in agents:
        if a not in mine:
            first.setdefault(_name(a)[:1].upper(), []).append(a)
    taken = set(mine.values())
    tags = {}
    for a in agents:
        if a in mine:
            tags[a] = mine[a]
            continue
        f = _name(a)[:1].upper()
        if len(first[f]) == 1 and f not in taken:
            tags[a] = f
        else:
            tags[a] = KNOWN[a][1] if a in KNOWN else _name(a)[:2].upper()
    return tags


def _agents(cfg: dict, sessions: list, closed: list) -> list:
    """Agents with a slot on the pill: the configured ones, then any other that has a session."""
    out = [a for a in (cfg.get("agents") or []) if isinstance(a, str)] or ["claude"]
    for a in [s["agent"] for s in sessions] + [r.get("agent") or sid.split("-", 1)[0] for _t, sid, r in closed]:
        if a and a not in out:
            out.append(a)
    return out


def _archive(path: str, rec: dict, now: float) -> None:
    """Session over: remember it for Reopen (terminal sessions with a real id only), then drop it."""
    name = os.path.basename(path)
    if rec.get("pid") and rec.get("term") is not False and not name.startswith("hermes-ask-"):
        try:
            os.makedirs(CLOSED_DIR, exist_ok=True)
            rec = dict(rec, closed_ts=now)
            tmp = os.path.join(CLOSED_DIR, f".{name}.{os.getpid()}.tmp")
            with open(tmp, "w") as f:
                json.dump(rec, f)
            os.replace(tmp, os.path.join(CLOSED_DIR, name))
        except OSError:
            pass
    try:
        os.remove(path)
    except OSError:
        pass


def _closed(now: float, live_ids: set) -> list:
    out = []
    try:
        names = [n for n in os.listdir(CLOSED_DIR) if n.endswith(".json")]
    except FileNotFoundError:
        return out
    for name in names:
        p = os.path.join(CLOSED_DIR, name)
        try:
            with open(p) as f:
                rec = json.load(f)
        except Exception:
            continue
        if now - float(rec.get("closed_ts", 0)) > CLOSED_MAX_S:
            try:
                os.remove(p)
            except OSError:
                pass
            continue
        if name[:-5] not in live_ids:
            out.append((float(rec.get("closed_ts", 0)), name[:-5], rec))
    out.sort(reverse=True)
    for _ts, sid, _rec in out[CLOSED_KEEP:]:
        try:
            os.remove(os.path.join(CLOSED_DIR, sid + ".json"))
        except OSError:
            pass
    return out[:CLOSED_KEEP]


def _ago(s: int) -> str:
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h"


def _stat(pid: int):
    """-> (comm, ppid, tty_nr, starttime) from /proc/<pid>/stat."""
    with open(f"/proc/{pid}/stat") as f:
        s = f.read()
    comm = s[s.index("(") + 1:s.rindex(")")]
    rest = s[s.rindex(")") + 2:].split()
    return comm, int(rest[1]), int(rest[4]), rest[19]


def _alive(rec: dict):
    """True / False when the record names its process; None for old records without one."""
    pid = rec.get("pid")
    if not pid:
        return None
    try:
        return _stat(int(pid))[3] == str(rec.get("start")) and not _zombie(int(pid))
    except Exception:
        return False


def _zombie(pid: int) -> bool:
    """Exited, but its parent hasn't collected it yet (tmux can leave a closed pane's agent like this)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] in ("Z", "X")
    except OSError:
        return True


def _boot_time() -> float:
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime "):
                    return float(line.split()[1])
    except OSError:
        pass
    return 0.0


BOOT = _boot_time()


# ---------- where is the tab? ----------
def _tmux_panes() -> dict:
    """pane_pid -> {target, pane, session, attached} for every tmux pane (cached ~1.5 s)."""
    now = time.time()
    if now - _cache["tmux_t"] < 1.5:
        return _cache["tmux"]
    panes = {}
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_pid}\t#{pane_id}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{session_attached}"],
            capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) == 6 and f[0].isdigit():
                panes[int(f[0])] = {"pane": f[1], "session": f[2], "target": f"{f[2]}:{f[3]}.{f[4]}",
                                    "attached": f[5] not in ("", "0")}
    except Exception:
        pass
    _cache["tmux_t"], _cache["tmux"] = now, panes
    return panes


def _tab(rec: dict) -> dict:
    """What kind of terminal the agent sits in: tmux (attached or not), a plain ssh tab, or a desktop window."""
    try:
        pid = int(rec.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if pid <= 1:
        return {"kind": "unknown", "window": True}
    panes = _tmux_panes()
    child, cur = None, pid
    for _ in range(12):
        if cur <= 1:
            break
        if cur in panes:
            p = panes[cur]
            return {"kind": "tmux", "window": p["attached"], "tmux": p["target"], "pane": p["pane"],
                    "pane_is_agent": cur == pid}
        try:
            comm, ppid, _tty, _start = _stat(cur)
        except Exception:
            break
        if comm.startswith("sshd"):
            since = ""
            try:
                start = float(_stat(child)[3]) / CLK_TCK + BOOT if child else 0
                since = time.strftime("%b %d %H:%M", time.localtime(start)) if start else ""
            except Exception:
                pass
            return {"kind": "ssh", "window": True, "since": since}
        if comm.startswith(("gnome-terminal", "kgx", "xterm", "konsole", "tilix", "alacritty", "kitty")):
            return {"kind": "desktop", "window": True}
        child, cur = cur, ppid
    return {"kind": "unknown", "window": True}


def _tab_words(t: dict) -> str:
    if t["kind"] == "tmux":
        return "tmux, open in a window" if t["window"] else "NO WINDOW (tmux, nobody attached)"
    if t["kind"] == "ssh":
        return "plain ssh tab" + (f" since {t['since']}" if t.get("since") else "") + " (no tmux)"
    if t["kind"] == "desktop":
        return "desktop terminal"
    return ""


# ---------- Esc-interrupted Claude turns ----------
def _transcript(rec: dict, sid: str) -> str:
    p = rec.get("transcript") or ""
    if p and os.path.isfile(p):
        return p
    hits = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", f"{glob.escape(sid)}.jsonl"))
    return hits[0] if hits else ""


def _interrupted(agent: str, path: str) -> bool:
    """True when the agent's transcript shows the last turn was interrupted (Esc). Claude Code and
    Codex fire no hook on Esc, so without this a stopped turn would stay yellow (or red)."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    key = (st.st_size, st.st_mtime_ns)
    hit = _cache["tx"].get(path)
    if hit and hit[0] == key:
        return hit[1]
    result = False
    try:
        with open(path, "rb") as f:
            f.seek(max(0, st.st_size - 256 * 1024))
            lines = f.read().splitlines()
        result = (_codex_aborted if agent == "codex" else _claude_aborted)(lines)
    except Exception:
        result = False
    if len(_cache["tx"]) > 64:
        _cache["tx"].clear()
    _cache["tx"][path] = (key, result)
    return result


def _codex_aborted(lines: list) -> bool:
    """Codex rollout: the last turn event is turn_aborted (task_started / task_complete otherwise)."""
    for raw in reversed(lines):
        if b"event_msg" not in raw:
            continue
        try:
            d = json.loads(raw)
        except Exception:
            continue
        t = (d.get("payload") or {}).get("type")
        if t in ("turn_aborted", "task_started", "task_complete", "turn_started", "turn_complete"):
            return t == "turn_aborted"
    return False


def _claude_aborted(lines: list) -> bool:
    """Claude transcript: the last real entry is '[Request interrupted by user...]'."""
    for raw in reversed(lines):
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if d.get("type") not in ("user", "assistant") or d.get("isSidechain") or d.get("isMeta"):
            continue
        content = (d.get("message") or {}).get("content")
        texts = [content] if isinstance(content, str) else [
            c.get("text", "") for c in (content or []) if isinstance(c, dict) and c.get("type") == "text"]
        if d["type"] == "user" and texts and all(t.startswith(("<command-", "<local-command")) for t in texts):
            continue   # slash-command echo, not a turn
        return d["type"] == "user" and any(t.startswith("[Request interrupted by user") for t in texts)
    return False


# ---------- snapshot ----------
def _load_sessions(now: float) -> list:
    sessions = []
    try:
        names = os.listdir(STATE_DIR)
    except FileNotFoundError:
        names = []
    for name in names:
        if not name.endswith(".json"):
            continue
        p = os.path.join(STATE_DIR, name)
        try:
            with open(p) as f:
                rec = json.load(f)
        except Exception:
            continue
        age = now - float(rec.get("ts", 0))
        st = rec.get("state", "done")
        alive = _alive(rec)
        if alive is False:
            _archive(p, rec, now)
            continue
        if age > DROP_S.get(st, 6 * 3600) or (alive is None and age > 6 * 3600):
            try:
                os.remove(p)
            except OSError:
                pass
            continue
        if st == "ended" or rec.get("term") is False:
            continue
        sid = name[:-5]
        agent = rec.get("agent") or sid.split("-", 1)[0]
        if st in ("working", "needs_you") and agent in ("claude", "codex"):
            tx = _transcript(rec, sid.split("-", 1)[1] if "-" in sid else sid) if agent == "claude" \
                else str(rec.get("transcript") or "")
            if tx and _interrupted(agent, tx):
                st = "interrupted"
        if st == "working" and age > WORKING_STALE_S:
            st = "stale"
        tab = _tab(rec)
        sessions.append({"id": sid, "agent": agent, "state": st, "where": str(rec.get("where", "")),
                         "age_s": int(age), "first": float(rec.get("first_ts", rec.get("ts", 0))),
                         "window": bool(tab["window"]), "tab": tab["kind"], "tab_words": _tab_words(tab),
                         "tmux": tab.get("tmux", ""), "_proc": (agent, rec.get("pid"), rec.get("start")),
                         "_ts": float(rec.get("ts", 0))})
    # one window shows one conversation: when two sessions sit in the same process (Codex /new, or a
    # resume inside a running agent), only the most recently active one gets the dot
    newest = {}
    for s in sessions:
        k = s["_proc"]
        if k[1] and (k not in newest or s["_ts"] > newest[k]["_ts"]):
            newest[k] = s
    sessions = [s for s in sessions if not s["_proc"][1] or newest[s["_proc"]] is s]
    for s in sessions:
        del s["_proc"], s["_ts"]
    sessions.sort(key=lambda s: s["first"])
    return sessions


def _clean(s: str) -> str:
    return re.sub(r"[\t\r\n]+", " ", str(s))


def snapshot() -> dict:
    now = time.time()
    sessions = _load_sessions(now)
    closed_recs = _closed(now, {s["id"] for s in sessions})
    cfg = _config()
    agents = _agents(cfg, sessions, closed_recs)
    tags = _tags(agents, cfg)
    shown = [a for a in agents if a in (cfg.get("agents") or ["claude"]) or any(s["agent"] == a for s in sessions)]
    dots, rows, lines, lights = [], [], [], {}
    for agent in shown:
        letter, name = tags[agent], _name(agent)
        mine = [s for s in sessions if s["agent"] == agent]
        if not mine:
            dots.append(f"{letter}:off")
            lights[agent] = "off"
            lines.append(f"{letter}  {name}: no tab")
            rows.append("\t".join([letter, "off", "1", "", letter, f"{name}: no tab", ""]))
            continue
        for i, s in enumerate(mine, 1):
            color = COLOR.get(s["state"], "green")
            s["label"] = f"{letter}{i}"
            words = f"{WORDS.get(s['state'], s['state'])} - {s['where']} ({_ago(s['age_s'])})"
            dots.append(f"{letter}:{color}")
            lines.append(f"{letter}{i} {name}: {words}" + ("" if s["window"] else " - NO WINDOW"))
            target = s["tmux"] if TMUX_TARGET_RE.match(s["tmux"] or "") else ""
            text = f"{s['where']} - {WORDS.get(s['state'], s['state'])} {_ago(s['age_s'])}"
            if s["tab_words"]:
                text += f" - {s['tab_words']}"
            rows.append("\t".join(_clean(x) for x in
                                  [letter, color, "1" if s["window"] else "0", s["id"], s["label"],
                                   f"{name} {text}", target]))
        lights[agent] = max((COLOR.get(s["state"], "green") for s in mine), key=RANK.get)
    worst = max(lights.values(), key=RANK.get) if lights else "off"
    tip = "\n".join(lines).replace('"', "'")
    for s in sessions:
        s.pop("first", None)
    closed = []
    for ts, sid, rec in closed_recs:
        agent = rec.get("agent") or sid.split("-", 1)[0]
        closed.append("\t".join(_clean(x) for x in [tags.get(agent, "?"), sid,
                      f"{_name(agent)} {rec.get('where', '')} - closed {_ago(int(now - ts))} ago"]))
    return {"dotstr": ",".join(dots), "rows": "\n".join(rows), "closed": "\n".join(closed), "lights": lights,
            "light": worst, "tip": tip, "sessions": sessions, "ts": int(now)}


# ---------- close ----------
def close_session(sid: str) -> tuple:
    """-> (http code, result dict). Ends one live terminal session that our hooks recorded."""
    if not ID_RE.match(sid or ""):
        return 400, {"ok": False, "error": "bad id"}
    path = os.path.join(STATE_DIR, sid + ".json")
    try:
        with open(path) as f:
            rec = json.load(f)
    except Exception:
        return 404, {"ok": False, "error": "no such session (already closed?)"}
    if rec.get("term") is False:
        return 403, {"ok": False, "error": "not a terminal session"}
    if not _alive(rec):
        _archive(path, rec, time.time())
        return 200, {"ok": True, "how": "already gone"}
    pid = int(rec["pid"])
    tab = _tab(rec)
    how = ""
    if tab["kind"] == "tmux" and tab.get("pane_is_agent") and tab.get("pane"):
        # the pane runs nothing but the agent: kill the pane, and its tmux session ends with it
        r = subprocess.run(["tmux", "kill-pane", "-t", tab["pane"]], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            how = f"tmux kill-pane {tab['pane']} ({tab['tmux']})"
    if not how:
        try:
            os.kill(pid, signal.SIGTERM)
            how = f"SIGTERM pid {pid}"
        except ProcessLookupError:
            how = "already gone"
    for _ in range(50):
        if not _alive(rec):
            break
        time.sleep(0.1)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
            how += " + SIGKILL"
        except ProcessLookupError:
            pass
        time.sleep(0.5)
    gone = not _alive(rec)
    if gone:
        _archive(path, rec, time.time())
    _cache["tmux_t"] = 0.0
    print(f"close {sid}: {how} -> {'gone' if gone else 'STILL ALIVE'}", file=sys.stderr, flush=True)
    return (200 if gone else 500), {"ok": gone, "how": how, "id": sid}


def load_token() -> str:
    """The shared secret the pill must send. Created on first start (32 random bytes, hex, mode 600)."""
    env = os.environ.get("AGENT_LIGHTS_TOKEN", "").strip()
    if env:
        return env
    try:
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
        if len(tok) >= 16:
            return tok
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    tok = secrets.token_hex(32)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(tok + "\n")
    print(f"agent-lights: new token written to {TOKEN_FILE}", file=sys.stderr, flush=True)
    return tok


TOKEN = ""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj) -> None:
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _allowed(self) -> bool:
        """Private source address AND the right token. A web page can't send the custom header
        cross-site (no CORS here), and a stranger on the LAN doesn't know the token."""
        try:
            ip = ipaddress.ip_address(self.client_address[0].split("%")[0])
            if ip.version == 6 and ip.ipv4_mapped:
                ip = ip.ipv4_mapped
            local = any(ip in n for n in ALLOWED_NETS)
        except ValueError:
            local = False
        sent = self.headers.get("X-Agent-Lights-Token", "")
        return local and bool(TOKEN) and hmac.compare_digest(sent.encode(), TOKEN.encode())

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/status", "/"):
            if not self._allowed():
                return self._send(403, {"ok": False, "error": "forbidden: wrong or missing token"})
            self._send(200, snapshot())
        elif path == "/health":
            self._send(200, b'{"ok":true}')
        else:
            self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        u = urlsplit(self.path)
        if u.path != "/close":
            return self._send(404, {"error": "not found"})
        if not self._allowed():
            return self._send(403, {"ok": False, "error": "forbidden: wrong or missing token"})
        n = min(int(self.headers.get("Content-Length") or 0), 4096)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        q = parse_qs(raw) if raw and not raw.lstrip().startswith("{") else {}
        sid = (q.get("id") or parse_qs(u.query).get("id") or [""])[0]
        if raw.lstrip().startswith("{"):
            try:
                sid = str(json.loads(raw).get("id", ""))
            except Exception:
                sid = ""
        code, res = close_session(sid)
        self._send(code, res)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(STATE_DIR, exist_ok=True)
    TOKEN = load_token()
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"agent-lights status on {BIND}:{PORT}", file=sys.stderr, flush=True)
    srv.serve_forever()
