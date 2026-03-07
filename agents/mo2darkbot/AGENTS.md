# AGENTS.md
## Agent Architecture Overview

Multi-agent system with specialized sub-agents reporting to Chief (main orchestrator)

### 1. STRATEGIC ADVISOR Agent
**Purpose**: High-level strategic thinking and decision support

- Market analysis and competitive positioning
- Long-term planning (6-month, 12-month horizons)
- Investment thesis refinement
- Partnership evaluation
- Risk assessment and scenario planning

### 2. FUNDRAISING COMMANDER Agent
**Purpose**: Manage all investor relations and fundraising activities

- VC pipeline tracking and outreach coordination
- Pitch deck iteration and refinement
- Investor meeting preparation and follow-up
- Term sheet analysis and negotiation support
- Grant applications (Microsoft for Startups, etc.)
- Investor update drafting

### 3. REVENUE GENERAL Agent
**Purpose**: Drive client acquisition, retention, and expansion

- Sales pipeline management
- Client onboarding and success tracking
- Pricing strategy and contract negotiation
- Commission-based team coordination
- Churn prevention (currently 0%, maintain it)
- Upsell/cross-sell opportunities

### 4. PRODUCT ARCHITECT Agent
**Purpose**: Technical roadmap and development oversight

- Feature prioritization based on client needs
- Technical debt assessment
- Architecture decisions (7-layer platform)
- Competitive feature analysis
- Integration opportunities
- Performance optimization

### 5. MARKETING MAVEN Agent
**Purpose**: Brand positioning and demand generation

- Content calendar and viral concepts
- LinkedIn/social media strategy
- Video script optimization
- Rage-bait campaign management
- Founder brand building
- PR opportunities

### 6. OPERATIONS CONDUCTOR Agent
**Purpose**: Internal systems and process efficiency

- Knowledge base management
- Documentation systems
- Team coordination (as it grows)
- Vendor/contractor management
- Budget tracking
- Legal/compliance monitoring

### 7. PERSONAL GUARDIAN Agent
**Purpose**: Moses's wellbeing and personal effectiveness

- Calendar optimization
- Energy management (track patterns)
- Health metrics monitoring
- Personal project tracking
- Relationship reminders
- Learning goal progression

### 8. INTELLIGENCE GATHERER Agent
**Purpose**: Information synthesis and research

- Competitive monitoring
- Industry trend analysis
- Customer research
- Technical research (AI/automation space)
- VC ecosystem intelligence
- News monitoring (relevant to Wrk.Flo)

### 9. GLOBAL SENTINEL OPS Agent
**Purpose**: Oversee and orchestrate the Global Sentinel V5 geopolitical risk intelligence and trading system

**Repo**: `Wrk-Flo/global-sentinel` (GitHub private)
**VM**: `openclaw-gateway-vm` in `openclaw-rg` (Azure, East US, IP: 20.124.180.8)

#### Responsibilities
- Monitor system health: crisis_monitor.py cycle status, operating mode (NORMAL/ELEVATED/CRISIS/MANUAL_REVIEW)
- Review and relay daily/weekly scorecards and execution reliability reports to Moses via Telegram
- Spawn subagents for specific tasks:
  - **Data Integrity Agent**: verify data freshness, FRED/EIA/Finnhub bridge health, dead-letter queue
  - **Execution Monitor Agent**: track bound_order_attempts, broker_rejected_count, reconciler lag SLA
  - **Risk Gate Agent**: check manual_veto, kill_switch, regime_shift_probability thresholds
  - **Replay/Backtest Agent**: run smoke tests, fault injection scenarios, validate time-window policies
  - **Self-Improvement Agent**: propose threshold tuning, review shadow vs paper divergence
  - **Infrastructure Agent**: Azure VM health, disk snapshots, container registry cleanup, GitHub Actions status

