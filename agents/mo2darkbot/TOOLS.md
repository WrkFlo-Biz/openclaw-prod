# TOOLS.md
## Tool Integration Framework

## OpenClaw Production (Cloud) Tool Routing

These bots run in Azure Container Apps. Use `mcporter` for Google Workspace in production.

### Hard Rules (Avoid Dead Ends)

- Do not run `gog` in production. It uses a keyring and will fail non-interactively (`no TTY available`, `GOG_KEYRING_PASSWORD` prompts).
- Do not call Calendar/Docs tools on `google-workspace.*` (that server is Gmail IMAP only). Use `google-workspace-api.*`.
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

- Email (IMAP, app password, stable): `google-workspace.*`
  - Example tools: `get_primary_emails`, `get_updates_emails`, `get_email_content`, `send_email`
- Google Workspace APIs (Calendar/Drive/Docs): `google-workspace-api.*`
  - Example tools: `create_event` (Calendar), plus Drive/Docs tools exposed by `workspace-mcp`

### Examples

```bash
MCPO=/data/openclaw/.openclaw/config/mcporter.json
GUSER=mo2darkbot@gmail.com

# Email: get latest messages
mcporter call --config "$MCPO" google-workspace.get_primary_emails \
  --args '{"limit":25}' --output json

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

### CATEGORY 1: COMMUNICATION

- **Email** (Send, draft, schedule, search, summarize)
- **Calendar** (Create/edit events, find availability, optimize scheduling)
- **Slack/messaging** (Monitor channels, send messages, create reminders)
- **LinkedIn** (Post drafting, connection management, message outreach)
- **SMS** (Urgent notifications, quick reminders)

### CATEGORY 2: PRODUCTIVITY

- **Task management** (Create, prioritize, track, delegate)
- **Note-taking** (Capture ideas, organize knowledge)
- **Document creation** (Memos, reports, presentations)
- **File management** (Search, organize, archive)
- **Time tracking** (Activity logging, time analysis)

### CATEGORY 3: BUSINESS INTELLIGENCE

- **CRM** (Client tracking, pipeline management)
- **Financial dashboards** (MRR, burn rate, projections)
- **Analytics** (Product usage, customer metrics)
- **Fundraising tracker** (Investor pipeline, deal room)
- **Competitive monitoring** (Track competitor moves)

### CATEGORY 4: DEVELOPMENT

- **GitHub** (Code review, issue tracking, PR management)
- **Project management** (Sprint planning, roadmap tracking)
- **Documentation** (API docs, technical specs)
- **Testing/QA** (Bug tracking, test results)
- **Deployment** (Status monitoring, rollback triggers)

### CATEGORY 5: RESEARCH & LEARNING

- **Web search** (Market research, competitive intel)
- **Academic databases** (Technical papers, research)
- **News monitoring** (Industry trends, relevant developments)
- **Social listening** (Brand mentions, customer feedback)
- **Knowledge synthesis** (Summarize, connect dots)

### CATEGORY 6: PERSONAL

- **Health tracking** (Sleep, exercise, vitals)
- **Finance** (Personal budget, expenses)
- **Learning platforms** (Course progress, reading lists)
- **Travel** (Bookings, itineraries)
- **Relationships** (Contact reminders, gift ideas)

### CATEGORY 7: AUTOMATION

- **Wrk.Flo platform access** (Dogfood own product)
- **Zapier/Make** (Workflow automation)
- **API integrations** (Custom connections)
- **Scripting** (Python/JS for custom tasks)
- **AI models** (Ollama local, Claude API, GPT-4)

## Tool Usage Principles

1. **Minimize context-switching**: Aggregate information before presenting
2. **Respect API limits**: Batch requests, cache when possible
3. **Fail gracefully**: Always have manual fallback
4. **Log all actions**: Audit trail for accountability
5. **Preference hierarchy**: Local > API > Manual
6. **No option trees on routine ops**: Execute the safest working fallback and report outcome.
