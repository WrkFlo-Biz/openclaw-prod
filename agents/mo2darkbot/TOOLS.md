# TOOLS.md
## Tool Integration Framework

## OpenClaw Production (Cloud) Tool Routing

These bots run with an Azure VM gateway. Use `mcporter` for Google Workspace in production.

### Role Boundary (CoS)

- Operate in CoS scope only: operations, execution, planning, unblocks.
- If a task is primarily campaign/content/brand execution, hand off to `mo2drkbot`.
- Shared Google account namespace:
  - Calendar summaries: `OPS: ...`
  - Docs: `OPS_...`
  - Task tags: `[OPS]`, `[EXEC]`, `[ADMIN]`

### Hard Rules (Avoid Dead Ends)

- Do not run `gog` in production. It uses a keyring and will fail non-interactively (`no TTY available`, `GOG_KEYRING_PASSWORD` prompts).
- Use `google-workspace-api.*` for Gmail + Calendar + Drive + Docs (single full server).
- Do not use legacy `google-workspace.*` commands.
- Do not use paired/local Mac node execution for Calendar/Docs in production. If you see `gateway closed (1008): pairing required`, reroute immediately to cloud tools.
- Do not stop to ask method-selection questions when a safe fallback exists.
- Fallback order for Calendar: `google-workspace-api.create_event` -> retry with schema-corrected args -> send `.ics` invite by email.
- Fallback order for Docs: `google-workspace-api.create_doc`/`modify_doc_text` -> write a Markdown fallback in shared workspace and email location.

### Canonical Commands (Copy/Paste)

```bash
# Always use the persisted prod config file:
MCPO=/data/openclaw/.openclaw/config/mcporter.json
GUSER=mo2darkbot@gmail.com
SHARED_DIR=/data/openclaw/.openclaw/shared
KANBAN="$SHARED_DIR/KANBAN.md"
SECOND_BRAIN="$SHARED_DIR/SECOND_BRAIN.md"

# Discover servers + tools (never guess tool names):
mcporter list --config "$MCPO"

# Call a tool:
mcporter call --config "$MCPO" <server>.<tool> --args '<json>' --output json
```

### Shared Kanban + Second Brain (Agent-to-Agent)

- Shared board path: `/data/openclaw/.openclaw/shared/KANBAN.md`
- Shared second brain path: `/data/openclaw/.openclaw/shared/SECOND_BRAIN.md`
- In each workspace these are linked as:
  - `SHARED_KANBAN.md`
  - `SHARED_SECOND_BRAIN.md`
- Delegation rule:
  - Every handoff must include a Kanban card ID (`OPS-###`).
  - Receiver updates the same card status and adds evidence in `Notes`.

### Which Server To Use

- Google Workspace full (Gmail/Calendar/Drive/Docs): `google-workspace-api.*`
  - Gmail examples: `search_gmail_messages`, `get_gmail_message_content`, `send_gmail_message`
  - Calendar examples: `list_calendars`, `create_event`
  - Docs/Drive examples: `create_doc`, `modify_doc_text`, `search_drive_files`

### Examples

```bash
MCPO=/data/openclaw/.openclaw/config/mcporter.json
GUSER=mo2darkbot@gmail.com

# Email: search latest inbox messages
mcporter call --config "$MCPO" google-workspace-api.search_gmail_messages \
  --args "{\"user_google_email\":\"${GUSER}\",\"query\":\"in:inbox newer_than:3d\"}" --output json

# Calendar: list calendars (many workspace-mcp tools require user_google_email)
mcporter call --config "$MCPO" google-workspace-api.list_calendars \
  --args "{\"user_google_email\":\"${GUSER}\"}" --output json

# Calendar: create an event (required args are summary/start_time/end_time)
mcporter call --config "$MCPO" google-workspace-api.create_event \
  --args "{\"user_google_email\":\"${GUSER}\",\"summary\":\"Ops Sync\",\"start_time\":\"2026-02-11T21:00:00Z\",\"end_time\":\"2026-02-11T21:30:00Z\"}" \
  --output json

# Docs: create and then edit a document
mcporter call --config "$MCPO" google-workspace-api.create_doc \
  --args "{\"user_google_email\":\"${GUSER}\",\"title\":\"Ops Notes\"}" --output json
mcporter call --config "$MCPO" google-workspace-api.modify_doc_text \
  --args "{\"user_google_email\":\"${GUSER}\",\"document_id\":\"<DOC_ID>\",\"start_index\":1,\"text\":\"Initial note.\"}" \
  --output json

# Calendar/Docs/Drive: always run `mcporter list --config "$MCPO" google-workspace-api --schema` first
# so you pass the required args for the specific tool.
```

## CATEGORY 1: COMMUNICATION

- **Email** (Send, draft, schedule, search, summarize)
- **Calendar** (Create/edit events, find availability, optimize scheduling)
- **Slack/messaging** (Monitor channels, send messages, create reminders)
- **LinkedIn** (Post drafting, connection management, message outreach)
- **SMS** (Urgent notifications, quick reminders)

## CATEGORY 2: PRODUCTIVITY

- **Task management** (Create, prioritize, track, delegate)
- **Note-taking** (Capture ideas, organize knowledge)
- **Document creation** (Memos, reports, presentations)
- **File management** (Search, organize, archive)
- **Time tracking** (Activity logging, time analysis)

## CATEGORY 3: BUSINESS INTELLIGENCE

- **CRM** (Client tracking, pipeline management)
- **Financial dashboards** (MRR, burn rate, projections)
- **Analytics** (Product usage, customer metrics)
- **Fundraising tracker** (Investor pipeline, deal room)
- **Competitive monitoring** (Track competitor moves)

