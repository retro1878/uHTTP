#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# fileserver — install / update / status / uninstall script
# Usage:
#   sudo bash fileserver-install.sh install [--port PORT] [--dir DIR] [--user USER]
#                                           [--bind ADDR] [--token TOKEN]
#                                           [--allow-host HOST]... [--max-upload MiB]
#   sudo bash fileserver-install.sh update  [--force] [--dry-run]
#   sudo bash fileserver-install.sh status
#   sudo bash fileserver-install.sh uninstall
#
# `update` re-applies the serve.py and unit built into *this* script, keeping the
# deployed settings and auth token. It does no network I/O: re-run the README
# curl to fetch a newer script, then run `update` from it.
# ─────────────────────────────────────────────────────────────────────────────
set -e

VERSION="1.1.0"

INSTALL_DIR="/opt/fileserver"
SERVICE_NAME="fileserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${INSTALL_DIR}/.fs_config"
VERSION_FILE="${INSTALL_DIR}/.fs_version"
TOKEN_FILE="${INSTALL_DIR}/.fs_token"
BACKUP_DIR="${INSTALL_DIR}/backups"

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
    [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
}

usage() {
    bold "fileserver install script (v$VERSION)"
    echo
    echo "  sudo bash $0 install   [--port PORT] [--dir DIR] [--user USER]"
    echo "                         [--bind ADDR] [--token TOKEN]"
    echo "                         [--allow-host HOST]... [--max-upload MiB]"
    echo "  sudo bash $0 update    [--force] [--dry-run]"
    echo "  sudo bash $0 status"
    echo "  sudo bash $0 uninstall"
    echo
    echo "  update applies the server and unit built into this script to an"
    echo "  existing install. Deployed settings and the auth token are kept."
    echo "  --force    re-apply even if the version already matches (or is newer)"
    echo "  --dry-run  show what update would change, then stop"
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

# Left unset on purpose: install fills in the defaults, update reads the
# deployed values off disk, and an empty value here is how update detects a
# setting passed on the command line (which update does not accept).
PORT=""
SERVE_DIR=""
RUN_USER=""
BIND=""
TOKEN=""
MAX_UPLOAD=""
ALLOW_HOSTS=()
FORCE=0
DRY_RUN=0

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
        --force)      FORCE=1;          shift ;;
        --dry-run)    DRY_RUN=1;        shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
    require_root

    # Best-effort only, for the closing note: uninstall must still work on a
    # broken install, so this reads the config without validating it.
    local deployed_dir="$DEFAULT_DIR"
    if [[ -f $CONFIG_FILE ]]; then
        deployed_dir=$(grep -m1 '^SERVE_DIR=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    [[ -n $deployed_dir ]] || deployed_dir="$DEFAULT_DIR"

    cyan "Stopping and disabling service..."
    systemctl stop  "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    cyan "Removing service file..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    cyan "Removing install directory..."
    rm -rf "$INSTALL_DIR"

    green "✓ fileserver uninstalled."
    echo  "  Serve directory $deployed_dir and its contents were NOT removed."
}

# ── validation ────────────────────────────────────────────────────────────────

# Applied to settings from the command line and, on update, to values read back
# off disk — so it never trusts its input.
validate_config() {
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
}

# Derived from the validated config, immediately before the unit is rendered.
prepare_unit_vars() {
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
}

# ── embedded server source ────────────────────────────────────────────────────

# Writes the Python server to $1. Install and update both call this, so the
# server the two ship can never drift apart.
write_serve_py() {
    local dest=$1
    cat > "$dest" << 'PYEOF'
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
}

# ── systemd unit ──────────────────────────────────────────────────────────────

# Renders the unit from the validated config to $1. Install and update share it.
render_unit() {
    local dest=$1
    cat > "$dest" << EOF
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
}

print_config() {
    bold "  Serve directory : $SERVE_DIR"
    bold "  Port            : $PORT"
    bold "  Bind            : $BIND"
    bold "  Service user    : $RUN_USER"
    bold "  Max upload      : ${MAX_UPLOAD} MiB"
    bold "  Extra hosts     : ${ALLOW_HOSTS[*]:-<none>}"
}

# ── config persistence ────────────────────────────────────────────────────────
#
# .fs_config is the single source of truth for a deployed instance; the unit is
# rendered from it. It is written 0600 root:root and read back with the strict
# parser below.

