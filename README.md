# OpenClaw Production Deployment

Production deployment for OpenClaw on Azure Container Apps (ACA).

## Quick Start

### Local Build & Test
```bash
docker build -t openclaw-prod .
docker run -d --name openclaw \
  -e AZURE_OPENAI_API_KEY=your_key \
  -e AZURE_OPENAI_ENDPOINT=your_endpoint \
  -e AZURE_OPENAI_DEPLOYMENT=gpt-4o \
  -e TELEGRAM_BOT_TOKEN_DEFAULT=token1 \
  -e TELEGRAM_BOT_TOKEN_MO2DRKBOT=token2 \
  -v openclaw-data:/data/openclaw/.openclaw \
  openclaw-prod
```

### Deploy to Azure (Container Apps, Recommended)

1. **Push to ACR:**
```bash
az acr login --name openclawacr
docker tag openclaw-prod openclawacr.azurecr.io/openclaw:latest
docker push openclawacr.azurecr.io/openclaw:latest
```

2. **Deploy Container App:**
```bash
az containerapp create \
  --name openclaw-gateway \
  --resource-group openclaw-rg \
  --environment openclaw-env \
  --image openclawacr.azurecr.io/openclaw:latest \
  --ingress external --target-port 18789 --transport auto \
  --min-replicas 1 --max-replicas 1 \
  --registry-server openclawacr.azurecr.io \
  --registry-username <acr-username> --registry-password <acr-password> \
  --environment-variables \
    AZURE_OPENAI_ENDPOINT=<endpoint> \
    AZURE_OPENAI_DEPLOYMENT=gpt-4o \
    AZURE_OPENAI_API_VERSION=2024-05-01-preview \
    GITHUB_REPO=Wrk-Flo/openclaw-prod \
    OPENCLAW_GATEWAY_BIND=lan \
    OPENCLAW_GATEWAY_PORT=18789 \
  --secure-environment-variables \
    AZURE_OPENAI_API_KEY=<key> \
    TELEGRAM_BOT_TOKEN_DEFAULT=<token> \
    TELEGRAM_BOT_TOKEN_MO2DRKBOT=<token> \
    GH_TOKEN=<github-token> \
    OPENAI_API_KEY=<openai-token-for-codex> \
    OPENCLAW_GATEWAY_TOKEN=<token> \
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| AZURE_OPENAI_API_KEY | Yes | Azure OpenAI API key |
| AZURE_OPENAI_ENDPOINT | Yes | Azure OpenAI endpoint URL |
| AZURE_OPENAI_DEPLOYMENT | Yes | Model deployment name (e.g., gpt-4o) |
| AZURE_OPENAI_API_VERSION | No | Azure OpenAI API version (defaults to 2024-05-01-preview) |
| TELEGRAM_BOT_TOKEN_DEFAULT | Yes | Primary Telegram bot token |
| TELEGRAM_BOT_TOKEN_MO2DRKBOT | No | Secondary Telegram bot token |
| GITHUB_REPO | No | GitHub repo slug used by skills (defaults to Wrk-Flo/openclaw-prod) |
| GH_TOKEN | No | GitHub token used by `gh` inside runtime |
| OPENAI_API_KEY | No | Enables `codex` CLI usage in `coding-agent` skill |
| OPENCLAW_GATEWAY_TOKEN | Yes | Gateway auth token |

## Architecture

- **Runtime:** Azure Container Apps (HTTPS + WebSockets)
- **Registry:** Azure Container Registry
- **AI Backend:** Azure OpenAI Service
- **Channels:** Telegram (polling mode, no inbound webhooks)
- **Gateway:** WebSocket gateway on port `18789` (token-auth protected)

## WebSocket Gateway Access

The Control UI runs in a browser and requires a secure context (HTTPS). Azure Container Apps provides an HTTPS endpoint by default, so the UI can connect using `wss://`.

Get the current endpoint:

```bash
az containerapp show \
  --resource-group openclaw-rg \
  --name openclaw-gateway \
  --query "properties.configuration.ingress.fqdn" -o tsv
```

Open `https://<that-fqdn>/` and include `OPENCLAW_GATEWAY_TOKEN` when prompted for auth.

## Installed Skill Dependencies

The production image includes the binaries required for core cloud automation skills:

- `gh` for `github`
- `codex` for `coding-agent`
- `clawhub`
- `mcporter`
- `jq` + `rg` for `session-logs`
- `summarize`
- `ffmpeg` for media workflows

Verify from a running container:

```bash
openclaw skills check
openclaw skills info github
openclaw skills info coding-agent
```

## Logs

View logs in Azure Portal:
1. Go to Container Apps > openclaw-gateway
2. Click "Logs" for real-time logs

## Redeploy (< 2 minutes)

```bash
git push origin main  # Triggers GitHub Actions CI/CD
```

Or manual:
```bash
az container delete -g openclaw-rg -n openclaw-aci --yes
az container create -g openclaw-rg -n openclaw-aci --image openclawacr.azurecr.io/openclaw:$(date +%s) \
  --os-type Linux --restart-policy Always --cpu 1 --memory 2
```
