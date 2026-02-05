# OpenClaw Production Dockerfile
# Multi-capability autonomous agent with safety gates

FROM python:3.11-slim

LABEL maintainer="OpenClaw Team"
LABEL description="OpenClaw Autonomous Agent Skills"
LABEL version="1.0.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV OPENCLAW_HOME=/data/openclaw
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Create application directories
RUN mkdir -p /data/openclaw/.openclaw/agents/skills \
    /data/openclaw/.openclaw/agents/config \
    /data/openclaw/logs \
    /data/openclaw/state \
    /data/openclaw/scripts \
    /data/openclaw/processed \
    /data/openclaw/backups

# Copy agent files
COPY .openclaw/agents/ /data/openclaw/.openclaw/agents/

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Set working directory
WORKDIR /data/openclaw

# Create non-root user for security
RUN groupadd -r openclaw && useradd -r -g openclaw openclaw
RUN chown -R openclaw:openclaw /data/openclaw

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Switch to non-root user
USER openclaw

# Expose port for webhooks
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
