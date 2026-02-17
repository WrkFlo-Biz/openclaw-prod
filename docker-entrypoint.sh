#!/bin/bash
set -e

PERSIST_DIR="/data/openclaw/.openclaw"
CONFIG_DIR="/tmp/openclaw-state"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# Run active state on local disk to avoid Azure Files SQLite lock contention.
# Persist snapshots to Azure Files so state is restored across container restarts.
STATE_RESTORE_DIRS=(
  "agents"
  "canvas"
  "config"
  "credentials"
  "cron"
  "devices"
  "memory"
  "shared"
  "slack"
  "telegram"
)
STATE_PERSIST_EXTRA_DIRS=(
  "workspace"
  "workspace-mo2darkbot"
  "workspace-mo2drkbot"
)
STATE_FILES=(
  ".sessions-cleared-v3"
  ".memory-index-reset-aoai-embed3-v2"
  "openclaw.json"
)

restore_runtime_state() {
  mkdir -p "$PERSIST_DIR" "$CONFIG_DIR"
  local dir
  local file
  for dir in "${STATE_RESTORE_DIRS[@]}"; do
    if [ -d "$PERSIST_DIR/$dir" ]; then
      mkdir -p "$CONFIG_DIR/$dir"
      cp -a "$PERSIST_DIR/$dir/." "$CONFIG_DIR/$dir/" 2>/dev/null || true
    fi
  done
  for file in "${STATE_FILES[@]}"; do
    if [ -f "$PERSIST_DIR/$file" ]; then
      cp -a "$PERSIST_DIR/$file" "$CONFIG_DIR/$file" 2>/dev/null || true
    fi
  done
  # Clear stale session lock files restored from Azure Files (previous PID is dead).
  find "$CONFIG_DIR" -name '*.lock' -type f -delete 2>/dev/null || true
}

persist_runtime_state() {
  # Avoid copying back transient artifacts to Azure Files.
  prune_telegram_tmp_runtime
  prune_cron_tmp_runtime
  prune_config_backups_runtime
  # Never persist session lock files — they are PID-specific and stale after restart.
  find "$CONFIG_DIR" -name '*.lock' -type f -delete 2>/dev/null || true

  mkdir -p "$PERSIST_DIR"
  local dir
  local file
  for dir in "${STATE_RESTORE_DIRS[@]}" "${STATE_PERSIST_EXTRA_DIRS[@]}"; do
    if [ -d "$CONFIG_DIR/$dir" ]; then
      mkdir -p "$PERSIST_DIR/$dir"
      cp -a "$CONFIG_DIR/$dir/." "$PERSIST_DIR/$dir/" 2>/dev/null || true
    fi
  done
  for file in "${STATE_FILES[@]}"; do
    if [ -f "$CONFIG_DIR/$file" ]; then
      cp -a "$CONFIG_DIR/$file" "$PERSIST_DIR/$file" 2>/dev/null || true
    fi
  done

  # Keep Azure Files state clean: atomic writes can leave orphan *.tmp files and noisy backups.
  prune_telegram_tmp_persist
  prune_cron_tmp_persist
  prune_cron_backups_persist
  prune_config_backups_persist
}

prune_telegram_tmp_runtime() {
  find "$CONFIG_DIR/telegram" -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null || true
}

prune_telegram_tmp_persist() {
  find "$PERSIST_DIR/telegram" -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null || true
}

prune_cron_tmp_runtime() {
  find "$CONFIG_DIR/cron" -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null || true
}

prune_cron_tmp_persist() {
  find "$PERSIST_DIR/cron" -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null || true
}

