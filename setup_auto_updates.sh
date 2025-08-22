#!/usr/bin/env bash
set -euo pipefail

EMAIL=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""   # <- Plaintext: erwäge später einen Anmeldetoken/Passwort-File mit restr. Rechten

export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Paketlisten aktualisieren & Grundlagen installieren…"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  unattended-upgrades apt-transport-https ca-certificates \
  msmtp msmtp-mta bsd-mailx

echo "[2/8] msmtp als sendmail-Provider konfigurieren…"
/usr/bin/sudo bash -c "cat > /etc/msmtprc <<'EOF'
# msmtp systemweite Konfiguration
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
EOF"

sudo chmod 600 /etc/msmtprc
sudo chown root:root /etc/msmtprc
# Mailx so konfigurieren, dass es msmtp nutzt
/usr/bin/sudo bash -c "cat > /etc/mail.rc <<'EOF'
set sendmail=/usr/bin/msmtp
set from=${EMAIL}
set realname=Unattended-Upgrades
set usefrom=yes
set envelope-from=yes
EOF"

echo "[3/8] Periodische APT-Jobs konfigurieren…"
/usr/bin/sudo bash -c "cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";          // täglich Paketlisten
APT::Periodic::Download-Upgradeable-Packages "1"; // täglich Pakete laden
APT::Periodic::Unattended-Upgrade "1";            // täglich upgraden
APT::Periodic::AutocleanInterval "7";             // wöchentlich autoclean
EOF"

echo "[4/8] unattended-upgrades fein einstellen…"
/usr/bin/sudo bash -c "cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
// Welche Quellen akzeptiert werden (Debian & Ubuntu Patterns, nicht passende werden ignoriert)
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

// Reporting per Mail
Unattended-Upgrade::Mail "${EMAIL}";
Unattended-Upgrade::MailReport "on-change"; // bei Änderungen & Fehlern mailen

// Verhalten
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true"; // rebootet auch bei eingeloggten Nutzern
Unattended-Upgrade::MinimalSteps "true";               // kleinere Schritte, geringere Downtime
Unattended-Upgrade::InstallOnShutdown "false";         // bevorzugt nächtliche Runs

// Optional: Kernel-Pinning/Blacklist möglich, aktuell leer
Unattended-Upgrade::Package-Blacklist {
};
EOF"

echo "[5/8] APT Timer & Dienste aktivieren…"
# Auf modernen Systemen steuern systemd Timer die Läufe zusätzlich:
if systemctl list-unit-files | grep -q apt-daily.timer; then
  sudo systemctl enable --now apt-daily.timer || true
fi
if systemctl list-unit-files | grep -q apt-daily-upgrade.timer; then
  sudo systemctl enable --now apt-daily-upgrade.timer || true
fi

sudo systemctl enable --now unattended-upgrades

echo "[6/8] Test-Mail versenden…"
echo "Test: msmtp/sendmail ist für unattended-upgrades eingerichtet." \
  | mail -s "OK: Auto-Update-Mail-Test auf $(hostname -f)" "${EMAIL}" || true

echo "[7/8] (Optional) Ubuntu Release-Upgrades automatisieren…"
# Nur auf Ubuntu sinnvoll: unbeaufsichtigte Dist-Upgrade (z.B. 22.04->24.04)
if [ -f /etc/lsb-release ] && grep -qi ubuntu /etc/lsb-release; then
  sudo apt-get install -y --no-install-recommends ubuntu-release-upgrader-core

  # Nur LTS->LTS Upgrades erlauben (empfohlen)
  sudo sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades || true

  # Systemd Service + Timer anlegen (wöchentlicher Check So 03:00)
  /usr/bin/sudo bash -c "cat > /etc/systemd/system/ubuntu-auto-release-upgrade.service <<'EOF'
[Unit]
Description=Unbeaufsichtigtes Ubuntu Release-Upgrade (do-release-upgrade)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '\
  LOG=/var/log/ubuntu-release-upgrade-auto.log; \
  echo \"=== \$(date -Is) Starting release upgrade check ===\" | tee -a \"$LOG\"; \
  if /usr/bin/do-release-upgrade -c -m server | grep -qi \"New release\"; then \
     echo \"Neue Version gefunden – starte unbeaufsichtigtes Upgrade\" | tee -a \"$LOG\"; \
     /usr/bin/do-release-upgrade -f DistUpgradeViewNonInteractive -m server -q >> \"$LOG\" 2>&1; \
     STATUS=\$?; \
     SUBJECT=\"Release-Upgrade \$(hostname -f): Exit \$STATUS\"; \
     /usr/bin/mail -s \"$SUBJECT\" ${EMAIL} < \"$LOG\"; \
     exit \$STATUS; \
  else \
     echo \"Keine neue Version verfügbar\" | tee -a \"$LOG\"; \
     /usr/bin/mail -s \"Release-Upgrade: keine neue Version auf \$(hostname -f)\" ${EMAIL} < \"$LOG\"; \
  fi'
EOF"

  /usr/bin/sudo bash -c "cat > /etc/systemd/system/ubuntu-auto-release-upgrade.timer <<'EOF'
[Unit]
Description=Wöchentlicher Check auf Ubuntu Release-Upgrades

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF"

  sudo systemctl daemon-reload
  sudo systemctl enable --now ubuntu-auto-release-upgrade.timer
else
  echo "→ Nicht Ubuntu: Release-Upgrade-Automatik wird übersprungen."
fi

echo "[8/8] Dry-Run zum Gegencheck starten…"
sudo unattended-upgrades --dry-run --debug |& tee /var/log/unattended-upgrades-dryrun.log || true
echo "Konfiguration abgeschlossen."
