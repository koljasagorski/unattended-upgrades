# Auto Updates & Release Upgrades for Ubuntu/Debian with Email Reports

## Beschreibung

Dieses Script richtet auf **Ubuntu** und **Debian** vollautomatische tägliche Paketupdates via `unattended-upgrades` ein, versendet Mail-Reports (bei Änderungen/Fehlern) über einen eigenen SMTP-Relay (`msmtp`) und automatisiert Major/Release-Upgrades:

- **Ubuntu**: Wöchentlicher Check & unbeaufsichtigtes **LTS → LTS Release-Upgrade** (`do-release-upgrade`) mit Log/Report per Mail.  
- **Debian**: Schaltet APT-Quellen auf den `stable`-Alias, sodass beim nächsten Stable-Release ein normaler `full-upgrade` den Major-Sprung ausführt. Ein wöchentlicher `systemd`-Timer führt den Upgrade-Job aus und mailt das Log.

---

## Features

- `unattended-upgrades` mit:
  - täglichem Update/Upgrade
  - automatischem Autoremove ungenutzter Pakete
  - geplanten Reboots (default **02:00**)
  - E-Mail-Report bei Änderungen & Fehlern
- SMTP-Relay via **msmtp** + **mailx**
- Ubuntu **Release-Upgrades (LTS→LTS)** automatisch, Bericht per Mail
- Debian **Full-Upgrades wöchentlich** (mit stable-Alias), Bericht per Mail
- Automatische Sicherungen deiner **APT-Quellen** vor Änderungen

---

## Voraussetzungen

- **Ubuntu 20.04+** oder **Debian 10+**
- Ausgehende Verbindung zum SMTP-Server
- Root-Zugriff

---

## Installation & Nutzung

bash
# 1) Script auf Zielsystem kopieren & starten
curl -fsSL https://raw.githubusercontent.com/koljasagorski/unattended-upgrades/refs/heads/main/setup_auto_updates.sh -o setup_auto_updates.sh \
  && chmod +x setup_auto_updates.sh \
  && sudo bash setup_auto_updates.sh

# 2) Fertig. Testmail wird automatisch versendet.

Konfiguration

Passe oben im Script folgende Variablen an:

EMAIL="dein@postfach.tld"
SMTP_HOST="smtp.example.org"
SMTP_PORT="465"
SMTP_USER="user"
SMTP_PASS="passwort"
REBOOT_TIME="02:00"

Sicherheitshinweise
	•	Downtime: Release-/Major-Upgrades & Auto-Reboots können Dienste unterbrechen → Wartungsfenster beachten.
	•	SMTP-Secret: Die Zugangsdaten liegen in /etc/msmtprc (Root, 0600). In Produktion besser aus Secret-File/Keyring laden.
	•	Backports: sind in Origins-Pattern aktiviert. Wer konservativer fahren will, entfernt die -backports-Zeilen.

⸻

Deaktivieren (optional)
	•	Ubuntu Release-Upgrade Timer:
 sudo systemctl disable --now ubuntu-auto-release-upgrade.timer

 	•	Debian Full-Upgrade Timer:

  sudo systemctl disable --now debian-auto-full-upgrade.timer

  Logs
	•	Unattended-Upgrades Dry-Run:
/var/log/unattended-upgrades-dryrun.log
	•	Ubuntu Release-Upgrade:
/var/log/ubuntu-release-upgrade-auto.log
	•	Debian Full-Upgrade:
/var/log/debian-auto-full-upgrade.log
	•	msmtp:
/var/log/msmtp.log
