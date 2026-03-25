#!/usr/bin/env bash
# OpenClaw-Vault: Shell Switching (Molt)
#
# Switches between shell levels by swapping the OpenClaw config
# and restarting the container stack.
#
# Usage: bash scripts/switch-shell.sh <hard|split|soft>
#
# Each switch runs a pre-audit (what's the current state?) and
# post-audit (verify the new state is correct).

set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_LEVEL="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

RUNTIME="podman"
command -v podman &>/dev/null || RUNTIME="docker"

COMPOSE=""
if command -v "${RUNTIME}-compose" &>/dev/null; then
    COMPOSE="${RUNTIME}-compose"
elif $RUNTIME compose version &>/dev/null 2>&1; then
    COMPOSE="$RUNTIME compose"
fi

case "$SHELL_LEVEL" in
    hard|1)
        CONFIG_SRC="$VAULT_DIR/config/hard-shell.json5"
        SHELL_NAME="Hard Shell"
        SHELL_DESC="Maximum lockdown — conversation only, no file access"
        ;;
    split|2)
        CONFIG_SRC="$VAULT_DIR/config/split-shell.json5"
        SHELL_NAME="Split Shell"
        SHELL_DESC="Workspace file I/O enabled — persistent memory, identity, notes"
        ;;
    soft|3)
        echo -e "${YELLOW}Soft Shell is not yet implemented.${NC}"
        echo "Available: hard (1), split (2)"
        exit 1
        ;;
    *)
        echo "OpenClaw-Vault: Shell Switching (Molt)"
        echo ""
        echo "Usage: $0 <hard|split|soft>"
        echo ""
        echo "  hard  (1)  Hard Shell    — Maximum lockdown, conversation only"
        echo "  split (2)  Split Shell   — Workspace file I/O, persistent memory"
        echo "  soft  (3)  Soft Shell    — Broad autonomy (not yet implemented)"
        echo ""
        echo "Current shell level:"
        bash "$VAULT_DIR/scripts/vault-audit.sh" --config 2>/dev/null | grep "Shell level"
        exit 1
        ;;
esac

if [ ! -f "$CONFIG_SRC" ]; then
    echo -e "${RED}ERROR: Config file not found: $CONFIG_SRC${NC}"
    exit 1
fi

echo ""
echo -e "${BOLD}Molting to: $SHELL_NAME${NC}"
echo "  $SHELL_DESC"
echo ""

# --- Pre-audit ---
echo -e "${BOLD}Pre-molt audit:${NC}"
bash "$VAULT_DIR/scripts/vault-audit.sh" --changes 2>/dev/null | grep -E 'MODIFIED|NEW|OK|WARNING|FLAG' | head -10
echo ""

# --- Confirm if switching to a more permissive shell ---
if [ "$SHELL_LEVEL" = "split" ] || [ "$SHELL_LEVEL" = "2" ] || [ "$SHELL_LEVEL" = "soft" ] || [ "$SHELL_LEVEL" = "3" ]; then
    echo -e "${YELLOW}You are increasing agent capability.${NC}"
    echo "The agent will be able to read/write files in its workspace."
    echo ""
    read -rp "Continue? [y/N] " confirm
    if [ "${confirm,,}" != "y" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

# --- Stop the stack ---
echo ""
echo "[molt] Stopping containers..."
cd "$VAULT_DIR"
$COMPOSE down 2>/dev/null || $RUNTIME stop openclaw-vault vault-proxy 2>/dev/null

# --- Swap the config ---
echo "[molt] Installing $SHELL_NAME config..."
# The entrypoint copies /opt/openclaw-hardening.json5 to ~/.openclaw/openclaw.json
# We need to update the source config in the image. Since we can't modify the image,
# we copy the config to the persistent volume (if it exists) or rebuild.

# For persistent volume: overwrite the config directly
local_vol_path=$($RUNTIME volume inspect openclaw-vault_vault-data --format '{{.Mountpoint}}' 2>/dev/null || echo "")
if [ -n "$local_vol_path" ] && [ -d "$local_vol_path" ]; then
    cp "$CONFIG_SRC" "$local_vol_path/openclaw.json"
    echo "[molt] Config written to persistent volume"
else
    # No persistent volume yet — the entrypoint will handle it
    # We need to update the source config that the Containerfile bakes in
    cp "$CONFIG_SRC" "$VAULT_DIR/config/openclaw-hardening.json5"
    echo "[molt] Config updated in source (entrypoint will copy on start)"
    echo "[molt] Rebuilding container image..."
    $RUNTIME build -t openclaw-vault -f "$VAULT_DIR/Containerfile" "$VAULT_DIR" 2>&1 | tail -3
    $RUNTIME tag openclaw-vault openclaw-vault_vault 2>/dev/null
fi

# --- Start the stack ---
echo "[molt] Starting containers..."
cd "$VAULT_DIR"
$COMPOSE up -d 2>/dev/null || {
    echo -e "${RED}Failed to start containers${NC}"
    exit 1
}

# --- Wait for gateway ---
echo "[molt] Waiting for gateway (up to 90s)..."
for i in $(seq 1 90); do
    if $RUNTIME logs openclaw-vault 2>&1 | grep -q "listening on ws://"; then
        echo "[molt] Gateway ready (${i}s)"
        break
    fi
    sleep 1
done

# --- Post-audit ---
echo ""
echo -e "${BOLD}Post-molt verification:${NC}"
bash "$VAULT_DIR/scripts/vault-audit.sh" --config 2>/dev/null | grep -E 'Shell level|profile|security|Elevated|deny'
echo ""

# --- Run security checks ---
echo -e "${BOLD}Security verification:${NC}"
bash "$VAULT_DIR/scripts/verify.sh" 2>&1 | grep -E 'PASS|FAIL|Results'
echo ""

echo -e "${GREEN}${BOLD}Molt complete: $SHELL_NAME active.${NC}"
echo ""
echo "Next steps:"
echo "  - Send a message to your bot on Telegram"
if [ "$SHELL_LEVEL" = "split" ] || [ "$SHELL_LEVEL" = "2" ]; then
    echo "  - Ask Hum to remember something: 'Remember my dentist is Dr. Smith'"
    echo "  - Run audit: bash scripts/vault-audit.sh --memory"
fi
echo "  - Run full audit: bash scripts/vault-audit.sh --all"
