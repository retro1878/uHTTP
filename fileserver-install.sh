#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# fileserver — install / uninstall script
# Usage:
#   sudo ./fileserver-install.sh install [--port PORT] [--dir DIR] [--user USER]
#                                       [--bind ADDR] [--token TOKEN]
#                                       [--allow-host HOST]... [--max-upload MiB]
#   sudo ./fileserver-install.sh uninstall
# ─────────────────────────────────────────────────────────────────────────────
set -e

INSTALL_DIR="/opt/fileserver"
SERVICE_NAME="fileserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DEFAULT_PORT=8080
DEFAULT_DIR="/srv/fileserver"
DEFAULT_USER="www-data"
DEFAULT_BIND="127.0.0.1"
DEFAULT_MAX_UPLOAD=512   # MiB

# ── helpers ───────────────────────────────────────────────────────────────────
red()   { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
cyan()  { echo -e "\033[0;36m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

die()   { red "ERROR: $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

usage() {
    bold "fileserver install script"
    echo
    echo "  sudo $0 install   [--port PORT] [--dir DIR] [--user USER]"
    echo "                    [--bind ADDR] [--token TOKEN]"
    echo "                    [--allow-host HOST]... [--max-upload MiB]"
    echo "  sudo $0 uninstall"
    echo
    echo "Defaults:"
    echo "  --port       $DEFAULT_PORT"
    echo "  --dir        $DEFAULT_DIR"
    echo "  --user       $DEFAULT_USER"
    echo "  --bind       $DEFAULT_BIND   (use 0.0.0.0 to expose on the network)"
    echo "  --token      <random>        (auto-generated if omitted; enables auth)"
    echo "  --max-upload $DEFAULT_MAX_UPLOAD MiB"
    echo
    echo "  --allow-host HOST   extra Host header to accept, repeatable."
    echo "                      Required when serving behind a reverse proxy:"
    echo "                      e.g. --allow-host files.example.com"
    echo "                      Requests arriving with any other non-IP Host are"
    echo "                      rejected, which blocks DNS-rebinding attacks."
    exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage
CMD=$1; shift

PORT=$DEFAULT_PORT
SERVE_DIR=$DEFAULT_DIR
RUN_USER=$DEFAULT_USER
BIND=$DEFAULT_BIND
TOKEN=""
MAX_UPLOAD=$DEFAULT_MAX_UPLOAD
ALLOW_HOSTS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --port|--dir|--user|--bind|--token|--allow-host|--max-upload)
            [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value" ;;
    esac
    case $1 in
        --port)       PORT=$2;          shift 2 ;;
        --dir)        SERVE_DIR=$2;     shift 2 ;;
        --user)       RUN_USER=$2;      shift 2 ;;
        --bind)       BIND=$2;          shift 2 ;;
        --token)      TOKEN=$2;         shift 2 ;;
        --allow-host) ALLOW_HOSTS+=("$2"); shift 2 ;;
        --max-upload) MAX_UPLOAD=$2;    shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
    require_root

    cyan "Stopping and disabling service..."
    systemctl stop  "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    cyan "Removing service file..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    cyan "Removing install directory..."
    rm -rf "$INSTALL_DIR"

    green "✓ fileserver uninstalled."
    echo  "  Serve directory $SERVE_DIR and its contents were NOT removed."
}

