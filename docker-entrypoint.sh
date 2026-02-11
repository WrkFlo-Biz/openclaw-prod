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
  "$CONFIG_DIR/workspace/memory" \
  "$CONFIG_DIR/memory-index" \
  "$CONFIG_DIR/memory-db" \
  "$CONFIG_DIR/logs" \
  "$CONFIG_DIR/shared" \
  "$CONFIG_DIR/agents" \
  "$CONFIG_DIR/credentials" \
  "$CONFIG_DIR/telegram" \
  "$CONFIG_DIR/slack"

chmod 700 "$CONFIG_DIR" \
  "$CONFIG_DIR/workspace" \
  "$CONFIG_DIR/logs" \
  "$CONFIG_DIR/shared" \
  "$CONFIG_DIR/agents" \
  "$CONFIG_DIR/credentials" \
  "$CONFIG_DIR/telegram" \
  "$CONFIG_DIR/slack" 2>/dev/null || true

# One-time: clear stale sessions after model switch (Claude -> GPT-5-mini).
# Old sessions reference response IDs from the previous model's Responses API
# that the new model can't resolve, causing HTTP 400 errors.
# Remove this block after the first successful deploy.
if [ -f "$CONFIG_DIR/.sessions-cleared-v3" ]; then
  echo "Sessions already cleared (v3: identity fix + per-agent workspace)."
else
  echo "Clearing stale sessions for identity fix..."
  find "$CONFIG_DIR/agents" -name "sessions.json" -delete 2>/dev/null || true
  touch "$CONFIG_DIR/.sessions-cleared-v3"
fi

# One-time: nuke memory index so it rebuilds with Azure OpenAI embeddings.
if [ -f "$CONFIG_DIR/.memory-index-reset-aoai-embed3" ]; then
  echo "Memory index already reset for Azure OpenAI embeddings."
else
  echo "Resetting memory index to force Azure OpenAI embeddings rebuild..."
  rm -rf "$CONFIG_DIR/memory-index/"*.db "$CONFIG_DIR/memory-index/"*.db-* \
         "$CONFIG_DIR/memory-index/"*.sqlite "$CONFIG_DIR/memory-index/"*.sqlite-* 2>/dev/null || true
  touch "$CONFIG_DIR/.memory-index-reset-aoai-embed3"
fi


# Seed shared planning files from git repo into persistent storage.
# Preserve runtime edits so the board/brain remain durable across restarts.
SHARED_SRC_DIR="/opt/openclaw-shared"
SHARED_DIR="$CONFIG_DIR/shared"
seed_shared_file() {
  local filename="$1"
  local src="$SHARED_SRC_DIR/$filename"
  local dest="$SHARED_DIR/$filename"
  if [ ! -f "$src" ]; then
    return
  fi
  if [ -s "$dest" ]; then
    echo "Preserved shared file $filename"
    return
  fi
  cp "$src" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
  echo "Seeded shared file $filename"
}

seed_shared_file "KANBAN.md"
seed_shared_file "SECOND_BRAIN.md"

# Seed agent workspace files from git repo into persistent storage.
# Only write missing/empty files so runtime edits persist.
AGENT_SRC_DIR="/opt/openclaw-agents"
seed_agent_workspace() {
  local agent_id="$1"
  local ws_dir="$CONFIG_DIR/workspace-${agent_id}"
  local src
  local name
  local dest
  mkdir -p "$ws_dir"
  if [ -d "$AGENT_SRC_DIR/$agent_id" ]; then
    for src in "$AGENT_SRC_DIR/$agent_id/"*.md; do
      [ -e "$src" ] || continue
      name="$(basename "$src")"
      dest="$ws_dir/$name"
      if [ -s "$dest" ]; then
        continue
      fi
      cp "$src" "$dest"
      chmod 600 "$dest" 2>/dev/null || true
    done
    # Link shared planning system into each workspace for agent-to-agent coordination.
    if [ -f "$SHARED_DIR/KANBAN.md" ]; then
      ln -sfn "$SHARED_DIR/KANBAN.md" "$ws_dir/SHARED_KANBAN.md"
    fi
    if [ -f "$SHARED_DIR/SECOND_BRAIN.md" ]; then
      ln -sfn "$SHARED_DIR/SECOND_BRAIN.md" "$ws_dir/SHARED_SECOND_BRAIN.md"
    fi
    echo "Seeded workspace for $agent_id"
  fi
}

seed_agent_workspace "mo2darkbot"
seed_agent_workspace "mo2drkbot"

