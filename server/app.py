"""OPEN_UP server: file-type rules, learned picks, and the picker/settings UI.

Standard library only. State lives in /data/state.json (a mounted volume).
"""
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DATA_DIR = Path(os.environ.get("OPENUP_DATA", "/data"))
STATE_FILE = DATA_DIR / "state.json"
STATIC_DIR = Path(__file__).parent / "static"
PORT = int(os.environ.get("OPENUP_PORT", "7777"))

LOCK = threading.Lock()
SESSIONS = {}  # id -> session dict (in memory, short-lived)
SESSION_TTL = 600

DEFAULT_STATE = {
    "apps": {},  # path -> {name, bundleId}
    "rules": {},  # ext -> [app paths], ranked
    "picks": {},  # ext -> {app path -> {count, last}}
    "settings": {"learn": True},
}


def load_state():
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    state = json.loads(json.dumps(DEFAULT_STATE))
    for k, v in data.items():
        if isinstance(v, dict) and isinstance(state.get(k), dict):
            state[k].update(v)
        else:
            state[k] = v
    return state


def save_state(state):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, STATE_FILE)


STATE = load_state()


def norm_ext(ext):
    ext = (ext or "").strip().lower().lstrip(".")
    return ext or "(none)"


def ext_of(path):
    name = os.path.basename(path.rstrip("/"))
    if "." not in name.lstrip("."):
        return "(none)"
    return norm_ext(name.rsplit(".", 1)[1])


def app_name(path, fallback=None):
    info = STATE["apps"].get(path)
    if info and info.get("name"):
        return info["name"]
    if fallback:
        return fallback
    return os.path.basename(path).removesuffix(".app")


def rank(ext, candidates):
    """Score apps for an extension. Returns (ranked, others)."""
    scores = {}  # path -> {score, reasons, name}
    names = {c["path"]: c.get("name") for c in candidates}

    def bump(path, pts, reason):
        e = scores.setdefault(path, {"score": 0.0, "reasons": []})
        e["score"] += pts
        e["reasons"].append(reason)

    for scope, label in ((ext, "rule"), ("*", "any-type rule")):
        for i, path in enumerate(STATE["rules"].get(scope, [])):
            base = 1000 if scope == ext else 400
            bump(path, base - i * 10, f"{label} #{i + 1}")

    if STATE["settings"].get("learn", True):
        now = time.time()
        for path, p in STATE["picks"].get(ext, {}).items():
            pts = p.get("count", 0) * 5
            if now - p.get("last", 0) < 7 * 86400:
                pts += 3
            if pts:
                bump(path, pts, f"used {p.get('count', 0)}x")

    n = len(candidates)
    for i, c in enumerate(candidates):
        # macOS lists better handlers first; tiny score so rules/learning dominate
        bump(c["path"], 1 + (n - i) / max(n, 1), "macOS")

    ranked = sorted(scores.items(), key=lambda kv: (-kv[1]["score"], app_name(kv[0], names.get(kv[0])).lower()))
    ranked_list = [
        {"path": p, "name": app_name(p, names.get(p)), "score": round(s["score"], 2), "reasons": s["reasons"]}
        for p, s in ranked
    ]
    seen = set(scores)
    others = sorted(
        ({"path": p, "name": info.get("name") or app_name(p)} for p, info in STATE["apps"].items() if p not in seen),
        key=lambda a: a["name"].lower(),
    )
    return ranked_list, others


def record_pick(ext, path, always):
    picks = STATE["picks"].setdefault(ext, {})
    p = picks.setdefault(path, {"count": 0, "last": 0})
    if STATE["settings"].get("learn", True):
        p["count"] += 1
    p["last"] = time.time()
    if always:
        rules = [a for a in STATE["rules"].get(ext, []) if a != path]
        STATE["rules"][ext] = [path] + rules


