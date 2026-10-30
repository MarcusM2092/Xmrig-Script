#!/bin/bash
set -euo pipefail

# Install dependencies
echo "Installing dependencies..."
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y curl jq tar
    # msr-tools is not needed on ARM, so we skip it
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl jq tar
    # msr-tools is not needed on ARM, so we skip it
else
    echo "Unsupported package manager. Please install curl, jq, and tar manually."
    exit 1
fi

# Create directory and download release
echo "Setting up mining directory..."
sudo mkdir -p /root/moneroocean
cd /root/moneroocean

download_release() {
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
    jq -er --arg asset "$2" --arg prefix "https://github.com/$1/releases/download/" '
      .assets | if type == "array" then . else error("Expected release assets") end
      | map(select(type == "object") | select(.name | type == "string")
        | select(.name | test($asset; "i")) | .browser_download_url
        | select(type == "string")
        | select(startswith($prefix) and test("^https://[-A-Za-z0-9._~:/%+]+$")))
      | first') || { echo 'No matching release asset' >&2; exit 1; }
  curl -fL -o "$3" -- "$url"
}

echo "Downloading XMRig..."
download_release MoneroOcean/xmrig 'lin-compat\.tar\.gz$' xmrig.tar.gz
tar xf xmrig.tar.gz
chmod +x xmrig

# Create optimized config
cat > config.json <<EOF
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

# Create systemd service file
cat > /tmp/moneroocean.service <<EOF
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
CPUQuota=90%

[Install]
WantedBy=multi-user.target
EOF

# Install and enable service
echo "Setting up systemd service..."
sudo mv /tmp/moneroocean.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable moneroocean
sudo systemctl start moneroocean

echo "MoneroOcean miner installed and running as systemd service"
echo "Check status with: systemctl status moneroocean"
echo "View logs with: journalctl -u moneroocean -f"
