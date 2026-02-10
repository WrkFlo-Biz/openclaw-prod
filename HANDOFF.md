# OpenClaw Production — Handoff Log (2026-02-10)

## Repository & Infrastructure

- **Repo**: `Wrk-Flo/openclaw-prod` (GitHub)
- **Platform**: Azure Container Apps
- **Resource group**: `openclaw-rg`, container app: `openclaw-gateway`
- **Registry**: `wrkfloopenclawacr.azurecr.io/openclaw`
- **Container user**: `openclaw` (HOME=/data/openclaw), NOT root
- **Persistent storage**: Azure Files mounted at `/data/openclaw/.openclaw`
- **Deploy**: Push to `main` → GitHub Actions → Docker build → Azure (~15 min)
- **Latest commit**: `47dc7a1` (feat: allow mo2darkbot to use mo2drkbot as subagent)

**Current prod state (2026-02-10)**:
- **Revision**: `openclaw-gateway--0000045`
- **Image**: `wrkfloopenclawacr.azurecr.io/openclaw:47dc7a13116828db9d470840cc62924687fb6f62`
- **Startup command override**: `/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh` (Azure Files)

**IMPORTANT (2026-02-09)**: Production currently overrides the image entrypoint.
- Container app startup command: `/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh` (on the Azure Files mount)
- This file is the real source of truth for startup config (including `memorySearch`).
- Verify with:
  ```bash
  az containerapp show -g openclaw-rg -n openclaw-gateway --query "properties.template.containers[0].command" -o json
  ```

## Agents

| ID | Handle | Role | Workspace |
|----|--------|------|-----------|
| `mo2darkbot` | @mo2darkbot | Chief of Staff ("Mo"/"Chief") | `/data/openclaw/.openclaw/workspace-mo2darkbot` |
| `mo2drkbot` | @mo2drkbot | CMO ("Momo CMO"/"Maven") | `/data/openclaw/.openclaw/workspace-mo2drkbot` |

- No `main` agent. Primary model: `azure-openai/gpt-5-mini` with fallbacks: gpt-5.2, gpt-4o, claude-opus-4-6
- Workspace files seeded from `agents/{id}/*.md` via the prod entrypoint override (missing/empty only so edits persist)

## Key Files

| File | Purpose |
|------|---------|
| `docker-entrypoint.sh` | Image entrypoint (may be bypassed in prod if command override is set) |
| `/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh` | **Prod startup script** (generates `openclaw.json`, seeds workspaces, starts gateway) |
| `.github/workflows/deploy.yml` | Builds Docker, deploys to Azure, mounts Azure Files |
| `Dockerfile` | Installs openclaw + tools, creates non-root user |
| `mcporter-config.json` | MCP server template: `gmail-mcp-imap` + `workspace-mcp` (Calendar/Docs/Drive) |
| `/data/openclaw/.openclaw/config/mcporter.json` | **Prod runtime MCP config** (persisted; used by cron prompts) |
| `himalaya-config.toml` | himalaya email client template |
| `agents/mo2darkbot/*.md` | Mo (CoS) workspace seed |
| `agents/mo2drkbot/*.md` | Momo (CMO) workspace seed |
| `scripts/self-ops.sh` | In-container: restart, redeploy, health, status |

---

# PENDING TASKS (Priority Order)

## TASK 1: Verify Gemini Embeddings Fix (DEPLOY IN PROGRESS)

**Status**: **DEPLOYED + VERIFIED (2026-02-09 19:33 UTC)** — production was using `docker-entrypoint.custom.sh` (not the repo `docker-entrypoint.sh`), so the fix had to be applied there.

**Problem**: Logs show `openai embeddings failed: 429 insufficient_quota`. Config says `provider: "gemini"` but OpenAI was being used.

**Investigation completed**:
- Config schema validated — all fields match OpenClaw's strict Zod schema
- Full source trace: `resolveMemorySearchConfig()` → `mergeConfig()` (memory-search.js:49) → `createEmbeddingProvider()` (embeddings.js:82) → routes to Gemini when provider="gemini"
- Gemini client reads GEMINI_API_KEY via `resolveApiKeyForProvider({provider:"google"})` → env map in model-auth.js:215
- Memory index stores provider in `meta` table; mismatch triggers `runSafeReindex`
- Old index was OpenAI-based; reindex to Gemini was likely failing silently

