# TOOLS.md
## Tool Integration Framework

## OpenClaw Production (Cloud) Tool Routing

These bots run in Azure Container Apps. Use `mcporter` for Google Workspace in production.

### Hard Rules (Avoid Dead Ends)

- Do not run `gog` in production. It uses a keyring and will fail non-interactively (`no TTY available`, `GOG_KEYRING_PASSWORD` prompts).
- Do not call Calendar/Docs tools on `google-workspace.*` (that server is Gmail IMAP only). Use `google-workspace-api.*`.

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

### CATEGORY 1: WRITING & EDITING

- **Document creation** (Google Docs, Notion, Obsidian integration)
- **Grammar/style checking** (Grammarly API, Hemingway integration)
- **Version control** (Track draft iterations, show diff)
- **Plagiarism checking** (Ensure originality)
- **Reading level analysis** (Flesch-Kincaid, target audience match)
- **Word count tracking** (Daily writing goals, book progress)

### CATEGORY 2: RESEARCH & INTELLIGENCE

- **Web scraping** (Competitor content analysis, trend monitoring)
- **News aggregation** (Google Alerts, industry publications)
- **Academic databases** (Research citations for thought pieces)
- **Quote databases** (Famous speeches, refugee narratives)
- **Image search** (Visual inspiration, stock photo sourcing)
- **Transcript generation** (Moses's speaking events, interviews)

### CATEGORY 3: SOCIAL MEDIA MANAGEMENT

- **LinkedIn** (Post scheduling, engagement tracking, comment monitoring)
- **Twitter/X** (Thread creation, reply suggestions, trend-jacking)
- **YouTube** (Video metadata optimization, comment analysis)
- **Analytics** (Cross-platform performance tracking)
- **Hashtag research** (Trend identification, reach optimization)
- **Influencer monitoring** (Track mentions, amplification opportunities)

### CATEGORY 4: EMAIL MARKETING

- **Newsletter platforms** (Substack, Mailchimp, Beehiiv integration)
- **List segmentation** (Audience-specific messaging)
- **A/B testing** (Subject lines, send times)
- **Performance analytics** (Open rates, click-through, conversions)
- **Template library** (Reusable frameworks)
- **Drip campaign management** (Automated sequences)

### CATEGORY 5: VISUAL CONTENT

- **Graphic design** (Canva API for social graphics)
- **Video editing** (Script-to-storyboard translation)
- **Screenshot/screen recording** (Product demos, tutorials)
- **Meme generation** (Rage-bait campaign assets)
- **Presentation creation** (Speaking engagement slides)
- **Data visualization** (Charts, infographics for blog posts)

### CATEGORY 6: SEO & DISTRIBUTION

- **Keyword research** (Google Trends, Ahrefs integration)
- **SEO optimization** (Title tags, meta descriptions)
- **Backlink monitoring** (Authority building)
- **Content syndication** (Medium, LinkedIn Articles republishing)
- **Podcast placement** (Guest appearance pitching)
- **Media database** (Journalist contact management)

### CATEGORY 7: ANALYTICS & INSIGHTS

- **Content performance dashboards** (What's working, what's not)
- **Audience growth tracking** (Follower/subscriber trends)
- **Engagement heatmaps** (Where readers drop off)
- **Conversion attribution** (Content to Wrk.Flo leads)
- **Competitor benchmarking** (Share of voice analysis)
- **Sentiment analysis** (Brand perception monitoring)

### CATEGORY 8: COLLABORATION

- **Feedback collection** (Moses's edits, stakeholder input)
- **Approval workflows** (Legal review for sensitive topics)
- **Asset libraries** (Brand guidelines, logo files, imagery)
- **Commenting systems** (Track revision suggestions)
- **File sharing** (Draft distribution to reviewers)

### CATEGORY 9: BOOK DEVELOPMENT

- **Manuscript management** (Scrivener integration, chapter organization)
- **Research database** (Evernote, Notion for sources)
- **Writing sprint timers** (Pomodoro, accountability tracking)
- **Publisher research** (Agent/publisher fit analysis)
- **Proposal generation** (Query letters, sample chapters)
- **Citation management** (Zotero for footnotes/bibliography)

### CATEGORY 10: AI AUGMENTATION

- **Ollama models** (Local LLMs for draft generation)
- **Claude API** (Long-form editing, structural analysis)
- **Image generation** (Midjourney/DALL-E for conceptual art)
- **Voice synthesis** (Script reading for audio testing)
- **Transcription** (Whisper for voice-to-text idea capture)

## Tool Usage Principles

1. **Human voice primacy**: Tools assist, never replace Moses's authentic voice
2. **Draft fast, edit slow**: Use AI for volume, Moses's eye for quality
3. **Multi-modal creation**: Support Moses's hyperphantasia with visual workflows
4. **Archive everything**: Even rejected ideas have future value
5. **Attribution clarity**: Always know what's Moses vs. what's AI-assisted
