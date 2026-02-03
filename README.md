# OpenClaw Production Deployment

Production deployment for OpenClaw on Azure Container Apps.

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

### Deploy to Azure

1. **Push to ACR:**
```bash
az acr login --name openclawacr
docker tag openclaw-prod openclawacr.azurecr.io/openclaw:latest
docker push openclawacr.azurecr.io/openclaw:latest
```

2. **Deploy Container App:**
```bash
az containerapp update \
  --name openclaw-app \
  --resource-group openclaw-rg \
  --image openclawacr.azurecr.io/openclaw:latest
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| AZURE_OPENAI_API_KEY | Yes | Azure OpenAI API key |
| AZURE_OPENAI_ENDPOINT | Yes | Azure OpenAI endpoint URL |
| AZURE_OPENAI_DEPLOYMENT | Yes | Model deployment name (e.g., gpt-4o) |
| TELEGRAM_BOT_TOKEN_DEFAULT | Yes | Primary Telegram bot token |
| TELEGRAM_BOT_TOKEN_MO2DRKBOT | No | Secondary Telegram bot token |

## Architecture

- **Runtime:** Azure Container Apps (serverless containers)
- **Registry:** Azure Container Registry
- **AI Backend:** Azure OpenAI Service
- **Channels:** Telegram (polling mode, no inbound webhooks)

## Logs

View logs in Azure Portal:
1. Go to Container Apps > openclaw-app
2. Click "Log stream" for real-time logs
3. Or use "Logs" for querying with KQL

## Redeploy (< 2 minutes)

```bash
git push origin main  # Triggers GitHub Actions CI/CD
```

Or manual:
```bash
az containerapp update -n openclaw-app -g openclaw-rg --image openclawacr.azurecr.io/openclaw:$(date +%s)
```