**Fix applied** (`/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh`):
1. One-time deletion of local SQLite memory-search index files (`/tmp/openclaw-memory/*.sqlite*`, flag: `.memory-index-reset-gemini`)
2. Startup echo confirming GEMINI_API_KEY is present

**Verify after deploy**:
```bash
az containerapp logs show -g openclaw-rg -n openclaw-gateway --tail 100 2>&1 | grep -i -E "gemini|openai|embed|memory.*reset|GEMINI_API_KEY"
```

**Expected**:
- `Resetting memory index to force Gemini embeddings rebuild...`
- `GEMINI_API_KEY present: yes`
- No more `openai embeddings failed: 429`

**Verified in prod logs (2026-02-09 19:33 UTC)**:
- `Resetting memory index to force Gemini embeddings rebuild...`
- `Configured memorySearch provider: gemini (model: gemini-embedding-001)`
- `GEMINI_API_KEY present: 'yes'`

**If still failing**:
1. Check GEMINI_API_KEY exists: `az containerapp show -g openclaw-rg -n openclaw-gateway --query "properties.template.containers[0].env[?name=='GEMINI_API_KEY']" -o json`
2. Gemini client uses `https://generativelanguage.googleapis.com/v1beta` — verify accessible
3. If config validation fails entirely, OpenClaw returns empty `{}` config → defaults to provider "auto" → tries OpenAI first. Check for any Zod validation errors in logs.
4. Nuclear option: add `"memorySearch": {"provider":"gemini","model":"gemini-embedding-001","fallback":"none"}` directly on each agent entry in the `agents.list` array (not just defaults)

**Source files** (at `$(npm root -g)/openclaw/dist/`):
- `memory/embeddings.js:82` — `if (id === "gemini")` routes to Gemini
- `memory/embeddings-gemini.js:106` — `resolveGeminiEmbeddingClient`
- `agents/memory-search.js:49` — `provider = overrides?.provider ?? defaults?.provider ?? "auto"`
- `config/validation.js:84` — `OpenClawSchema.safeParse(raw)` — on fail returns `{}` (io.js:248)
- `memory/manager.js:1041` — `runSync()` detects provider mismatch

## TASK 2: Fix Gmail/IMAP Authentication

**Status**: **FIXED (2026-02-09 20:44 UTC)** — issue was the wrong Gmail account. **FOLLOW-UP FIX (2026-02-10 00:09 UTC)** — Evening/Night cron jobs were using the wrong mcporter tool + missing `--config`.

**Setup**: Switched from workspace-mcp (OAuth, kept expiring) to gmail-mcp-imap (App Password). Config written to 3 locations at runtime:
- `$HOME/.mcporter/config.json`
- `$HOME/.mcporter/mcporter.json`
- `$CONFIG_DIR/config/mcporter.json`

**What needs fixing**:
1. **Root cause**: Bot was trying to auth as `mo2dark@gmail.com`, but the configured app password is for `mo2darkbot@gmail.com`.
   - Confirmed inside prod container:
     - `mo2dark@gmail.com` + app password → IMAP FAIL (`AUTHENTICATIONFAILED`)
     - `mo2darkbot@gmail.com` + same app password → IMAP OK, SMTP OK
2. **Fix**: Patched the prod entrypoint override (`/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh`) to generate mcporter + himalaya configs for `mo2darkbot@gmail.com` instead of `mo2dark@gmail.com`, then restarted revision.

**Prod now logs a warning on startup if the app password is not length 16.**

