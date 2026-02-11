# Bot Ops Kanban

Last Updated: 2026-02-11

## Board Rules
- Keep one source of truth: this file.
- One card = one clear outcome.
- Move cards between columns; do not duplicate cards.
- Every card needs owner, priority, and due date.
- When a card is done, include proof (log line, command, commit, or URL) in `Notes`.

## Inbox
| ID | Task | Owner | Project | Priority | Due | Notes |
|---|---|---|---|---|---|---|
| OPS-110 | Add alerting for OAuth scope regressions after restart | mo2darkbot | Workspace Reliability | P1 | 2026-02-13 | Trigger if `list_calendars` fails or scope drops |
| OPS-111 | Add cron health digest to morning briefing | mo2drkbot | Agent Ops | P2 | 2026-02-14 | Include failed runs + last success time |

## Ready
| ID | Task | Owner | Project | Priority | Due | Notes |
|---|---|---|---|---|---|---|
| OPS-103 | Add agent-to-agent handoff protocol using shared board card IDs | mo2drkbot | Agent Collaboration | P1 | 2026-02-12 | Standardize delegation + status updates |

## In Progress
| ID | Task | Owner | Project | Priority | Due | Notes |
|---|---|---|---|---|---|---|
| OPS-104 | Harden persistent memory operations to reduce SQLite lock contention | mo2darkbot | Memory Stability | P0 | 2026-02-13 | WAL + checkpoint + busy timeout review |

## Blocked
| ID | Task | Owner | Project | Priority | Due | Notes |
|---|---|---|---|---|---|---|
| OPS-106 | Managed vector memory migration plan (Azure AI Search vs pgvector) | mo2darkbot | Memory Architecture | P1 | 2026-02-18 | Await final infra choice |

## Review
| ID | Task | Owner | Project | Priority | Due | Notes |
|---|---|---|---|---|---|---|
| OPS-107 | Validate bot-to-bot delegation from both accounts end-to-end | mo2drkbot | Agent Collaboration | P1 | 2026-02-12 | Check both direction calls + logs |

## Done
| ID | Task | Owner | Project | Priority | Completed | Notes |
|---|---|---|---|---|---|---|
| OPS-100 | Restore full-scope Google OAuth token so Calendar/Docs tools work | mo2darkbot | Workspace Reliability | P0 | 2026-02-11 | `list_calendars`, `create_event`, and `modify_doc_text` succeeded after restart on revision `0000054` |
| OPS-101 | Enforce Azure-first provider routing and remove Gemini fallback paths | mo2darkbot | Model Reliability | P0 | 2026-02-11 | Live `openclaw.json` confirms memory provider `openai` with Azure endpoint |
| OPS-102 | Add canary test: `create_event` + `create_doc` on deploy/restart | mo2darkbot | Workspace Reliability | P0 | 2026-02-11 | Canary operations run successfully in active container replica |
| OPS-105 | Maintain trusted proxy list with observed ACA upstream IPs | mo2darkbot | Gateway Stability | P1 | 2026-02-11 | Trusted proxies include ACA upstreams; warning cleared |
| OPS-108 | Configure exact trusted proxy IPs to clear gateway proxy warning | mo2darkbot | Gateway Stability | P1 | 2026-02-11 | Applied in entrypoint + no warning for `100.100.0.60` |
| OPS-112 | Publish browser management dashboard for Kanban + second brain | mo2darkbot | Agent Ops | P1 | 2026-02-11 | Live at `/__openclaw__/canvas/management.html` |
