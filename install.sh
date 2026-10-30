#!/usr/bin/env bash

# Robust installer with error handling and logging
LOG_FILE="/tmp/moneroocean-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

set -euo pipefail

trap 'echo "Error occurred at line $LINENO. Check $LOG_FILE for details."; exit 1' ERR

echo "Starting installation..."

# Package installation with retry mechanism
install_pkgs() {
    local retries=3
    local count=0
    until sudo dnf install -y curl jq tar msr-tools || sudo apt-get install -y curl jq tar msr-tools; do
        ((count++))
        if [ "$count" -ge "$retries" ]; then
            echo "Failed to install packages after $retries attempts."
            exit 1
        fi
        echo "Retrying package installation ($count)..."
        sleep 5
    done
}

echo "Updating system and installing dependencies..."
install_pkgs

echo "Configuring huge pages..."
# Attempt to set huge pages; failing here shouldn't kill the script if it's already set
sudo sysctl -w vm.nr_hugepages=1280 || echo "Note: Could not set huge pages, performance may be lower."

echo "Downloading XMRig..."
INSTALL_DIR="/opt/moneroocean"
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

URL=$(curl -fsSL https://api.github.com/repos/MoneroOcean/xmrig/releases/latest | jq -er '.assets[] | select(.name | test("lin-compat\\.tar\\.gz$")) | .browser_download_url' | head -n 1)

sudo curl -fL -o xmrig.tar.gz "$URL"
sudo tar -xf xmrig.tar.gz --strip-components=1
sudo rm -f xmrig.tar.gz
sudo chmod +x xmrig

echo "Generating config..."
sudo tee "$INSTALL_DIR/config.json" > /dev/null <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "priority": 5,
        "asm": true
    },
    "pools": [
        {
            "url": "gulf.moneroocean.stream:10128",
            "user": "42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv",
            "pass": "Donation",
            "tls": false
        }
    ]
}
EOF

echo "Installing service..."
sudo tee /etc/systemd/system/moneroocean.service > /dev/null <<EOF
[Unit]
Description=MoneroOcean Miner
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xmrig -c $INSTALL_DIR/config.json
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now moneroocean.service

echo "Installation complete. Service logs: sudo journalctl -u moneroocean.service -f"
