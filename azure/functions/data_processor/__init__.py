"""
OpenClaw Data Processor Azure Function
Fetches, transforms, and stores data from various sources.
"""

import azure.functions as func
import logging
import json
import os
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
import aiohttp
import asyncio

# Initialize logging
logger = logging.getLogger(__name__)

# Configuration
STORAGE_CONNECTION = os.environ.get('AzureWebJobsStorage')
ADMIN_CHAT_ID = os.environ.get('TELEGRAM_ADMIN_CHAT_ID')
GITHUB_TOKEN = os.environ.get('GITHUB_TOKEN', '')
GITHUB_REPO = os.environ.get('GITHUB_REPO', '')


class RateLimiter:
    """Simple rate limiter for API requests."""

    def __init__(self, max_requests: int = 10, window_seconds: int = 60):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.requests: List[datetime] = []

    def can_proceed(self) -> bool:
        now = datetime.utcnow()
        cutoff = now - timedelta(seconds=self.window_seconds)
        self.requests = [r for r in self.requests if r > cutoff]

        if len(self.requests) < self.max_requests:
            self.requests.append(now)
            return True
        return False


class DataTransformer:
    """Data transformation utilities."""

    @staticmethod
    def flatten(data: Dict, separator: str = '_', prefix: str = '') -> Dict:
        """Flatten nested dictionary."""
        items = {}
        for key, value in data.items():
            new_key = f"{prefix}{separator}{key}" if prefix else key
            if isinstance(value, dict):
                items.update(DataTransformer.flatten(value, separator, new_key))
            else:
                items[new_key] = value
        return items

    @staticmethod
    def add_timestamp(data: Dict) -> Dict:
        """Add processing timestamp to data."""
        data['processed_at'] = datetime.utcnow().isoformat()
        return data

    @staticmethod
    def aggregate(data: List[Dict], group_by: str, metrics: List[Dict]) -> List[Dict]:
        """Aggregate data by group."""
        groups = {}
        for item in data:
            key = item.get(group_by, 'unknown')
            if key not in groups:
                groups[key] = []
            groups[key].append(item)

        results = []
        for key, items in groups.items():
            result = {group_by: key}
            for metric in metrics:
                if 'sum' in metric:
                    field = metric['sum']
                    result[f'sum_{field}'] = sum(i.get(field, 0) for i in items)
                if 'count' in metric:
                    result['count'] = len(items)
                if 'avg' in metric:
                    field = metric['avg']
                    values = [i.get(field, 0) for i in items]
                    result[f'avg_{field}'] = sum(values) / len(values) if values else 0
            results.append(result)

        return results


class DataFetcher:
    """Fetch data from various sources."""

    def __init__(self):
        self.rate_limiter = RateLimiter(max_requests=10, window_seconds=60)

    async def fetch_rest_api(
        self,
        url: str,
        headers: Optional[Dict] = None,
        params: Optional[Dict] = None
    ) -> Dict:
        """Fetch data from REST API."""
        if not self.rate_limiter.can_proceed():
            raise Exception("Rate limit exceeded")

        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=headers, params=params) as response:
                if response.status == 200:
                    return await response.json()
                else:
                    raise Exception(f"API error: {response.status}")

    async def fetch_github_stats(self, repo: str, token: str) -> Dict:
        """Fetch GitHub repository statistics."""
        headers = {
            'Authorization': f'Bearer {token}',
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'OpenClaw-DataProcessor'
        }

        base_url = f"https://api.github.com/repos/{repo}"

        async with aiohttp.ClientSession() as session:
            # Fetch multiple endpoints in parallel
            async def fetch(endpoint):
                async with session.get(f"{base_url}/{endpoint}", headers=headers) as resp:
                    if resp.status == 200:
                        return await resp.json()
                    return None

            results = await asyncio.gather(
                fetch(''),  # Repo info
                fetch('contributors'),
                fetch('commits?per_page=10'),
                return_exceptions=True
            )

            return {
                'repo_info': results[0] if not isinstance(results[0], Exception) else None,
                'contributors': results[1] if not isinstance(results[1], Exception) else [],
                'recent_commits': results[2] if not isinstance(results[2], Exception) else []
            }


# Azure Function entry points

app = func.FunctionApp()