**Cron follow-up (why the bot still said “email not working”)**:
- **Symptom**: Evening/Night Email Briefing cron runs returned `Unknown MCP server 'google-workspace'` and referenced a non-existent tool `google-workspace.gmail_list_emails` (and did not pass `--config`).
- **Root cause**: The Evening/Night cron *messages* were outdated and differed from the working Morning/Midday messages.
- **Fix (prod state on Azure Files)**: Updated `/data/openclaw/.openclaw/cron/jobs.json` for:
  - Evening job `d9c2ed60-6825-4c52-9012-ac585d97f0c2`
  - Night job `8534c662-1fe0-4e01-a881-cc109edc85c3`
  - Replaced the `gmail_list_emails` command with the working IMAP tools + explicit config:
    - `mcporter call --config /data/openclaw/.openclaw/config/mcporter.json google-workspace.get_primary_emails --args '{"limit":50}' --output json`
    - `mcporter call --config /data/openclaw/.openclaw/config/mcporter.json google-workspace.get_updates_emails --args '{"limit":50}' --output json`
- **Verified**: Evening job produced a real categorized summary (no MCP server errors) on `2026-02-10 00:08 UTC` (see `/data/openclaw/.openclaw/cron/runs/d9c2ed60-6825-4c52-9012-ac585d97f0c2.jsonl`).

**To update password**:
```bash
az containerapp secret set -g openclaw-rg -n openclaw-gateway --secrets gmail-app-password='NEW_PASSWORD'
# Restart:
az containerapp revision restart -g openclaw-rg -n openclaw-gateway --revision $(az containerapp show -g openclaw-rg -n openclaw-gateway --query properties.latestRevisionName -o tsv)
```

**Alternatives already installed in container**:
- `himalaya` — CLI email client, config at `$HOME/.config/himalaya/config.toml`
- `gog` (gogcli) — **local-only bootstrap** for OAuth consent. **Do not use in prod bots** (keyring + no TTY issues).

## TASK 3: Enable Google Workspace Calendar/Docs/Drive (workspace-mcp)

**Status**: **ENABLED (2026-02-10)** — `create_event` / Docs tools were missing because prod only had the email-only adapter (`gmail-mcp-imap`).

**Root cause**:
- `mcporter` server `google-workspace` was configured as `npx -y gmail-mcp-imap` which exposes Gmail-only tools.
- Calendar + Docs require a Google API adapter (we use `workspace-mcp`).
- Prod also had a persistent `/data/openclaw/.openclaw/config/mcporter.json` on Azure Files that was not being updated by the new image template until the entrypoint was patched.

**Fix applied**:
1. **Repo**: `mcporter-config.json` now includes:
   - `google-workspace` (gmail-mcp-imap, app password)
   - `google-workspace-api` (workspace-mcp: gmail+calendar+drive+docs)
   - Agent docs updated: `agents/*/TOOLS.md` now contains a hard routing table + canonical `mcporter` command templates so bots stop guessing (and stop trying `gog`).
2. **Prod persistent state** (Azure Files `openclaw-state` share):
   - Updated `/data/openclaw/.openclaw/config/mcporter.json` to include `google-workspace-api`.
   - Patched `/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh` so future restarts re-generate:
     - `$HOME/.mcporter/config.json`
     - `$HOME/.mcporter/mcporter.json`
     - `/data/openclaw/.openclaw/config/mcporter.json` (persisted)
     using `/opt/mcporter-config.json` from the image.
   - Ensures `/data/openclaw/.openclaw/credentials/workspace-mcp` directory exists.
3. **Azure Container App secrets**:
   - Updated `google-oauth-client-id`, `google-oauth-client-secret`, `google-oauth-refresh-token`
   - The refresh token now includes Calendar/Drive/Docs scopes (obtained via local `gog` OAuth consent).
   - Restarted revision to apply secrets.

**How to use**:
- Keep email calls on `google-workspace.*`
- Use Calendar/Docs/Drive calls on `google-workspace-api.*`
  - Example: `google-workspace-api.create_event` (NOT `google-workspace.create_event`)

**Verify**:
```bash
# Fast check (no container exec): confirm mcporter.json on Azure Files includes both servers
KEY=$(az storage account keys list -g openclaw-rg -n openclaw96c9db66 --query "[0].value" -o tsv)
az storage file download --account-name openclaw96c9db66 --account-key "$KEY" \
  --share-name openclaw-state --path config/mcporter.json --dest /tmp/mcporter.json --no-progress
jq -r '.mcpServers|keys[]' /tmp/mcporter.json | sort

# If exec is not rate-limited:
az containerapp exec -g openclaw-rg -n openclaw-gateway --tty --command \
  "mcporter list --config /data/openclaw/.openclaw/config/mcporter.json"
```

