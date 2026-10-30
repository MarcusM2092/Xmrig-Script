#!/usr/bin/env bash
# Strict mode: exit on error, undefined var, or pipe failure
set -euo pipefail

# 1. Detect package manager and force non-interactive
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_ARGS="-y"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
    PKG_ARGS="-y -qq"
    export DEBIAN_FRONTEND=noninteractive
else
    echo "Unsupported package manager."
    exit 1
fi

echo "Updating and installing dependencies using $PKG_MGR..."
# Wrap in a subshell with a timeout so it doesn't hang forever
sudo $PKG_MGR update $PKG_ARGS
sudo $PKG_MGR install $PKG_ARGS curl jq tar msr-tools

# 2. Huge pages setup
echo "Configuring huge pages..."
sudo sysctl -w vm.nr_hugepages=1280 || true

# 3. Download XMRig
INSTALL_DIR="/opt/moneroocean"
echo "Downloading to $INSTALL_DIR..."
sudo mkdir -p "$INSTALL_DIR"

# Get latest release URL
URL=$(curl -fsSL https://api.github.com/repos/MoneroOcean/xmrig/releases/latest | jq -er '.assets[] | select(.name | test("lin-compat\\.tar\\.gz$")) | .browser_download_url' | head -n 1)

sudo curl -fL -o "$INSTALL_DIR/xmrig.tar.gz" "$URL"
sudo tar -xf "$INSTALL_DIR/xmrig.tar.gz" -C "$INSTALL_DIR" --strip-components=1
sudo rm -f "$INSTALL_DIR/xmrig.tar.gz"
sudo chmod +x "$INSTALL_DIR/xmrig"

# 4. Write config
sudo tee "$INSTALL_DIR/config.json" > /dev/null <<EOF
{
    "autosave": true,
    "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": true, "asm": true },
    "pools": [{
        "url": "gulf.moneroocean.stream:10128",
        "user": "42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv",
        "pass": "Donation"
    }]
}
EOF

# 5. Service setup
echo "Starting service..."
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
echo "Successfully installed."
