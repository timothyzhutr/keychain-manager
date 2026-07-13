#!/usr/bin/env python3
"""
Keychain Manager — a tiny local web UI for your macOS login keychain.

No dependencies. Wraps the built-in `security` CLI.
Run:  python3 keychain_manager.py
It opens a browser tab bound to 127.0.0.1 with a random access token.

What it does:
  - List generic + internet passwords in your login keychain
  - Search / filter them
  - Reveal a password (macOS will prompt you to authorize — that's the OS, working as intended)
  - Copy a password to the clipboard
  - Add a new generic password
  - Delete an item

It never stores passwords anywhere. Reveals are read on-demand from the keychain.
"""

import http.server
import json
import re
import secrets
import socket
import subprocess
import threading
import urllib.parse
import webbrowser

SECURITY = "/usr/bin/security"
TOKEN = secrets.token_urlsafe(24)
HOST = "127.0.0.1"


# ---------------------------------------------------------------------------
# security CLI wrappers
# ---------------------------------------------------------------------------
def login_keychain() -> str:
    out = subprocess.run(
        [SECURITY, "login-keychain"], capture_output=True, text=True, check=True
    ).stdout
    return out.strip().strip('"').strip()


# Named-attribute line, e.g.  "acct"<blob>="alice"   or   "labl"<blob>=0xAB..  "GitHub\000"
_ATTR_RE = re.compile(r'"(\w{4})"<[^>]*>=(.*)')


def _parse_value(raw: str):
    raw = raw.strip()
    if raw == "<NULL>":
        return None
    # Hex form sometimes followed by a quoted decoding: 0xAB..  "text\000"
    m = re.search(r'"((?:[^"\\]|\\.)*)"\s*$', raw)
    if m:
        val = m.group(1)
        # decode octal escapes like \000 and drop trailing NULs
        val = re.sub(r"\\(\d{3})", lambda x: chr(int(x.group(1), 8)), val)
        return val.rstrip("\x00")
    if raw.startswith("0x"):
        try:
            return bytes.fromhex(raw[2:].split()[0]).decode("utf-8").rstrip("\x00")
        except Exception:
            return raw
    return raw


def list_items():
    """Parse `security dump-keychain` into a list of items."""
    kc = login_keychain()
    out = subprocess.run(
        [SECURITY, "dump-keychain", kc], capture_output=True, text=True
    ).stdout

    items = []
    cur = None
    for line in out.splitlines():
        s = line.strip()
        cm = re.match(r'class:\s*"(\w+)"', s)
        if cm:
            if cur is not None:
                items.append(cur)
            klass = cm.group(1)
            cur = {"class": klass, "attrs": {}}
            continue
        if cur is None:
            continue
        am = _ATTR_RE.match(s)
        if am:
            key, raw = am.group(1), am.group(2)
            val = _parse_value(raw)
            if val is not None and val != "":
                cur["attrs"][key] = val
    if cur is not None:
        items.append(cur)

    result = []
    for it in items:
        if it["class"] not in ("genp", "inet"):
            continue
        a = it["attrs"]
        account = a.get("acct", "")
        service = a.get("svce") or a.get("srvr") or ""
        label = a.get("labl") or a.get("0007") or service or account
        result.append(
            {
                "kind": it["class"],
                "kindLabel": "internet" if it["class"] == "inet" else "generic",
                "account": account,
                "service": service,
                "label": label,
                "desc": a.get("desc", ""),
            }
        )
    # stable, readable ordering
    result.sort(key=lambda x: (x["service"].lower(), x["account"].lower()))
    return result


def reveal(kind: str, service: str, account: str):
    cmd = [SECURITY, "find-internet-password" if kind == "inet" else "find-generic-password"]
    if service:
        cmd += ["-s", service]
    if account:
        cmd += ["-a", account]
    cmd += ["-w"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        err = p.stderr.strip() or "not found"
        if "44" in err or "could not be found" in err.lower():
            err = "Item not found."
        elif "128" in err or "User canceled" in err or "-25293" in err:
            err = "Authorization was canceled."
        raise RuntimeError(err)
    return p.stdout.rstrip("\n")


def add_generic(service: str, account: str, password: str, desc: str = ""):
    cmd = [SECURITY, "add-generic-password", "-a", account, "-s", service, "-w", password, "-U"]
    if desc:
        cmd += ["-j", desc]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "failed to add")