## CATEGORY 4: DEVELOPMENT

- **GitHub** (Code review, issue tracking, PR management)
- **Project management** (Sprint planning, roadmap tracking)
- **Documentation** (API docs, technical specs)
- **Testing/QA** (Bug tracking, test results)
- **Deployment** (Status monitoring, rollback triggers)

## CATEGORY 5: RESEARCH & LEARNING

- **Web search** (Market research, competitive intel)
- **Academic databases** (Technical papers, research)
- **News monitoring** (Industry trends, relevant developments)
- **Social listening** (Brand mentions, customer feedback)
- **Knowledge synthesis** (Summarize, connect dots)

## CATEGORY 6: PERSONAL

- **Health tracking** (Sleep, exercise, vitals)
- **Finance** (Personal budget, expenses)
- **Learning platforms** (Course progress, reading lists)
- **Travel** (Bookings, itineraries)
- **Relationships** (Contact reminders, gift ideas)

## CATEGORY 7: AUTOMATION

- **Wrk.Flo platform access** (Dogfood own product)
- **Zapier/Make** (Workflow automation)
- **API integrations** (Custom connections)
- **Scripting** (Python/JS for custom tasks)
- **AI models** (Ollama local, Claude API, GPT-4)

## CATEGORY 8: GLOBAL SENTINEL OPS

**Purpose**: Monitor and control the Global Sentinel V5 trading intelligence system

### GitHub Repo Access
```bash
# Clone/pull latest
gh repo clone Wrk-Flo/global-sentinel /tmp/global-sentinel 2>/dev/null || git -C /tmp/global-sentinel pull

# Check CI status
gh run list --repo Wrk-Flo/global-sentinel --limit 5

# View recent commits
gh api repos/Wrk-Flo/global-sentinel/commits --jq '.[0:5][] | "\(.sha[0:8]) \(.commit.message | split("\n")[0])"'
```

### Azure VM Operations
```bash
# VM status
az vm show --name openclaw-gateway-vm --resource-group openclaw-rg -d --query "{powerState:powerState, publicIps:publicIps}" -o json

# Run command on VM (no SSH needed)
az vm run-command invoke --resource-group openclaw-rg --name openclaw-gateway-vm \
  --command-id RunShellScript --scripts "python3 /path/to/script.py"

# Check disk snapshots
az snapshot list --resource-group openclaw-rg --query "[?contains(name,'openclaw')].{name:name,created:timeCreated}" -o table
```

### Sentinel Monitoring Commands (run on VM via az vm run-command)
```bash
# System health
az vm run-command invoke -g openclaw-rg -n openclaw-gateway-vm --command-id RunShellScript \
  --scripts "cd /data/openclaw/global-sentinel && python3 scripts/healthcheck.py"

# Current mode
az vm run-command invoke -g openclaw-rg -n openclaw-gateway-vm --command-id RunShellScript \
  --scripts "cat /data/openclaw/global-sentinel/control/manual_veto.json; cat /data/openclaw/global-sentinel/control/kill_switch.json"

# Latest scorecard
az vm run-command invoke -g openclaw-rg -n openclaw-gateway-vm --command-id RunShellScript \
  --scripts "cat /data/openclaw/global-sentinel/reports/weekly/scorecard_latest.json"

# Execution reliability
az vm run-command invoke -g openclaw-rg -n openclaw-gateway-vm --command-id RunShellScript \
  --scripts "cd /data/openclaw/global-sentinel && python3 src/execution/execution_reliability_metrics.py"

# Stale intent sweep
az vm run-command invoke -g openclaw-rg -n openclaw-gateway-vm --command-id RunShellScript \
  --scripts "cd /data/openclaw/global-sentinel && python3 src/execution/stale_intent_sweeper.py --stale-after-minutes 30"
```

### Sentinel Architecture Reference
```
src/
  crisis_monitor.py          # Main 24/7 loop (NORMAL/ELEVATED/CRISIS/MANUAL_REVIEW)
  execution/
    order_intent_registry.py  # Intent tracking (draft->submitted->filled/rejected)
    shadow_order_router.py    # Routes packages to broker adapters (shadow mode)
    stale_intent_sweeper.py   # Cleans orphaned intents
    time_window_ttl_policy.py # Per-window TTL rules
    broker_state_reconciler_loop.py  # Reconciles broker state
  risk/
    square_root_impact_gate.py  # Econophysics: I(Q) = Y*sigma*sqrt(Q/V)
    local_risk_mcp.py           # Risk gate evaluation
  alpha/                        # Signal generation
  ingest/                       # Data pipelines (FRED, EIA, Finnhub)
  macro/                        # Fed/CPI/jobs/monetary policy
config/
  thresholds.yaml, assets_watchlist.yaml, execution_reliability.yaml
control/
  manual_veto.json, kill_switch.json
```

### Subagent Spawning for Sentinel Tasks
When Moses asks about sentinel status or trading operations, spawn focused subagents:
- `sentinel-health`: Run healthcheck, report mode, freshness, risk gate status
- `sentinel-exec`: Check execution metrics, bound attempts, rejections, fills
- `sentinel-replay`: Run smoke tests for a specific scenario
- `sentinel-sweep`: Run stale intent sweep, report orphaned orders
- `sentinel-infra`: Check VM health, disk space, snapshot status, ACR images

## Tool Usage Principles

1. **Minimize context-switching**: Aggregate information before presenting
2. **Respect API limits**: Batch requests, cache when possible
3. **Fail gracefully**: Always have manual fallback
4. **Log all actions**: Audit trail for accountability
5. **Preference hierarchy**: Local > API > Manual
6. **No option trees on routine ops**: Execute the safest working fallback and report outcome.
