#!/bin/bash
set -e

CONFIG_DIR="/data/openclaw/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

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
      "dmPolicy": "open",
      "allowFrom": ["*"],
      "groupPolicy": "allowlist",
      "streamMode": "off",
      "accounts": {
        "default": {
          "name": "@mo2darkbot",
          "enabled": true,
          "botToken": "${TELEGRAM_BOT_TOKEN_DEFAULT}",
          "dmPolicy": "open",
          "allowFrom": ["*"]
        },
        "mo2drkbot": {
          "name": "@mo2drkbot",
          "enabled": ${TELEGRAM_BOT_TOKEN_MO2DRKBOT:+true}${TELEGRAM_BOT_TOKEN_MO2DRKBOT:-false},
          "botToken": "${TELEGRAM_BOT_TOKEN_MO2DRKBOT:-}",
          "dmPolicy": "open",
          "allowFrom": ["*"]
        }
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "0.0.0.0"
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
