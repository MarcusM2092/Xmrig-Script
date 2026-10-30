sudo apt-get install curl jq
mkdir -p ~/moneroocean && cd ~/moneroocean
download_release() {
  local url
  url=$(set -o pipefail
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
      jq -er --arg asset "$2" --arg prefix "https://github.com/$1/releases/download/" '
        .assets | if type == "array" then . else error("Expected release assets") end
        | map(select(type == "object") | select(.name | type == "string")
          | select(.name | test($asset; "i")) | .browser_download_url
          | select(type == "string")
          | select(startswith($prefix) and test("^https://[-A-Za-z0-9._~:/%+]+$")))
        | first') || { echo 'No matching release asset' >&2; exit 1; }
  curl -fL -o "$3" -- "$url"
}
download_release MoneroOcean/xmrig 'lin-compat\.tar\.gz$' xmrig.tar.gz && tar xf xmrig.tar.gz && chmod +x xmrig

./xmrig --config=./config.json -o gulf.moneroocean.stream:20004 -u 42qdWYwdo8GXVJaQF6WNtCCvRCgZmB4Kc3BYbait61jVbCo9vDooqvEEUhHnMxf1bzJrVwGQB5jT5CzF8AvcDu6i8qrHBZv --rig-id Donation --keepalive --tls