def delete_item(kind: str, service: str, account: str):
    cmd = [SECURITY, "delete-internet-password" if kind == "inet" else "delete-generic-password"]
    if service:
        cmd += ["-s", service]
    if account:
        cmd += ["-a", account]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "failed to delete")


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    def _auth_ok(self):
        qs = urllib.parse.urlparse(self.path).query
        tok = urllib.parse.parse_qs(qs).get("t", [""])[0]
        if tok == TOKEN:
            return True
        if self.headers.get("X-Token") == TOKEN:
            return True
        return False

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj))

    def log_message(self, *args):
        pass  # quiet

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            if not self._auth_ok():
                self._send(403, "Forbidden — use the launch URL with the token.", "text/plain")
                return
            self._send(200, HTML.replace("__TOKEN__", TOKEN), "text/html; charset=utf-8")
            return
        if path == "/api/list":
            if not self._auth_ok():
                self._json(403, {"error": "forbidden"})
                return
            try:
                self._json(200, {"items": list_items()})
            except Exception as e:
                self._json(500, {"error": str(e)})
            return
        self._send(404, "not found", "text/plain")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            self._json(403, {"error": "forbidden"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or "{}")
        except Exception:
            self._json(400, {"error": "bad json"})
            return
        try:
            if path == "/api/reveal":
                pw = reveal(body.get("kind", "genp"), body.get("service", ""), body.get("account", ""))
                self._json(200, {"password": pw})
            elif path == "/api/add":
                add_generic(
                    body.get("service", "").strip(),
                    body.get("account", "").strip(),
                    body.get("password", ""),
                    body.get("desc", "").strip(),
                )
                self._json(200, {"ok": True})
            elif path == "/api/delete":
                delete_item(body.get("kind", "genp"), body.get("service", ""), body.get("account", ""))
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "not found"})
        except Exception as e:
            self._json(500, {"error": str(e)})


HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Keychain Manager</title>
<style>
  :root{
    --bg:#f5f5f7; --card:#ffffff; --ink:#1d1d1f; --muted:#6e6e73;
    --line:#e3e3e6; --accent:#0a84ff; --accent-ink:#fff;
    --danger:#ff3b30; --ok:#34c759; --chip:#eef1f5; --shadow:0 1px 3px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.05);
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#000; --card:#1c1c1e; --ink:#f5f5f7; --muted:#98989d;
      --line:#2c2c2e; --accent:#0a84ff; --chip:#2c2c2e; --shadow:0 1px 3px rgba(0,0,0,.4); }
  }
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",Segoe UI,sans-serif;
    background:var(--bg);color:var(--ink);-webkit-font-smoothing:antialiased}
  header{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 82%, transparent);
    backdrop-filter:saturate(180%) blur(20px);border-bottom:1px solid var(--line);padding:14px 20px}
  .bar{max-width:960px;margin:0 auto;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
  h1{font-size:18px;margin:0;font-weight:600;letter-spacing:-.01em;display:flex;gap:8px;align-items:center}
  h1 .lock{font-size:20px}
  .grow{flex:1}
  input,select,textarea{font:inherit;color:var(--ink);background:var(--card);border:1px solid var(--line);
    border-radius:10px;padding:9px 12px;outline:none}
  input:focus,textarea:focus,select:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
  #search{min-width:220px;flex:1}
  button{font:inherit;font-weight:550;cursor:pointer;border:1px solid var(--line);background:var(--card);
    color:var(--ink);border-radius:10px;padding:9px 14px;transition:.12s}
  button:hover{transform:translateY(-1px)}
  button.primary{background:var(--accent);color:var(--accent-ink);border-color:transparent}
  button.ghost{background:transparent}
  button.danger{color:var(--danger)}
  main{max-width:960px;margin:22px auto;padding:0 20px 80px}
  .count{color:var(--muted);font-size:13px;margin:0 2px 12px}
  .grid{display:grid;gap:10px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;
    box-shadow:var(--shadow);display:flex;gap:14px;align-items:center}
  .card .main{flex:1;min-width:0}
  .svc{font-weight:600;letter-spacing:-.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .acct{color:var(--muted);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .chip{font-size:11px;font-weight:600;color:var(--muted);background:var(--chip);border-radius:20px;
    padding:3px 9px;text-transform:uppercase;letter-spacing:.03em}
  .pw{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;background:var(--chip);
    border-radius:8px;padding:6px 10px;margin-top:8px;user-select:all;word-break:break-all;display:none}
  .pw.show{display:block}
  .actions{display:flex;gap:6px;flex-shrink:0}
  .actions button{padding:7px 11px;font-size:13px}
  .empty{text-align:center;color:var(--muted);padding:60px 0}
  dialog{border:none;border-radius:18px;padding:0;background:var(--card);color:var(--ink);
    box-shadow:0 20px 60px rgba(0,0,0,.3);max-width:420px;width:92%}
  dialog::backdrop{background:rgba(0,0,0,.35);backdrop-filter:blur(2px)}
  .dlg{padding:22px}
  .dlg h2{margin:0 0 4px;font-size:17px}
  .dlg p{margin:0 0 16px;color:var(--muted);font-size:13px}
  .field{display:flex;flex-direction:column;gap:5px;margin-bottom:12px}
  .field label{font-size:12px;font-weight:600;color:var(--muted)}
  .field input,.field textarea{width:100%}
  .dlg .row{display:flex;gap:8px;justify-content:flex-end;margin-top:6px}
  .toast{position:fixed;bottom:22px;left:50%;transform:translateX(-50%) translateY(20px);opacity:0;
    background:var(--ink);color:var(--bg);padding:10px 18px;border-radius:12px;font-size:13px;font-weight:550;
    transition:.25s;pointer-events:none;z-index:50}
  .toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
  .spin{display:inline-block;width:14px;height:14px;border:2px solid currentColor;border-top-color:transparent;
    border-radius:50%;animation:sp .7s linear infinite;vertical-align:-2px}
  @keyframes sp{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<header>
  <div class="bar">
    <h1><span class="lock">🔐</span> Keychain Manager</h1>
    <div class="grow"></div>
    <input id="search" type="search" placeholder="Search service or account…" autocomplete="off">
    <select id="filter">
      <option value="all">All</option>
      <option value="genp">Generic</option>
      <option value="inet">Internet</option>
    </select>
    <button class="ghost" id="refresh" title="Reload">↻</button>
    <button class="primary" id="addBtn">+ Add</button>
  </div>
</header>

<main>
  <div class="count" id="count"></div>
  <div class="grid" id="list"></div>
</main>

<dialog id="addDlg">
  <div class="dlg">
    <h2>Add password</h2>
    <p>Creates a generic password in your login keychain (updates it if the service + account already exist).</p>
    <div class="field"><label>Service</label><input id="a_service" placeholder="e.g. My API"></div>
    <div class="field"><label>Account</label><input id="a_account" placeholder="e.g. alice@example.com"></div>
    <div class="field"><label>Password</label><input id="a_password" type="text" placeholder="secret value"></div>
    <div class="field"><label>Note (optional)</label><input id="a_desc" placeholder="description"></div>
    <div class="row">
      <button class="ghost" id="a_cancel">Cancel</button>
      <button class="primary" id="a_save">Save</button>
    </div>
  </div>
</dialog>

<div class="toast" id="toast"></div>

<script>
const TOKEN = "__TOKEN__";
const $ = s => document.querySelector(s);
let ITEMS = [];

function api(path, method="GET", body){
  return fetch(path + "?t=" + encodeURIComponent(TOKEN), {
    method,
    headers: body ? {"Content-Type":"application/json"} : {},
    body: body ? JSON.stringify(body) : undefined
  }).then(async r => {
    const j = await r.json().catch(()=>({error:"bad response"}));
    if(!r.ok) throw new Error(j.error || ("HTTP "+r.status));
    return j;
  });
}

let toastTimer;
function toast(msg){
  const t = $("#toast"); t.textContent = msg; t.classList.add("show");
  clearTimeout(toastTimer); toastTimer = setTimeout(()=>t.classList.remove("show"), 1800);
}
const esc = s => (s||"").replace(/[&<>"]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function render(){
  const q = $("#search").value.trim().toLowerCase();
  const f = $("#filter").value;
  const rows = ITEMS.filter(it =>
    (f==="all" || it.kind===f) &&
    (!q || (it.service+" "+it.account+" "+it.label).toLowerCase().includes(q))
  );
  $("#count").textContent = rows.length + " item" + (rows.length!==1?"s":"") +
    (rows.length!==ITEMS.length ? " (of "+ITEMS.length+")" : "");
  const list = $("#list");
  if(!rows.length){ list.innerHTML = '<div class="empty">Nothing here.</div>'; return; }
  list.innerHTML = rows.map((it,i)=>{
    const idx = ITEMS.indexOf(it);
    return `<div class="card" data-i="${idx}">
      <div class="main">
        <div class="svc">${esc(it.service || it.label || "(no service)")}</div>
        <div class="acct">${esc(it.account || "—")}${it.desc?" · "+esc(it.desc):""}</div>
        <div class="pw" id="pw-${idx}"></div>
      </div>
      <span class="chip">${it.kindLabel}</span>
      <div class="actions">
        <button class="reveal" data-i="${idx}">Reveal</button>
        <button class="ghost del" data-i="${idx}" title="Delete">🗑</button>
      </div>
    </div>`;
  }).join("");
}

async function reveal(i, btn){
  const it = ITEMS[i], box = $("#pw-"+i);
  if(box.classList.contains("show")){ box.classList.remove("show"); btn.textContent="Reveal"; return; }
  btn.innerHTML = '<span class="spin"></span>';
  try{
    const j = await api("/api/reveal","POST",{kind:it.kind,service:it.service,account:it.account});
    box.textContent = j.password === "" ? "(empty)" : j.password;
    box.classList.add("show");
    btn.textContent = "Copy";
    btn.onclick = () => { navigator.clipboard.writeText(j.password); toast("Copied to clipboard"); };
  }catch(e){
    toast(e.message);
    btn.textContent = "Reveal";
  }
}

async function del(i){
  const it = ITEMS[i];
  if(!confirm(`Delete this ${it.kindLabel} password?\n\n${it.service||it.label}\n${it.account}`)) return;
  try{
    await api("/api/delete","POST",{kind:it.kind,service:it.service,account:it.account});
    toast("Deleted");
    load();
  }catch(e){ toast(e.message); }
}

async function load(){
  $("#list").innerHTML = '<div class="empty"><span class="spin"></span> Loading…</div>';
  try{
    const j = await api("/api/list");
    ITEMS = j.items; render();
  }catch(e){
    $("#list").innerHTML = '<div class="empty">Error: '+esc(e.message)+'</div>';
  }
}

$("#list").addEventListener("click", e=>{
  const rb = e.target.closest(".reveal"); if(rb){ reveal(+rb.dataset.i, rb); return; }
  const db = e.target.closest(".del"); if(db){ del(+db.dataset.i); return; }
});
$("#search").addEventListener("input", render);
$("#filter").addEventListener("change", render);
$("#refresh").addEventListener("click", load);

// Add dialog
$("#addBtn").addEventListener("click", ()=>{
  ["a_service","a_account","a_password","a_desc"].forEach(id=>$("#"+id).value="");
  $("#addDlg").showModal(); $("#a_service").focus();
});
$("#a_cancel").addEventListener("click", ()=>$("#addDlg").close());
$("#a_save").addEventListener("click", async ()=>{
  const service=$("#a_service").value.trim(), account=$("#a_account").value.trim(),
        password=$("#a_password").value, desc=$("#a_desc").value.trim();
  if(!service || !account){ toast("Service and account are required"); return; }
  try{
    await api("/api/add","POST",{service,account,password,desc});
    $("#addDlg").close(); toast("Saved"); load();
  }catch(e){ toast(e.message); }
});

load();
</script>
</body>
</html>"""


def main():
    # find a free port
    sock = socket.socket()
    sock.bind((HOST, 0))
    port = sock.getsockname()[1]
    sock.close()

    server = http.server.ThreadingHTTPServer((HOST, port), Handler)
    url = f"http://{HOST}:{port}/?t={TOKEN}"
    print("\n  🔐  Keychain Manager is running")
    print(f"      {url}\n")
    print("  Press Ctrl+C to stop.\n")
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Stopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