write_config() {
    local tmp="${CONFIG_FILE}.tmp"
    {
        printf 'PORT=%s\n'        "$PORT"
        printf 'SERVE_DIR=%s\n'   "$SERVE_DIR"
        printf 'RUN_USER=%s\n'    "$RUN_USER"
        printf 'BIND=%s\n'        "$BIND"
        printf 'MAX_UPLOAD=%s\n'  "$MAX_UPLOAD"
        printf 'ALLOW_HOSTS=%s\n' "${ALLOW_HOSTS[*]:-}"
    } > "$tmp"
    chown root:root "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# Deliberately does NOT `source` the file: this runs as root, so sourcing would
# execute whatever it happens to contain. Every value is also re-validated by
# validate_config() before it reaches the unit.
read_config() {
    [[ -f $CONFIG_FILE ]] || return 1

    local owner mode
    owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null || echo '?')
    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '?')
    [[ $owner == root && $mode == 600 ]] \
        || die "$CONFIG_FILE must be root-owned mode 600 (found ${owner}:${mode}); refusing to read it."

    PORT=""; SERVE_DIR=""; RUN_USER=""; BIND=""; MAX_UPLOAD=""; ALLOW_HOSTS=()

    local line key value
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line || $line == \#* ]]; then
            continue
        fi
        key=${line%%=*}
        value=${line#*=}
        case $key in
            PORT)        PORT=$value ;;
            SERVE_DIR)   SERVE_DIR=$value ;;
            RUN_USER)    RUN_USER=$value ;;
            BIND)        BIND=$value ;;
            MAX_UPLOAD)  MAX_UPLOAD=$value ;;
            ALLOW_HOSTS)
                ALLOW_HOSTS=()
                if [[ -n $value ]]; then
                    read -r -a ALLOW_HOSTS <<< "$value"
                fi
                ;;
            *) die "$CONFIG_FILE: unexpected key '$key'" ;;
        esac
    done < "$CONFIG_FILE"

    [[ -n $PORT && -n $SERVE_DIR && -n $RUN_USER && -n $BIND && -n $MAX_UPLOAD ]] \
        || die "$CONFIG_FILE is incomplete; fix it or re-run 'install'."
}

# One-time migration for installs that predate .fs_config. Anything that cannot
# be recovered is left empty for the caller to default, and reported.
migrate_config_from_unit() {
    local exec_line unit_user
    exec_line=$(grep -m1 '^ExecStart=' "$SERVICE_FILE" 2>/dev/null || true)
    [[ -n $exec_line ]] || return 1

    local -a argv=()
    read -r -a argv <<< "$exec_line"

    local i=1 arg
    while (( i < ${#argv[@]} )); do
        arg=${argv[i]}
        case $arg in
            --port)       PORT=${argv[i+1]:-} ;            i=$(( i + 2 )) ;;
            --dir)        SERVE_DIR=${argv[i+1]:-} ;       i=$(( i + 2 )) ;;
            --bind)       BIND=${argv[i+1]:-} ;            i=$(( i + 2 )) ;;
            --max-upload) MAX_UPLOAD=${argv[i+1]:-} ;      i=$(( i + 2 )) ;;
            --allow-host) ALLOW_HOSTS+=("${argv[i+1]:-}"); i=$(( i + 2 )) ;;
            *)            i=$(( i + 1 )) ;;
        esac
    done

    # The unit renders this as "<MiB>m", so store the bare integer.
    MAX_UPLOAD=${MAX_UPLOAD%[mMkKgG]}

    # User= is authoritative for the service user, not anything in ExecStart.
    unit_user=$(grep -m1 '^User=' "$SERVICE_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [[ -n $unit_user ]]; then
        RUN_USER=$unit_user
    fi

    return 0
}

# ── health check ──────────────────────────────────────────────────────────────

# 0.0.0.0 means "every IPv4 address", so probe loopback instead.
health_target() {
    case $BIND in
        0.0.0.0) echo "127.0.0.1" ;;
        ::|::0)  echo "[::1]" ;;
        *:*)     echo "[$BIND]" ;;
        *)       echo "$BIND" ;;
    esac
}

