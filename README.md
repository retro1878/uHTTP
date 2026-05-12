# uHTTP

minimal HTTP file server — upload, browse, download.

```sh
# install with defaults (port 8080, /srv/fileserver, www-data)
sudo ./fileserver-install.sh install

# custom port, directory, and service user
sudo ./fileserver-install.sh install --port 9000 --dir /opt/files --user nobody

# remove service and install dir (leaves your files intact)
sudo ./fileserver-install.sh uninstall
```

no dependencies beyond python3 and systemd.
