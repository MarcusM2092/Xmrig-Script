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

# Detect CPU architecture to download the correct binary
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)
        ASSET_REGEX='(arm64|aarch64).*\.tar\.gz$'
        ;;
    armv7l)
        ASSET_REGEX='(arm|armv7).*\.tar\.gz$'
        ;;
    x86_64)
        ASSET_REGEX='(lin-x64|lin-compat).*\.tar\.gz$'
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Detected architecture: $ARCH"

download_release() {
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
    jq -er --arg asset "$2" --arg prefix "https://github.com/$1/releases/download/" '
      .assets | if type == "array" then . else error("Expected release assets") end
      | map(select(type == "object") | select(.name | type == "string")
        | select(.name | test($asset; "i")) | .browser_download_url
        | select(type == "string")
        | select(startswith($prefix) and test("^https://[-A-Za-z0-9._~:/%+]+$")))
      | first') || { echo "No matching release asset for pattern $2" >&2; exit 1; }
  curl -fL -o "$3" -- "$url"
}

echo "Downloading XMRig..."
download_release MoneroOcean/xmrig "$ASSET_REGEX" xmrig.tar.gz

# Extract and move xmrig binary to /root/moneroocean/xmrig
tar -xf xmrig.tar.gz
find . -name "xmrig" -type f -exec mv {} /root/moneroocean/ \;
rm -rf xmrig.tar.gz xmrig-*
chmod +x /root/moneroocean/xmrig

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

# Create systemd service file
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

echo "MoneroOcean miner installed and running as systemd service."
echo "Check status: systemctl status moneroocean"
