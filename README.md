# OpenClaw Production Deployment

Production deployment for OpenClaw on Azure Container Instances (ACI).

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

### Deploy to Azure (ACI)

1. **Push to ACR:**
```bash
az acr login --name openclawacr
docker tag openclaw-prod openclawacr.azurecr.io/openclaw:latest
docker push openclawacr.azurecr.io/openclaw:latest
```

2. **Deploy Container Group:**
```bash
az container delete -g openclaw-rg -n openclaw-aci --yes
az container create \
  --name openclaw-aci \
  --resource-group openclaw-rg \
  --image openclawacr.azurecr.io/openclaw:latest \
  --os-type Linux \
  --restart-policy Always \
  --cpu 1 --memory 2 \
  --registry-username <acr-username> \
  --registry-password <acr-password> \
  --environment-variables \
    AZURE_OPENAI_ENDPOINT=<endpoint> \
    AZURE_OPENAI_DEPLOYMENT=gpt-4o \
    AZURE_OPENAI_API_VERSION=2024-05-01-preview \
  --secure-environment-variables \
    AZURE_OPENAI_API_KEY=<key> \
    TELEGRAM_BOT_TOKEN_DEFAULT=<token> \
    TELEGRAM_BOT_TOKEN_MO2DRKBOT=<token> \
    OPENCLAW_GATEWAY_TOKEN=<token> \
  --azure-file-volume-account-name <storage-account> \
  --azure-file-volume-account-key <storage-key> \
  --azure-file-volume-share-name <file-share> \
  --azure-file-volume-mount-path /data/openclaw
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| AZURE_OPENAI_API_KEY | Yes | Azure OpenAI API key |
| AZURE_OPENAI_ENDPOINT | Yes | Azure OpenAI endpoint URL |
| AZURE_OPENAI_DEPLOYMENT | Yes | Model deployment name (e.g., gpt-4o) |
| TELEGRAM_BOT_TOKEN_DEFAULT | Yes | Primary Telegram bot token |
| TELEGRAM_BOT_TOKEN_MO2DRKBOT | No | Secondary Telegram bot token |
| OPENCLAW_GATEWAY_TOKEN | Yes | Gateway auth token |

## Architecture

- **Runtime:** Azure Container Instances (serverless containers)
- **Registry:** Azure Container Registry
- **AI Backend:** Azure OpenAI Service
- **Channels:** Telegram (polling mode, no inbound webhooks)

## Logs

View logs in Azure Portal:
1. Go to Container Instances > openclaw-aci
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
