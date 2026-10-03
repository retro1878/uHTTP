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
# publish download links that work without the token (see "public downloads")
sudo bash fileserver-install.sh install --bind 0.0.0.0 --public-download
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

an upload never replaces a file that is already there. if the name is taken the
incoming file is kept alongside it as `name(0).ext`, `name(1).ext` and so on, the
same thing a browser does when you select several files sharing a name. delete a
file from the table first if you meant to replace it.

each row also has a **wget** button that copies a ready-to-paste command for
that file, credentials included:

```sh
wget --user=u --password='<the token>' http://<host>:8080/dl/<file>
```

the host is whichever address you loaded the page from, so the command fits the
way you actually reach the server. the page is behind the token, so this tells
an already-authenticated client nothing it did not already have — but the
command is a credential: it lands in shell history on whatever machine you run
it on, and it carries delete rights. run the server with `--public-download` and
the button copies the command with no credentials in it at all (see below),
which is what makes it safe to paste into a channel.

each row has a **delete** button beside its download link. it asks for
confirmation, then removes the file and its per-file download counters. the
browse page is the only thing that lists files, so anything it does not show —
dotfiles like `.fs_stats.json`, symlinks, subdirectories — cannot be deleted
through the API either. the running totals in the header are left alone; they
are a record of what has been served, not of what is currently on disk.

## auth

the installer generates a random token on install (or use `--token`) and prints it at the end.
every route requires http basic auth — the password is the token, the username is ignored —
except `GET /dl/<file>` when installed with `--public-download` (see below). that includes
deleting, so the token is a full read/write credential: give it only to people who should be
able to remove files.

```sh
curl -u :TOKEN http://localhost:8080/api/files
```

the browser prompts for a username/password the first time — enter anything as the username and the token as the password.

five wrong attempts from one address earn a `429` for the next minute. that only
ever refuses guesses: a request carrying the correct token is answered normally
however many failures that address has accumulated, and a success clears the
counter. an attacker therefore cannot lock the owner out from behind a shared
address, nor wedge a valid client.

if the token file is missing the service refuses to start rather than coming up
without authentication. running `serve.py` by hand needs `--token`, `FS_TOKEN`,
or an explicit `--no-auth`.

## open downloads

`--public-download` answers `GET /dl/<file>` without credentials, so a download
link can be published as it stands:

```sh
curl -fsSL http://<host>:8080/dl/<file> -o /tmp/<file>
```

nothing else opens with it. the browse page, the API, uploads and deletes all
still require the token, and an unauthenticated request to any of them is refused
with the same `401` whether or not the path exists — so it does not even confirm
which files are there. the `Host` allow-list and the cross-site checks apply to
`/dl/` exactly as they do elsewhere.

the wget button follows the setting: while downloads are open it copies a command
carrying no credentials, which is what makes that command safe to paste somewhere
public. the token is not a read-only credential — it deletes — so the difference
between the two buttons is the whole point.

set it at install, or put `PUBLIC_DOWNLOAD=1` in `/opt/fileserver/.fs_config` and
re-run `update` on an existing install. `update` itself refuses the flag, the same
way it refuses every other setting.

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
