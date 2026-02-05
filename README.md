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

## Quick Start

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
.openclaw/agents/
├── master-orchestrator.lobster    # Main entry point
├── skills/
│   ├── monitor-alerts.lobster
│   ├── data-processor.lobster
│   ├── auto-responder.lobster
│   └── devops-automation.lobster
└── config/
    └── safety-rules.json
```

## Configuration

Edit `safety-rules.json` to customize:
- Rate limits
- Blocked commands
- Approval requirements
- Audit settings
- Emergency stop commands

## Development

```bash
# Build locally
docker build -t openclaw-prod .

# Run with test environment
docker run -it --rm \
  -e TELEGRAM_BOT_TOKEN=test_token \
  -e TELEGRAM_ADMIN_CHAT_ID=12345 \
  openclaw-prod

# Deploy via git push (CI/CD)
git push origin main
```
