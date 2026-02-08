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
  "$CONFIG_DIR/telegram" \
  "$CONFIG_DIR/slack"

chmod 700 "$CONFIG_DIR" \
  "$CONFIG_DIR/workspace" \
  "$CONFIG_DIR/logs" \
  "$CONFIG_DIR/agents" \
  "$CONFIG_DIR/credentials" \
  "$CONFIG_DIR/telegram" \
  "$CONFIG_DIR/slack" 2>/dev/null || true

# One-time: clear stale sessions after model switch (Claude -> GPT-5-mini).
# Old sessions reference response IDs from the previous model's Responses API
# that the new model can't resolve, causing HTTP 400 errors.
# Remove this block after the first successful deploy.
if [ -f "$CONFIG_DIR/.sessions-cleared-v2" ]; then
  echo "Sessions already cleared for model switch."
else
  echo "Clearing stale sessions for model switch..."
  find "$CONFIG_DIR/agents" -name "sessions.json" -delete 2>/dev/null || true
  touch "$CONFIG_DIR/.sessions-cleared-v2"
fi


# Seed agent workspace files from git repo into persistent storage.
# Always overwrite so workspaces stay in sync with the repo.
AGENT_SRC_DIR="/opt/openclaw-agents"
seed_agent_workspace() {
  local agent_id="$1"
  local ws_dir="$CONFIG_DIR/workspace-${agent_id}"
  mkdir -p "$ws_dir"
  if [ -d "$AGENT_SRC_DIR/$agent_id" ]; then
    cp "$AGENT_SRC_DIR/$agent_id/"*.md "$ws_dir/" 2>/dev/null || true
    echo "Seeded workspace for $agent_id"
  fi
}

seed_agent_workspace "mo2darkbot"
seed_agent_workspace "mo2drkbot"

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

# Build Telegram accounts object safely with jq (prevents JSON injection from env vars).
ACCOUNTS_OBJ='{}'
if [ -n "${BOT_TOKEN_DEFAULT}" ]; then
  ACCOUNTS_OBJ="$(echo "$ACCOUNTS_OBJ" | jq --arg token "$BOT_TOKEN_DEFAULT" '.default = {
    "name": "@mo2darkbot",
    "enabled": true,
    "botToken": $token,
    "dmPolicy": "allowlist",
    "allowFrom": ["7091381625"],
    "dms": {"7091381625": {}}
  }')"
fi

if [ -n "${BOT_TOKEN_MO2DRKBOT}" ]; then
  ACCOUNTS_OBJ="$(echo "$ACCOUNTS_OBJ" | jq --arg token "$BOT_TOKEN_MO2DRKBOT" '.mo2drkbot = {
    "name": "@mo2drkbot",
    "enabled": true,
    "botToken": $token,
    "dmPolicy": "allowlist",
    "allowFrom": ["7091381625"],
    "dms": {"7091381625": {}}
  }')"
fi

# Build Slack channel config if tokens are provided
SLACK_CONFIG='null'
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  SLACK_CONFIG="$(jq -n \
    --arg bot_token "${SLACK_BOT_TOKEN}" \
    --arg app_token "${SLACK_APP_TOKEN:-}" \
  '{
    "enabled": true,
    "botToken": $bot_token,
    "appToken": $app_token,
    "dm": {
      "enabled": true,
      "policy": "allowlist",
      "allowFrom": ["*"]
    },
    "channels": {},
    "replyToMode": "all",
    "actions": {
      "reactions": true,
      "messages": true,
      "pins": true,
      "memberInfo": true,
      "emojiList": true
    }
  }')"
fi

# Build the full config JSON safely using jq (all env var values are properly escaped).
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
jq -n \
  --arg now "$NOW" \
  --arg aoai_key "${AZURE_OPENAI_API_KEY}" \
  --arg aoai_ep "${AZURE_OPENAI_ENDPOINT}" \
  --arg aoai_ver "${AZURE_OPENAI_API_VERSION:-2024-05-01-preview}" \
  --arg aoai_dep "${AZURE_OPENAI_DEPLOYMENT:-gpt-5-mini}" \
  --arg acl_key "${AZURE_CLAUDE_API_KEY}" \
  --arg acl_ep "${AZURE_CLAUDE_ENDPOINT}" \
  --arg gh_tok "${GH_TOKEN}" \
  --arg github_tok "${GITHUB_TOKEN}" \
  --arg github_repo "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}" \
  --arg openai_key "${OPENAI_API_KEY}" \
  --arg gemini_key "${GEMINI_API_KEY}" \
  --arg gplaces_key "${GOOGLE_PLACES_API_KEY}" \
  --arg eleven_key "${ELEVENLABS_API_KEY}" \
  --arg gmail_pw "${GMAIL_APP_PASSWORD}" \
  --arg gw_token "$GATEWAY_TOKEN" \
  --arg gw_bind "$GATEWAY_BIND" \
  --argjson gw_port "$GATEWAY_PORT" \
  --arg config_dir "$CONFIG_DIR" \
  --argjson accounts "$ACCOUNTS_OBJ" \
  --argjson slack_config "$SLACK_CONFIG" \
