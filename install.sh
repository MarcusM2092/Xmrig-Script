#!/usr/bin/env bash
set -euo pipefail

WALLET="42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv"
WORKER="Donation"
INSTALL_DIR="/opt/moneroocean"

echo "Installing required packages..."
if command -v dnf >/dev/null 2>&1; then
sudo dnf install -y curl jq tar msr-tools
elif command -v apt-get >/dev/null 2>&1; then
sudo apt-get update && sudo apt-get install -y curl jq tar msr-tools
fi

echo "Configuring huge pages and MSR..."
sudo modprobe msr 2>/dev/null || true
sudo sysctl -w vm.nr_hugepages=1280
if ! grep -q "vm.nr_hugepages" /etc/sysctl.conf 2>/dev/null; then
echo "vm.nr_hugepages=1280" | sudo tee -a /etc/sysctl.conf >/dev/null
fi

echo "Downloading MoneroOcean XMRig..."
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

URL=(curl−fsSLhttps://api.github.com/repos/MoneroOcean/xmrig/releases/latest∣jq−er′.assets[]∣select(.name∣test("lin−compat.tar.gz")) | .browser_download_url' | head -n 1)

sudo curl -fsSL -o xmrig.tar.gz "$URL"
sudo tar -xf xmrig.tar.gz
sudo rm -f xmrig.tar.gz
sudo chmod +x xmrig

echo "Writing optimized configuration..."
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

echo "Done. Service is running as root with huge pages and MSR optimizations enabled."