@app.function_name("ProcessMarketData")
@app.timer_trigger(schedule="0 */15 * * * *", arg_name="timer", run_on_startup=False)
async def process_market_data(timer: func.TimerRequest) -> None:
    """Process market data every 15 minutes."""
    logger.info("Starting market data processing")

    fetcher = DataFetcher()
    transformer = DataTransformer()

    try:
        # Fetch cryptocurrency prices
        data = await fetcher.fetch_rest_api(
            "https://api.coingecko.com/api/v3/simple/price",
            params={
                "ids": "bitcoin,ethereum,solana",
                "vs_currencies": "usd",
                "include_24hr_change": "true"
            }
        )

        # Transform data
        flattened = transformer.flatten(data)
        result = transformer.add_timestamp(flattened)

        logger.info(f"Market data processed: {json.dumps(result)}")

        # Store result (would use blob storage binding in production)
        return json.dumps(result)

    except Exception as e:
        logger.error(f"Error processing market data: {str(e)}")
        raise


@app.function_name("ProcessGitHubStats")
@app.timer_trigger(schedule="0 0 0 * * *", arg_name="timer", run_on_startup=False)
async def process_github_stats(timer: func.TimerRequest) -> None:
    """Process GitHub statistics daily."""
    logger.info("Starting GitHub stats processing")

    if not GITHUB_TOKEN or not GITHUB_REPO:
        logger.warning("GitHub token or repo not configured")
        return

    fetcher = DataFetcher()
    transformer = DataTransformer()

    try:
        data = await fetcher.fetch_github_stats(GITHUB_REPO, GITHUB_TOKEN)

        # Process contributors
        contributors = data.get('contributors', [])
        if contributors:
            aggregated = transformer.aggregate(
                [{'author': c['login'], 'contributions': c['contributions']} for c in contributors],
                group_by='author',
                metrics=[{'sum': 'contributions'}]
            )

            result = {
                'repo': GITHUB_REPO,
                'total_contributors': len(contributors),
                'top_contributors': aggregated[:10],
                'recent_commits': len(data.get('recent_commits', [])),
                'processed_at': datetime.utcnow().isoformat()
            }

            logger.info(f"GitHub stats processed: {json.dumps(result)}")
            return json.dumps(result)

    except Exception as e:
        logger.error(f"Error processing GitHub stats: {str(e)}")
        raise


@app.function_name("ProcessDataPipeline")
@app.route(route="process/{pipeline}", methods=["POST"])
async def process_data_pipeline(req: func.HttpRequest) -> func.HttpResponse:
    """HTTP-triggered data processing pipeline."""
    pipeline = req.route_params.get('pipeline', 'all')

    logger.info(f"Processing pipeline: {pipeline}")

    try:
        body = req.get_json() if req.get_body() else {}
        chat_id = body.get('chatId', ADMIN_CHAT_ID)

        results = {}

        if pipeline in ['all', 'market']:
            # Process market data
            fetcher = DataFetcher()
            market_data = await fetcher.fetch_rest_api(
                "https://api.coingecko.com/api/v3/simple/price",
                params={"ids": "bitcoin,ethereum", "vs_currencies": "usd"}
            )
            results['market'] = market_data

        if pipeline in ['all', 'github'] and GITHUB_TOKEN:
            # Process GitHub data
            fetcher = DataFetcher()
            github_data = await fetcher.fetch_github_stats(GITHUB_REPO, GITHUB_TOKEN)
            results['github'] = {
                'contributors': len(github_data.get('contributors', [])),
                'recent_commits': len(github_data.get('recent_commits', []))
            }

        response = {
            'status': 'success',
            'pipeline': pipeline,
            'results': results,
            'processed_at': datetime.utcnow().isoformat()
        }

        return func.HttpResponse(
            json.dumps(response),
            mimetype="application/json",
            status_code=200
        )

    except Exception as e:
        logger.error(f"Pipeline error: {str(e)}")
        return func.HttpResponse(
            json.dumps({'error': str(e)}),
            mimetype="application/json",
            status_code=500
        )


@app.function_name("HealthCheck")
@app.route(route="health", methods=["GET"])
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """Health check endpoint."""
    return func.HttpResponse(
        json.dumps({
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'service': 'openclaw-data-processor'
        }),
        mimetype="application/json",
        status_code=200
    )
