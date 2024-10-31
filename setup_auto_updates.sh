#!/bin/bash

# Script zur Konfiguration automatischer Updates für alle Pakete

echo "Aktualisiere Paketlisten und installiere unattended-upgrades..."
sudo apt update
sudo apt install -y unattended-upgrades

# Konfiguriere automatische Updates
echo "Konfiguriere automatische Updates für alle Pakete..."

sudo bash -c 'cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF'

# Konfiguration für unattended-upgrades
sudo bash -c 'cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Origins-Pattern {
        // Automatische Updates von allen Quellen akzeptieren
        "origin=Debian,codename=\${distro_codename}-security";
        "origin=Debian,codename=\${distro_codename}-updates";
        "origin=Debian,codename=\${distro_codename}-backports";
        "origin=Ubuntu,codename=\${distro_codename}-security";
        "origin=Ubuntu,codename=\${distro_codename}-updates";
        "origin=Ubuntu,codename=\${distro_codename}-backports";
};

// Automatisches Entfernen nicht mehr benötigter Pakete
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatische Neustarts aktivieren, wenn notwendig
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF'

# Aktivieren des Dienstes für automatische Updates
echo "Aktiviere und starte den Dienst für automatische Updates..."
sudo systemctl enable unattended-upgrades
sudo systemctl start unattended-upgrades

echo "Automatische Updates sind konfiguriert."
