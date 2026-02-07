FROM node:22-slim

LABEL maintainer="mo2dark"
LABEL description="OpenClaw Production Container"

# Install runtime dependencies required by key OpenClaw skills.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       ffmpeg \
       gh \
       git \
       jq \
       python3 \
       ripgrep \
       tmux \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g \
       @openai/codex \
       clawhub \
       mcporter \
       openclaw@latest \
       pnpm \
       summarize

# Install Lobster workflow engine
RUN git clone https://github.com/openclaw/lobster.git /opt/lobster \
    && cd /opt/lobster && pnpm install && pnpm build && npm link

# Create non-root user
RUN groupadd -r openclaw && useradd -r -g openclaw -d /data/openclaw -s /bin/bash openclaw

# Create app directory
WORKDIR /data/openclaw

# Create necessary directories and set ownership
RUN mkdir -p /data/openclaw/.openclaw/workspace \
    /data/openclaw/.openclaw/logs \
    /data/openclaw/.openclaw/agents \
    /data/openclaw/.openclaw/credentials \
    /data/openclaw/.openclaw/telegram \
    && chown -R openclaw:openclaw /data/openclaw

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

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