def gc_sessions():
    cutoff = time.time() - SESSION_TTL
    for sid in [k for k, v in SESSIONS.items() if v["created"] < cutoff]:
        SESSIONS.pop(sid, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "OPEN_UP/1.0"

    def log_message(self, fmt, *args):
        print("[openup]", fmt % args, flush=True)

    # --- helpers -----------------------------------------------------------
    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        # Requiring a JSON content type forces a CORS preflight for cross-origin
        # browser requests (which we never approve), so random web pages can't
        # rewrite your rules.
        if "application/json" not in (self.headers.get("Content-Type") or ""):
            raise ValueError("Content-Type must be application/json")
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def send_file(self, name, ctype):
        path = STATIC_DIR / name
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # --- routes --------------------------------------------------------------
    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route in ("/", "/settings"):
            return self.send_file("settings.html", "text/html; charset=utf-8")
        if route == "/pick":
            return self.send_file("pick.html", "text/html; charset=utf-8")
        if route == "/theme.css":
            return self.send_file("theme.css", "text/css; charset=utf-8")
        if route == "/health":
            return self.send_json({"ok": True})
        if route == "/api/state":
            with LOCK:
                return self.send_json(STATE)
        if route.startswith("/api/session/"):
            sid = route.rsplit("/", 1)[1]
            with LOCK:
                s = SESSIONS.get(sid)
                if not s:
                    return self.send_json({"error": "session expired"}, 404)
                ranked, others = rank(s["ext"], s["candidates"])
                return self.send_json({"id": sid, "ext": s["ext"], "files": s["files"], "ranked": ranked, "others": others})
        if route.startswith("/api/rank/"):
            ext = norm_ext(route.rsplit("/", 1)[1])
            with LOCK:
                ranked, _ = rank(ext, [])
                return self.send_json({"ext": ext, "ranked": ranked})
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        try:
            body = self.read_json()
        except ValueError as e:
            return self.send_json({"error": str(e)}, 415)
        route = self.path.split("?", 1)[0]
        with LOCK:
            if route == "/api/apps":
                apps = {}
                for a in body.get("apps", []):
                    if a.get("path", "").endswith(".app"):
                        apps[a["path"]] = {"name": a.get("name") or app_name(a["path"]), "bundleId": a.get("bundleId")}
                STATE["apps"] = apps
                save_state(STATE)
                return self.send_json({"ok": True, "count": len(apps)})

            if route == "/api/session":
                gc_sessions()
                files = [f for f in body.get("files", []) if isinstance(f, str)]
                if not files:
                    return self.send_json({"error": "no files"}, 400)
                ext = norm_ext(body["ext"]) if body.get("ext") else ext_of(files[0])
                sid = uuid.uuid4().hex[:12]
                SESSIONS[sid] = {
                    "files": files,
                    "ext": ext,
                    "candidates": [c for c in body.get("candidates", []) if c.get("path")],
                    "created": time.time(),
                }
                ranked, others = rank(ext, SESSIONS[sid]["candidates"])
                return self.send_json({"id": sid, "ext": ext, "ranked": ranked, "others": others})

            if route == "/api/pick":
                ext, path = norm_ext(body.get("ext")), body.get("app", "")
                if not path.endswith(".app"):
                    return self.send_json({"error": "bad app"}, 400)
                record_pick(ext, path, bool(body.get("always")))
                save_state(STATE)
                return self.send_json({"ok": True})

            if route == "/api/rules":
                ext = norm_ext(body.get("ext")) if body.get("ext") != "*" else "*"
                apps = [a for a in body.get("apps", []) if isinstance(a, str) and a.endswith(".app")]
                if apps:
                    STATE["rules"][ext] = apps
                else:
                    STATE["rules"].pop(ext, None)
                save_state(STATE)
                return self.send_json({"ok": True})

            if route == "/api/picks/reset":
                ext = body.get("ext")
                if ext:
                    STATE["picks"].pop(norm_ext(ext), None)
                else:
                    STATE["picks"] = {}
                save_state(STATE)
                return self.send_json({"ok": True})

            if route == "/api/settings":
                STATE["settings"].update({k: v for k, v in body.items() if k in ("learn",)})
                save_state(STATE)
                return self.send_json({"ok": True})

        self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    print(f"[openup] listening on :{PORT}, state at {STATE_FILE}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
