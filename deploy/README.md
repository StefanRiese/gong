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
curl -fsSLO https://raw.githubusercontent.com/StefanRiese/lumo/main/deploy/install.sh
bash install.sh
```

The script

1. downloads the latest release from GitHub and checks its SHA-256 checksum,
2. creates the system user `lumo`,
3. installs the program to `/opt/lumo`,
4. installs `avahi-daemon`, so the container is reachable by name: `http://<hostname>.local:8080`,
   e.g. `http://lumo.local:8080` for a container named `lumo` (`SKIP_AVAHI=1` skips it),
5. installs and starts the systemd service `lumo` and checks that it answers,
6. prints the **setup link** `http://<container-ip>:8080/einrichtung?token=…`.

Open the setup link in a browser: choose the school, enter the Schulportal login (it is
tested right away) and a password for the web UI. The web UI then opens, logged in. Later
changes: *Einstellungen* in the web UI.

The setup link only works until the setup is done; it is also in the log
(`journalctl -u lumo`) and in `/var/lib/lumo/setup-token`.
Without the token nobody else in the network can take over the unconfigured server.

Alternatively, `install.sh` asks in the terminal whether to enter the credentials there; they
are written to `/etc/lumo/config.env` (readable by root only).
`bash /opt/lumo/deploy/install.sh --configure` does that again later.

**Where settings live:** settings made in the web UI are stored in the database
(`/var/lib/lumo/lumo.db`) and take precedence over `config.env`.
`install.sh --configure` hands the keys it writes back to `config.env`.

## Push notifications (ntfy)

Set up in the web UI under *Einstellungen → Benachrichtigungen* („Zufälliges Thema“
creates a hard-to-guess topic), or with `install.sh --configure`. On your phone, install the **ntfy** app (Android: Play Store/F-Droid, iOS: App Store), tap **+** and
subscribe to that topic on the same server (default `https://ntfy.sh`). Then open
**Benachrichtigungen** (bell icon) in the web UI and press **Testnachricht senden**.

What happens:

- the server keeps all data in sync in the background: substitutions and homework every
  15 min, grades and course pages every 2 h, only between 6 and 22 o'clock; notifications
  come from these syncs;
- the first check after setup only records the current state (no flood of old entries);
- new or changed substitutions, new homework and new grades are sent once each;
  tapping a notification opens the matching page of the web UI (`APP_URL`);
- grade values are **not** included by default (`NOTIFY_GRADE_VALUES='true'` to change);
- if ntfy is unreachable, the notification is sent with the next check.

Privacy: on the public ntfy.sh server anyone who knows the topic name can read the messages.
Keep the random name secret, or use your own ntfy server / an access token (`NTFY_TOKEN`).
All settings: see `config.env.example` (`NOTIFY`, `SYNC`, `POLL_INTERVAL_MINUTES`,
`GRADES_INTERVAL_MINUTES`, `ACTIVE_HOURS`, …). Change them in the web UI (*Einstellungen →
Server*), with `install.sh --configure`, or by editing `config.env` and restarting the service
(values set in the web UI take precedence over `config.env`).

Without internet access on the container, copy a release archive over and use
`bash install.sh --from lumo-linux-x64.tar.gz`.

## School meals and WebUntis (optional)

Both are read-only and set up in the web UI under *Einstellungen* (or with the
`CASEDA_*` / `UNTIS_*` keys in `config.env`, see `config.env.example`):

