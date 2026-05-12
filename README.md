# uHTTP

minimal HTTP file server — upload, browse, download.

```sh
curl -fsSL https://raw.githubusercontent.com/retro1878/uHTTP/main/fileserver-install.sh -o fileserver-install.sh
```

```sh
chmod +x fileserver-install.sh
```

```sh
# install with defaults (port 8080, /srv/fileserver, www-data)
sudo ./fileserver-install.sh install
```

```sh
# custom port, directory, and service user
sudo ./fileserver-install.sh install --port 9000 --dir /opt/files --user nobody
```

```sh
# remove service and install dir (leaves your files intact)
sudo ./fileserver-install.sh uninstall
```

no dependencies beyond python3 and systemd.
