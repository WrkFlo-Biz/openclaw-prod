# Auto Responder Skill for OpenClaw
# Purpose: Reply to Telegram messages based on rules, send notifications/summaries
# Approval: REQUIRED for external sends

name: auto-responder
description: Automated message responses and notifications with safety gates
version: 1.0.0
approval_required: true  # External sends require approval

triggers:
  - type: message
    source: telegram
    filter: "{{ message.chat_id in config.allowed_chats }}"
  - type: schedule
    cron: "0 9 * * *"  # Daily summary at 9 AM
  - type: command
    pattern: "/respond {action}"
  - type: event
    name: "alert_generated"

config:
  rate_limit:
    max_messages_per_minute: 5
    max_messages_per_hour: 50
    cooldown_seconds: 10

  allowed_chats:
    - "${TELEGRAM_MAIN_CHAT_ID}"
    - "${TELEGRAM_ADMIN_CHAT_ID}"

  auto_approve:
    # These response types can be sent without manual approval
    enabled: true
    types:
      - "acknowledgment"
      - "status_response"
      - "help_response"
    max_length: 500

  require_approval:
    # These always require manual approval
    types:
      - "external_notification"
      - "bulk_message"
      - "public_announcement"
      - "forwarded_content"

  response_rules:
    - name: "help_command"
      trigger:
        type: command
        pattern: "/help"
      response:
        type: "help_response"
        template: "help_menu"
      approval: false

    - name: "status_command"
      trigger:
        type: command
        pattern: "/status"
      response:
        type: "status_response"
        template: "system_status"
      approval: false

    - name: "greeting"
      trigger:
        type: keyword
        patterns: ["hello", "hi", "hey"]
        case_insensitive: true
      response:
        type: "acknowledgment"
        template: "greeting_response"
      approval: false

    - name: "question_detection"
      trigger:
        type: pattern
        regex: "^(how|what|when|where|why|can|could|would|is|are|do|does).*\\?$"
        case_insensitive: true
      response:
        type: "acknowledgment"
        template: "question_acknowledgment"
      approval: false

    - name: "alert_notification"
      trigger:
        type: event
        name: "critical_alert"
      response:
        type: "external_notification"
        template: "alert_notification"
        recipients: "{{ config.notification_recipients }}"
      approval: true  # Requires approval

    - name: "daily_summary"
      trigger:
        type: schedule
        cron: "0 9 * * *"
      response:
        type: "external_notification"
        template: "daily_summary"
        recipients: "{{ config.summary_recipients }}"
      approval: true  # Requires approval

  notification_recipients:
    - chat_id: "${TELEGRAM_ADMIN_CHAT_ID}"
      types: ["critical_alert", "daily_summary"]

  summary_recipients:
    - chat_id: "${TELEGRAM_MAIN_CHAT_ID}"
      types: ["daily_summary"]

---
# Workflow Definition

