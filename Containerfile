# OpenClaw-Vault: Hardened OpenClaw Container
# Defense-in-depth Layer 2 — rootless container with minimal attack surface
#
# Build:  podman build -t openclaw-vault -f Containerfile .
# Or:     docker build -t openclaw-vault -f Containerfile .

# node 20.18.2-alpine — pinned 2026-02-26
FROM node:20-alpine@sha256:ba8312129a193a1f1a781d93afcf6e641956d6e48e3ddefa9b64cd86790ee64c AS builder

# Install OpenClaw CLI (pinned to stable release)
RUN npm install -g @anthropic-ai/openclaw@2026.2.17

# --- Production stage ---
# node 20.18.2-alpine — pinned 2026-02-26
FROM node:20-alpine@sha256:ba8312129a193a1f1a781d93afcf6e641956d6e48e3ddefa9b64cd86790ee64c

LABEL maintainer="OpenClaw-Vault" \
      description="Hardened OpenClaw sandbox — rootless, read-only, proxy-gated"

# Remove package managers and network tools after base setup
# Keep only what OpenClaw needs to function
RUN apk --no-cache add tini ca-certificates \
    && rm -rf /sbin/apk /usr/bin/wget /usr/bin/curl \
    && rm -rf /var/cache/apk/* /tmp/*

# Copy OpenClaw from builder
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /usr/local/bin/openclaw /usr/local/bin/openclaw

# Create non-root user
RUN addgroup -g 1000 -S vault \
    && adduser -u 1000 -S vault -G vault -h /home/vault -s /bin/sh

# Hardened OpenClaw config — stored in /opt so tmpfs on ~/.config doesn't shadow it.
# entrypoint.sh copies it to the tmpfs at startup.
COPY config/openclaw-hardening.yml /opt/openclaw-hardening.yml
RUN chown -R vault:vault /home/vault

# Entrypoint wrapper — waits for proxy CA cert before starting OpenClaw
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Proxy configuration — all traffic routes through vault-proxy sidecar
# The container NEVER contacts external services directly
ENV HTTP_PROXY=http://vault-proxy:8080 \
    HTTPS_PROXY=http://vault-proxy:8080 \
    NO_PROXY=localhost,127.0.0.1 \
    NODE_EXTRA_CA_CERTS=/opt/proxy-ca/mitmproxy-ca-cert.pem \
    HOME=/home/vault

# Run as non-root
USER vault
WORKDIR /home/vault/workspace

# tini handles PID 1 responsibilities (signal forwarding, zombie reaping)
# entrypoint.sh waits for proxy CA cert, then execs into the CMD
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["openclaw", "--config", "/home/vault/.config/openclaw/config.yml"]