'{
  "meta": {
    "lastTouchedVersion": "2026.2.1",
    "lastTouchedAt": $now
  },
  "env": {
    "AZURE_OPENAI_API_KEY": $aoai_key,
    "AZURE_OPENAI_ENDPOINT": $aoai_ep,
    "AZURE_OPENAI_API_VERSION": $aoai_ver,
    "AZURE_OPENAI_DEPLOYMENT": $aoai_dep,
    "AZURE_CLAUDE_API_KEY": $acl_key,
    "AZURE_CLAUDE_ENDPOINT": $acl_ep,
    "GH_TOKEN": $gh_tok,
    "GITHUB_TOKEN": $github_tok,
    "GITHUB_REPO": $github_repo,
    "OPENAI_API_KEY": $openai_key,
    "GEMINI_API_KEY": $gemini_key,
    "GOOGLE_PLACES_API_KEY": $gplaces_key,
    "ELEVENLABS_API_KEY": $eleven_key,
    "GMAIL_APP_PASSWORD": $gmail_pw
  },
  "models": {
    "mode": "merge",
    "providers": {
      "azure-openai": {
        "baseUrl": ($aoai_ep + "openai/v1"),
        "apiKey": $aoai_key,
        "auth": "api-key",
        "api": "openai-completions",
        "models": [
          {"id": "gpt-5-mini", "name": "GPT-5 mini", "reasoning": false, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 200000, "maxTokens": 8192},
          {"id": "gpt-5.2", "name": "GPT-5.2", "reasoning": false, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 200000, "maxTokens": 8192},
          {"id": "gpt-5.2-codex", "name": "GPT-5.2 Codex", "reasoning": false, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 200000, "maxTokens": 8192},
          {"id": "gpt-4o", "name": "GPT-4o", "reasoning": false, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 128000, "maxTokens": 4096}
        ]
      },
      "azure-claude": {
        "baseUrl": ($acl_ep + "/anthropic"),
        "apiKey": $acl_key,
        "api": "anthropic-messages",
        "headers": {
          "x-api-key": $acl_key,
          "anthropic-version": "2023-06-01"
        },
        "models": [
          {"id": "claude-opus-4-6", "name": "Claude Opus 4.6", "reasoning": true, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 200000, "maxTokens": 32768}
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-openai/gpt-5-mini",
        "fallbacks": ["azure-openai/gpt-5.2", "azure-openai/gpt-4o", "azure-claude/claude-opus-4-6"]
      },
      "workspace": ($config_dir + "/workspace"),
      "maxConcurrent": 4,
      "subagents": {"maxConcurrent": 8}
    },
    "list": [
      {"id": "main", "tools": {"profile": "full", "allow": ["llm-task"]}},
      {"id": "mo2darkbot", "name": "@mo2darkbot", "tools": {"profile": "full", "allow": ["llm-task"]}},
      {"id": "mo2drkbot", "name": "@mo2drkbot", "tools": {"profile": "full", "allow": ["llm-task"]}}
    ]
  },
  "session": {"dmScope": "per-account-channel-peer"},
  "channels": (
    {
      "telegram": {
        "enabled": true,
        "dmPolicy": "allowlist",
        "allowFrom": ["7091381625"],
        "groupPolicy": "allowlist",
        "streamMode": "off",
        "accounts": $accounts
      }
    } + (if $slack_config != null then {"slack": $slack_config} else {} end)
  ),
  "gateway": {
    "port": $gw_port,
    "mode": "local",
    "bind": $gw_bind,
    "trustedProxies": ["10.0.0.0/8", "100.100.0.0/16", "172.16.0.0/12"],
    "auth": {"mode": "token", "token": $gw_token}
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
    "profiles": {"openclaw": {"cdpPort": 18800, "color": "#FF4500"}}
  },
  "plugins": {
    "entries": {
      "telegram": {"enabled": true},
      "slack": (if $slack_config != null then {"enabled": true} else {"enabled": false} end),
      "lobster": {"enabled": true},
      "voice-call": {"enabled": true},
      "llm-task": {
        "enabled": true,
        "config": {
          "defaultProvider": "azure-openai",
          "defaultModel": "gpt-5-mini",
          "defaultAuthProfileId": "main",
          "allowedModels": [
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
}' > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE" 2>/dev/null || true
chmod 600 "$CONFIG_DIR/agents/main/sessions/sessions.json" 2>/dev/null || true

echo "OpenClaw config generated at $CONFIG_FILE"
ACCOUNT_COUNT=0
if [ -n "${BOT_TOKEN_DEFAULT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
if [ -n "${BOT_TOKEN_MO2DRKBOT}" ]; then ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1)); fi
echo "Configured Telegram accounts: ${ACCOUNT_COUNT}"
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  echo "Slack channel: enabled (socket mode)"
else
  echo "Slack channel: disabled (no SLACK_BOT_TOKEN)"
fi
echo "Configured agent primary model: azure-openai/gpt-5-mini"
echo "Configured agent fallbacks: azure-openai/gpt-5.2, azure-openai/gpt-4o, azure-claude/claude-opus-4-6"
echo "Gateway bind mode: ${GATEWAY_BIND} (port ${GATEWAY_PORT})"
if [ -n "${GH_TOKEN:-}" ]; then
  echo "GitHub token configured for skill runtime"
else
  echo "GitHub token not configured"
fi

# Start OpenClaw gateway
exec openclaw gateway run --bind "${GATEWAY_BIND}" --port "${GATEWAY_PORT}"