# ── install ───────────────────────────────────────────────────────────────────
do_install() {
    require_root

    # Validate port
    [[ $PORT =~ ^[0-9]+$ ]] && [[ $PORT -ge 1 ]] && [[ $PORT -le 65535 ]] \
        || die "Invalid port: $PORT"

    # Everything below is interpolated into the systemd unit, so anything that
    # could inject a directive or split ExecStart has to be rejected up front.
    [[ $SERVE_DIR == /* ]] || die "--dir must be an absolute path: $SERVE_DIR"
    case $SERVE_DIR in
        *[$'\n\r\t']*|*' '*) die "--dir must not contain whitespace: $SERVE_DIR" ;;
    esac
    [[ $BIND =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $BIND =~ ^[0-9a-fA-F:]+$ ]] \
        || die "Invalid bind address: $BIND"
    [[ $RUN_USER =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid user name: $RUN_USER"
    [[ $MAX_UPLOAD =~ ^[0-9]+$ ]] && (( MAX_UPLOAD > 0 )) \
        || die "Invalid --max-upload in MiB: $MAX_UPLOAD"
    case $TOKEN in
        *[$'\n\r']*) die "--token must not contain newlines" ;;
    esac
    if [[ $RUN_USER == root ]]; then
        red "WARNING: running the service as root is not recommended."
    fi

    ALLOW_HOST_ARGS=""
    for h in "${ALLOW_HOSTS[@]}"; do
        [[ $h =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] \
            || die "Invalid --allow-host: $h"
        ALLOW_HOST_ARGS+=" --allow-host $h"
    done

    # The server holds the request body and its parsed copy in memory at once,
    # so give systemd a ceiling a few times above the configured upload cap.
    MEMORY_MAX="$(( MAX_UPLOAD * 4 ))M"

    # ProtectHome would hide a serve directory that lives under /home or /root.
    PROTECT_HOME="ProtectHome=true"
    case $SERVE_DIR in /home/*|/root/*) PROTECT_HOME="ProtectHome=read-only" ;; esac

    # Validate / create run user
    if ! id -u "$RUN_USER" &>/dev/null; then
        cyan "Creating system user '$RUN_USER'..."
        useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
    fi

    # Create directories
    cyan "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$SERVE_DIR"
    chown "$RUN_USER":"$RUN_USER" "$SERVE_DIR"
    chmod 755 "$SERVE_DIR"

    # ── auth token ────────────────────────────────────────────────────────────
    if [[ -z "$TOKEN" ]]; then
        if command -v openssl &>/dev/null; then
            TOKEN=$(openssl rand -hex 24)
        else
            TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
    fi
    printf 'FS_TOKEN=%s\n' "$TOKEN" > "$INSTALL_DIR/.fs_token"
    chown root:root "$INSTALL_DIR/.fs_token"
    chmod 600 "$INSTALL_DIR/.fs_token"

    # ── write Python server ───────────────────────────────────────────────────
    cyan "Writing server..."
    cat > "$INSTALL_DIR/serve.py" << 'PYEOF'
#!/usr/bin/env python3
"""fileserver — minimal HTTP file server with web UI, upload, and download tracking."""

import argparse
import base64
import hmac
import http.server
import ipaddress
import json
import mimetypes
import os
import re
import sys
import tempfile
import threading
import time
import urllib.parse
from email import policy
from email.parser import BytesParser
from http import HTTPStatus

STATS_FILE = ".fs_stats.json"
_stats_lock = threading.Lock()

MAX_UPLOAD_BYTES = 512 * 1024 * 1024  # 512 MiB
AUTH_WINDOW = 60
AUTH_MAX_FAILURES = 5
SOCKET_TIMEOUT = 60


def parse_size(value):
    """Parse a byte count with an optional k/m/g suffix."""
    m = re.fullmatch(r"\s*(\d+)\s*([kmgKMG]?)\s*", str(value))
    if not m:
        raise argparse.ArgumentTypeError(f"invalid size: {value!r}")
    scale = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[m.group(2).lower()]
    size = int(m.group(1)) * scale
    if size <= 0:
        raise argparse.ArgumentTypeError("size must be greater than zero")
    return size


# ── stats persistence ─────────────────────────────────────────────────────────

def load_stats(serve_dir):
    p = os.path.join(serve_dir, STATS_FILE)
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"files": {}, "total_downloads": 0, "total_bytes": 0}


def save_stats(serve_dir, stats):
    p = os.path.join(serve_dir, STATS_FILE)
    with open(p, "w") as f:
        json.dump(stats, f)


def record_download(serve_dir, filename, filesize):
    with _stats_lock:
        stats = load_stats(serve_dir)
        entry = stats["files"].get(filename, {"count": 0, "bytes": 0, "last": 0})
        entry["count"] += 1
        entry["bytes"] += filesize
        entry["last"] = int(time.time())
        stats["files"][filename] = entry
        stats["total_downloads"] = stats.get("total_downloads", 0) + 1
        stats["total_bytes"] = stats.get("total_bytes", 0) + filesize
        save_stats(serve_dir, stats)


# ── HTML UI ───────────────────────────────────────────────────────────────────

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fileserver</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#080808;--surface:#111;--surface2:#161616;
  --border:#202020;--border-dim:#181818;
  --text:#d4d4d4;--muted:#4a4a4a;--muted2:#666;
  --accent:#3ddc97;--accent-dim:rgba(61,220,151,.1);--accent-glow:rgba(61,220,151,.25);
  --red:#ff5f5f;--font:'IBM Plex Mono',monospace
}
html,body{height:100%}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:13px;line-height:1.5}

/* header */
header{
  border-bottom:1px solid var(--border);
  padding:14px 24px;
  display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap
}
.logo{font-size:14px;font-weight:600;color:var(--accent);letter-spacing:.06em}
.logo em{color:var(--muted2);font-style:normal;font-weight:400}
.stats-bar{display:flex;gap:28px;flex-wrap:wrap}
.stat{display:flex;flex-direction:column;align-items:flex-end}
.stat-value{font-size:16px;font-weight:600;color:var(--text);line-height:1.2}
.stat-label{font-size:9px;color:var(--muted2);text-transform:uppercase;letter-spacing:.12em;margin-top:1px}

/* upload zone */
.upload-wrap{padding:20px 24px 0}
.upload-zone{
  border:1px dashed var(--border);border-radius:3px;
  padding:18px 24px;cursor:pointer;
  transition:border-color .15s,background .15s;
  position:relative;text-align:center
}
.upload-zone:hover,.upload-zone.over{border-color:var(--accent);background:var(--accent-dim)}
.upload-zone input{position:absolute;inset:0;opacity:0;cursor:pointer;width:100%;height:100%}
.upload-hint{color:var(--muted2);font-size:12px}
.upload-hint strong{color:var(--accent);font-weight:500}
.upload-progress{display:none;margin-top:10px}
.upload-status{font-size:11px;color:var(--muted2)}
.pbar{height:1px;background:var(--border);border-radius:1px;margin-top:6px;overflow:hidden}
.pbar-fill{height:100%;background:var(--accent);width:0%;transition:width .2s}

/* file table */
.table-wrap{padding:20px 24px 32px}
.table-head-row{display:flex;align-items:center;justify-content:space-between;margin-bottom:10px}
.section-label{font-size:9px;text-transform:uppercase;letter-spacing:.14em;color:var(--muted)}
.refresh-btn{
  background:none;border:none;color:var(--muted2);cursor:pointer;
  font-family:var(--font);font-size:11px;padding:2px 6px;border-radius:2px;
  transition:color .15s
}
.refresh-btn:hover{color:var(--accent)}
table{width:100%;border-collapse:collapse}
thead th{
  text-align:left;font-size:9px;text-transform:uppercase;letter-spacing:.12em;
  color:var(--muted);padding:6px 8px;border-bottom:1px solid var(--border);font-weight:500
}
thead th:last-child{text-align:right}
tbody tr{border-bottom:1px solid var(--border-dim);transition:background .1s}
tbody tr:hover{background:var(--surface)}
tbody td{padding:9px 8px;vertical-align:middle}

/* file name cell */
.fname{display:flex;align-items:center;gap:8px;min-width:0}
.fext{
  flex-shrink:0;font-size:9px;font-weight:600;letter-spacing:.06em;
  padding:2px 5px;border-radius:2px;background:var(--border);color:var(--muted2);
  text-transform:uppercase
}
.fbase{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:240px}

/* other cells */
.fsize{color:var(--muted2);font-size:12px;white-space:nowrap}
.fdl{font-size:12px;color:var(--muted);white-space:nowrap}
.fdl.active{color:var(--accent)}
.flast{color:var(--muted);font-size:11px;white-space:nowrap}

/* download button */
.dl-btn{
  float:right;background:none;border:1px solid var(--border);
  color:var(--muted2);padding:4px 14px;border-radius:2px;
  cursor:pointer;font-family:var(--font);font-size:11px;font-weight:500;
  text-decoration:none;display:inline-block;transition:all .15s;
  letter-spacing:.04em
}
.dl-btn:hover{border-color:var(--accent);color:var(--accent);background:var(--accent-dim)}

.empty{text-align:center;padding:48px;color:var(--muted2);font-size:12px}

/* toast */
.toast{
  position:fixed;bottom:20px;right:20px;background:var(--surface2);
  border:1px solid var(--border);border-left:3px solid var(--accent);
  padding:9px 14px;border-radius:3px;font-size:12px;
  opacity:0;transform:translateY(8px);transition:all .2s ease;
  pointer-events:none;max-width:300px;z-index:100
}
.toast.show{opacity:1;transform:translateY(0)}
.toast.err{border-left-color:var(--red)}
</style>
</head>
<body>

<header>
  <div class="logo">fs<em>://</em>server</div>
  <div class="stats-bar">
    <div class="stat">
      <span class="stat-value" id="s-files">—</span>
      <span class="stat-label">files</span>
    </div>
    <div class="stat">
      <span class="stat-value" id="s-dls">—</span>
      <span class="stat-label">downloads</span>
    </div>
    <div class="stat">
      <span class="stat-value" id="s-bytes">—</span>
      <span class="stat-label">served</span>
    </div>
  </div>
</header>

<div class="upload-wrap">
  <div class="upload-zone" id="zone">
    <input type="file" id="finput" multiple>
    <div class="upload-hint"><strong>click to upload</strong>&nbsp;&nbsp;or drag files here</div>
    <div class="upload-progress" id="uprog">
      <div class="upload-status" id="ustatus">uploading…</div>
      <div class="pbar"><div class="pbar-fill" id="pfill"></div></div>
    </div>
  </div>
</div>

<div class="table-wrap">
  <div class="table-head-row">
    <span class="section-label">files</span>
    <button class="refresh-btn" onclick="load()">&#8635; refresh</button>
  </div>
  <table>
    <thead>
      <tr>
        <th>name</th>
        <th>size</th>
        <th>downloads</th>
        <th>last download</th>
        <th></th>
      </tr>
    </thead>
    <tbody id="tbody"></tbody>
  </table>
</div>

<div class="toast" id="toast"></div>

<script>
const $ = id => document.getElementById(id);

function fmtSize(b) {
  if (!b) return '0 B';
  const u = ['B','KB','MB','GB','TB'];
  const i = Math.min(Math.floor(Math.log(b) / Math.log(1024)), 4);
  return (b / Math.pow(1024, i)).toFixed(i ? 1 : 0) + ' ' + u[i];
}

function fmtAge(ts) {
  if (!ts) return '—';
  const s = Math.floor((Date.now() / 1000) - ts);
  if (s < 60)    return 'just now';
  if (s < 3600)  return Math.floor(s/60)   + 'm ago';
  if (s < 86400) return Math.floor(s/3600) + 'h ago';
  return Math.floor(s/86400) + 'd ago';
}

function esc(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function getExt(name) {
  const i = name.lastIndexOf('.');
  return i > 0 ? name.slice(i+1).toLowerCase() : '';
}

function toast(msg, err=false) {
  const t = $('toast');
  t.textContent = msg;
  t.className = 'toast show' + (err ? ' err' : '');
  clearTimeout(t._t);
  t._t = setTimeout(() => t.className = 'toast', 3200);
}

async function load() {
  try {
    const [fr, sr] = await Promise.all([
      fetch('/api/files').then(r => r.json()),
      fetch('/api/stats').then(r => r.json()),
    ]);
    const files = fr.files || [];
    $('s-files').textContent  = files.length;
    $('s-dls').textContent    = (sr.total_downloads || 0).toLocaleString();
    $('s-bytes').textContent  = fmtSize(sr.total_bytes || 0);

    const tb = $('tbody');
    if (!files.length) {
      tb.innerHTML = '<tr><td colspan="5"><div class="empty">no files yet — upload something</div></td></tr>';
      return;
    }
    tb.innerHTML = files.map(f => {
      const e  = getExt(f.name);
      const base = e ? esc(f.name.slice(0, -(e.length+1))) : esc(f.name);
      const extBadge = e ? '<span class="fext">'+esc(e)+'</span>' : '';
      const dlClass = f.downloads > 0 ? ' active' : '';
      return '<tr>'
        + '<td><div class="fname">'+extBadge+'<span class="fbase" title="'+esc(f.name)+'">'+base+'</span></div></td>'
        + '<td><span class="fsize">'+fmtSize(f.size)+'</span></td>'
        + '<td><span class="fdl'+dlClass+'">'+f.downloads+'&times;</span></td>'
        + '<td><span class="flast">'+fmtAge(f.last_download)+'</span></td>'
        + '<td><a class="dl-btn" href="/dl/'+encodeURIComponent(f.name)+'">&#8595; download</a></td>'
        + '</tr>';
    }).join('');
  } catch(e) {
    toast('failed to load files', true);
  }
}

// ── upload ────────────────────────────────────────────────────────────────────
const zone = $('zone'), finput = $('finput');

zone.addEventListener('dragover',  e => { e.preventDefault(); zone.classList.add('over'); });
zone.addEventListener('dragleave', () => zone.classList.remove('over'));
zone.addEventListener('drop', e => {
  e.preventDefault();
  zone.classList.remove('over');
  upload(e.dataTransfer.files);
});
finput.addEventListener('change', () => upload(finput.files));

async function upload(files) {
  if (!files.length) return;
  const prog = $('uprog'), fill = $('pfill'), status = $('ustatus');
  prog.style.display = 'block';
  let ok = 0;
  for (let i = 0; i < files.length; i++) {
    const f = files[i];
    status.textContent = 'uploading ' + f.name + '…';
    fill.style.width = (i / files.length * 100) + '%';
    const fd = new FormData();
    fd.append('file', f);
    try {
      const r = await fetch('/upload', { method:'POST', body:fd });
      const d = await r.json();
      if (!r.ok) throw new Error(d.error || 'upload failed');
      ok++;
    } catch(e) {
      toast(f.name + ': ' + e.message, true);
    }
  }
  fill.style.width = '100%';
  setTimeout(() => { prog.style.display='none'; fill.style.width='0%'; finput.value=''; }, 500);
  if (ok) toast(ok + ' file' + (ok>1?'s':'') + ' uploaded');
  load();
}

load();
</script>
</body>
</html>"""


# ── HTTP handler ──────────────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):
    serve_dir = "."
    token = None
    allowed_hosts = frozenset()
    max_upload = MAX_UPLOAD_BYTES
    timeout = SOCKET_TIMEOUT
    _auth_failures = {}
    _auth_lock = threading.Lock()

    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}", flush=True)

    # ── authentication ────────────────────────────────────────────────────────

    def _check_auth(self):
        if self.token is None:
            return True      # only reachable when started with --no-auth
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return False
        try:
            cred = base64.b64decode(auth[6:].strip(), validate=True)
            cred = cred.decode("utf-8")
        except Exception:
            return False
        if ":" not in cred:
            return False
        _, password = cred.split(":", 1)
        # Compare bytes: compare_digest raises TypeError on non-ASCII str.
        return hmac.compare_digest(password.encode("utf-8"), self.token.encode("utf-8"))

    # ── request origin ────────────────────────────────────────────────────────

    def _hostname_allowed(self, host):
        """Accept an allow-listed name, a literal IP, or nothing else."""
        if not host:
            return False
        if host.startswith("["):
            name = host.partition("]")[0][1:]          # [::1]:8080 -> ::1
        else:
            name = host.rsplit(":", 1)[0] if ":" in host else host
        name = name.strip().lower().rstrip(".")
        if not name:
            return False
        if name in self.allowed_hosts:
            return True
        try:
            ipaddress.ip_address(name)
        except ValueError:
            return False
        # A literal IP cannot be reached by DNS rebinding, so it is safe to take.
        return True

    def _origin_ok(self):
        """Reject cross-site browser requests, which carry cookies/credentials."""
        site = self.headers.get("Sec-Fetch-Site", "").lower()
        if site and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        if origin:
            if origin == "null":
                return False
            try:
                host = urllib.parse.urlsplit(origin).hostname or ""
            except ValueError:
                return False
            if not self._hostname_allowed(host):
                return False
        return True

    def _guard_request(self):
        host = self.headers.get("Host", "")
        if not self._hostname_allowed(host):
            self.log_error("rejected Host %r", host)
            self.send_json({"error": "Host not allowed. Pass --allow-host <name> to "
                                     "permit it, or connect using an IP address."}, 403)
            return False
        if not self._origin_ok():
            self.log_error("rejected cross-site request")
            self.send_json({"error": "Cross-site request rejected."}, 403)
            return False
        return True

    def _auth_failures_for(self, ip):
        now = time.time()
        with self._auth_lock:
            recent = [t for t in self._auth_failures.get(ip, []) if now - t < AUTH_WINDOW]
            self._auth_failures[ip] = recent
            return len(recent)

    def _record_auth_failure(self, ip):
        with self._auth_lock:
            self._auth_failures.setdefault(ip, []).append(time.time())

    def _require_auth(self):
        ip = self.client_address[0]
        if self._auth_failures_for(ip) >= AUTH_MAX_FAILURES:
            self.send_json({"error": "Too many failed attempts. Try again later."}, 429)
            return False
        if self._check_auth():
            return True
        self._record_auth_failure(ip)
        body = json.dumps({"error": "Unauthorized"}).encode()
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="fileserver"')
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)
        return False

    def send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._guard_request():
            return
        if not self._require_auth():
            return
        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        if path == "/":
            self._serve_html()
        elif path == "/api/files":
            self._api_files()
        elif path == "/api/stats":
            self._api_stats()
        elif path.startswith("/dl/"):
            self._download(urllib.parse.unquote(path[4:]))
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self._guard_request():
            return
        if not self._require_auth():
            return
        if self.path == "/upload":
            self._upload()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def _serve_html(self):
        body = HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _api_files(self):
        stats = load_stats(self.serve_dir)
        files = []
        try:
            for entry in sorted(os.scandir(self.serve_dir), key=lambda e: e.name.lower()):
                if entry.name.startswith(".") or not entry.is_file(follow_symlinks=False):
                    continue
                st = entry.stat(follow_symlinks=False)
                fs = stats["files"].get(entry.name, {})
                files.append({
                    "name":          entry.name,
                    "size":          st.st_size,
                    "mtime":         int(st.st_mtime),
                    "downloads":     fs.get("count", 0),
                    "bytes_served":  fs.get("bytes", 0),
                    "last_download": fs.get("last", 0),
                })
        except OSError as e:
            self.log_error("listing %s failed: %s", self.serve_dir, e)
            self.send_json({"error": "Failed to list files."}, 500)
            return
        self.send_json({"files": files})

    def _api_stats(self):
        stats = load_stats(self.serve_dir)
        self.send_json({
            "total_downloads": stats.get("total_downloads", 0),
            "total_bytes":     stats.get("total_bytes", 0),
        })

    def _download(self, filename):
        filename = filename.replace("\r", "").replace("\n", "").replace('"', "")
        if (not filename or "\x00" in filename
                or any(p.startswith(".") for p in filename.split("/"))):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            filepath = os.path.realpath(os.path.join(self.serve_dir, filename))
            root     = os.path.realpath(self.serve_dir)
            if not (filepath.startswith(root + os.sep) or filepath == root):
                self.send_error(HTTPStatus.FORBIDDEN)
                return
            if not os.path.isfile(filepath):
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            filesize = os.path.getsize(filepath)
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        record_download(self.serve_dir, filename, filesize)
        mime, _ = mimetypes.guess_type(filename)
        mime = mime or "application/octet-stream"
        # Header values are latin-1, so a non-latin-1 filename would raise here.
        # Send an ASCII fallback plus the RFC 5987 form.
        fallback = re.sub(r"[^A-Za-z0-9._ -]", "_",
                          filename.encode("ascii", "ignore").decode("ascii")).strip()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", filesize)
        self.send_header("Content-Disposition",
                         f"attachment; filename=\"{fallback or 'download'}\"; "
                         f"filename*=UTF-8''{urllib.parse.quote(filename, safe='')}")
        self.end_headers()
        with open(filepath, "rb") as f:
            while chunk := f.read(65536):
                self.wfile.write(chunk)

    def _upload(self):
        ct = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ct:
            self.send_json({"error": "Expected multipart/form-data"}, 400)
            return
        boundary = None
        for part in ct.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = part[9:].strip('"')
                break
        if not boundary:
            self.send_json({"error": "No boundary"}, 400)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            self.send_json({"error": "Invalid Content-Length"}, 400)
            return
        if length <= 0:
            self.send_json({"error": "Empty request body"}, 400)
            return
        if length > self.max_upload:
            self.send_json({"error": f"Upload too large (max {self.max_upload} bytes)"}, 413)
            return
        try:
            body = self.rfile.read(length)
        except TimeoutError:
            raise        # let the handler drop this connection
        except Exception:
            self.send_json({"error": "Failed to read request body"}, 400)
            return
        if len(body) > self.max_upload:
            self.send_json({"error": "Upload too large"}, 413)
            return

        saved = []
        try:
            msg = BytesParser(policy=policy.default).parsebytes(
                b"Content-Type: multipart/form-data; boundary=" + boundary.encode() + b"\r\n\r\n" + body
            )
            for part in msg.iter_parts():
                filename = part.get_filename()
                data = part.get_payload(decode=True)
                if not filename or not data:
                    continue
                filename = os.path.basename(filename)
                if not filename or filename.startswith("."):
                    continue
                target = os.path.join(self.serve_dir, filename)
                fd, tmp = tempfile.mkstemp(dir=self.serve_dir, prefix=".upload-", suffix=".tmp")
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                os.replace(tmp, target)
                saved.append(filename)
        except Exception as e:
            self.log_error("upload failed: %s", e)
            self.send_json({"error": "Upload failed."}, 400)
            return
        if saved:
            self.send_json({"saved": saved})
        else:
            self.send_json({"error": "No files saved"}, 400)


# ── entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="fileserver")
    parser.add_argument("--port",  "-p", type=int, default=8080)
    parser.add_argument("--dir",   "-d",           default=".")
    parser.add_argument("--bind",  "-b",           default="127.0.0.1")
    parser.add_argument("--token", "-t",           default=os.environ.get("FS_TOKEN", ""))
    parser.add_argument("--allow-host", action="append", default=[], metavar="HOST",
                        help="extra Host header value to accept (repeatable)")
    parser.add_argument("--max-upload", type=parse_size, default=MAX_UPLOAD_BYTES,
                        metavar="SIZE", help="maximum upload size, e.g. 512m or 1g")
    parser.add_argument("--no-auth", action="store_true",
                        help="disable authentication entirely (not recommended)")
    args = parser.parse_args()

    serve_dir = os.path.abspath(args.dir)
    if not os.path.isdir(serve_dir):
        print(f"Error: '{serve_dir}' is not a directory.")
        sys.exit(1)

    # Fail closed: an unset token is a configuration error, not a free pass.
    if args.no_auth:
        token = None
    elif args.token:
        token = args.token
    else:
        print("Error: no auth token. Pass --token, set FS_TOKEN, or pass")
        print("       --no-auth to run without authentication.")
        sys.exit(1)

    allowed = {"localhost", "::1"}
    if args.bind not in ("0.0.0.0", "::"):
        allowed.add(args.bind.lower())
    allowed.update(h.strip().lower() for h in args.allow_host if h.strip())

    Handler.serve_dir = serve_dir
    Handler.token = token
    Handler.allowed_hosts = frozenset(allowed)
    Handler.max_upload = args.max_upload
    server = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)

    print(f"Serving : {serve_dir}")
    print(f"Endpoint: http://{args.bind}:{args.port}/")
    print(f"Max upl : {args.max_upload // (1024 * 1024)} MiB")
    print("Hosts   : " + ", ".join(sorted(allowed)) + " (and any bare IP)")
    if token is None:
        print("Auth    : DISABLED via --no-auth")
    else:
        print("Auth    : enabled (HTTP Basic)")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")

if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$INSTALL_DIR/serve.py"
    chown root:root "$INSTALL_DIR/serve.py"

    # ── write systemd service ─────────────────────────────────────────────────
    cyan "Creating systemd service..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=fileserver — HTTP file server with web UI
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
# No leading '-' : the service must refuse to start without its token.
EnvironmentFile=${INSTALL_DIR}/.fs_token
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/serve.py --port ${PORT} --dir ${SERVE_DIR} --bind ${BIND} --max-upload ${MAX_UPLOAD}m${ALLOW_HOST_ARGS}
Restart=on-failure
RestartSec=5
# Hardening
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
${PROTECT_HOME}
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
ReadWritePaths=${SERVE_DIR}
MemoryMax=${MEMORY_MAX}
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF

    # ── enable + start ────────────────────────────────────────────────────────
    cyan "Enabling and starting service..."
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    # ── done ──────────────────────────────────────────────────────────────────
    echo
    green "✓ fileserver installed and running."
    echo
    bold "  Serve directory : $SERVE_DIR"
    bold "  Port            : $PORT"
    bold "  Bind            : $BIND"
    bold "  Service user    : $RUN_USER"
    bold "  Max upload      : ${MAX_UPLOAD} MiB"
    bold "  Extra hosts     : ${ALLOW_HOSTS[*]:-<none>}"
    bold "  Python script   : $INSTALL_DIR/serve.py"
    bold "  Service file    : $SERVICE_FILE"
    echo
    cyan "  Auth token      : $TOKEN"
    cyan "  Authenticate with: curl -u :$TOKEN http://<host>:${PORT}/"
    echo
    cyan "  Open: http://$(hostname -I | awk '{print $1}'):${PORT}/"
    if [[ $BIND == 0.0.0.0 ]]; then
        echo
        red  "  WARNING: bound to 0.0.0.0 and serving plain HTTP. The token is"
        red  "           sent in cleartext on every request — use a TLS reverse"
        red  "           proxy (see README) instead of exposing this directly."
    fi
    if [[ -z $ALLOW_HOST_ARGS ]]; then
        echo
        echo "  Note: requests are accepted by IP or as 'localhost'. If you put a"
        echo "        TLS proxy in front, re-run with --allow-host <your.domain>"
        echo "        or the proxy will get 403 responses."
    fi
    echo
    echo "  Useful commands:"
    echo "    systemctl status  $SERVICE_NAME"
    echo "    journalctl -fu    $SERVICE_NAME"
    echo "    systemctl restart $SERVICE_NAME"
    echo "    sudo $0 uninstall"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    install)   do_install   ;;
    uninstall) do_uninstall ;;
    *)         usage        ;;
esac
