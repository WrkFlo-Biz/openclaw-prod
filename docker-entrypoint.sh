#!/bin/bash
set -e

CONFIG_DIR="/data/openclaw/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# IMPORTANT: OpenClaw reads config/state from OPENCLAW_STATE_DIR by default (~/.openclaw).
# In Azure Container Apps we want all state on the Azure Files mount.
export OPENCLAW_STATE_DIR="$CONFIG_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"

# Best-effort permissions hardening.
# Note: Azure Files volumes often present as 0777; we still try to restrict.
umask 077

# Ensure state directories exist
mkdir -p \
  "$CONFIG_DIR/workspace" \
  "$CONFIG_DIR/logs" \
  "$CONFIG_DIR/agents" \
  "$CONFIG_DIR/credentials" \
  "$CONFIG_DIR/telegram"

chmod 700 "$CONFIG_DIR" \
  "$CONFIG_DIR/workspace" \
  "$CONFIG_DIR/logs" \
  "$CONFIG_DIR/agents" \
  "$CONFIG_DIR/credentials" \
  "$CONFIG_DIR/telegram" 2>/dev/null || true

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
          \"dmPolicy\": \"allowlist\",
          \"allowFrom\": [\"7091381625\"],
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
          \"dmPolicy\": \"allowlist\",
          \"allowFrom\": [\"7091381625\"],
          \"dms\": {\"7091381625\": {}}
        }"
fi

# Create config from environment variables (Telegram polling mode: no webhook).
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
    "AZURE_OPENAI_DEPLOYMENT": "${AZURE_OPENAI_DEPLOYMENT:-gpt-5-mini}",
    "AZURE_CLAUDE_API_KEY": "${AZURE_CLAUDE_API_KEY}",
    "AZURE_CLAUDE_ENDPOINT": "${AZURE_CLAUDE_ENDPOINT}",
    "GH_TOKEN": "${GH_TOKEN}",
    "GITHUB_TOKEN": "${GITHUB_TOKEN}",
    "GITHUB_REPO": "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}",
    "OPENAI_API_KEY": "${OPENAI_API_KEY}",
    "GEMINI_API_KEY": "${GEMINI_API_KEY}",
    "GOOGLE_PLACES_API_KEY": "${GOOGLE_PLACES_API_KEY}",
    "ELEVENLABS_API_KEY": "${ELEVENLABS_API_KEY}"
  },
  "models": {
    "mode": "merge",
    "providers": {
      "azure-openai": {
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}openai/v1",
        "apiKey": "${AZURE_OPENAI_API_KEY}",
        "auth": "api-key",
        "api": "openai-responses",
        "models": [
          {
            "id": "gpt-5-mini",
            "name": "GPT-5 mini",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192
          },
          {
            "id": "gpt-5.2",
            "name": "GPT-5.2",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192
          },
          {
            "id": "gpt-5.2-codex",
            "name": "GPT-5.2 Codex",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192
          },
          {
            "id": "gpt-4o",
            "name": "GPT-4o",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 128000,
            "maxTokens": 4096
          }
        ]
      },
      "azure-claude": {
        "baseUrl": "${AZURE_CLAUDE_ENDPOINT}/anthropic",
        "apiKey": "${AZURE_CLAUDE_API_KEY}",
        "api": "anthropic-messages",
        "headers": {
          "x-api-key": "${AZURE_CLAUDE_API_KEY}",
          "anthropic-version": "2023-06-01"
        },
        "models": [
          {
            "id": "claude-opus-4-6",
            "name": "Claude Opus 4.6",
            "reasoning": true,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 32768
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-claude/claude-opus-4-6",
        "fallbacks": [
          "azure-openai/gpt-5.2",
          "azure-openai/gpt-4o",
          "azure-openai/gpt-5-mini"
        ]
      },
      "workspace": "$CONFIG_DIR/workspace",
      "maxConcurrent": 4,
      "subagents": {"maxConcurrent": 8}
    },
    "list": [
      {"id": "main", "tools": {"profile": "full", "allow": ["llm-task"]}},
      {"id": "mo2darkbot", "name": "@mo2darkbot", "tools": {"profile": "full", "allow": ["llm-task"]}},
      {"id": "mo2drkbot", "name": "@mo2drkbot", "tools": {"profile": "full", "allow": ["llm-task"]}}
    ]
  },
  "session": {
    "dmScope": "per-account-channel-peer"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "allowlist",
      "allowFrom": ["7091381625"],
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
    "trustedProxies": ["10.0.0.0/8", "100.100.0.0/16", "172.16.0.0/12"],
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "browser": {
    "enabled": true,
    "remoteCdpTimeoutMs": 1500,
    "remoteCdpHandshakeTimeoutMs": 3000,
    "defaultProfile": "openclaw",
    "color": "#FF4500",
    "headless": true,
    "noSandbox": true,
    "attachOnly": false,
    "executablePath": "/usr/bin/chromium",
    "profiles": {
      "openclaw": {"cdpPort": 18800, "color": "#FF4500"}
    }
  },
  "plugins": {
    "entries": {
      "telegram": {"enabled": true},
      "lobster": {"enabled": true},
      "voice-call": {"enabled": true},
      "llm-task": {
        "enabled": true,
        "config": {
          "defaultProvider": "openai-codex",
          "defaultModel": "gpt-5.2",
          "defaultAuthProfileId": "main",
          "allowedModels": [
            "openai-codex/gpt-5.3-codex",
            "azure-claude/claude-opus-4-6",
            "azure-openai/gpt-5-mini",
            "azure-openai/gpt-5.2",
            "azure-openai/gpt-5.2-codex",
            "azure-openai/gpt-4o"
          ],
          "maxTokens": 800,
          "timeoutMs": 30000
        }
      }
    }
  }
}
EOF

chmod 600 "$CONFIG_FILE" 2>/dev/null || true
chmod 600 "$CONFIG_DIR/agents/main/sessions/sessions.json" 2>/dev/null || true

echo "OpenClaw config generated at $CONFIG_FILE"
ACCOUNT_COUNT=0
if [ -n "${BOT_TOKEN_DEFAULT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
if [ -n "${BOT_TOKEN_MO2DRKBOT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
echo "Configured Telegram accounts: ${ACCOUNT_COUNT}"
echo "Configured agent primary model: azure-claude/claude-opus-4-6"
echo "Configured agent fallbacks: azure-openai/gpt-5.2, azure-openai/gpt-4o, azure-openai/gpt-5-mini"
echo "Gateway bind mode: ${GATEWAY_BIND} (port ${GATEWAY_PORT})"
if [ -n "${GH_TOKEN:-}" ]; then
  echo "GitHub token configured for skill runtime"
else
  echo "GitHub token not configured"
fi

# Start OpenClaw gateway
exec openclaw gateway run --bind "${GATEWAY_BIND}" --port "${GATEWAY_PORT}"
