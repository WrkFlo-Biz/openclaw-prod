# Data Processor Skill for OpenClaw
# Purpose: Fetch data from APIs on schedule, transform and aggregate data, store results
# Approval: Not required (read-only operations)

name: data-processor
description: Fetches, transforms, and stores data from various sources
version: 1.0.0
approval_required: false

triggers:
  - type: schedule
    cron: "0 * * * *"  # Every hour
  - type: webhook
    endpoint: /webhooks/data-process
  - type: command
    pattern: "/process {pipeline}"

config:
  rate_limit:
    max_requests_per_minute: 10
    max_storage_ops_per_minute: 20

  storage:
    type: file  # file, database, s3
    base_path: "/data/openclaw/processed"
    database_url: "${DATABASE_URL}"
    s3_bucket: "${S3_BUCKET}"

  pipelines:
    market_data:
      enabled: true
      schedule: "*/15 * * * *"
      sources:
        - name: coingecko
          type: rest_api
          url: "https://api.coingecko.com/api/v3/simple/price"
          params:
            ids: "bitcoin,ethereum,solana"
            vs_currencies: "usd"
          headers: {}
      transforms:
        - type: flatten
        - type: add_timestamp
        - type: rename_fields
          mapping:
            bitcoin: btc_price
            ethereum: eth_price
            solana: sol_price
      output:
        type: file
        path: "market_data/prices_{date}.json"
        format: json

    github_stats:
      enabled: true
      schedule: "0 0 * * *"  # Daily
      sources:
        - name: github_api
          type: rest_api
          url: "https://api.github.com/repos/${GITHUB_REPO}/stats/contributors"
          headers:
            Authorization: "Bearer ${GITHUB_TOKEN}"
      transforms:
        - type: aggregate
          group_by: author
          metrics:
            - sum: commits
            - sum: additions
            - sum: deletions
      output:
        type: file
        path: "github_stats/contributors_{date}.json"
        format: json

    system_metrics:
      enabled: true
      schedule: "*/5 * * * *"
      sources:
        - name: system_stats
          type: command
          command: "df -h && free -m && uptime"
      transforms:
        - type: parse_system_stats
        - type: add_timestamp
      output:
        type: file
        path: "system_metrics/stats_{timestamp}.json"
        format: json

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
        limit: "{{ config.rate_limit.max_requests_per_minute }}"
        window: "1m"
      on_exceeded:
        action: queue
        message: "Rate limit reached, queuing request"

    - id: get_pipeline
      action: select_pipeline
      params:
        pipelines: "{{ config.pipelines }}"
        requested: "{{ trigger.params.pipeline | default('all') }}"
      output: active_pipelines

    - id: process_each_pipeline
      action: foreach
      params:
        items: "{{ active_pipelines }}"
        as: pipeline
      steps:
        - id: fetch_data
          action: fetch_sources
          params:
            sources: "{{ pipeline.sources }}"
            timeout_seconds: 30
            retry_count: 3
          output: raw_data
          on_error:
            action: log_and_continue
            notify: true

        - id: validate_data
          action: validate
          params:
            data: "{{ raw_data }}"
            schema: "{{ pipeline.schema | default(null) }}"
          output: validated_data

        - id: transform_data
          action: apply_transforms
          params:
            data: "{{ validated_data }}"
            transforms: "{{ pipeline.transforms }}"
          output: transformed_data

        - id: store_results
          action: store_data
          params:
            data: "{{ transformed_data }}"
            output_config: "{{ pipeline.output }}"
            storage_config: "{{ config.storage }}"
          output: storage_result

        - id: log_pipeline_run
          action: audit_log
          params:
            action_type: "data_processing"
            pipeline: "{{ pipeline.name }}"
            records_processed: "{{ transformed_data | length }}"
            storage_result: "{{ storage_result }}"
            log_file: "{{ safety_config.audit.log_file }}"

    - id: cleanup_old_data
      action: cleanup
      params:
        base_path: "{{ config.storage.base_path }}"
        retention_days: 30
        dry_run: false

    - id: generate_summary
      action: create_summary
      params:
        pipelines: "{{ active_pipelines }}"
        results: "{{ pipeline_results }}"
      output: summary

---
# Transform Functions

transforms:
  flatten:
    description: "Flatten nested JSON structures"
    params:
      separator: "_"
      max_depth: 3

  add_timestamp:
    description: "Add processing timestamp to each record"
    params:
      field_name: "processed_at"
      format: "ISO8601"

  rename_fields:
    description: "Rename fields according to mapping"
    params:
      mapping: {}

  aggregate:
    description: "Aggregate data by group"
    params:
      group_by: null
      metrics: []

  filter:
    description: "Filter records based on conditions"
    params:
      conditions: []
      mode: "all"  # all, any

  enrich:
    description: "Enrich data with additional lookups"
    params:
      lookup_source: null
      join_key: null

  parse_system_stats:
    description: "Parse system command output into structured data"
    params:
      format: "auto"

---
# Output Formats

output_formats:
  json:
    extension: ".json"
    options:
      indent: 2
      ensure_ascii: false

  csv:
    extension: ".csv"
    options:
      delimiter: ","
      header: true
      quoting: "minimal"

  parquet:
    extension: ".parquet"
    options:
      compression: "snappy"
