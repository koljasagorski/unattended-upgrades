#!/usr/bin/env bash
set -euo pipefail

# =========================
# Konfiguration
# =========================
EMAIL=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""   # Tipp: In Prod aus Secret-Datei lesen
REBOOT_TIME="02:00"               # geplante Reboots durch unattended-upgrades

export DEBIAN_FRONTEND=noninteractive

# =========================
# Helper
# =========================
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
is_ubuntu() { [ -f /etc/lsb-release ] && grep -qi 'ubuntu' /etc/lsb-release; }
is_debian() { [ -f /etc/os-release ] && grep -qi '^ID=debian' /etc/os-release; }
ts() { date -Is; }

log() { echo "[$(ts)] $*"; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Bitte als root ausführen (sudo bash $0)"; exit 1
  fi
}

# Sichert Datei, falls vorhanden
backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.$(date +%Y%m%d%H%M%S).bak"
  fi
}

# =========================
# Start
# =========================
require_root
log "Starte Setup für automatische Updates inkl. Mail-Reports…"

log "[1/9] Paketquellen aktualisieren & Basispakete installieren"
apt-get update -y
apt-get install -y --no-install-recommends \
  unattended-upgrades ca-certificates apt-transport-https \
  msmtp msmtp-mta bsd-mailx

# =========================
# msmtp + mailx konfigurieren
# =========================
log "[2/9] Konfiguriere msmtp (SMTP Relay) & mailx"
backup_file /etc/msmtprc
cat > /etc/msmtprc <<EOF
# msmtp systemweit
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${EMAIL}
user           ${SMTP_USER}
password       ${SMTP_PASS}
EOF
chmod 600 /etc/msmtprc
chown root:root /etc/msmtprc

backup_file /etc/mail.rc
cat > /etc/mail.rc <<EOF
set sendmail=/usr/bin/msmtp
set from=${EMAIL}
set realname=Unattended-Upgrades
set usefrom=yes
set envelope-from=yes
EOF

# =========================
# APT Periodics
# =========================
log "[3/9] Richte APT-Periodics ein (tägliche Läufe)"
backup_file /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";          // täglich Paketlisten
APT::Periodic::Download-Upgradeable-Packages "1"; // täglich Pakete laden
APT::Periodic::Unattended-Upgrade "1";            // täglich upgraden
APT::Periodic::AutocleanInterval "7";             // wöchentlich autoclean
EOF

# =========================
# unattended-upgrades
# =========================
log "[4/9] Konfiguriere unattended-upgrades (Mail, Quellen, Reboot)"
. /etc/os-release
DIST_CODENAME="${VERSION_CODENAME:-}"

backup_file /etc/apt/apt.conf.d/50unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Quellen: Muster funktionieren für Ubuntu & Debian, Nicht-Passendes wird ignoriert.
Unattended-Upgrade::Origins-Pattern {
  // Ubuntu
  "origin=Ubuntu,codename=\${distro_codename}-security";
  "origin=Ubuntu,codename=\${distro_codename}-updates";
  "origin=Ubuntu,codename=\${distro_codename}-backports";

  // Debian
  "origin=Debian,codename=\${distro_codename}-security";
  "origin=Debian,codename=\${distro_codename}-updates";
  "origin=Debian,codename=\${distro_codename}-backports";
};

// Mail-Reporting
Unattended-Upgrade::Mail "${EMAIL}";
Unattended-Upgrade::MailReport "on-change"; // E-Mail bei Änderungen & Fehlern

// Verhalten
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";

// Paket-Blacklist (leer)
Unattended-Upgrade::Package-Blacklist {};
EOF

# =========================
# Systemd APT Timer & Dienst
# =========================
log "[5/9] Aktiviere systemd Timer für APT & unattended-upgrades"
systemctl enable --now unattended-upgrades || true

if systemctl list-unit-files | grep -q apt-daily.timer; then
  systemctl enable --now apt-daily.timer || true
fi
if systemctl list-unit-files | grep -q apt-daily-upgrade.timer; then
  systemctl enable --now apt-daily-upgrade.timer || true
fi