prune_cron_backups_persist() {
  # Retain a small tail of cron snapshots; old ones create noise and consume space.
  local keep="${OPENCLAW_CRON_SNAPSHOT_KEEP:-5}"
  local cron_dir="$PERSIST_DIR/cron"

  # Best-effort: if keep is invalid, fall back to 5.
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    keep=5
  fi

  # Drop timestamped backups like jobs.json.bak.<epoch>; keep jobs.json.bak.
  rm -f "$cron_dir"/jobs.json.bak.* 2>/dev/null || true

  shopt -s nullglob
  local snapshots=( "$cron_dir"/jobs.json.pre-brief.*.bak )
  if [ "${#snapshots[@]}" -gt "$keep" ] 2>/dev/null; then
    IFS=$'\n' sorted=( $(printf '%s\n' "${snapshots[@]}" | sort) )
    unset IFS
    local delete_count=$((${#sorted[@]} - keep))
    local i
    for ((i=0; i<delete_count; i++)); do
      rm -f "${sorted[$i]}" 2>/dev/null || true
    done
  fi
  shopt -u nullglob
}

prune_config_backups_runtime() {
  rm -f \
    "$CONFIG_DIR/config/.write_test" \
    "$CONFIG_DIR/config/docker-entrypoint.custom.sh.bak."* \
    "$CONFIG_DIR/config/mcporter.json.bak."* \
    2>/dev/null || true
}

prune_config_backups_persist() {
  rm -f \
    "$PERSIST_DIR/config/.write_test" \
    "$PERSIST_DIR/config/docker-entrypoint.custom.sh.bak."* \
    "$PERSIST_DIR/config/mcporter.json.bak."* \
    2>/dev/null || true
}

sanitize_sessions_sessionfile_paths() {
  # OpenClaw persists `sessionFile` paths in sessions.json. When state is restored from
  # Azure Files to the runtime state dir, those paths can point outside the current
  # sessions dir (e.g. old `/data/...` paths), causing:
  #   "Session file path must be within sessions directory"
  # This breaks inbound handlers (Telegram) and heartbeat.
  if ! command -v node >/dev/null 2>&1; then
    echo "WARNING: node not found; skipping sessionFile sanitization"
    return 0
  fi

  shopt -s nullglob
  local session_files=( "$CONFIG_DIR"/agents/*/sessions/sessions.json )
  shopt -u nullglob
  if [ "${#session_files[@]}" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  local f
  for f in "${session_files[@]}"; do
    node -e '
const fs = require("fs");
const path = require("path");

const filePath = process.argv[2];
const persistDir = process.argv[3] || "";
const runtimeDir = process.argv[4] || "";
const sessionsDir = path.dirname(filePath);
const agentId = path.basename(path.dirname(sessionsDir));

function isWithinDir(baseDir, targetPath) {
  const rel = path.relative(baseDir, targetPath);
  return !rel.startsWith("..") && !path.isAbsolute(rel);
}

function normalizeSessionFile(sessionFile) {
  if (typeof sessionFile !== "string") return { ok: false };
  let sf = sessionFile.trim();
  if (!sf) return { ok: false };

  // Map persisted absolute paths into the runtime state dir.
  if (path.isAbsolute(sf) && persistDir && runtimeDir) {
    const pd = persistDir.endsWith(path.sep) ? persistDir : persistDir + path.sep;
    if (sf.startsWith(pd)) {
      sf = path.join(runtimeDir, sf.slice(pd.length));
    }
  }

  const resolved = path.resolve(sessionsDir, sf);
  if (isWithinDir(sessionsDir, resolved)) {
    const rel = path.relative(sessionsDir, resolved);
    // Avoid returning a directory path.
    if (!rel || rel.endsWith(path.sep)) return { ok: false };
    return { ok: true, value: rel };
  }

  // Best-effort salvage: if the basename exists inside sessionsDir, rewrite to basename.
  const base = path.basename(sf);
  const salvage = path.join(sessionsDir, base);
  if (isWithinDir(sessionsDir, salvage) && fs.existsSync(salvage)) {
    return { ok: true, value: base };
  }

  return { ok: false };
}

function walk(node) {
  if (!node || typeof node !== "object") return 0;
  let changes = 0;
  if (Array.isArray(node)) {
    for (const item of node) changes += walk(item);
    return changes;
  }

  if (Object.prototype.hasOwnProperty.call(node, "sessionFile")) {
    const norm = normalizeSessionFile(node.sessionFile);
    if (!norm.ok) {
      delete node.sessionFile;
      changes += 1;
    } else if (node.sessionFile !== norm.value) {
      node.sessionFile = norm.value;
      changes += 1;
    }
  }

  for (const v of Object.values(node)) changes += walk(v);
  return changes;
}

let raw = "";
try {
  raw = fs.readFileSync(filePath, "utf8");
} catch {
  process.exit(0);
}

let data;
try {
  data = JSON.parse(raw);
} catch (e) {
  console.error(`[sessions-sanitize] ${agentId}: invalid JSON in sessions store (${e && e.message ? e.message : e})`);
  process.exit(0);
}

const changed = walk(data);
if (changed > 0) {
  const tmpPath = filePath + ".tmp";
  try {
    fs.writeFileSync(tmpPath, JSON.stringify(data) + "\n");
    fs.renameSync(tmpPath, filePath);
  } catch (e) {
    console.error(`[sessions-sanitize] ${agentId}: failed to write sanitized sessions.json (${e && e.message ? e.message : e})`);
    process.exit(0);
  }
  console.log(`[sessions-sanitize] ${agentId}: fixed ${changed} sessionFile path(s)`);
}
' "$f" "$PERSIST_DIR" "$CONFIG_DIR" 2>/dev/null || true
  done
}

restore_runtime_state

# Cleanup any stale temp files that were restored/persisted previously.
prune_telegram_tmp_runtime
prune_telegram_tmp_persist
prune_cron_tmp_runtime
prune_cron_tmp_persist
prune_cron_backups_persist
prune_config_backups_runtime
prune_config_backups_persist

export OPENCLAW_STATE_DIR="$CONFIG_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"

# Best-effort permissions hardening.
# Note: Azure Files volumes often present as 0777; we still try to restrict.
umask 077

# Ensure state directories exist
mkdir -p \
  "$CONFIG_DIR/workspace" \
  "$CONFIG_DIR/workspace/memory" \
  "$CONFIG_DIR/memory-index-cache" \
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

# Memory search uses SQLite; store active DBs on local disk to avoid Azure Files locks.
MEMORY_DB_DIR="/tmp/openclaw-memory"
mkdir -p "$MEMORY_DB_DIR"
chmod 700 "$MEMORY_DB_DIR" 2>/dev/null || true

# Persist snapshots of memory DBs on mounted storage for restart durability.
MEMORY_CACHE_DIR="$PERSIST_DIR/memory-index-cache"
mkdir -p "$MEMORY_CACHE_DIR"
chmod 700 "$MEMORY_CACHE_DIR" 2>/dev/null || true

restore_memory_index_cache() {
  local agent_id="$1"
  local restored=0

  for suffix in "" "-wal" "-shm"; do
    local src="$MEMORY_CACHE_DIR/${agent_id}.sqlite${suffix}"
    local dest="$MEMORY_DB_DIR/${agent_id}.sqlite${suffix}"
    if [ -s "$src" ] && [ ! -s "$dest" ]; then
      cp "$src" "$dest" 2>/dev/null || true
      restored=1
    fi
  done

  if [ "$restored" -eq 1 ]; then
    echo "Restored memory index cache for $agent_id"
  fi
}

save_memory_index_cache() {
  local agent_id="$1"
  local saved=0

  if [ ! -s "$MEMORY_DB_DIR/${agent_id}.sqlite" ]; then
    return 0
  fi

  for suffix in "" "-wal" "-shm"; do
    local src="$MEMORY_DB_DIR/${agent_id}.sqlite${suffix}"
    local dest="$MEMORY_CACHE_DIR/${agent_id}.sqlite${suffix}"
    if [ -e "$src" ]; then
      cp "$src" "$dest" 2>/dev/null || true
      saved=1
    fi
  done

  if [ "$saved" -eq 1 ]; then
    echo "Saved memory index cache for $agent_id"
  fi
}

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

# Fix up any persisted sessionFile paths that point outside the sessions dir.
sanitize_sessions_sessionfile_paths

# One-time: nuke memory index so it rebuilds with Azure OpenAI embeddings.
if [ -f "$CONFIG_DIR/.memory-index-reset-aoai-embed3-v2" ]; then
  echo "Memory index already reset for Azure OpenAI embeddings."
else
  echo "Resetting memory index to force Azure OpenAI embeddings rebuild..."
  rm -f "$MEMORY_DB_DIR/"*.sqlite "$MEMORY_DB_DIR/"*.sqlite-* 2>/dev/null || true
  rm -f "$MEMORY_CACHE_DIR/"*.sqlite "$MEMORY_CACHE_DIR/"*.sqlite-* 2>/dev/null || true
  touch "$CONFIG_DIR/.memory-index-reset-aoai-embed3-v2"
fi

# Restore cached index into /tmp so memory search is warm after restarts.
restore_memory_index_cache "mo2darkbot"
restore_memory_index_cache "mo2drkbot"


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
# Role guardrails are always refreshed; other files are only written when missing/empty.
AGENT_SRC_DIR="/opt/openclaw-agents"
seed_agent_workspace() {
  local agent_id="$1"
  local ws_dir="$CONFIG_DIR/workspace-${agent_id}"
  local src
  local name
  local dest
  local should_copy
  mkdir -p "$ws_dir"
  if [ -d "$AGENT_SRC_DIR/$agent_id" ]; then
    for src in "$AGENT_SRC_DIR/$agent_id/"*.md; do
      [ -e "$src" ] || continue
      name="$(basename "$src")"
      dest="$ws_dir/$name"
      should_copy="false"
      if [ "$name" = "ROLE_GUARDRAILS.md" ]; then
        should_copy="true"
      elif [ ! -s "$dest" ]; then
        should_copy="true"
      fi
      if [ "$should_copy" != "true" ]; then
        continue
      fi
      cp "$src" "$dest"
      chmod 600 "$dest" 2>/dev/null || true
    done
    # Copy shared planning system into each workspace for agent-to-agent coordination.
    # Avoid symlinks because Azure Files mounts do not reliably support them.
    if [ -f "$SHARED_DIR/KANBAN.md" ]; then
      cp "$SHARED_DIR/KANBAN.md" "$ws_dir/SHARED_KANBAN.md" 2>/dev/null || true
      chmod 600 "$ws_dir/SHARED_KANBAN.md" 2>/dev/null || true
    fi
    if [ -f "$SHARED_DIR/SECOND_BRAIN.md" ]; then
      cp "$SHARED_DIR/SECOND_BRAIN.md" "$ws_dir/SHARED_SECOND_BRAIN.md" 2>/dev/null || true
      chmod 600 "$ws_dir/SHARED_SECOND_BRAIN.md" 2>/dev/null || true
    fi
    echo "Seeded workspace for $agent_id"
  fi
}

seed_agent_workspace "mo2darkbot"
seed_agent_workspace "mo2drkbot"

# Configure mcporter with a single Google Workspace full server (workspace-mcp).
# Write to all locations mcporter/openclaw might look for config.
# Keep optional app-password normalization for himalaya and any legacy tools.
if [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
  GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD//[[:space:]]/}"
  export GMAIL_APP_PASSWORD
fi

# Allow overriding the Gmail address; default to the bot mailbox.
GMAIL_EMAIL="${GMAIL_EMAIL:-mo2darkbot@gmail.com}"
export GMAIL_EMAIL
# OAuth refresh tokens are sometimes copied with whitespace/newlines.
GOOGLE_OAUTH_REFRESH_TOKEN="${GOOGLE_OAUTH_REFRESH_TOKEN:-}"
GOOGLE_OAUTH_REFRESH_TOKEN="${GOOGLE_OAUTH_REFRESH_TOKEN//[[:space:]]/}"
export GOOGLE_OAUTH_REFRESH_TOKEN
WS_MCP_CREDENTIALS_DIR="$CONFIG_DIR/credentials/workspace-mcp"
export WS_MCP_CREDENTIALS_DIR

mkdir -p "$HOME/.mcporter" "$CONFIG_DIR/config" "$WS_MCP_CREDENTIALS_DIR"
chmod 700 "$WS_MCP_CREDENTIALS_DIR" 2>/dev/null || true
sed -e "s|mo2dark@gmail.com|${GMAIL_EMAIL}|g" \
    /opt/mcporter-config.json > "$HOME/.mcporter/config.json"

  # Ensure workspace-mcp receives correct credential dir + user email.
  # OAuth secrets are intentionally NOT injected into the MCP env because:
  # - workspace-mcp can refresh from the on-disk credential cache
  # - injecting stale secrets can override good cached credentials and break Calendar/Docs
  TMP_MCPO="$(mktemp)"
  jq --arg ws_dir "$WS_MCP_CREDENTIALS_DIR" \
     --arg guser "$GMAIL_EMAIL" \
     '.mcpServers["google-workspace-api"].env = (
        (.mcpServers["google-workspace-api"].env // {})
        + {
            "GOOGLE_MCP_CREDENTIALS_DIR": $ws_dir,
            "WORKSPACE_MCP_CREDENTIALS_DIR": $ws_dir,
            "USER_GOOGLE_EMAIL": $guser
          }
      )' "$HOME/.mcporter/config.json" > "$TMP_MCPO"
  mv "$TMP_MCPO" "$HOME/.mcporter/config.json"

  # Seed workspace-mcp credential cache for non-interactive Calendar/Docs/Drive calls.
  # Preserve an existing cache restored from mounted storage.
  WS_EXISTING_CRED=""
  for cand in \
    "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}.json" \
    "$WS_MCP_CREDENTIALS_DIR/${GMAIL_EMAIL}_credentials.json"; do
    if [ -s "$cand" ]; then
      WS_EXISTING_CRED="$cand"
      break
    fi
  done

  if [ -n "$WS_EXISTING_CRED" ]; then
    echo "workspace-mcp OAuth credential cache present for ${GMAIL_EMAIL} (preserved)"
  elif [ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ] && [ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ] && [ -n "${GOOGLE_OAUTH_REFRESH_TOKEN:-}" ]; then
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
    echo "workspace-mcp OAuth secrets missing and no cached credential file found; calendar/docs may require interactive auth"
  fi

cp "$HOME/.mcporter/config.json" "$HOME/.mcporter/mcporter.json"
cp "$HOME/.mcporter/config.json" "$CONFIG_DIR/config/mcporter.json"
chmod 600 "$HOME/.mcporter/config.json" "$HOME/.mcporter/mcporter.json" \
          "$CONFIG_DIR/config/mcporter.json" 2>/dev/null || true
echo "mcporter google-workspace-api (full) configured for ${GMAIL_EMAIL}"

# workspace-mcp should use the on-disk credential cache; avoid leaking OAuth secrets into
# runtime env where they might override cached credentials.
unset GOOGLE_OAUTH_REFRESH_TOKEN GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET

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

# Hard-disable non-Azure providers in this deployment path; all model routing is Azure-backed.
unset GEMINI_API_KEY
unset OPENAI_API_KEY

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
      "maxConcurrent": 1,
      "subagents": {"maxConcurrent": 1},
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
          "path": "/tmp/openclaw-memory/{agentId}.sqlite",
          "vector": {"enabled": true}
        },
        "sync": {
          "onSessionStart": false,
          "onSearch": false,
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
  "bindings": [
    {"agentId": "mo2darkbot", "match": {"channel": "telegram", "accountId": "default"}},
    {"agentId": "mo2drkbot", "match": {"channel": "telegram", "accountId": "mo2drkbot"}}
  ],
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
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true
    },
    "trustedProxies": [
      "127.0.0.1",
      "::1",
      "10.0.0.0/8",
      "100.100.0.0/16",
      "172.16.0.0/12",
      "100.100.0.60",
      "100.100.0.197",
      "100.100.194.25"
    ],
    "auth": {"mode": "token", "token": $gw_token, "allowTailscale": true}
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
  if [ "${OPENCLAW_ENABLE_COS_BRIEFS:-true}" = "true" ]; then
    if /usr/local/bin/configure-brief-cron "$CONFIG_DIR" "mo2darkbot" "ops"; then
      echo "Daily brief cron cadence configured for CoS agent: mo2darkbot"
    else
      echo "WARNING: Failed to configure CoS daily brief cron cadence"
    fi
  fi
  if [ "${OPENCLAW_ENABLE_CMO_BRIEFS:-true}" = "true" ]; then
    if /usr/local/bin/configure-brief-cron "$CONFIG_DIR" "mo2drkbot" "marketing"; then
      echo "Daily brief cron cadence configured for CMO agent: mo2drkbot"
    else
      echo "WARNING: Failed to configure CMO daily brief cron cadence"
    fi
  fi
  if [ -n "${OPENCLAW_BRIEF_AGENT_ID:-}" ] && [ "${OPENCLAW_ENABLE_LEGACY_BRIEF_AGENT:-false}" = "true" ]; then
    if /usr/local/bin/configure-brief-cron "$CONFIG_DIR" "${OPENCLAW_BRIEF_AGENT_ID}" "ops"; then
      echo "Legacy brief agent cadence configured for: ${OPENCLAW_BRIEF_AGENT_ID}"
    else
      echo "WARNING: Failed to configure legacy brief agent cadence"
    fi
  fi
  if [ "${OPENCLAW_ENABLE_COS_BRIEFS:-true}" != "true" ] && [ "${OPENCLAW_ENABLE_CMO_BRIEFS:-true}" != "true" ] && [ "${OPENCLAW_ENABLE_LEGACY_BRIEF_AGENT:-false}" != "true" ]; then
    echo "Daily brief cron cadence skipped (all brief profiles disabled)"
  fi
else
  if [ "${OPENCLAW_ENABLE_LEGACY_BRIEF_AGENT:-false}" = "true" ] && [ -n "${OPENCLAW_BRIEF_AGENT_ID:-}" ]; then
    if /usr/local/bin/configure-brief-cron "$CONFIG_DIR" "${OPENCLAW_BRIEF_AGENT_ID}" "ops"; then
      echo "Legacy brief cron cadence configured for agent: ${OPENCLAW_BRIEF_AGENT_ID}"
    else
      echo "WARNING: Failed to configure legacy brief cron cadence"
    fi
  else
    echo "Daily brief cron cadence disabled"
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

# Persist memory DB snapshots periodically while gateway is running.
# This keeps memory durable across container restarts without using Azure Files as live SQLite storage.
MEMORY_CACHE_SYNC_SECS="${OPENCLAW_MEMORY_CACHE_SYNC_SECS:-120}"
if [ "$MEMORY_CACHE_SYNC_SECS" -gt 0 ] 2>/dev/null; then
  (
    while true; do
      sleep "$MEMORY_CACHE_SYNC_SECS"
      save_memory_index_cache "mo2darkbot" 2>/dev/null || true
      save_memory_index_cache "mo2drkbot" 2>/dev/null || true
    done
  ) &
  echo "Memory cache sync enabled every ${MEMORY_CACHE_SYNC_SECS}s"
fi

# Persist full runtime state back to Azure Files on an interval so it survives restarts.
STATE_SYNC_SECS="${OPENCLAW_STATE_SYNC_SECS:-60}"
if [ "$STATE_SYNC_SECS" -gt 0 ] 2>/dev/null; then
  (
    while true; do
      sleep "$STATE_SYNC_SECS"
      persist_runtime_state 2>/dev/null || true
    done
  ) &
  echo "Runtime state sync enabled every ${STATE_SYNC_SECS}s"
fi

# Persist initial config/state before launching the gateway.
persist_runtime_state 2>/dev/null || true

# Start OpenClaw gateway
exec openclaw gateway run --bind "${GATEWAY_BIND}" --port "${GATEWAY_PORT}"
