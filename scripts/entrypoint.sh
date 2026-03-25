#!/bin/sh
# OpenClaw-Vault entrypoint wrapper
#
# Handles both volatile (tmpfs/Hard Shell) and persistent (volume/Split Shell) modes.
# 1. Install or preserve OpenClaw config
# 2. Wait for mitmproxy CA cert
# 3. Install or preserve auth profile
# 4. Exec into OpenClaw

CONFIG_SRC="/opt/openclaw-hardening.json5"
CONFIG_DST="/home/vault/.openclaw/openclaw.json"
AUTH_DIR="/home/vault/.openclaw/agents/main/agent"
AUTH_FILE="$AUTH_DIR/auth-profiles.json"
CERT="/opt/proxy-ca/mitmproxy-ca-cert.pem"

# --- 1. Config installation ---
# On tmpfs (Hard Shell): always copy — tmpfs is empty on start.
# On persistent volume (Split Shell): only copy on first run.
# The switch-shell.sh script writes config directly to the volume when switching.
mkdir -p "$(dirname "$CONFIG_DST")"

if [ -f "$CONFIG_DST" ]; then
    echo "[vault] Existing config preserved (persistent volume)"
else
    if [ -f "$CONFIG_SRC" ]; then
        cp "$CONFIG_SRC" "$CONFIG_DST"
        echo "[vault] Config installed from image (first run)"
    else
        echo "[vault] ERROR: No config found at $CONFIG_SRC or $CONFIG_DST" >&2
        exit 1
    fi
fi

# --- 2. Wait for mitmproxy CA cert ---
echo "[vault] Waiting for proxy CA certificate..."
for i in $(seq 1 60); do
    if [ -f "$CERT" ] && grep -q "END CERTIFICATE" "$CERT" 2>/dev/null; then
        echo "[vault] CA certificate found."
        break
    fi
    sleep 1
done
if [ ! -f "$CERT" ] || ! grep -q "END CERTIFICATE" "$CERT" 2>/dev/null; then
    echo "[vault] ERROR: Proxy CA cert not found or incomplete after 60s. Aborting." >&2
    exit 1
fi

# --- 3. Auth profile ---
# Placeholder API key — the real key is injected by the proxy sidecar.
# Only create if it doesn't exist (preserves across restarts on persistent volume).
if [ ! -f "$AUTH_FILE" ]; then
    mkdir -p "$AUTH_DIR"
    cat > "$AUTH_FILE" << 'AUTHEOF'
{
  "profiles": {
    "anthropic:api": {
      "provider": "anthropic",
      "type": "api_key",
      "key": "sk-ant-api03-placeholder-vault-proxy-will-inject-real-key-placeholder"
    }
  },
  "order": {
    "anthropic": ["anthropic:api"]
  }
}
AUTHEOF
    echo "[vault] Auth profile installed (placeholder key — real key injected by proxy)"
else
    echo "[vault] Auth profile preserved (persistent volume)"
fi

# --- 4. Start OpenClaw ---
echo "[vault] Starting OpenClaw..."
exec "$@"
