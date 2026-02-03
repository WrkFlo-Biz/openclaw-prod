#!/bin/bash
set -e

CONFIG_DIR="/data/openclaw/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# Ensure state directories exist (Azure File share mounts can be empty)
mkdir -p "$CONFIG_DIR/workspace" "$CONFIG_DIR/logs" "$CONFIG_DIR/agents" "$CONFIG_DIR/credentials" "$CONFIG_DIR/telegram"

BOT_NAME="@mo2darkbot"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN_DEFAULT}"
if [ -n "${TELEGRAM_BOT_TOKEN_MO2DRKBOT}" ]; then
  BOT_NAME="@mo2drkbot"
  BOT_TOKEN="${TELEGRAM_BOT_TOKEN_MO2DRKBOT}"
fi

GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-change-me}"
TELEGRAM_WEBHOOK_URL="${TELEGRAM_WEBHOOK_URL:-}"
TELEGRAM_WEBHOOK_SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
if [ -z "${TELEGRAM_WEBHOOK_URL}" ]; then
  echo "TELEGRAM_WEBHOOK_URL is required for webhook mode" >&2
  exit 1
fi
if [ -z "${TELEGRAM_WEBHOOK_SECRET}" ]; then
  echo "TELEGRAM_WEBHOOK_SECRET is required for webhook mode" >&2
  exit 1
fi
if [ -z "${BOT_TOKEN}" ]; then
  echo "TELEGRAM_BOT_TOKEN_DEFAULT (or TELEGRAM_BOT_TOKEN_MO2DRKBOT) is required" >&2
  exit 1
fi

# Create config from environment variables
cat > "$CONFIG_FILE" << EOF
{
  "meta": {
    "lastTouchedVersion": "2026.2.1",
    "lastTouchedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  },
  "env": {
    "AZURE_OPENAI_API_KEY": "${AZURE_OPENAI_API_KEY}",
    "AZURE_OPENAI_ENDPOINT": "${AZURE_OPENAI_ENDPOINT}",
    "AZURE_OPENAI_API_VERSION": "${AZURE_OPENAI_API_VERSION:-2024-05-01-preview}",
    "AZURE_OPENAI_DEPLOYMENT": "${AZURE_OPENAI_DEPLOYMENT:-gpt-4o}"
  },
  "models": {
    "mode": "merge",
    "providers": {
      "azure-gpt4o": {
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1",
        "apiKey": "${AZURE_OPENAI_API_KEY}",
        "auth": "api-key",
        "api": "openai-completions",
        "models": [
          {
            "id": "${AZURE_OPENAI_DEPLOYMENT:-gpt-4o}",
            "name": "GPT-4o",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "azure-gpt4o/${AZURE_OPENAI_DEPLOYMENT:-gpt-4o}"},
      "workspace": "$CONFIG_DIR/workspace",
      "maxConcurrent": 4,
      "subagents": {"maxConcurrent": 8}
    },
    "list": [
      {"id": "main"},
      {"id": "mo2darkbot", "name": "@mo2darkbot"},
      {"id": "mo2drkbot", "name": "@mo2drkbot"}
    ]
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "webhookUrl": "${TELEGRAM_WEBHOOK_URL}",
      "webhookSecret": "${TELEGRAM_WEBHOOK_SECRET}",
      "dmPolicy": "open",
      "allowFrom": ["*"],
      "groupPolicy": "allowlist",
      "streamMode": "off",
      "accounts": {
        "default": {
          "name": "${BOT_NAME}",
          "enabled": true,
          "botToken": "${BOT_TOKEN}",
          "dmPolicy": "open",
          "allowFrom": ["*"]
        }
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "plugins": {
    "entries": {
      "telegram": {"enabled": true}
    }
  }
}
EOF

echo "OpenClaw config generated at $CONFIG_FILE"

# Start OpenClaw gateway
exec openclaw gateway run --bind 0.0.0.0 --port 18789