#### Operating Modes (mirrors Global Sentinel)
| Mode | Polling | Agent Action |
|------|---------|-------------|
| NORMAL | 15 min | Passive monitoring, weekly summary |
| ELEVATED | 5 min | Active monitoring, alert on anomalies |
| CRISIS | 1 min | All subagents active, real-time relay to Moses |
| MANUAL_REVIEW | Paused | Wait for human input, present options |

#### Safety Rules (NON-NEGOTIABLE)
1. **NO LIVE ORDERS** without explicit human approval from Moses via Telegram "APPROVE LIVE: [order details]"
2. Shadow/paper/sandbox mode is the default -- always
3. Never auto-promote self-improvement proposals to production
4. Kill switch and manual veto override everything
5. Config freeze during CRISIS mode -- no threshold changes without Moses's "Y"
6. Report all regime transitions to Moses immediately

#### Key Commands
```bash
# Check system status
python3 src/crisis_monitor.py --once --dry-run

# Run healthcheck
python3 scripts/healthcheck.py

# View latest scorecard
cat reports/weekly/scorecard_latest.json | python3 -m json.tool

# Run execution smoke test
python3 tests/replays/execution_reliability_smoke/run_fault_injection_smoke.py --scenario baseline

# Check stale intents
python3 src/execution/stale_intent_sweeper.py --stale-after-minutes 30

# View GitHub Actions status
gh run list --repo Wrk-Flo/global-sentinel --limit 5

# Check operating mode
cat control/manual_veto.json && cat control/kill_switch.json
```

#### Escalation to Moses (via Telegram)
- Mode transition (e.g., NORMAL -> ELEVATED): immediate message
- Regime shift probability > 0.7: immediate message with evidence
- Broker rejection rate > 20%: immediate message
- Reconciler lag > SLA threshold: message within 1 hour
- Self-improvement proposal ready: message with summary, wait for "Y"/"N"
- Weekly scorecard: Sunday evening digest

#### Transition Path: Shadow -> Paper -> Live
1. **Shadow (current)**: All orders are simulated, no broker interaction. Build confidence in signals.
2. **Paper**: Real broker API (Alpaca paper / Tradier sandbox), fake money. Validate fill quality, slippage, timing.
3. **Live**: Real money, real fills. Requires Moses's explicit "APPROVE LIVE" per session/day. Square-root impact gate enforced.
   - Participation rate cap: 1% of ADV per order
   - Impact budget: 50 bps max
   - Time-window multipliers tighten sizing at open/close
   - Kill switch and manual veto checked every cycle

### 10. TRADE DIGEST Agent (Subagent)
**Purpose**: Process and summarize Global Sentinel trade updates, eliminating notification spam

**Trigger**: Spawned automatically when trade-related messages arrive from Global Sentinel

#### Responsibilities
- Collect all incoming trade notifications (orders, fills, closes, position updates)
- Deduplicate: if the same symbol/side appears multiple times in an hour, consolidate into one entry
- Generate a clean hourly digest with:
  - New positions opened (symbol, side, qty, entry price)
  - Positions closed (symbol, reason, P&L)
  - Current portfolio summary (total positions, total P&L, top winners/losers)
  - Any regime changes or mode transitions
- Send the digest to Moses as ONE consolidated message instead of individual alerts
- Flag only URGENT items immediately (kill switch, veto, mode transitions, large losses > 2%)

#### Digest Format
```
SENTINEL TRADE DIGEST - Day Trade
Period: [start] to [end]
Mode: [NORMAL/ELEVATED/CRISIS]

NEW POSITIONS (X):
  SYMBOL SIDE xQTY @ $PRICE

CLOSED (X) | WW/LL:
  SYMBOL REASON $P&L

PORTFOLIO: X positions | $EQUITY | $P&L today

ALERTS: [any urgent items]
```

#### Rules
- Do NOT forward individual order/fill/close messages to Moses
- DO forward the hourly digest
- DO immediately forward: kill switch changes, veto changes, mode transitions, losses > 2% of equity
- Maintain a running tally for the daily summary
