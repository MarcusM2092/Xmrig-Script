#!/usr/bin/env bash
set -euo pipefail

WALLET="42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv"
WORKER="Donation"
INSTALL_DIR="/opt/moneroocean"

echo "Installing dependencies..."
if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl jq tar msr-tools
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq curl jq tar msr-tools
fi

echo "Setting huge pages..."
sudo sysctl -w vm.nr_hugepages=1280 || true

echo "Downloading MoneroOcean XMRig..."
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

URL=$(curl -fsSL https://api.github.com/repos/MoneroOcean/xmrig/releases/latest | jq -er '.assets[] | select(.name | test("lin-compat\\.tar\\.gz$")) | .browser_download_url' | head -n 1)

sudo curl -fL -o xmrig.tar.gz "$URL"
# Extract and find the binary regardless of folder name
sudo tar -xf xmrig.tar.gz
# Use find to locate and move the binary to the root of /opt/moneroocean
sudo find . -name "xmrig" -type f -exec mv {} . \;
sudo rm -rf xmrig.tar.gz xmrig-*
sudo chmod +x xmrig

echo "Writing configuration..."
sudo tee config.json > /dev/null <<EOF
{
    "autosave": true,
    "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": true, "asm": true },
    "pools": [{
        "url": "gulf.moneroocean.stream:10128",
        "user": "$WALLET",
        "pass": "$WORKER"
    }]
}
EOF

echo "Starting systemd service..."
sudo tee /etc/systemd/system/moneroocean.service > /dev/null <<EOF
[Unit]
Description=MoneroOcean Miner
After=network-online.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xmrig -c $INSTALL_DIR/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now moneroocean.service
echo "Installation complete."
