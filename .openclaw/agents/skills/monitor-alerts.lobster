# Monitor & Alert Skill for OpenClaw
# Purpose: Watch GitHub PRs, issues, deployments; monitor Telegram channels; price/API status monitoring
# Approval: Not required (read-only operations)

name: monitor-alerts
description: Monitors various sources and generates alerts based on conditions
version: 1.0.0
approval_required: false

triggers:
  - type: schedule
    cron: "*/5 * * * *"  # Every 5 minutes
  - type: webhook
    endpoint: /webhooks/monitor
  - type: command
    pattern: "/monitor {source}"

config:
  rate_limit:
    max_checks_per_minute: 10

  github:
    enabled: true
    repositories:
      - "${GITHUB_REPO}"
    watch:
      - pull_requests
      - issues
      - deployments
      - releases
    filters:
      labels: ["urgent", "critical", "bug"]
      authors: []  # Empty means all authors

  telegram:
    enabled: true
    channels: "${TELEGRAM_MONITOR_CHANNELS}"
    keywords:
      - "error"
      - "critical"
      - "urgent"
      - "down"
      - "alert"

  api_health:
    enabled: true
    endpoints:
      - name: "Main API"
        url: "${API_HEALTH_URL}"
        expected_status: 200
        timeout_seconds: 10
      - name: "Database"
        url: "${DB_HEALTH_URL}"
        expected_status: 200
        timeout_seconds: 5

  price_monitoring:
    enabled: "${PRICE_MONITOR_ENABLED:-false}"
    assets: "${PRICE_MONITOR_ASSETS}"
    threshold_percent: 5

---
# Workflow Definition

workflow:
  steps:
    - id: load_config
      action: read_config
      params:
        file: "/data/openclaw/.openclaw/agents/config/safety-rules.json"
      output: safety_config

    - id: check_rate_limit
      action: rate_limit_check
      params:
        limit: "{{ config.rate_limit.max_checks_per_minute }}"
        window: "1m"
      on_exceeded:
        action: skip
        message: "Rate limit exceeded, skipping this run"

    - id: github_monitor
      condition: "{{ config.github.enabled }}"
      action: github_check
      params:
        repositories: "{{ config.github.repositories }}"
        watch_types: "{{ config.github.watch }}"
        filters: "{{ config.github.filters }}"
      output: github_alerts

    - id: telegram_monitor
      condition: "{{ config.telegram.enabled }}"
      action: telegram_scan
      params:
        channels: "{{ config.telegram.channels }}"
        keywords: "{{ config.telegram.keywords }}"
        lookback_minutes: 5
      output: telegram_alerts

    - id: api_health_check
      condition: "{{ config.api_health.enabled }}"
      action: http_health_check
      params:
        endpoints: "{{ config.api_health.endpoints }}"
      output: health_alerts

    - id: price_monitor
      condition: "{{ config.price_monitoring.enabled }}"
      action: price_check
      params:
        assets: "{{ config.price_monitoring.assets }}"
        threshold: "{{ config.price_monitoring.threshold_percent }}"
      output: price_alerts

    - id: aggregate_alerts
      action: merge_results
      params:
        sources:
          - "{{ github_alerts }}"
          - "{{ telegram_alerts }}"
          - "{{ health_alerts }}"
          - "{{ price_alerts }}"
      output: all_alerts

    - id: filter_duplicates
      action: deduplicate
      params:
        input: "{{ all_alerts }}"
        key: "alert_hash"
        ttl_minutes: 60
      output: new_alerts

    - id: log_alerts
      action: audit_log
      params:
        action_type: "monitor_check"
        results: "{{ new_alerts }}"
        log_file: "{{ safety_config.audit.log_file }}"

    - id: send_notifications
      condition: "{{ new_alerts | length > 0 }}"
      action: notify
      params:
        alerts: "{{ new_alerts }}"
        channels:
          - type: telegram
            chat_id: "${TELEGRAM_ALERT_CHAT_ID}"
          - type: log
            file: "/data/openclaw/logs/alerts.log"

---
# Alert Templates

templates:
  github_pr:
    title: "GitHub PR Alert"
    body: |
      **New PR in {{ repo }}**
      Title: {{ title }}
      Author: {{ author }}
      Labels: {{ labels | join(", ") }}
      URL: {{ url }}

  github_issue:
    title: "GitHub Issue Alert"
    body: |
      **New Issue in {{ repo }}**
      Title: {{ title }}
      Author: {{ author }}
      Labels: {{ labels | join(", ") }}
      URL: {{ url }}

  api_down:
    title: "API Health Alert"
    body: |
      **Service Down: {{ name }}**
      URL: {{ url }}
      Status: {{ status }}
      Response Time: {{ response_time }}ms
      Error: {{ error }}

  price_change:
    title: "Price Alert"
    body: |
      **{{ asset }} Price Change**
      Direction: {{ direction }}
      Change: {{ change_percent }}%
      Current: ${{ current_price }}
      Previous: ${{ previous_price }}

  telegram_keyword:
    title: "Telegram Keyword Alert"
    body: |
      **Keyword Match in {{ channel }}**
      Keywords: {{ matched_keywords | join(", ") }}
      Message: {{ message_preview }}
      From: {{ sender }}
