# uHTTP

minimal HTTP file server — upload, browse, download.

```sh
curl -fsSL https://raw.githubusercontent.com/retro1878/uHTTP/main/fileserver-install.sh -o fileserver-install.sh
```

```sh
chmod +x fileserver-install.sh
```

```sh
# install with defaults (port 8080, /srv/fileserver, www-data, localhost-only,
# auto-generated auth token, 512 MiB upload limit)
sudo ./fileserver-install.sh install
```

```sh
# custom port, directory, service user, and token
sudo ./fileserver-install.sh install --port 9000 --dir /opt/files --user nobody --token "$(openssl rand -hex 24)"
```

```sh
# reachable from the LAN: bind to an address and raise the upload limit
sudo ./fileserver-install.sh install --bind 192.168.1.5 --max-upload 2048
```

```sh
# remove service and install dir (leaves your files intact)
sudo ./fileserver-install.sh uninstall
```

no dependencies beyond python3 and systemd.

## web ui

`http://<host>:8080/` serves the browse/upload page — a table of files with size,
download count and last-download time, plus click-or-drag upload. every route is
behind the token, so the browser asks for credentials before the page loads.

## auth

the installer generates a random token on install (or use `--token`) and prints it at the end.
all routes require http basic auth — the password is the token, the username is ignored.

```sh
curl -u :TOKEN http://localhost:8080/api/files
```

the browser prompts for a username/password the first time — enter anything as the username and the token as the password.

if the token file is missing the service refuses to start rather than coming up
without authentication. running `serve.py` by hand needs `--token`, `FS_TOKEN`,
or an explicit `--no-auth`.

## network exposure

the server binds to `127.0.0.1` (localhost only) by default.
pass `--bind 0.0.0.0` at install to listen on all interfaces.

requests are only accepted when the `Host` header is `localhost` or a bare IP
address — anything else gets a `403`. that stops a malicious page from reaching a
localhost server via DNS rebinding. if you reach the server by hostname, including
through a reverse proxy, name it at install time:

```sh
sudo ./fileserver-install.sh install --bind 0.0.0.0 --allow-host files.example.com
```

`--allow-host` is repeatable. cross-site browser requests (per `Origin` and
`Sec-Fetch-Site`) are rejected too, so a page you visit cannot POST uploads to the
server with your cached credentials.

## https

the server speaks plain http. put a tls reverse proxy in front for anything public:

```sh
# caddy — auto-provisions a cert and forwards to the server
files.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

then install with `--allow-host files.example.com` so the forwarded `Host` header
is accepted, and keep `--bind` on `127.0.0.1`.

## limits

`--max-upload` (default 512 MiB) caps a single upload, and the installer sizes the
systemd `MemoryMax` ceiling to match. connections that stall for 60 seconds are
dropped.
