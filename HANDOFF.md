# OpenClaw Production — Handoff Log (2026-02-09)

## Repository & Infrastructure

- **Repo**: `Wrk-Flo/openclaw-prod` (GitHub)
- **Platform**: Azure Container Apps
- **Resource group**: `openclaw-rg`, container app: `openclaw-gateway`
- **Registry**: `wrkfloopenclawacr.azurecr.io/openclaw`
- **Container user**: `openclaw` (HOME=/data/openclaw), NOT root
- **Persistent storage**: Azure Files mounted at `/data/openclaw/.openclaw`
- **Deploy**: Push to `main` → GitHub Actions → Docker build → Azure (~15 min)
- **Latest commit**: `677fe60` (fix: force reset memory index for Gemini embeddings)

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
| `mcporter-config.json` | gmail-mcp-imap template (placeholder `${GMAIL_APP_PASSWORD}`) |
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

**Status**: **FIXED (2026-02-09 20:44 UTC)** — issue was the wrong Gmail account.

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

**To update password**:
```bash
az containerapp secret set -g openclaw-rg -n openclaw-gateway --secrets gmail-app-password='NEW_PASSWORD'
# Restart:
az containerapp revision restart -g openclaw-rg -n openclaw-gateway --revision $(az containerapp show -g openclaw-rg -n openclaw-gateway --query properties.latestRevisionName -o tsv)
```

**Alternatives already installed in container**:
- `himalaya` — CLI email client, config at `$HOME/.config/himalaya/config.toml`
- `gog` (gogcli) — Google API CLI, could use service account

## TASK 3: Verify Agent Identities

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
| Config lost on restart | All changes must go through docker-entrypoint.sh |
| LLM FailoverError | Restart clears stuck sessions |
