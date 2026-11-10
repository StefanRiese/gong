#!/usr/bin/env bash
# Installs or updates lumo on Debian/Ubuntu with systemd
# (e.g. a Proxmox LXC container). Run as root.
#
#   install.sh                       install/update to the latest GitHub release
#   install.sh --version v1.2.0      install a specific release
#   install.sh --from FILE.tar.gz    install from a local release archive
#   install.sh --configure           (re)enter credentials in config.env
#   install.sh --rollback            switch back to the previously installed version
#   install.sh --uninstall [--purge] remove the program (--purge: also config + data)
#   install.sh --auto-update         install the version requested in the web UI
#                                    (run by lumo-update.service)
#
# Options: --non-interactive (never prompt), -h/--help

set -euo pipefail

APP=lumo
REPO=${REPO:-StefanRiese/lumo}
SERVICE_USER=${SERVICE_USER:-lumo}
PREFIX=${PREFIX:-/opt/$APP}
CONFIG_DIR=${CONFIG_DIR:-/etc/$APP}
CONFIG_FILE="$CONFIG_DIR/config.env"
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
UNIT_FILE="$UNIT_DIR/$APP.service"
UPDATE_UNITS=("$APP-update.path" "$APP-update.service")
DROPIN_DIR="$UNIT_DIR/$APP.service.d"
STATE_DIR=${STATE_DIR:-/var/lib/$APP}
# For testing the script without root/systemd (not for normal use).
SKIP_SYSTEMD=${SKIP_SYSTEMD:-0}
SKIP_USER=${SKIP_USER:-0}

action=install
from=""
version=latest
interactive=1
purge=0
[[ -t 0 ]] || interactive=0

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWarnung:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) from=${2:?--from needs a file}; shift 2 ;;
    --version) version=${2:?--version needs a tag}; shift 2 ;;
    --configure) action=configure; shift ;;
    --rollback) action=rollback; shift ;;
    --uninstall) action=uninstall; shift ;;
    --auto-update) action=auto-update; interactive=0; shift ;;
    --purge) purge=1; shift ;;
    --non-interactive) interactive=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers

need_root() {
  [[ $SKIP_SYSTEMD == 1 || $EUID -eq 0 ]] || die "Bitte als root ausführen (z. B. mit sudo)."
}

systemd() {
  [[ $SKIP_SYSTEMD == 1 ]] && return 0
  systemctl "$@"
}

fetch() { # url dest
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null; then
    wget -q -O "$2" "$1"
  else
    die "curl oder wget wird benötigt: apt install curl"
  fi
}

http_ok() { # url
  if command -v curl >/dev/null; then
    curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null
  elif command -v wget >/dev/null; then
    wget -q -O /dev/null --timeout=3 "$1" 2>/dev/null
  else
    return 2
  fi
}

