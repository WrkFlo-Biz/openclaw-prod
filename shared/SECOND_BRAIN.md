# OpenClaw Second Brain

Last Updated: 2026-02-11
Primary Board: `/data/openclaw/.openclaw/shared/KANBAN.md`

## 1) Command Center
- Mission: run Wrk.Flo bots with reliable automation, durable memory, and zero operational guesswork.
- Operating rhythm:
  - Daily: process inbox, update Kanban, close blockers.
  - Weekly: re-prioritize with RICE, archive completed context, log key decisions.
  - Monthly: remove stale automations and simplify workflows.

## 2) Active Projects (RICE View)
| Project ID | Project | Reach | Impact | Confidence | Effort | Score | Status |
|---|---|---:|---:|---:|---:|---:|---|
| PRJ-01 | Workspace reliability (Calendar/Docs/Drive) | 10 | 10 | 8 | 3 | 266 | Active |
| PRJ-02 | Memory stability + persistence | 10 | 9 | 7 | 6 | 105 | Active |
| PRJ-03 | Agent collaboration protocols | 8 | 8 | 8 | 2 | 256 | Active |
| PRJ-04 | Billing/provider hardening (Azure-first) | 9 | 9 | 7 | 3 | 189 | Active |

## 3) Areas (Always-On Ownership)
| Area | Owner | Success Definition | Cadence |
|---|---|---|---|
| Infra & Deploy | mo2darkbot | Healthy gateway, stable revisions, clean logs | Daily |
| Content & Comms | mo2drkbot | Clear updates, useful briefs, on-time campaign tasks | Daily |
| Memory & Knowledge | mo2darkbot | Searchable durable memory, low lock/error rates | Daily |
| Collaboration | both | Reliable delegation with traceable ownership | Daily |

## 4) Resources Index
| Resource | Path | Purpose |
|---|---|---|
| Handoff log | `HANDOFF.md` | Operational timeline and incidents |
| Ops commands | `scripts/ops.sh` | Azure and deploy control |
| Self-ops commands | `scripts/self-ops.sh` | In-container recovery actions |
| Gateway bootstrap | `docker-entrypoint.sh` | Source of truth for model routing, memory store, and startup sync behavior |
| Management dashboard source | `canvas/management.html` | Browser Kanban/Second Brain UI served from canvas |
| Workspace tools (Mo) | `agents/mo2darkbot/TOOLS.md` | Runtime tool routing and commands |
| Workspace tools (Momo) | `agents/mo2drkbot/TOOLS.md` | Runtime tool routing and commands |

## 5) Decision Log
| Date (UTC) | Decision | Why | Owner | Revisit |
|---|---|---|---|---|
| 2026-02-11 | Use one shared Kanban + one shared Second Brain file | Keeps both bots aligned and removes duplicate state | both | 2026-03-01 |
| 2026-02-11 | Seed shared files only if missing/empty | Preserve in-cloud edits across restarts | mo2darkbot | 2026-03-01 |
| 2026-02-11 | Keep Google Workspace actions on `google-workspace-api` only | Prevent wrong-tool failures for Calendar/Docs/Drive | mo2darkbot | 2026-02-18 |
| 2026-02-11 | Pin memory embeddings to Azure OpenAI and disable startup warm by default | Avoid Gemini drift and reduce startup 429 rate-limit spikes | mo2darkbot | 2026-02-25 |
| 2026-02-11 | Publish management dashboard at `/__openclaw__/canvas/management.html` | Single browser control surface for Kanban + second brain status | mo2darkbot | 2026-03-01 |
| 2026-02-11 | Keep live memory SQLite on `/tmp`, snapshot to mounted cache every 120s | Prevent Azure Files SQLite locks while preserving restart durability | mo2darkbot | 2026-02-18 |
| 2026-02-11 | Hard-disable Gemini key in gateway bootstrap path | Enforce Azure-only model routing and avoid third-party billing drift | mo2darkbot | 2026-02-18 |

## 6) Agent-to-Agent Handoff Standard
- Rule 1: Every delegation must reference a card ID from Kanban.
- Rule 2: Request format:
  - `Card: OPS-###`
  - `Goal: <single outcome>`
  - `Definition of done: <verifiable result>`
  - `Deadline: <UTC date/time>`
- Rule 3: Receiver updates card status and posts result evidence in `Notes`.

## 7) Daily Capture Template
```
Date (UTC):
Wins:
Blockers:
Decisions made:
New tasks to add:
Context to archive:
```

## 8) Weekly Review Checklist
- [ ] Clear all `Inbox` cards (move to Ready/Blocked/Archive).
- [ ] Re-score active projects with RICE.
- [ ] Promote recurring blockers into explicit remediation cards.
- [ ] Archive completed context from this file into an external doc if needed.
- [ ] Confirm next week priorities in `KANBAN.md`.
