# uHTTP

minimal HTTP file server — upload, browse, download, delete.

```sh
curl -fsSL https://raw.githubusercontent.com/retro1878/uHTTP/main/fileserver-install.sh -o fileserver-install.sh
```

`curl` does not set the executable bit, so the examples below run the script
with `bash`. `chmod +x fileserver-install.sh` and `./fileserver-install.sh` work
just as well if you prefer.

```sh
# install with defaults (port 8080, /srv/fileserver, www-data, localhost-only,
# auto-generated auth token, 512 MiB upload limit)
sudo bash fileserver-install.sh install
```

```sh
# custom port, directory, service user, and token
sudo bash fileserver-install.sh install --port 9000 --dir /opt/files --user nobody --token "$(openssl rand -hex 24)"
```

```sh
# reachable from the LAN: bind to an address and raise the upload limit
sudo bash fileserver-install.sh install --bind 192.168.1.5 --max-upload 2048
```

```sh
# remove service and install dir (leaves your files intact)
sudo bash fileserver-install.sh uninstall
```

no dependencies beyond python3 and systemd.

## updating

`update` applies the server and systemd unit built into the script you are
running, keeping your settings and your auth token.

```sh
# 1. fetch the newer script
curl -fsSL https://raw.githubusercontent.com/retro1878/uHTTP/main/fileserver-install.sh -o fileserver-install.sh
```

```sh
# 2. apply it
sudo bash fileserver-install.sh update
```

the script does no network i/o of its own — you only ever run a script you
fetched yourself.

your port, directory, service user, bind address, upload limit and allowed hosts
are read back from `/opt/fileserver/.fs_config`, so an update never alters them,
and the token is left untouched, so connected clients keep working. re-running
`install` on a live box is refused for exactly that reason — it generates a new
token. installs from before v1.1 have no `.fs_config`; the first `update`
recovers the settings from the existing unit and writes that file.

installs from before authentication was added have no token file at all. the
server refuses to start without one, so `update` declines those until you pass
`--init-token`, which generates a token — after which every client must
authenticate. those installs also listened on every interface (their unit had no
`--bind`), so that is preserved rather than quietly narrowed to localhost.

if the service does not come back healthy, the previous server and unit are
restored automatically and the update exits non-zero.

```sh
# version, settings and service state
sudo bash fileserver-install.sh status
```

```sh
# show what an update would change, and change nothing
sudo bash fileserver-install.sh update --dry-run
```

```sh
# re-apply, or override a downgrade refusal
sudo bash fileserver-install.sh update --force
```

```sh
# an install from before authentication: generate a token, then apply
sudo bash fileserver-install.sh update --init-token
```

to change a setting, edit `/opt/fileserver/.fs_config` (root-only) and re-run
`update`. each update keeps a timestamped copy of the previous server and unit
under `/opt/fileserver/backups/`.

## web ui

`http://<host>:8080/` serves the browse/upload page — a table of files with size,
download count and last-download time, plus click-or-drag upload. every route is
behind the token, so the browser asks for credentials before the page loads.

each row has a **delete** button beside its download link. it asks for
confirmation, then removes the file and its per-file download counters. the
browse page is the only thing that lists files, so anything it does not show —
dotfiles like `.fs_stats.json`, symlinks, subdirectories — cannot be deleted
through the API either. the running totals in the header are left alone; they
are a record of what has been served, not of what is currently on disk.

## auth

the installer generates a random token on install (or use `--token`) and prints it at the end.
all routes require http basic auth — the password is the token, the username is ignored. that
includes deleting, so the token is a full read/write credential: give it only to people who
should be able to remove files.

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
sudo bash fileserver-install.sh install --bind 0.0.0.0 --allow-host files.example.com
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