# Type=simple returns from `systemctl restart` before the socket is bound, so a
# single probe would race the bind and roll back good updates.
wait_healthy() {
    local target token i=0 tries=15
    target=$(health_target)
    token=$(cut -d= -f2- "$TOKEN_FILE" 2>/dev/null || true)

    if ! command -v curl &>/dev/null; then
        cyan "  curl not found — falling back to systemd state only."
        while (( i < tries )); do
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                return 0
            fi
            i=$(( i + 1 ))
            sleep 1
        done
        return 1
    fi

    while (( i < tries )); do
        # --fail matters: without it curl exits 0 on 401/403/500, which are
        # exactly the failures this is meant to catch.
        if systemctl is-active --quiet "$SERVICE_NAME" \
           && curl --fail --silent --show-error --max-time 5 \
                   -u ":${token}" "http://${target}:${PORT}/api/files" >/dev/null 2>&1; then
            return 0
        fi
        i=$(( i + 1 ))
        sleep 1
    done
    return 1
}

# True when version $1 is higher than version $2.
version_gt() {
    [[ $1 != "$2" ]] \
        && [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# ── install ───────────────────────────────────────────────────────────────────
do_install() {
    require_root

    # install is the only verb that takes settings; update preserves them.
    PORT=${PORT:-$DEFAULT_PORT}
    SERVE_DIR=${SERVE_DIR:-$DEFAULT_DIR}
    RUN_USER=${RUN_USER:-$DEFAULT_USER}
    BIND=${BIND:-$DEFAULT_BIND}
    MAX_UPLOAD=${MAX_UPLOAD:-$DEFAULT_MAX_UPLOAD}

    # Re-running install regenerates the auth token, which breaks every client.
    # Send that to 'update' instead, which exists precisely to avoid it.
    if [[ -f $SERVICE_FILE && $FORCE -eq 0 ]]; then
        die "'$SERVICE_NAME' is already installed. Use 'update' to apply this \
version without rotating the auth token, or 'install --force' to reinstall from scratch."
    fi

    validate_config
    prepare_unit_vars

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
    printf 'FS_TOKEN=%s\n' "$TOKEN" > "$TOKEN_FILE"
    chown root:root "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    # ── write server + unit ───────────────────────────────────────────────────
    # Same-directory temp then rename, so an interrupted run cannot leave a
    # truncated serve.py or a half-written unit behind.
    cyan "Writing server..."
    local tmp_py="${INSTALL_DIR}/.serve.py.new"
    write_serve_py "$tmp_py"
    chmod +x "$tmp_py"
    chown root:root "$tmp_py"
    mv -f "$tmp_py" "$INSTALL_DIR/serve.py"

    write_config

    cyan "Creating systemd service..."
    local tmp_unit="${SERVICE_FILE}.new"
    render_unit "$tmp_unit"
    chmod 644 "$tmp_unit"
    chown root:root "$tmp_unit"
    mv -f "$tmp_unit" "$SERVICE_FILE"

    # ── enable + start ────────────────────────────────────────────────────────
    cyan "Enabling and starting service..."
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    # Record the version only once the service is actually up, so a failed
    # install cannot make a later `update` believe it is already current.
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        printf '%s\n' "$VERSION" > "$VERSION_FILE"
        chmod 644 "$VERSION_FILE"
    else
        red "WARNING: $SERVICE_NAME is not active; version not recorded."
        echo "         Check: journalctl -u $SERVICE_NAME -n 50 --no-pager"
    fi

    # ── done ──────────────────────────────────────────────────────────────────
    echo
    green "✓ fileserver installed and running (v$VERSION)."
    echo
    print_config
    bold "  Python script   : $INSTALL_DIR/serve.py"
    bold "  Service file    : $SERVICE_FILE"
    bold "  Settings stored : $CONFIG_FILE"
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
    echo "    sudo $0 status"
    echo "    sudo $0 uninstall"
}

# ── update ────────────────────────────────────────────────────────────────────
do_update() {
    require_root
    command -v systemctl &>/dev/null || die "systemd is required for update."

    if [[ -n $PORT || -n $SERVE_DIR || -n $RUN_USER || -n $BIND || -n $MAX_UPLOAD \
          || ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
        die "update takes no settings — it keeps the deployed ones.
       Change them by editing $CONFIG_FILE and re-running update."
    fi

    [[ -f $INSTALL_DIR/serve.py ]] || die "Not installed: $INSTALL_DIR/serve.py is missing. Run 'install' first."
    [[ -f $SERVICE_FILE ]]         || die "Not installed: $SERVICE_FILE is missing. Run 'install' first."
    [[ -f $TOKEN_FILE ]]           || die "Auth token $TOKEN_FILE is missing; refusing to touch a broken install."

    # ── gather the deployed settings ─────────────────────────────────────────
    if read_config; then
        cyan "Settings read from $CONFIG_FILE"
    else
        cyan "No $CONFIG_FILE (installed before v1.1) — recovering from the unit"
        PORT=""; SERVE_DIR=""; RUN_USER=""; BIND=""; MAX_UPLOAD=""; ALLOW_HOSTS=()
        migrate_config_from_unit \
            || die "Could not read ExecStart= from $SERVICE_FILE."
        local fell_back=""
        if [[ -z $PORT ]]; then       PORT=$DEFAULT_PORT;           fell_back+=" port"; fi
        if [[ -z $SERVE_DIR ]]; then  SERVE_DIR=$DEFAULT_DIR;       fell_back+=" dir"; fi
        if [[ -z $RUN_USER ]]; then   RUN_USER=$DEFAULT_USER;       fell_back+=" user"; fi
        if [[ -z $BIND ]]; then       BIND=$DEFAULT_BIND;           fell_back+=" bind"; fi
        if [[ -z $MAX_UPLOAD ]]; then MAX_UPLOAD=$DEFAULT_MAX_UPLOAD; fell_back+=" max-upload"; fi
        if [[ -n $fell_back ]]; then
            red "WARNING: not present in the unit, defaulting:${fell_back}"
        fi
    fi

    validate_config
    prepare_unit_vars

    # ── version gate ─────────────────────────────────────────────────────────
    local deployed=""
    if [[ -f $VERSION_FILE ]]; then
        deployed=$(tr -d '[:space:]' < "$VERSION_FILE")
    fi

    if [[ -z $deployed ]]; then
        cyan "Deployed version unrecorded (installed before v1.1); proceeding."
    elif [[ $deployed == "$VERSION" ]]; then
        if [[ $FORCE -eq 0 ]]; then
            green "✓ Already up to date (version $VERSION)."
            echo  "  Use --force to re-apply anyway."
            return 0
        fi
        cyan "Re-applying version $VERSION (--force)."
    elif version_gt "$deployed" "$VERSION" && [[ $FORCE -eq 0 ]]; then
        die "Deployed version $deployed is newer than this script ($VERSION).
       Refusing to downgrade; pass --force if that is really what you want."
    fi

    # ── dry run ──────────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 1 ]]; then
        bold "Dry run — nothing will be changed."
        echo
        print_config
        echo
        echo  "  Deployed version : ${deployed:-<unrecorded>}"
        echo  "  Script version   : $VERSION"
        echo
        echo  "  Would back up   $INSTALL_DIR/serve.py and $SERVICE_FILE"
        echo  "                  to $BACKUP_DIR/"
        echo  "  Would rewrite   both from this script (v$VERSION)"
        echo  "  Would restart   $SERVICE_NAME and verify it answers /api/files"
        echo  "  Token           $TOKEN_FILE left untouched"
        return 0
    fi

    # ── back up ──────────────────────────────────────────────────────────────
    # Not under $SERVE_DIR: that is ReadWritePaths= and owned by the service
    # user, which would let the server read or tamper with its own rollback.
    local stamp backup
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$BACKUP_DIR/${deployed:-unknown}-$stamp"
    mkdir -p "$backup"
    cp -p "$INSTALL_DIR/serve.py" "$backup/serve.py"
    cp -p "$SERVICE_FILE"         "$backup/${SERVICE_NAME}.service"
    printf '%s\n' "${deployed:-unknown}" > "$backup/version"
    chmod -R go-rwx "$BACKUP_DIR"
    cyan "Backed up to $backup"

    # Warn about unit directives we do not manage, so a hand-tuned setting is
    # not reverted silently. It stays recoverable from the backup either way.
    local extra
    extra=$(grep -vE '^(#|$|\[Unit\]|\[Service\]|\[Install\]|Description=|After=|Type=|User=|Group=|EnvironmentFile=|ExecStart=|Restart=|RestartSec=|PrivateTmp=|NoNewPrivileges=|ProtectSystem=|ProtectHome=|PrivateDevices=|ProtectKernelTunables=|ProtectKernelModules=|ProtectControlGroups=|RestrictNamespaces=|RestrictRealtime=|RestrictAddressFamilies=|LockPersonality=|ReadWritePaths=|MemoryMax=|TasksMax=|WantedBy=)' "$SERVICE_FILE" || true)
    if [[ -n $extra ]]; then
        red "WARNING: $SERVICE_FILE has directives this version does not manage:"
        printf '%s\n' "$extra" | sed 's/^/    /'
        echo "  They are in the backup but will not be in the regenerated unit."
    fi

    # ── apply ────────────────────────────────────────────────────────────────
    # The service user and serve directory may have been removed since install.
    if ! id -u "$RUN_USER" &>/dev/null; then
        cyan "Re-creating system user '$RUN_USER'..."
        useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
    fi
    mkdir -p "$SERVE_DIR"
    chown "$RUN_USER":"$RUN_USER" "$SERVE_DIR"

    cyan "Writing server v$VERSION..."
    local tmp_py="${INSTALL_DIR}/.serve.py.new"
    write_serve_py "$tmp_py"
    chmod +x "$tmp_py"
    chown root:root "$tmp_py"
    mv -f "$tmp_py" "$INSTALL_DIR/serve.py"

    write_config

    local tmp_unit="${SERVICE_FILE}.new"
    render_unit "$tmp_unit"
    chmod 644 "$tmp_unit"
    chown root:root "$tmp_unit"
    mv -f "$tmp_unit" "$SERVICE_FILE"

    cyan "Restarting $SERVICE_NAME..."
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" || true

    # ── verify, or roll back ─────────────────────────────────────────────────
    if wait_healthy; then
        # Stamped last: a crash before this point must not leave a version
        # recorded that would make the next update a no-op on a broken deploy.
        printf '%s\n' "$VERSION" > "$VERSION_FILE"
        chmod 644 "$VERSION_FILE"
        echo
        green "✓ Updated to v$VERSION (was ${deployed:-unrecorded})."
        echo "  Auth token unchanged; clients keep working."
        echo "  Backup: $backup"
        return 0
    fi

    red "✗ v$VERSION did not come up healthy. Rolling back..."
    cp -p "$backup/serve.py" "$INSTALL_DIR/serve.py"
    cp -p "$backup/${SERVICE_NAME}.service" "$SERVICE_FILE"
    systemctl daemon-reload || true
    systemctl restart "$SERVICE_NAME" || true
    echo
    red  "Rolled back to ${deployed:-the previous version}."
    echo "  Backup kept at: $backup"
    echo "  Logs:           journalctl -u $SERVICE_NAME -n 50 --no-pager"
    exit 1
}

# ── status ────────────────────────────────────────────────────────────────────
do_status() {
    require_root
    bold "fileserver status"
    echo

    local deployed=""
    if [[ -f $VERSION_FILE ]]; then
        deployed=$(tr -d '[:space:]' < "$VERSION_FILE")
    fi

    echo "  Script version  : $VERSION"
    if [[ -z $deployed ]]; then
        red "  Deployed version: unrecorded (installed before v1.1)"
    elif [[ $deployed == "$VERSION" ]]; then
        green "  Deployed version: $deployed (up to date)"
    elif version_gt "$deployed" "$VERSION"; then
        cyan "  Deployed version: $deployed (newer than this script)"
    else
        cyan "  Deployed version: $deployed (update available)"
    fi
    echo

    if command -v systemctl &>/dev/null; then
        local active enabled
        active=$(systemctl is-active  "$SERVICE_NAME" 2>/dev/null || true)
        enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)
        echo "  Service         : ${active:-unknown} / ${enabled:-unknown}"
    fi
    if [[ -f $INSTALL_DIR/serve.py ]]; then
        echo "  Server script   : $INSTALL_DIR/serve.py"
    else
        red "  Server script   : MISSING ($INSTALL_DIR/serve.py)"
    fi
    if [[ -f $SERVICE_FILE ]]; then
        echo "  Unit file       : $SERVICE_FILE"
    else
        red "  Unit file       : MISSING ($SERVICE_FILE)"
    fi

    # Never print the token itself — only whether it is there and who can read it.
    if [[ -f $TOKEN_FILE ]]; then
        echo "  Auth token      : set, $(stat -c '%U:%G %a' "$TOKEN_FILE" 2>/dev/null || echo 'perms unknown') (value not shown)"
    else
        red "  Auth token      : MISSING — the service cannot start without it"
    fi
    echo

    if read_config; then
        echo "  Settings from $CONFIG_FILE:"
        print_config
    else
        echo "  Settings        : $CONFIG_FILE not found (run 'update' to migrate)"
    fi

    local latest=""
    if [[ -d $BACKUP_DIR ]]; then
        latest=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
                     -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)
    fi
    if [[ -n $latest ]]; then
        echo
        echo "  Latest backup   : ${latest%/}"
    fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    install)   do_install   ;;
    update)    do_update    ;;
    status)    do_status    ;;
    uninstall) do_uninstall ;;
    *)         usage        ;;
esac
