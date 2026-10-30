#!/bin/bash
set -euo pipefail

echo "Installing dependencies..."
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y curl jq tar
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl jq tar
else
    echo "Unsupported package manager."
    exit 1
fi

echo "Setting up mining directory..."
sudo mkdir -p /root/moneroocean
cd /root/moneroocean

# Detect CPU architecture
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)
        echo "Detected ARM64 architecture"
        ;;
    armv7l)
        echo "Detected ARMv7 architecture"
        ;;
    x86_64)
        echo "Detected x86_64 architecture"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Download the correct ARM64 binary directly
echo "Downloading ARM64 XMRig..."
curl -fL -o xmrig.tar.gz "https://github.com/MoneroOcean/xmrig/releases/download/6.22.2/xmrig-arm64.tar.gz"

# Extract and move binary
tar -xf xmrig.tar.gz
mv xmrig /root/moneroocean/xmrig
rm -rf xmrig.tar.gz

# Create config
cat > /root/moneroocean/config.json <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "asm": true
    },
    "pools": [
        {
            "url": "gulf.moneroocean.stream:10128",
            "user": "42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv",
            "pass": "Donation",
            "keepalive": true,
            "tls": false
        }
    ]
}
EOF

# Create systemd service
cat > /etc/systemd/system/moneroocean.service <<EOF
[Unit]
Description=MoneroOcean Miner
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/moneroocean
ExecStart=/root/moneroocean/xmrig -c /root/moneroocean/config.json
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF

echo "Starting systemd service..."
sudo systemctl daemon-reload
sudo systemctl enable moneroocean
sudo systemctl restart moneroocean

echo "MoneroOcean miner installed and running."
echo "Check status: systemctl status moneroocean"