# =========================
# Ubuntu: Release-Upgrades automatisieren (LTS->LTS)
# =========================
setup_ubuntu_release_upgrade() {
  log "Ubuntu erkannt – richte automatische Release-Upgrades (LTS→LTS) ein"
  apt-get install -y --no-install-recommends ubuntu-release-upgrader-core

  # Nur LTS-Upgrade-Pfad
  sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades || true

  # Service & Timer (So 03:00)
  cat > /etc/systemd/system/ubuntu-auto-release-upgrade.service <<'EOS'
[Unit]
Description=Unbeaufsichtigtes Ubuntu Release-Upgrade (do-release-upgrade)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '\
  LOG=/var/log/ubuntu-release-upgrade-auto.log; \
  echo "=== $(date -Is) Start Ubuntu Release-Check ===" | tee -a "$LOG"; \
  if /usr/bin/do-release-upgrade -c -m server | grep -qi "New release"; then \
     echo "Neue Ubuntu-Version gefunden – starte unbeaufsichtigtes Upgrade" | tee -a "$LOG"; \
     /usr/bin/do-release-upgrade -f DistUpgradeViewNonInteractive -m server -q >> "$LOG" 2>&1; \
     STATUS=$?; \
     SUBJECT="Ubuntu Release-Upgrade $(hostname -f): Exit $STATUS"; \
     /usr/bin/mail -s "$SUBJECT" '"$EMAIL"' < "$LOG"; \
     exit $STATUS; \
  else \
     echo "Keine neue Ubuntu-Version verfügbar" | tee -a "$LOG"; \
     /usr/bin/mail -s "Ubuntu Release-Upgrade: keine neue Version auf $(hostname -f)" '"$EMAIL"' < "$LOG"; \
  fi'
EOS

  cat > /etc/systemd/system/ubuntu-auto-release-upgrade.timer <<'EOS'
[Unit]
Description=Wöchentlicher Check auf Ubuntu Release-Upgrades

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOS

  systemctl daemon-reload
  systemctl enable --now ubuntu-auto-release-upgrade.timer
}

# =========================
# Debian: Große Upgrades automatisieren
# Ansatz: Quellen auf "stable"-Alias umstellen => beim nächsten Stable-Release
# genügt ein normaler "full-upgrade". Ein wöchentlicher Timer führt das aus
# und versendet Logs per Mail.
# =========================
switch_debian_sources_to_stable_aliases() {
  log "Debian erkannt – stelle APT-Quellen auf 'stable'-Alias um (mit Backup)"

  # Hauptliste
  if [ -f /etc/apt/sources.list ]; then
    backup_file /etc/apt/sources.list
    if [ -n "${DIST_CODENAME:-}" ] && grep -q "$DIST_CODENAME" /etc/apt/sources.list; then
      sed -i "s/${DIST_CODENAME}/stable/g" /etc/apt/sources.list
    fi
  fi

  # Zusätzliche Listen
  if [ -d /etc/apt/sources.list.d ]; then
    find /etc/apt/sources.list.d -type f -name "*.list" | while read -r f; do
      backup_file "$f"
      if [ -n "${DIST_CODENAME:-}" ] && grep -q "$DIST_CODENAME" "$f"; then
        sed -i "s/${DIST_CODENAME}/stable/g" "$f"
      fi
    done
  fi

  # Falls security noch altes Schema hat, nicht schlimm – aliaswechsel erfolgt serverseitig.
  apt-get update -y || true
}

setup_debian_auto_full_upgrade() {
  log "Richte wöchentliches automatisches Debian Full-Upgrade + Mail-Report ein"

  cat > /etc/systemd/system/debian-auto-full-upgrade.service <<'EOS'
[Unit]
Description=Debian: automatisches Full-Upgrade mit Mail-Report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
Environment=NEEDRESTART_MODE=a
ExecStart=/bin/bash -lc '\
  LOG=/var/log/debian-auto-full-upgrade.log; \
  echo "=== $(date -Is) Start Debian Full-Upgrade ===" | tee -a "$LOG"; \
  apt-get update -y >> "$LOG" 2>&1; \
  apt-get -y -o Dpkg::Options::=--force-confnew full-upgrade >> "$LOG" 2>&1; \
  STATUS=$?; \
  echo "Exit-Code: $STATUS" | tee -a "$LOG"; \
  if [ -f /var/run/reboot-required ]; then echo "[Hinweis] Reboot erforderlich" | tee -a "$LOG"; fi; \
  /usr/bin/mail -s "Debian Full-Upgrade $(hostname -f): Exit $STATUS" '"$EMAIL"' < "$LOG"; \
  exit $STATUS'
EOS

  cat > /etc/systemd/system/debian-auto-full-upgrade.timer <<'EOS'
[Unit]
Description=Wöchentlicher Debian Full-Upgrade-Job

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOS

  systemctl daemon-reload
  systemctl enable --now debian-auto-full-upgrade.timer
}

# =========================
# Distro-spezifisches Setup
# =========================
if is_ubuntu; then
  setup_ubuntu_release_upgrade
elif is_debian; then
  switch_debian_sources_to_stable_aliases
  setup_debian_auto_full_upgrade
else
  log "Weder Ubuntu noch Debian klar erkannt – überspringe Release-Upgrade-Automatik."
fi

# =========================
# Test-Mail
# =========================
log "[8/9] Sende Test-Mail"
echo "Test: msmtp/sendmail für unattended-upgrades & Auto-Upgrades ist eingerichtet." \
  | mail -s "OK: Auto-Update-Mail-Test auf $(hostname -f)" "${EMAIL}" || true

# =========================
# Dry-Run & Abschluss
# =========================
log "[9/9] Starte unattended-upgrades Dry-Run (Log unter /var/log/unattended-upgrades-dryrun.log)"
unattended-upgrades --dry-run --debug |& tee /var/log/unattended-upgrades-dryrun.log || true

log "Konfiguration abgeschlossen. Automatische Updates & große Upgrades sind aktiv."
