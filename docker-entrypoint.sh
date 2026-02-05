#!/bin/bash
set -e

CONFIG_DIR="/data/openclaw/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# Ensure state directories exist
mkdir -p "$CONFIG_DIR/workspace" "$CONFIG_DIR/logs" "$CONFIG_DIR/agents" "$CONFIG_DIR/credentials" "$CONFIG_DIR/telegram"

# Bot tokens from environment
BOT_TOKEN_DEFAULT="${TELEGRAM_BOT_TOKEN_DEFAULT}"
BOT_TOKEN_MO2DRKBOT="${TELEGRAM_BOT_TOKEN_MO2DRKBOT}"

GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-change-me}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

case "${GATEWAY_BIND}" in
  loopback|lan|tailnet|auto|custom) ;;
  *)
    echo "Invalid OPENCLAW_GATEWAY_BIND: ${GATEWAY_BIND}. Use one of: loopback, lan, tailnet, auto, custom." >&2
    exit 1
    ;;
esac

# Align token variable names for tools/skills that expect GH_TOKEN.
if [ -z "${GH_TOKEN:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  export GITHUB_TOKEN="${GH_TOKEN}"
fi

# Validate at least one bot token is provided
if [ -z "${BOT_TOKEN_DEFAULT}" ] && [ -z "${BOT_TOKEN_MO2DRKBOT}" ]; then
  echo "At least one Telegram bot token is required (TELEGRAM_BOT_TOKEN_DEFAULT or TELEGRAM_BOT_TOKEN_MO2DRKBOT)" >&2
  exit 1
fi

# Build accounts JSON based on available tokens
ACCOUNTS_JSON=""
if [ -n "${BOT_TOKEN_DEFAULT}" ]; then
  ACCOUNTS_JSON="\"default\": {
          \"name\": \"@mo2darkbot\",
          \"enabled\": true,
          \"botToken\": \"${BOT_TOKEN_DEFAULT}\",
          \"dmPolicy\": \"open\",
          \"allowFrom\": [\"*\"],
          \"dms\": {\"7091381625\": {}}
        }"
fi

if [ -n "${BOT_TOKEN_MO2DRKBOT}" ]; then
  if [ -n "${ACCOUNTS_JSON}" ]; then
    ACCOUNTS_JSON="${ACCOUNTS_JSON},"
  fi
  ACCOUNTS_JSON="${ACCOUNTS_JSON}
        \"mo2drkbot\": {
          \"name\": \"@mo2drkbot\",
          \"enabled\": true,
          \"botToken\": \"${BOT_TOKEN_MO2DRKBOT}\",
          \"dmPolicy\": \"open\",
          \"allowFrom\": [\"*\"],
          \"dms\": {\"7091381625\": {}}
        }"
fi

# Create config from environment variables - POLLING MODE (no webhook)
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
    "AZURE_OPENAI_DEPLOYMENT": "${AZURE_OPENAI_DEPLOYMENT:-gpt-4o}",
    "GH_TOKEN": "${GH_TOKEN}",
    "GITHUB_TOKEN": "${GITHUB_TOKEN}",
    "GITHUB_REPO": "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}",
    "OPENAI_API_KEY": "${OPENAI_API_KEY}"
  },
  "models": {
    "mode": "merge",
    "providers": {
      "azure-gpt4o": {
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}openai/v1",
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
        ${ACCOUNTS_JSON}
      }
    }
  },
  "gateway": {
    "port": ${GATEWAY_PORT},
    "mode": "local",
    "bind": "${GATEWAY_BIND}",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "plugins": {
    "entries": {
      "telegram": {"enabled": true},
      "lobster": {"enabled": true}
    }
  }
}
EOF

echo "OpenClaw config generated at $CONFIG_FILE"
ACCOUNT_COUNT=0
if [ -n "${BOT_TOKEN_DEFAULT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
if [ -n "${BOT_TOKEN_MO2DRKBOT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
echo "Configured Telegram accounts: ${ACCOUNT_COUNT}"
echo "Configured model: azure-gpt4o/${AZURE_OPENAI_DEPLOYMENT:-gpt-4o}"
echo "Gateway bind mode: ${GATEWAY_BIND} (port ${GATEWAY_PORT})"
if [ -n "${GH_TOKEN:-}" ]; then
  echo "GitHub token configured for skill runtime"
else
  echo "GitHub token not configured"
fi

# Start OpenClaw gateway
exec openclaw gateway run --bind "${GATEWAY_BIND}" --port "${GATEWAY_PORT}"
