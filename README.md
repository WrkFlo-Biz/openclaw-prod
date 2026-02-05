# OpenClaw Autonomous Agent Skills

Multi-capability skill suite for OpenClaw bots with safety gates for 24/7 autonomous operation.

## Skills

| Skill | Purpose | Approval Required |
|-------|---------|-------------------|
| `monitor-alerts` | Watch GitHub PRs/issues, Telegram channels, API health | No (read-only) |
| `data-processor` | Fetch/transform/store data from APIs | No (read-only) |
| `auto-responder` | Reply to messages, send notifications | Yes (external sends) |
| `devops-automation` | Deploy containers, run scripts, backups | Yes (all actions) |
| `master-orchestrator` | Command routing, audit logging, emergency stop | Conditional |

## Deployment Options

### Option 1: Azure (Recommended for Production)

Fully serverless deployment using Azure Logic Apps, Functions, and Automation.

```bash
# Prerequisites
az login
az account set --subscription "Your Subscription"

# Set required environment variables
export TELEGRAM_BOT_TOKEN="your-bot-token"
export TELEGRAM_ADMIN_CHAT_ID="your-chat-id"

# Optional
export GITHUB_TOKEN="your-github-token"
export GITHUB_REPO="owner/repo"

# Deploy
cd azure/scripts
./deploy.sh
```

**Azure Services Used:**
| Component | Azure Service | Purpose |
|-----------|--------------|---------|
| Orchestration | Logic Apps Standard | Workflow engine, Telegram connector |
| Data Processing | Azure Functions | Python data pipelines |
| DevOps Tasks | Azure Automation | PowerShell runbooks |
| Storage | Blob Storage + Table Storage | State, audit logs |
| Secrets | Key Vault | Secure token storage |
| Monitoring | Application Insights | Full audit trail |

**Estimated Cost:** ~$200-500/month (consumption-based)

### Option 2: Docker (Local/Self-Hosted)

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your configuration
# Required: TELEGRAM_BOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID

# Build and run
docker-compose up -d

# View logs
docker-compose logs -f
```

## Safety Features

1. **Approval gates** on all destructive actions
2. **Command blocklist** (no `rm -rf`, no spending without approval)
3. **Rate limiting** (max 10 actions/minute)
4. **Audit logging** of all actions
5. **Emergency stop** via `/emergency-stop` command

## Commands

### System
- `/help` - Show available commands
- `/status` - System status
- `/skills` - List available skills
- `/pending` - Show pending approvals
- `/logs` - Recent audit logs

### Monitoring (No approval)
- `/monitor [source]` - Check monitors
- `/check [target]` - Health check

### Data (No approval)
- `/process [pipeline]` - Run data pipeline
- `/fetch [source]` - Fetch data

### Responses (Conditional approval)
- `/notify [message]` - Send notification
- `/summary` - Generate summary

### DevOps (Requires approval)
- `/deploy [target]` - Deploy container
- `/backup [resource]` - Create backup
- `/run-script [name]` - Execute script
- `/scale [service] [n]` - Scale service

### Admin
- `/approve [id]` - Approve pending action
- `/deny [id]` - Deny pending action
- `/emergency-stop` - Halt all operations

## File Structure

```
openclaw-prod/
├── .openclaw/agents/           # Lobster workflow definitions
│   ├── master-orchestrator.lobster
│   ├── skills/
│   │   ├── monitor-alerts.lobster
│   │   ├── data-processor.lobster
│   │   ├── auto-responder.lobster
│   │   └── devops-automation.lobster
│   └── config/
│       └── safety-rules.json
├── azure/                      # Azure deployment
│   ├── bicep/
│   │   └── main.bicep         # Infrastructure as Code
│   ├── logic-apps/            # Logic Apps workflows
│   │   ├── master-orchestrator/
│   │   ├── monitor-alerts/
│   │   └── devops-automation/
│   ├── functions/             # Azure Functions (Python)
│   │   └── data_processor/
│   ├── automation/            # Azure Automation runbooks
│   │   ├── Deploy-Container.ps1
│   │   └── Create-Backup.ps1
│   └── scripts/
│       └── deploy.sh          # Deployment script
├── Dockerfile                  # Docker deployment
├── docker-compose.yml
└── docker-entrypoint.sh
```

## Azure Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Telegram Bot                             │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Logic Apps Standard                           │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ Master          │  │ Monitor         │  │ DevOps          │  │
│  │ Orchestrator    │  │ Alerts          │  │ Automation      │  │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  │
└───────────┼─────────────────────┼─────────────────────┼─────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐
│ Azure Functions   │  │ Azure Tables      │  │ Azure Automation  │
│ (Data Processing) │  │ (State/Approvals) │  │ (Runbooks)        │
└───────────────────┘  └───────────────────┘  └───────────────────┘
            │                     │                     │
            └─────────────────────┼─────────────────────┘
                                  ▼
                    ┌─────────────────────────┐
                    │   Blob Storage          │
                    │   (Audit Logs/Backups)  │
                    └─────────────────────────┘
```

## Configuration

Edit `safety-rules.json` to customize:
- Rate limits
- Blocked commands
- Approval requirements
- Audit settings
- Emergency stop commands

## Monitoring & Audit

All actions are logged to:
- **Azure:** Application Insights + Blob Storage
- **Docker:** `/data/openclaw/logs/audit.log`

View audit logs:
```bash
# Azure
az monitor app-insights query --app <app-insights-name> \
  --analytics-query "traces | where message contains 'audit'"

# Docker
docker exec openclaw-prod tail -f /data/openclaw/logs/audit.log
```