config_get() { # key → value (unquoted) or empty
  [[ -f $CONFIG_FILE ]] || return 0
  local line
  line=$(grep -E "^[[:space:]]*$1=" "$CONFIG_FILE" | tail -n1 || true)
  line=${line#*=}
  if [[ $line == \'*\' || $line == \"*\" ]]; then line=${line:1:${#line}-2}; fi
  printf '%s' "$line"
}

# Sets KEY=value in config.env, quoted so systemd's EnvironmentFile reads it
# literally (single quotes; double quotes with escaping if needed).
config_set() { # key value
  local key=$1 value=$2 quoted tmp
  [[ $value != *$'\n'* ]] || die "Wert für $key darf keinen Zeilenumbruch enthalten."
  if [[ $value != *"'"* ]]; then
    quoted="'$value'"
  else
    quoted=${value//\\/\\\\}
    quoted=${quoted//\"/\\\"}
    quoted="\"$quoted\""
  fi
  tmp=$(mktemp "$CONFIG_DIR/.config.XXXXXX")
  # Values are passed via the environment: awk -v would interpret backslashes.
  CFG_KEY=$key CFG_LINE="$key=$quoted" awk '
    BEGIN { key = ENVIRON["CFG_KEY"]; line = ENVIRON["CFG_LINE"]; done = 0 }
    index($0, key "=") == 1 { if (!done) { print line; done = 1 }; next }
    { print }
    END { if (!done) print line }
  ' "$CONFIG_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

ask() { # prompt default → answer
  local answer
  read -r -p "$1${2:+ [$2]}: " answer
  printf '%s' "${answer:-$2}"
}

ask_secret() { # prompt → answer
  local answer
  read -r -s -p "$1: " answer
  echo >&2
  printf '%s' "$answer"
}

# ---------------------------------------------------------------------------
# steps

download_release() { # → path of archive
  local dir=$1 base name
  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "Nicht unterstützte Architektur: $(uname -m)" ;;
  esac
  name="$APP-linux-$arch.tar.gz"
  if [[ -n ${RELEASE_BASE_URL:-} ]]; then # for testing with a local mirror
    base=$RELEASE_BASE_URL
  elif [[ $version == latest ]]; then
    base="https://github.com/$REPO/releases/latest/download"
  else
    base="https://github.com/$REPO/releases/download/$version"
  fi
  say "Lade $name ($version) von GitHub …" >&2
  fetch "$base/$name" "$dir/$name" || die "Download fehlgeschlagen: $base/$name"
  fetch "$base/$name.sha256" "$dir/$name.sha256" || die "Prüfsumme nicht gefunden: $base/$name.sha256"
  (cd "$dir" && sha256sum -c --quiet "$name.sha256") || die "Prüfsumme stimmt nicht – Download beschädigt?"
  printf '%s' "$dir/$name"
}

ensure_user() {
  [[ $SKIP_USER == 1 ]] && return 0
  if ! getent passwd "$SERVICE_USER" >/dev/null; then
    say "Lege Systembenutzer '$SERVICE_USER' an"
    useradd --system --user-group --home-dir "$STATE_DIR" --no-create-home \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
}

install_files() { # archive workdir
  local archive=$1 work=$2 src
  mkdir -p "$work/extract"
  tar -xzf "$archive" -C "$work/extract" 2>/dev/null || die "Archiv ist beschädigt oder kein Release-Archiv: $archive"
  src="$work/extract/$APP"
  [[ -x $src/bin/server && -f $src/web/index.html && -f $src/deploy/$APP.service ]] ||
    die "Archiv hat nicht den erwarteten Inhalt: $archive"

  say "Installiere Version $(cat "$src/VERSION" 2>/dev/null || echo '?') nach $PREFIX"
  rm -rf "$PREFIX.new"
  mkdir -p "$(dirname "$PREFIX")"
  cp -a "$src" "$PREFIX.new"
  chown -R root:root "$PREFIX.new" 2>/dev/null || true
  chmod -R go-w "$PREFIX.new"
  if [[ -d $PREFIX ]]; then
    rm -rf "$PREFIX.old"
    mv "$PREFIX" "$PREFIX.old"
  fi
  mv "$PREFIX.new" "$PREFIX"

  mkdir -p "$UNIT_DIR"
  install -m 644 "$PREFIX/deploy/$APP.service" "$UNIT_FILE"
  local unit
  for unit in "${UPDATE_UNITS[@]}"; do
    [[ -f $PREFIX/deploy/$unit ]] && install -m 644 "$PREFIX/deploy/$unit" "$UNIT_DIR/$unit"
  done
}

ensure_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"
  if [[ ! -f $CONFIG_FILE ]]; then
    say "Erzeuge $CONFIG_FILE"
    install -m 600 "$PREFIX/config.env.example" "$CONFIG_FILE"
    config_set SPH_USERNAME ''
    config_set HOST 0.0.0.0
    config_set WEB_DIR "$PREFIX/web"
    return 0
  fi
  # Keep WEB_DIR pointing at the installed web UI.
  [[ -n $(config_get WEB_DIR) ]] || config_set WEB_DIR "$PREFIX/web"
  chmod 600 "$CONFIG_FILE"
}

config_complete() {
  [[ -n $(config_get SPH_USERNAME) && -n $(config_get SPH_PASSWORD) && -n $(config_get APP_PASSWORD_HASH) ]]
}

# Set up in the web UI: settings are in the database, no setup token left.
web_configured() {
  [[ -f $STATE_DIR/lumo.db && ! -f $STATE_DIR/setup-token ]]
}

configure() { # force
  local force=${1:-0}
  if [[ $force == 0 ]] && { config_complete || web_configured; }; then return 0; fi
  if [[ $interactive == 0 ]]; then
    say "Zugangsdaten fehlen: Einrichtung im Browser (Link folgt nach dem Start)"
    return 0
  fi
  if [[ $force == 0 ]] && [[ $(ask "Jetzt im Terminal einrichten? Sonst im Browser (j/n)" "n") != [jJyY]* ]]; then
    return 0
  fi

  echo
  say "Einrichtung"
  local school user pw app1 app2 hash
  school=$(ask "Schulnummer (Schulportal Hessen)" "$(config_get SPH_SCHOOL_ID)")
  [[ $school =~ ^[0-9]+$ ]] || die "Schulnummer muss eine Zahl sein."
  user=$(ask "Schulportal-Benutzername (z. B. vorname.nachname)" "$(config_get SPH_USERNAME)")
  [[ -n $user ]] || die "Benutzername fehlt."
  local has_pw=0
  [[ -n $(config_get SPH_PASSWORD) ]] && has_pw=1
  if [[ $has_pw == 1 ]]; then
    pw=$(ask_secret "Schulportal-Passwort (leer = unverändert)")
  else
    pw=$(ask_secret "Schulportal-Passwort")
    [[ -n $pw ]] || die "Passwort fehlt."
  fi

  echo "Passwort für die Web-Oberfläche (mind. 8 Zeichen; leer = unverändert, falls schon gesetzt)."
  app1=$(ask_secret "Neues Web-Passwort")
  if [[ -n $app1 ]]; then
    app2=$(ask_secret "Wiederholen")
    [[ $app1 == "$app2" ]] || die "Die Passwörter stimmen nicht überein."
    [[ ${#app1} -ge 8 ]] || die "Bitte mindestens 8 Zeichen verwenden."
    hash=$(printf '%s' "$app1" | "$PREFIX/bin/hash_password" --stdin | sed -n 's/^APP_PASSWORD_HASH=//p')
    [[ -n $hash ]] || die "Passwort-Hash konnte nicht erzeugt werden."
    config_set APP_PASSWORD_HASH "$hash"
  elif [[ -z $(config_get APP_PASSWORD_HASH) ]]; then
    die "Ein Web-Passwort ist erforderlich."
  fi

  config_set SPH_SCHOOL_ID "$school"
  config_set SPH_USERNAME "$user"
  [[ -z $pw ]] || config_set SPH_PASSWORD "$pw"
  configure_ntfy
  say "Einstellungen gespeichert in $CONFIG_FILE (nur für root lesbar)"
}

random_topic() {
  printf 'sph-%s' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
}

configure_ntfy() {
  echo
  echo "Push-Benachrichtigungen (Vertretungen, Hausaufgaben, Noten) über ntfy."
  echo "Auf ntfy.sh kann jeder mitlesen, der den Themennamen kennt – daher ein zufälliger Name."
  local current answer topic server token app_url ip port
  current=$(config_get NTFY_TOPIC)
  answer=$(ask "Benachrichtigungen aktivieren? (j/n)" "j")
  if [[ ! $answer =~ ^[jJyY] ]]; then
    config_set NTFY_TOPIC ''
    say "Benachrichtigungen deaktiviert."
    return 0
  fi

  server=$(config_get NTFY_URL)
  server=$(ask "ntfy-Server" "${server:-https://ntfy.sh}")
  [[ $server =~ ^https?://[^/]+ ]] || die "ntfy-Server muss mit http:// oder https:// beginnen."

  topic=$(ask "Thema" "${current:-$(random_topic)}")
  [[ $topic =~ ^[-_A-Za-z0-9]{1,64}$ ]] || die "Thema: nur Buchstaben, Ziffern, - und _ (max. 64 Zeichen)."

  token=$(ask_secret "Zugangs-Token (optional, leer = keiner/unverändert)")

  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  port=$(config_get PORT)
  app_url=$(config_get APP_URL)
  app_url=$(ask "Adresse der Web-Oberfläche für Links in Nachrichten" \
    "${app_url:-http://${ip:-127.0.0.1}:${port:-8080}}")

  config_set NTFY_URL "$server"
  config_set NTFY_TOPIC "$topic"
  [[ -z $token ]] || config_set NTFY_TOKEN "$token"
  config_set APP_URL "$app_url"

  echo
  echo "In der ntfy-App (Android/iOS) abonnieren:"
  echo "  Server: $server"
  echo "  Thema:  $topic"
  echo 'Testnachricht danach in der Web-Oberfläche unter „Benachrichtigungen“ senden.'
}

# avahi-daemon announces the machine as <hostname>.local (mDNS), so the web UI
# is reachable as http://lumo.local:8080 in a container named lumo.
# Best effort: without it only the IP address works. SKIP_AVAHI=1 skips it.
ensure_avahi() {
  [[ $SKIP_SYSTEMD == 1 || ${SKIP_AVAHI:-0} == 1 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || return 0
  if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
    say "Installiere avahi-daemon (Name $(hostname).local im Netzwerk)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q avahi-daemon >/dev/null 2>&1 ||
      { apt-get update -q >/dev/null 2>&1 &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q avahi-daemon >/dev/null 2>&1; } ||
      { warn "avahi-daemon konnte nicht installiert werden – erreichbar nur über die IP-Adresse"; return 0; }
  fi
  systemctl enable --now avahi-daemon >/dev/null 2>&1 ||
    warn "avahi-daemon läuft nicht – erreichbar nur über die IP-Adresse"
}

# Unprivileged LXC without "nesting" cannot set up the sandbox namespaces.
relax_sandbox() {
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN_DIR/no-namespaces.conf" <<'EOF'
# Added by install.sh: this container does not support the namespace-based
# sandboxing (enable "Nesting" in Proxmox and delete this file to restore it).
[Service]
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
PrivateDevices=no
ProtectKernelTunables=no
ProtectKernelModules=no
ProtectKernelLogs=no
ProtectControlGroups=no
ProtectClock=no
ProtectHostname=no
RestrictNamespaces=no
EOF
  systemd daemon-reload
}

start_service() {
  [[ $SKIP_SYSTEMD == 1 ]] && { say "(SKIP_SYSTEMD) Dienst nicht gestartet"; return 0; }
  systemctl daemon-reload
  systemctl enable "$APP" >/dev/null 2>&1
  # Updates from the web UI (Einstellungen → Update).
  if [[ -f $UNIT_DIR/$APP-update.path ]]; then
    systemctl enable --now "$APP-update.path" >/dev/null 2>&1 ||
      warn "Update aus der Web-Oberfläche nicht verfügbar ($APP-update.path)"
  fi

  say "Starte Dienst"
  systemctl restart "$APP" || true
  if wait_healthy; then return 0; fi

  local status
  status=$(systemctl show -p ExecMainStatus --value "$APP" 2>/dev/null || echo "")
  if [[ $status == 226 ]] || journalctl -u "$APP" -n 20 --no-pager 2>/dev/null | grep -q "226/NAMESPACE"; then
    warn "Der Container unterstützt die Sandbox-Funktionen nicht (Proxmox: Optionen → Features → Nesting)."
    warn "Starte mit reduzierter Sandbox."
    relax_sandbox
    systemctl restart "$APP" || true
    if wait_healthy; then return 0; fi
  fi

  journalctl -u "$APP" -n 30 --no-pager 2>/dev/null || true
  if [[ $(systemctl show -p ExecMainStatus --value "$APP" 2>/dev/null) == 78 ]]; then
    die "Ungültige Konfiguration – siehe Meldungen oben. Danach: bash $PREFIX/deploy/install.sh --configure"
  fi
  die "Dienst läuft nicht. Details: journalctl -u $APP"
}

wait_healthy() {
  local port url
  port=$(config_get PORT)
  url="http://127.0.0.1:${port:-8080}/healthz"
  local rc
  for _ in $(seq 1 30); do
    if http_ok "$url"; then return 0; else rc=$?; fi
    if [[ $rc -eq 2 ]]; then # neither curl nor wget: fall back to the unit state
      sleep 3
      systemctl is-active --quiet "$APP"
      return
    fi
    if systemctl is-failed --quiet "$APP"; then return 1; fi
    sleep 0.5
  done
  return 1
}

summary() {
  local port host ip
  port=$(config_get PORT)
  host=$(config_get HOST)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  say "Fertig."
  if [[ $host == 127.0.0.1 || $host == localhost ]]; then
    echo "  Erreichbar nur lokal: http://127.0.0.1:${port:-8080}  (HOST in $CONFIG_FILE)"
  else
    echo "  Web-Oberfläche: http://${ip:-<container-ip>}:${port:-8080}"
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
      echo "                  http://$(hostname).local:${port:-8080}"
    fi
  fi
  local token
  token=$(cat "$STATE_DIR/setup-token" 2>/dev/null || true)
  if [[ -n $token ]]; then
    local base="http://${ip:-<container-ip>}:${port:-8080}"
    [[ $host == 127.0.0.1 || $host == localhost ]] && base="http://127.0.0.1:${port:-8080}"
    echo
    say "Einrichtung im Browser öffnen (Schule, Zugangsdaten, Passwort):"
    echo "  $base/einrichtung?token=$token"
    echo
  fi
  echo "  Status:         systemctl status $APP"
  echo "  Logs:           journalctl -u $APP -f"
  echo "  Konfiguration:  $CONFIG_FILE"
  echo "  Update:         bash $PREFIX/deploy/install.sh"
}

# ---------------------------------------------------------------------------
# actions

WORK_DIR=""
cleanup() { [[ -z $WORK_DIR ]] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

do_install() {
  need_root
  local tmp archive
  WORK_DIR=$(mktemp -d)
  tmp=$WORK_DIR
  if [[ -n $from ]]; then
    [[ -f $from ]] || die "Datei nicht gefunden: $from"
    archive=$from
  else
    archive=$(download_release "$tmp")
  fi
  ensure_user
  install_files "$archive" "$tmp"
  ensure_config
  configure 0
  ensure_avahi
  start_service
  summary
}

# Run by lumo-update.service when the web UI asked for an update
# (file $STATE_DIR/update-request with the version, written by the server).
do_auto_update() {
  need_root
  local request="$STATE_DIR/update-request" result="$STATE_DIR/update-result"
  local requested installed newest
  [[ -f $request ]] || exit 0
  requested=$(head -c 64 "$request" | tr -d '[:space:]')
  rm -f "$request" # first: a failing run must not trigger again
  fail() {
    printf 'failed: %s\n' "$1" > "$result"
    chmod 644 "$result"
    die "$1"
  }
  [[ $requested =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Ungültige Version: $requested"
  installed=$(cat "$PREFIX/VERSION" 2>/dev/null || echo v0.0.0)
  installed=${installed%%-*}
  newest=$(printf '%s\n%s\n' "${installed#v}" "${requested#v}" | sort -V | tail -1)
  if [[ ${installed#v} == "${requested#v}" || $newest != "${requested#v}" ]]; then
    fail "$requested ist nicht neuer als die installierte Version $installed"
  fi
  say "Update von $installed auf $requested (angefordert in der Web-Oberfläche)"
  version=$requested
  rm -f "$result"
  # Subshell: die() inside the installation ends only it, so the failure is
  # reported to the web UI.
  if ! (do_install); then
    fail "Installation von $requested fehlgeschlagen – Details: journalctl -u $APP-update"
  fi
}

do_configure() {
  need_root
  [[ -x $PREFIX/bin/hash_password ]] || die "$APP ist nicht installiert."
  [[ $interactive == 1 ]] || die "--configure braucht ein Terminal."
  ensure_config
  configure 1
  # Settings made in the web UI take precedence over config.env: let the
  # server forget them for the keys just entered (applied on its next start).
  if [[ -d $STATE_DIR ]]; then
    printf '%s\n' SPH_SCHOOL_ID SPH_USERNAME SPH_PASSWORD APP_PASSWORD_HASH \
      NTFY_URL NTFY_TOPIC NTFY_TOKEN APP_URL > "$STATE_DIR/reset-web-settings"
    chmod 644 "$STATE_DIR/reset-web-settings"
  fi
  if [[ $SKIP_SYSTEMD != 1 ]] && systemctl is-enabled --quiet "$APP" 2>/dev/null; then
    start_service
  fi
}

do_rollback() {
  need_root
  [[ -d $PREFIX.old ]] || die "Keine vorherige Version vorhanden ($PREFIX.old)."
  say "Wechsle zurück zu Version $(cat "$PREFIX.old/VERSION" 2>/dev/null || echo '?')"
  rm -rf "$PREFIX.new"
  mv "$PREFIX" "$PREFIX.new"
  mv "$PREFIX.old" "$PREFIX"
  mv "$PREFIX.new" "$PREFIX.old"
  install -m 644 "$PREFIX/deploy/$APP.service" "$UNIT_FILE"
  start_service
  summary
}

do_uninstall() {
  need_root
  say "Entferne $APP"
  systemd disable --now "$APP" "${UPDATE_UNITS[0]}" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "${UPDATE_UNITS[@]/#/$UNIT_DIR/}"
  rm -rf "$DROPIN_DIR" "$PREFIX" "$PREFIX.old" "$PREFIX.new"
  systemd daemon-reload || true
  if [[ $purge == 1 ]]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    if [[ $SKIP_USER != 1 ]] && getent passwd "$SERVICE_USER" >/dev/null; then
      userdel "$SERVICE_USER" || true
    fi
    say "Konfiguration, Daten und Benutzer entfernt."
  else
    say "Konfiguration ($CONFIG_DIR) und Daten ($STATE_DIR) bleiben erhalten (--purge entfernt sie)."
  fi
}

case $action in
  install) do_install ;;
  configure) do_configure ;;
  rollback) do_rollback ;;
  uninstall) do_uninstall ;;
  auto-update) do_auto_update ;;
esac