workflow:
  steps:
    - id: load_safety_rules
      action: read_config
      params:
        file: "/data/openclaw/.openclaw/agents/config/safety-rules.json"
      output: safety_config

    - id: check_rate_limit
      action: rate_limit_check
      params:
        limit: "{{ config.rate_limit.max_messages_per_minute }}"
        window: "1m"
      on_exceeded:
        action: drop
        message: "Rate limit exceeded, dropping message"
        notify_admin: true

    - id: validate_source
      action: validate_chat
      params:
        chat_id: "{{ trigger.message.chat_id }}"
        allowed_chats: "{{ config.allowed_chats }}"
      on_invalid:
        action: ignore
        log: true

    - id: match_rules
      action: rule_matcher
      params:
        message: "{{ trigger.message }}"
        rules: "{{ config.response_rules }}"
      output: matched_rule

    - id: check_blocked_content
      action: content_filter
      params:
        message: "{{ trigger.message.text }}"
        blocked_patterns: "{{ safety_config.blocked_commands }}"
      on_blocked:
        action: reject
        notify_admin: true

    - id: generate_response
      condition: "{{ matched_rule != null }}"
      action: render_template
      params:
        template: "{{ matched_rule.response.template }}"
        context:
          message: "{{ trigger.message }}"
          user: "{{ trigger.message.from }}"
          timestamp: "{{ now() }}"
      output: response_content

    - id: check_response_length
      action: validate_length
      params:
        content: "{{ response_content }}"
        max_length: "{{ config.auto_approve.max_length }}"
      output: length_valid

    - id: determine_approval
      action: check_approval_required
      params:
        rule: "{{ matched_rule }}"
        response_type: "{{ matched_rule.response.type }}"
        auto_approve_types: "{{ config.auto_approve.types }}"
        require_approval_types: "{{ config.require_approval.types }}"
        length_valid: "{{ length_valid }}"
      output: needs_approval

    - id: request_approval
      condition: "{{ needs_approval }}"
      action: approval_gate
      params:
        action_type: "send_message"
        description: "Send response to {{ trigger.message.chat_id }}"
        content_preview: "{{ response_content | truncate(200) }}"
        timeout_minutes: 30
        notify_channel: "${TELEGRAM_ADMIN_CHAT_ID}"
      output: approval_result
      on_timeout:
        action: cancel
        notify: true
      on_denied:
        action: cancel
        log: true

    - id: send_response
      condition: "{{ not needs_approval or approval_result.approved }}"
      action: telegram_send
      params:
        chat_id: "{{ trigger.message.chat_id }}"
        text: "{{ response_content }}"
        reply_to: "{{ trigger.message.message_id }}"
        parse_mode: "Markdown"
      output: send_result

    - id: audit_log
      action: audit_log
      params:
        action_type: "auto_response"
        trigger: "{{ trigger }}"
        matched_rule: "{{ matched_rule.name }}"
        approval_required: "{{ needs_approval }}"
        approval_result: "{{ approval_result | default(null) }}"
        send_result: "{{ send_result }}"
        log_file: "{{ safety_config.audit.log_file }}"

---
# Response Templates

templates:
  help_menu:
    content: |
      **OpenClaw Bot Commands**

      /help - Show this help menu
      /status - Check system status
      /monitor - View monitoring status
      /process - Trigger data processing
      /deploy - (Requires approval) Deploy updates
      /emergency-stop - Halt all operations

      For more info, contact admin.

  system_status:
    content: |
      **System Status**

      Status: {{ status }}
      Uptime: {{ uptime }}
      Active Skills: {{ active_skills | join(", ") }}
      Last Check: {{ last_check }}
      Pending Approvals: {{ pending_approvals }}

  greeting_response:
    content: |
      Hello {{ user.first_name }}! How can I help you today?

      Type /help to see available commands.

  question_acknowledgment:
    content: |
      Thanks for your question, {{ user.first_name }}. Let me look into that for you.

  alert_notification:
    content: |
      **Alert Notification**

      Type: {{ alert.type }}
      Severity: {{ alert.severity }}
      Source: {{ alert.source }}

      {{ alert.message }}

      Time: {{ alert.timestamp }}

  daily_summary:
    content: |
      **Daily Summary - {{ date }}**

      **Monitoring**
      - Alerts triggered: {{ summary.alerts_count }}
      - Critical issues: {{ summary.critical_count }}

      **Data Processing**
      - Pipelines run: {{ summary.pipelines_count }}
      - Records processed: {{ summary.records_count }}

      **DevOps**
      - Deployments: {{ summary.deployments_count }}
      - Scripts executed: {{ summary.scripts_count }}

      **Actions Pending Approval**
      {{ summary.pending_approvals | join("\n") }}

  approval_request:
    content: |
      **Approval Required**

      Action: {{ action_type }}
      Description: {{ description }}

      Content Preview:
      ```
      {{ content_preview }}
      ```

      Reply with:
      /approve {{ request_id }} - Approve this action
      /deny {{ request_id }} - Deny this action
