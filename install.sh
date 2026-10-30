#!/usr/bin/env bash
set -euo pipefail

WALLET="42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv"
WORKER="Donation"
INSTALL_DIR="/opt/moneroocean"

echo "Updating and installing dependencies..."
if command -v dnf >/dev/null 2>&1; then
    sudo dnf update -y
    sudo dnf install -y curl jq tar msr-tools
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq curl jq tar msr-tools
else
    echo "Unsupported package manager. Please install curl, jq, tar, and msr-tools manually."
    exit 1
fi

echo "Configuring huge pages and MSR module..."
sudo modprobe msr 2>/dev/null || true # Load MSR module, ignore if already loaded or not available
sudo sysctl -w vm.nr_hugepages=1280 || echo "Warning: Could not set huge pages. Miner performance may be reduced."
if ! grep -q "vm.nr_hugepages" /etc/sysctl.conf; then
    echo "vm.nr_hugepages=1280" | sudo tee -a /etc/sysctl.conf >/dev/null
fi

echo "Downloading MoneroOcean XMRig to $INSTALL_DIR..."
sudo mkdir -p "$INSTALL_DIR"

URL=$(curl -fsSL https://api.github.com/repos/MoneroOcean/xmrig/releases/latest | jq -er '.assets[] | select(.name | test("lin-compat\\.tar\\.gz$")) | .browser_download_url' | head -n 1)

sudo curl -fL -o "$INSTALL_DIR/xmrig.tar.gz" "$URL"
sudo tar -xf "$INSTALL_DIR/xmrig.tar.gz" -C "$INSTALL_DIR" --strip-components=1
sudo rm -f "$INSTALL_DIR/xmrig.tar.gz"
sudo chmod +x "$INSTALL_DIR/xmrig"

echo "Writing optimized XMRig configuration..."
sudo tee "$INSTALL_DIR/config.json" > /dev/null <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": null,
        "priority": 5,
        "memory-pool": false,
        "yield": true,
        "asm": true,
        "argon2-impl": null
    },
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "coin": "monero",
            "url": "gulf.moneroocean.stream:10128",
            "user": "$WALLET",
            "pass": "$WORKER",
            "tls": false,
            "keepalive": true
        }
    ]
}
EOF

echo "Setting up systemd service..."
sudo tee /etc/systemd/system/moneroocean.service > /dev/null <<EOF
[Unit]
Description=MoneroOcean Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xmrig -c $INSTALL_DIR/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now moneroocean.service

echo "MoneroOcean miner installed and running as a systemd service."
echo "Check its status with: sudo systemctl status moneroocean.service"
echo "View logs with: sudo journalctl -u moneroocean.service -f"