# Configure mcporter with gmail-mcp-imap + workspace-mcp credentials.
# Write to all locations mcporter/openclaw might look for config.
if [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
  # Normalize app passwords copied with spaces (Google shows them grouped).
  GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD//[[:space:]]/}"
  export GMAIL_APP_PASSWORD

  # Allow overriding the Gmail address; default to the bot mailbox.
  GMAIL_EMAIL="${GMAIL_EMAIL:-mo2darkbot@gmail.com}"
  export GMAIL_EMAIL
  # OAuth refresh tokens are sometimes copied with whitespace/newlines.
  GOOGLE_OAUTH_REFRESH_TOKEN="${GOOGLE_OAUTH_REFRESH_TOKEN//[[:space:]]/}"
  export GOOGLE_OAUTH_REFRESH_TOKEN
  WS_MCP_CREDENTIALS_DIR="$CONFIG_DIR/credentials/workspace-mcp"
  export WS_MCP_CREDENTIALS_DIR

  if [ "${#GMAIL_APP_PASSWORD}" -ne 16 ]; then
    echo "WARNING: GMAIL_APP_PASSWORD length is ${#GMAIL_APP_PASSWORD} (expected 16 for Google App Password)."
  fi

  mkdir -p "$HOME/.mcporter" "$CONFIG_DIR/config" "$WS_MCP_CREDENTIALS_DIR"
  chmod 700 "$WS_MCP_CREDENTIALS_DIR" 2>/dev/null || true
  sed -e "s|\${GMAIL_APP_PASSWORD}|${GMAIL_APP_PASSWORD}|g" \
      -e "s|mo2dark@gmail.com|${GMAIL_EMAIL}|g" \
      /opt/mcporter-config.json > "$HOME/.mcporter/config.json"

  # Ensure workspace-mcp receives required auth env vars + correct credential dir key.
  TMP_MCPO="$(mktemp)"
  jq --arg ws_dir "$WS_MCP_CREDENTIALS_DIR" \
     --arg guser "$GMAIL_EMAIL" \
     --arg oauth_client_id "${GOOGLE_OAUTH_CLIENT_ID:-}" \
     --arg oauth_client_secret "${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
     --arg oauth_refresh_token "${GOOGLE_OAUTH_REFRESH_TOKEN:-}" \
     '.mcpServers["google-workspace-api"].env = (
        (.mcpServers["google-workspace-api"].env // {})
        + {
            "GOOGLE_MCP_CREDENTIALS_DIR": $ws_dir,
            "WORKSPACE_MCP_CREDENTIALS_DIR": $ws_dir,
            "USER_GOOGLE_EMAIL": $guser
          }
        + (if $oauth_client_id != "" then {"GOOGLE_OAUTH_CLIENT_ID": $oauth_client_id} else {} end)
        + (if $oauth_client_secret != "" then {"GOOGLE_OAUTH_CLIENT_SECRET": $oauth_client_secret} else {} end)
        + (if $oauth_refresh_token != "" then {"GOOGLE_OAUTH_REFRESH_TOKEN": $oauth_refresh_token} else {} end)
      )' "$HOME/.mcporter/config.json" > "$TMP_MCPO"
  mv "$TMP_MCPO" "$HOME/.mcporter/config.json"

  # Seed workspace-mcp credential cache for non-interactive Calendar/Docs/Drive calls.
  if [ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ] && [ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ] && [ -n "${GOOGLE_OAUTH_REFRESH_TOKEN:-}" ]; then
    WS_ACCESS_TOKEN=""
    WS_TOKEN_EXPIRY=""
    # Pre-fetch an access token so the credential file is immediately usable.
    TOKEN_RESPONSE="$(curl -fsS https://oauth2.googleapis.com/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=${GOOGLE_OAUTH_CLIENT_ID}" \
      --data-urlencode "client_secret=${GOOGLE_OAUTH_CLIENT_SECRET}" \
      --data-urlencode "refresh_token=${GOOGLE_OAUTH_REFRESH_TOKEN}" \
      --data-urlencode "grant_type=refresh_token" 2>/dev/null || true)"
    if [ -n "$TOKEN_RESPONSE" ]; then
      WS_ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // ""')"
      WS_EXPIRES_IN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.expires_in // 0')"
      if [ "$WS_EXPIRES_IN" -gt 0 ] 2>/dev/null; then
        WS_TOKEN_EXPIRY="$(date -u -d "@$(( $(date +%s) + WS_EXPIRES_IN - 60 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"
      fi
    fi

    jq -n \
      --arg token_uri "https://oauth2.googleapis.com/token" \
      --arg access_token "${WS_ACCESS_TOKEN}" \
      --arg client_id "${GOOGLE_OAUTH_CLIENT_ID}" \
      --arg client_secret "${GOOGLE_OAUTH_CLIENT_SECRET}" \
      --arg refresh_token "${GOOGLE_OAUTH_REFRESH_TOKEN}" \
      --arg expiry "${WS_TOKEN_EXPIRY}" \
      --argjson scopes '[
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/documents",
        "https://www.googleapis.com/auth/documents.readonly",
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "openid",
        "email",
        "profile"
      ]' \
      '{
        "token": $access_token,
        "refresh_token": $refresh_token,
        "token_uri": $token_uri,
        "client_id": $client_id,
        "client_secret": $client_secret,
        "scopes": $scopes,
        "expiry": $expiry
      }' > "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}_credentials.json"
    # Keep legacy filename too in case an older workspace-mcp build is deployed.
    cp "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}_credentials.json" "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}.json"
    chmod 600 "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}_credentials.json" \
              "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}.json" 2>/dev/null || true
    echo "workspace-mcp OAuth credential cache written for ${GMAIL_EMAIL}"
  else
    echo "workspace-mcp OAuth secrets missing; calendar/docs may require interactive auth"
  fi

  cp "$HOME/.mcporter/config.json" "$HOME/.mcporter/mcporter.json"
  cp "$HOME/.mcporter/config.json" "$CONFIG_DIR/config/mcporter.json"
  chmod 600 "$HOME/.mcporter/config.json" "$HOME/.mcporter/mcporter.json" \
            "$CONFIG_DIR/config/mcporter.json" 2>/dev/null || true
  echo "mcporter gmail-mcp-imap configured for ${GMAIL_EMAIL} (app password)"
else
  echo "GMAIL_APP_PASSWORD not set — skipping mcporter gmail config"
fi

# Configure himalaya email client
if [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
  mkdir -p "$HOME/.config/himalaya"
  sed -e "s|\${GMAIL_APP_PASSWORD}|${GMAIL_APP_PASSWORD}|g" \
      -e "s|mo2dark@gmail.com|${GMAIL_EMAIL}|g" \
      /opt/himalaya-config.toml > "$HOME/.config/himalaya/config.toml"
  chmod 600 "$HOME/.config/himalaya/config.toml" 2>/dev/null || true
  echo "Himalaya email client configured for ${GMAIL_EMAIL}"
else
  echo "GMAIL_APP_PASSWORD not set — skipping himalaya config"
fi

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
  --arg aoai_embed_dep "${AZURE_OPENAI_EMBEDDING_DEPLOYMENT:-text-embedding-3-small}" \
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
  --arg brave_key "${BRAVE_API_KEY:-}" \
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
    "GMAIL_APP_PASSWORD": $gmail_pw,
    "BRAVE_API_KEY": $brave_key
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
      "maxConcurrent": 2,
      "subagents": {"maxConcurrent": 8},
      "memorySearch": {
        "enabled": true,
        "provider": "openai",
        "model": $aoai_embed_dep,
        "remote": {
          "baseUrl": ($aoai_ep + "openai/v1"),
          "apiKey": $aoai_key,
          "headers": {
            "api-key": $aoai_key
          },
          "batch": {
            "enabled": false
          }
        },
        "fallback": "none",
        "sources": ["memory"],
        "store": {
          "path": ($config_dir + "/memory-index"),
          "vector": {"enabled": true}
        },
        "sync": {
          "onSessionStart": false,
          "onSearch": true,
          "watch": false
        }
      }
    },
    "list": [
      {"id": "mo2darkbot", "name": "@mo2darkbot", "workspace": ($config_dir + "/workspace-mo2darkbot"), "subagents": {"allowAgents": ["mo2drkbot"]}, "tools": {"profile": "full", "allow": ["llm-task"]}},
      {"id": "mo2drkbot", "name": "@mo2drkbot", "workspace": ($config_dir + "/workspace-mo2drkbot"), "subagents": {"allowAgents": ["mo2darkbot"]}, "tools": {"profile": "full", "allow": ["llm-task"]}}
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
    "trustedProxies": [
      "127.0.0.1",
      "::1",
      "100.100.0.60",
      "100.100.0.197",
      "100.100.194.25"
    ],
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

# Enforce the multi-brief cron cadence + output template in persistent state.
if [ "${OPENCLAW_ENFORCE_MULTI_BRIEF_CRON:-true}" = "true" ]; then
  BRIEF_AGENT_ID="${OPENCLAW_BRIEF_AGENT_ID:-mo2darkbot}"
  if /usr/local/bin/configure-brief-cron "$CONFIG_DIR" "$BRIEF_AGENT_ID"; then
    echo "Daily brief cron cadence configured for agent: ${BRIEF_AGENT_ID}"
  else
    echo "WARNING: Failed to configure daily brief cron cadence"
  fi
fi

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
echo "Configured memorySearch provider: openai via Azure OpenAI (model: ${AZURE_OPENAI_EMBEDDING_DEPLOYMENT:-text-embedding-3-small})"
echo "AZURE_OPENAI_API_KEY present: $([ -n "${AZURE_OPENAI_API_KEY:-}" ] && echo 'yes' || echo 'NO — embeddings will fail!')"
echo "Gateway bind mode: ${GATEWAY_BIND} (port ${GATEWAY_PORT})"
if [ -n "${GH_TOKEN:-}" ]; then
  echo "GitHub token configured for skill runtime"
else
  echo "GitHub token not configured"
fi

# Start OpenClaw gateway
exec openclaw gateway run --bind "${GATEWAY_BIND}" --port "${GATEWAY_PORT}"
