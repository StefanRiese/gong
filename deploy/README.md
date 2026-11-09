# Deployment on Proxmox (LXC)

The server is a single native program plus the web UI. No Docker, no Dart SDK and no Node.js are
needed on the target. It runs as a systemd service under its own system user.

## 1. Create the container

In the Proxmox web UI: **Create CT**

| Setting | Value |
|---|---|
| Template | Debian 12 or 13 (standard) |
| Unprivileged container | yes |
| Nesting | yes (Options → Features; default for new CTs) — enables the service sandbox |
| CPU / RAM / Disk | 1 core, 512 MB, 4 GB |
| Network | DHCP or a fixed IP in your LAN |

Start the container and open its console (or `pct enter <id>` on the Proxmox host).

## 2. Install

```sh
apt update && apt install -y curl ca-certificates
curl -fsSLO https://raw.githubusercontent.com/StefanRiese/schulportal-client/main/deploy/install.sh
bash install.sh
```

The script

1. downloads the latest release from GitHub and checks its SHA-256 checksum,
2. creates the system user `schulportal`,
3. installs the program to `/opt/schulportal-client`,
4. asks for school number, Schulportal username/password and a password for the web UI,
   and writes them to `/etc/schulportal-client/config.env` (readable by root only),
5. installs and starts the systemd service `schulportal-client` and checks that it answers.

Then open `http://<container-ip>:8080` and log in with the web UI password.

Without internet access on the container, copy a release archive over and use
`bash install.sh --from schulportal-client-linux-x64.tar.gz`.

## Day-to-day

| Task | Command |
|---|---|
| Update to the latest release | `bash /opt/schulportal-client/deploy/install.sh` |
| Install a specific version | `bash /opt/schulportal-client/deploy/install.sh --version v0.1.0` |
| Back to the previous version | `bash /opt/schulportal-client/deploy/install.sh --rollback` |
| Change credentials / web password | `bash /opt/schulportal-client/deploy/install.sh --configure` |
| Status | `systemctl status schulportal-client` |
| Logs | `journalctl -u schulportal-client -f` |
| Restart (after editing config.env) | `systemctl restart schulportal-client` |
| Remove (keep config + data) | `bash /opt/schulportal-client/deploy/install.sh --uninstall` |
| Remove everything | `bash /opt/schulportal-client/deploy/install.sh --uninstall --purge` |

Updates keep `config.env`. The previous version stays in `/opt/schulportal-client.old` for
`--rollback`.

## Files

| Path | Content |
|---|---|
| `/opt/schulportal-client/` | program (`bin/`, `lib/`), web UI (`web/`), `deploy/`, `VERSION` |
| `/etc/schulportal-client/config.env` | configuration and credentials (mode 600, root) |
| `/var/lib/schulportal-client/` | data directory (used from milestone 5 on) |
| `/etc/systemd/system/schulportal-client.service` | systemd unit |

`config.env` settings are described in `/opt/schulportal-client/config.env.example`.
Values are written in single quotes so special characters in passwords are read literally.

## Access from outside the LAN

Do not forward the port on your router. Options:

- **VPN / Tailscale** (recommended): install Tailscale in this or another container and open
  `http://<tailscale-ip>:8080`.
- **Reverse proxy with HTTPS** (e.g. Nginx Proxy Manager, Caddy, Traefik): proxy to
  `http://<container-ip>:8080`, then set in `config.env`:

  ```
  COOKIE_SECURE='true'
  TRUST_PROXY='true'
  ```

  and restart the service. With a proxy on the same container you can also set
  `HOST='127.0.0.1'`.

## Backups

Proxmox backups (vzdump) of the container include configuration and data. The program itself
can always be reinstalled with `install.sh`.

## Sandbox without "Nesting"

The unit uses systemd sandboxing (read-only system, private `/tmp`, no capabilities, …). In an
unprivileged container without *Nesting*, systemd cannot set this up and the service fails
with `226/NAMESPACE`. `install.sh` detects this and adds
`/etc/systemd/system/schulportal-client.service.d/no-namespaces.conf`, which relaxes the
sandbox. To restore full sandboxing: enable Nesting, restart the container, delete that file,
then run `systemctl daemon-reload && systemctl restart schulportal-client`.

## Building a release yourself

On a Linux x64 machine with the Dart SDK (Debian 12 / Ubuntu 22.04 or older, so the binary
runs on Debian 12 and 13):

```sh
bash deploy/build-release.sh     # → dist/schulportal-client-linux-x64.tar.gz (+ .sha256)
```

Pushing a tag `v*` builds releases for Linux, Windows and macOS on GitHub Actions and
publishes them as a GitHub release.