- **Schulessen** – login of the Caseda Schulmenü account; shows the own orders (page
  *Schulessen*, today's meal on Heute) and the balance. Ordering stays on the Caseda website.
- **Vertretungen (WebUntis)** – login of the school's WebUntis (a class account is enough);
  completes the Schulportal substitutions with what WebUntis knows and adds changes the
  Schulportal plan does not have yet. „Anmeldung prüfen“ tests the login.

The logins are tested before they are saved and can be switched off without losing them.

## Day-to-day

| Task | Command |
|---|---|
| Update to the latest release | web UI: *Einstellungen → Update*, or `bash /opt/lumo/deploy/install.sh` |
| Install a specific version | `bash /opt/lumo/deploy/install.sh --version v0.1.0` |
| Back to the previous version | `bash /opt/lumo/deploy/install.sh --rollback` |
| Change credentials / web password / ntfy / sync | web UI: *Einstellungen* (or `install.sh --configure`) |
| Status | `systemctl status lumo` |
| Logs | `journalctl -u lumo -f` |
| Restart (after editing config.env) | `systemctl restart lumo` |
| Remove (keep config + data) | `bash /opt/lumo/deploy/install.sh --uninstall` |
| Remove everything | `bash /opt/lumo/deploy/install.sh --uninstall --purge` |

Updates keep `config.env`. The previous version stays in `/opt/lumo.old` for
`--rollback`.

**Updates from the web UI:** the server checks GitHub for new releases every 12 hours
(`UPDATE_CHECK`) and shows a notice. „Jetzt aktualisieren“ in *Einstellungen → Update*
lets the (unprivileged) service write the wanted version to
`/var/lib/lumo/update-request`; the root units `lumo-update.path`
/ `.service` (installed and enabled by `install.sh`) then run `install.sh --auto-update`. It
only installs releases newer than the installed one, verifies the checksum, keeps the previous
version for `--rollback` and restarts the service. Log: `journalctl -u lumo-update`.

## Files

| Path | Content |
|---|---|
| `/opt/lumo/` | program (`bin/`, `lib/`), web UI (`web/`), `deploy/`, `VERSION` |
| `/etc/lumo/config.env` | configuration and credentials (mode 600, root) |
| `/var/lib/lumo/` | database `lumo.db`: settings from the web UI (incl. credentials), cached portal data, web logins (hashed), notification state; `setup-token` until set up |
| `/etc/systemd/system/lumo.service` | systemd unit |
| `/etc/systemd/system/lumo-update.{path,service}` | updates requested in the web UI (root) |

`config.env` settings are described in `/opt/lumo/config.env.example`.
Values are written in single quotes so special characters in passwords are read literally.

## Access from outside the LAN

Do not forward the port on your router. Options:

- **VPN / Tailscale** (recommended): install Tailscale in this or another container and open
  `http://<tailscale-ip>:8080`.
- **Reverse proxy with HTTPS** (e.g. Nginx Proxy Manager, Caddy, Traefik): proxy to
  `http://<container-ip>:8080`, then enable *Einstellungen → Web-Oberfläche*
  „Nur über HTTPS“ and „Hinter einem Reverse-Proxy“ (or in `config.env`:
  `COOKIE_SECURE='true'`, `TRUST_PROXY='true'`) and restart the service. With a proxy on the
  same container you can also choose „Nur auf diesem Gerät“ (`HOST='127.0.0.1'`).
  The proxy must not buffer `/api/events` (Server-Sent Events) for live updates.

## Backups

Proxmox backups (vzdump) of the container include configuration and data. The database
contains the Schulportal (and Caseda / WebUntis) credentials if they were entered in the web UI – treat backups
accordingly. The program itself
can always be reinstalled with `install.sh`.

## Sandbox without "Nesting"

The unit uses systemd sandboxing (read-only system, private `/tmp`, no capabilities, …). In an
unprivileged container without *Nesting*, systemd cannot set this up and the service fails
with `226/NAMESPACE`. `install.sh` detects this and adds
`/etc/systemd/system/lumo.service.d/no-namespaces.conf`, which relaxes the
sandbox. To restore full sandboxing: enable Nesting, restart the container, delete that file,
then run `systemctl daemon-reload && systemctl restart lumo`.

## Building a release yourself

On a Linux x64 machine with the Dart SDK (Debian 12 / Ubuntu 22.04 or older, so the binary
runs on Debian 12 and 13):

```sh
bash deploy/build-release.sh     # → dist/lumo-linux-x64.tar.gz (+ .sha256)
```

The Windows exe and the macOS app can only be built on Windows / macOS (see
[DESKTOP.md](DESKTOP.md)); `gh workflow run release.yml --ref main` builds everything on GitHub
Actions without publishing.

Pushing a tag `v*` builds releases for Linux, Windows and macOS on GitHub Actions and
publishes them as a GitHub release. The Windows and macOS builds are desktop apps with a tray /
menu bar icon, see [DESKTOP.md](DESKTOP.md).
