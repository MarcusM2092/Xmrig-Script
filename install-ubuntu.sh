#!/bin/bash
set -euo pipefail

echo "Installing dependencies..."
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y curl jq tar build-essential cmake libuv1-dev libssl-dev libhwloc-dev
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl jq tar gcc-c++ cmake libuv-devel openssl-devel hwloc-devel
else
    echo "Unsupported package manager."
    exit 1
fi

echo "Setting up mining directory..."
sudo mkdir -p /root/moneroocean
cd /root/moneroocean

# Clone and compile XMRig from source
echo "Cloning XMRig repository..."
git clone https://github.com/xmrig/xmrig.git
cd xmrig

echo "Configuring and building XMRig..."
./configure --with-crypto=hw
make -j$(nproc)

# Copy the compiled binary to the mining directory
sudo cp xmrig /root/moneroocean/
sudo chmod +x /root/moneroocean/xmrig

# Create config
cat > /root/moneroocean/config.json <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": false,
        "huge-pages-jit": false,
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
