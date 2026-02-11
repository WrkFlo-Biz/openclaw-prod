FROM node:22-slim

LABEL maintainer="mo2dark"
LABEL description="OpenClaw Production Container"

# Install runtime dependencies required by key OpenClaw skills.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       chromium \
       curl \
       ffmpeg \
       gh \
       git \
       jq \
       python3 \
       python3-pip \
       python3-venv \
       ripgrep \
       tmux \
       wget \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g \
       @google/gemini-cli \
       @openai/codex \
       clawhub \
       gmail-mcp-imap \
       mcporter \
       openclaw@latest \
       pnpm \
       summarize

# Install Go 1.23, build wacli from source, then remove Go to save space
RUN curl -fsSL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz | tar xz -C /usr/local \
    && GOBIN=/usr/local/bin /usr/local/go/bin/go install github.com/steipete/wacli/cmd/wacli@latest \
    && rm -rf /root/go /usr/local/go

# Install binary CLIs from GitHub releases (Linux amd64)
RUN set -eux; \
    ARCH="amd64"; \
    TMPDIR="$(mktemp -d)"; \
    # goplaces
    curl -fsSL "https://github.com/steipete/goplaces/releases/download/v0.2.1/goplaces_0.2.1_linux_${ARCH}.tar.gz" \
      | tar xz -C "$TMPDIR" && mv "$TMPDIR/goplaces" /usr/local/bin/goplaces; \
    # gogcli
    curl -fsSL "https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_${ARCH}.tar.gz" \
      | tar xz -C "$TMPDIR" && mv "$TMPDIR/gog" /usr/local/bin/gog; \
    # sag
    curl -fsSL "https://github.com/steipete/sag/releases/download/v0.2.2/sag_0.2.2_linux_${ARCH}.tar.gz" \
      | tar xz -C "$TMPDIR" && mv "$TMPDIR/sag" /usr/local/bin/sag; \
    # camsnap
    curl -fsSL "https://github.com/steipete/camsnap/releases/download/v0.2.0/camsnap_0.2.0_linux_${ARCH}.tar.gz" \
      | tar xz -C "$TMPDIR" && mv "$TMPDIR/camsnap" /usr/local/bin/camsnap; \
    # himalaya
    curl -fsSL "https://github.com/pimalaya/himalaya/releases/download/v1.1.0/himalaya.x86_64-linux.tgz" \
      | tar xz -C "$TMPDIR" && mv "$TMPDIR/himalaya" /usr/local/bin/himalaya; \
    chmod +x /usr/local/bin/goplaces /usr/local/bin/gog /usr/local/bin/sag \
             /usr/local/bin/camsnap /usr/local/bin/himalaya; \
    rm -rf "$TMPDIR"

# Install uv (Python package manager, needed by local-places skill)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && mv /root/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

# Install Python packages (Whisper for speech-to-text, workspace-mcp for Gmail OAuth)
RUN pip3 install --no-cache-dir --break-system-packages openai-whisper workspace-mcp

# Azure Files (SMB) mounts in Azure Container Apps commonly reject chmod/chown.
# OpenClaw hardens file perms (0600) for session and Telegram offset stores; treat chmod as best-effort
# so the gateway doesn't fail on EPERM in cloud-mounted volumes.
# NOTE: single backslashes inside single quotes — no double-escaping needed.
RUN set -eu; \
    OPENCLAW_DIR="$(npm root -g)/openclaw"; \
    if [ -d "$OPENCLAW_DIR/dist" ]; then \
      for f in $(rg -l --glob '*.js' 'await\s+[A-Za-z0-9_$.]+\.chmod\([^;]*,\s*(0o600|384)\);' "$OPENCLAW_DIR/dist" || true); do \
        sed -i -E 's/await[[:space:]]+([A-Za-z0-9_$.]+)\.chmod\(([^;]*),[[:space:]]*(0o600|384)\);/await \1.chmod(\2, \3).catch(() => {});/g' "$f"; \
      done; \
    fi

# Install Lobster workflow engine
RUN git clone https://github.com/openclaw/lobster.git /opt/lobster \
    && cd /opt/lobster && pnpm install && pnpm build && npm link

# Create non-root user
RUN groupadd -r openclaw && useradd -r -g openclaw -d /data/openclaw -s /bin/bash openclaw

# Create app directory
WORKDIR /data/openclaw

# Create necessary directories and set ownership
RUN mkdir -p /data/openclaw/.openclaw/workspace \
    /data/openclaw/.openclaw/workspace/memory \
    /data/openclaw/.openclaw/memory-index \
    /data/openclaw/.openclaw/logs \
    /data/openclaw/.openclaw/agents \
    /data/openclaw/.openclaw/credentials \
    /data/openclaw/.openclaw/telegram \
    /data/openclaw/.openclaw/slack \
    && chown -R openclaw:openclaw /data/openclaw

# Copy agent workspace seed files
COPY agents/ /opt/openclaw-agents/
COPY shared/ /opt/openclaw-shared/

# Copy mcporter and himalaya config templates (credentials injected at runtime)
COPY mcporter-config.json /opt/mcporter-config.json
COPY himalaya-config.toml /opt/himalaya-config.toml

# Copy ops scripts and entrypoint
COPY scripts/self-ops.sh /usr/local/bin/self-ops
COPY scripts/ops.sh /usr/local/bin/openclaw-ops
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/self-ops /usr/local/bin/openclaw-ops

# Set environment variables
ENV HOME=/data/openclaw
ENV OPENCLAW_HOME=/data/openclaw/.openclaw
ENV NODE_ENV=production

# Run as non-root
USER openclaw

# Gateway port (internal only - no public exposure needed for polling)
EXPOSE 18789

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:18789/api/health || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
