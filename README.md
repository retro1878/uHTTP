# uHTTP

minimal HTTP file server — upload, browse, download.

```sh
curl -fsSL https://raw.githubusercontent.com/retro1878/uHTTP/main/fileserver-install.sh -o fileserver-install.sh
```

```sh
chmod +x fileserver-install.sh
```

```sh
# install with defaults (port 8080, /srv/fileserver, www-data, localhost-only, auto-generated auth token)
sudo ./fileserver-install.sh install
```

```sh
# custom port, directory, service user, bind address, and token
sudo ./fileserver-install.sh install --port 9000 --dir /opt/files --user nobody --bind 0.0.0.0 --token supersekret
```

```sh
# remove service and install dir (leaves your files intact)
sudo ./fileserver-install.sh uninstall
```

no dependencies beyond python3 and systemd.

## auth

the installer generates a random token on install (or use `--token`) and prints it at the end.
all routes require http basic auth — the password is the token, the username is ignored.

```sh
curl -u :TOKEN http://localhost:8080/api/files
```

the browser prompts for a username/password the first time — enter anything as the username and the token as the password.

## network exposure

the server binds to `127.0.0.1` (localhost only) by default.
pass `--bind 0.0.0.0` at install to listen on all interfaces.

## https

the server speaks plain http. put a tls reverse proxy in front for anything public:

```sh
# caddy — auto-provisions a cert and forwards to the server
your.domain {
    reverse_proxy 127.0.0.1:8080
}
```