## TASK 4: Verify Agent Identities

**Status**: Likely fixed, needs confirmation

**What was done**: Per-agent workspaces, session clear (v3), IDENTITY.md files seeded.

**Verify**: Message each bot on Telegram asking "Who are you?"
- @mo2darkbot → Mo, Chief of Staff
- @mo2drkbot → Momo, CMO

**Note (2026-02-09 19:33 UTC)**: Sessions were cleared again (`.sessions-cleared-v3`) during the restart that applied the Gemini fix.

---

# USEFUL COMMANDS

```bash
# Container status
az containerapp show -g openclaw-rg -n openclaw-gateway --query "{revision: properties.latestRevisionName, image: properties.template.containers[0].image}" -o json

# View logs
az containerapp logs show -g openclaw-rg -n openclaw-gateway --tail 200

# Filter errors
az containerapp logs show -g openclaw-rg -n openclaw-gateway --tail 300 2>&1 | grep -i -E "error|fail|429|quota"

# Deploy history
gh run list --repo Wrk-Flo/openclaw-prod --limit 5

# Quick restart (no rebuild)
gh workflow run deploy.yml --repo Wrk-Flo/openclaw-prod -f skipBuild=true -f imageTag=latest

# Check secrets
az containerapp secret list -g openclaw-rg -n openclaw-gateway -o table
```

# KNOWN ISSUES

| Issue | Fix |
|-------|-----|
| Telegram 409 conflicts | deploy.yml auto-deactivates old revisions |
| chmod EPERM on Azure Files | OpenClaw dist patched with `.catch(()=>{})` |
| `az containerapp exec` no TTY | Use self-ops or GitHub Actions instead |
| Config lost on restart | Prod uses Azure Files entrypoint override: `/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh` |
| LLM FailoverError | Restart clears stuck sessions |

## RECENT HANDOFF — 2026-02-10

### What changed
- Added `mo2drkbot` to `mo2darkbot`’s `subagents.allowAgents` list so the CMO can be spawned.
- The only touched config is the prod entrypoint override (`/data/openclaw/.openclaw/config/docker-entrypoint.custom.sh`) plus the repo `docker-entrypoint.sh`; Azure Containers generate the same merged JSON (see `/data/openclaw/.openclaw/openclaw.json` post-start).
- Restarted revision `openclaw-gateway--0000044` so the gateway picked up the new allowlist entry and confirmed `/api/health` returns `200`.
- Noted the gateway token mismatch log noise in `az containerapp logs` while the UI reconnected; no config error was written.

### Verify for next CLI
- Run `az containerapp show -g openclaw-rg -n openclaw-gateway --query properties.latestRevisionName -o tsv` to confirm you are on `openclaw-gateway--0000044` (or whatever latest started after you read this).
- Fetch `openclaw` config via `az containerapp exec -g openclaw-rg -n openclaw-gateway --command "jq '.agents.list[] | select(.id==\"mo2darkbot\")' /data/openclaw/.openclaw/openclaw.json"` and ensure the `subagents.allowAgents` array lists `mo2drkbot`.
- Use the gateway once your session key is ready: spawn `mo2drkbot` from `mo2darkbot` (or use `openclaw agents list` from Mo) to confirm the allowlist works; the gateway should reply `status: ok` instead of `forbidden`.
- Health endpoint proof: `curl https://openclaw-gateway.wonderfulstone-86956ff4.eastus.azurecontainerapps.io/api/health` should keep returning `200` after restart.

### Next steps
- If you plan to change agent routing again, update both the version-controlled `docker-entrypoint.sh` (so future builds are aligned) and the runtime override, then restart the container app revision.
- Keep an eye on Azure logs for `Invalid config` errors; wrong JSON patches come from gateways if you send `config.patch` without a fresh `baseHash`.
