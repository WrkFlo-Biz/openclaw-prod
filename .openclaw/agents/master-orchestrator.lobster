# Master Orchestrator for OpenClaw Autonomous Agent Skills
# Purpose: Main controller that receives commands via Telegram, routes to sub-workflows, logs all actions
# Approval: Required for dangerous commands

name: master-orchestrator
description: Central command and control for all OpenClaw agent skills
version: 1.0.0
approval_required: conditional  # Depends on command type

triggers:
  - type: telegram
    events: ["message", "command"]
    filter: "{{ message.chat_id in config.authorized_chats }}"
  - type: startup
    action: "initialize"
  - type: schedule
    cron: "*/1 * * * *"  # Health check every minute
  - type: webhook
    endpoint: /webhooks/orchestrator

config:
  authorized_chats:
    - "${TELEGRAM_ADMIN_CHAT_ID}"
    - "${TELEGRAM_MAIN_CHAT_ID}"

  authorized_users:
    admin:
      - "${TELEGRAM_ADMIN_USER_ID}"
    operator:
      - "${TELEGRAM_OPERATOR_USER_IDS}"

  rate_limit:
    global_max_per_minute: 10
    per_skill_max_per_minute: 5

  skills:
    monitor-alerts:
      path: "/data/openclaw/.openclaw/agents/skills/monitor-alerts.lobster"
      enabled: true
      approval_required: false
      commands: ["/monitor", "/check", "/watch"]

    data-processor:
      path: "/data/openclaw/.openclaw/agents/skills/data-processor.lobster"
      enabled: true
      approval_required: false
      commands: ["/process", "/fetch", "/aggregate"]

    auto-responder:
      path: "/data/openclaw/.openclaw/agents/skills/auto-responder.lobster"
      enabled: true
      approval_required: conditional
      commands: ["/respond", "/notify", "/summary"]

    devops-automation:
      path: "/data/openclaw/.openclaw/agents/skills/devops-automation.lobster"
      enabled: true
      approval_required: true
      commands: ["/deploy", "/backup", "/run-script", "/scale", "/rollback"]

  emergency_stop:
    enabled: true
    commands: ["/emergency-stop", "/kill", "/halt", "/stop-all"]
    authorized_users: "admin"
    action: "halt_all_workflows"

  commands:
    system:
      - command: "/help"
        description: "Show available commands"
        approval: false
      - command: "/status"
        description: "Show system status"
        approval: false
      - command: "/skills"
        description: "List available skills"
        approval: false
      - command: "/pending"
        description: "Show pending approvals"
        approval: false
      - command: "/logs"
        description: "View recent audit logs"
        approval: false
      - command: "/approve {id}"
        description: "Approve a pending action"
        approval: false
        requires_role: "admin"
      - command: "/deny {id}"
        description: "Deny a pending action"
        approval: false
        requires_role: "admin"

  audit:
    enabled: true
    log_file: "/data/openclaw/logs/audit.log"
    detailed_logging: true
    retention_days: 30

  state:
    file: "/data/openclaw/state/orchestrator.json"
    backup_interval_minutes: 5

---
# Workflow Definition

workflow:
  steps:
    - id: initialize
      condition: "{{ trigger.type == 'startup' }}"
      action: sequence
      steps:
        - id: load_config
          action: read_config
          params:
            file: "/data/openclaw/.openclaw/agents/config/safety-rules.json"
          output: safety_config

        - id: load_state
          action: load_state
          params:
            file: "{{ config.state.file }}"
          output: state

        - id: load_skills
          action: foreach
          params:
            items: "{{ config.skills | dict_to_list }}"
            as: skill
          steps:
            - id: register_skill
              condition: "{{ skill.enabled }}"
              action: register_skill
              params:
                name: "{{ skill.name }}"
                path: "{{ skill.path }}"
                commands: "{{ skill.commands }}"
                approval_required: "{{ skill.approval_required }}"

        - id: log_startup
          action: audit_log
          params:
            action_type: "orchestrator_startup"
            skills_loaded: "{{ loaded_skills }}"
            log_file: "{{ config.audit.log_file }}"

        - id: notify_startup
          action: telegram_send
          params:
            chat_id: "${TELEGRAM_ADMIN_CHAT_ID}"
            text: |
              **OpenClaw Orchestrator Started**

              Skills Loaded: {{ loaded_skills | length }}
              Status: Ready

    - id: check_emergency_stop
      condition: "{{ trigger.type == 'telegram' }}"
      action: check_emergency
      params:
        message: "{{ trigger.message }}"
        emergency_commands: "{{ config.emergency_stop.commands }}"
        authorized_users: "{{ config.authorized_users[config.emergency_stop.authorized_users] }}"
      on_match:
        action: emergency_stop_handler

    - id: health_check
      condition: "{{ trigger.type == 'schedule' }}"
      action: health_check
      params:
        skills: "{{ config.skills }}"
        state: "{{ state }}"
      output: health_status
      on_unhealthy:
        action: notify
        params:
          chat_id: "${TELEGRAM_ADMIN_CHAT_ID}"
          template: "health_alert"

    - id: process_command
      condition: "{{ trigger.type == 'telegram' and trigger.message.text | startswith('/') }}"
      action: sequence
      steps:
        - id: parse_command
          action: parse_command
          params:
            text: "{{ trigger.message.text }}"
          output: parsed_command

        - id: check_authorization
          action: check_authorization
          params:
            user_id: "{{ trigger.message.from.id }}"
            command: "{{ parsed_command.command }}"
            authorized_users: "{{ config.authorized_users }}"
            commands: "{{ config.commands }}"
          on_unauthorized:
            action: reject
            notify: true

        - id: rate_limit_check
          action: rate_limit_check
          params:
            user_id: "{{ trigger.message.from.id }}"
            limits: "{{ config.rate_limit }}"
          on_exceeded:
            action: reject
            message: "Rate limit exceeded. Please wait before sending more commands."

        - id: route_command
          action: route_to_skill
          params:
            command: "{{ parsed_command.command }}"
            args: "{{ parsed_command.args }}"
            skills: "{{ config.skills }}"
            system_commands: "{{ config.commands.system }}"
          output: route_result

        - id: execute_system_command
          condition: "{{ route_result.type == 'system' }}"
          action: execute_system_command
          params:
            command: "{{ parsed_command.command }}"
            args: "{{ parsed_command.args }}"
            user: "{{ trigger.message.from }}"
            state: "{{ state }}"
          output: system_result

        - id: delegate_to_skill
          condition: "{{ route_result.type == 'skill' }}"
          action: invoke_skill
          params:
            skill_name: "{{ route_result.skill }}"
            command: "{{ parsed_command.command }}"
            args: "{{ parsed_command.args }}"
            context:
              message: "{{ trigger.message }}"
              user: "{{ trigger.message.from }}"
              chat_id: "{{ trigger.message.chat_id }}"
          output: skill_result

        - id: send_response
          action: telegram_send
          params:
            chat_id: "{{ trigger.message.chat_id }}"
            text: "{{ system_result.response | default(skill_result.response) }}"
            reply_to: "{{ trigger.message.message_id }}"
            parse_mode: "Markdown"

    - id: process_message
      condition: "{{ trigger.type == 'telegram' and not trigger.message.text | startswith('/') }}"
      action: invoke_skill
      params:
        skill_name: "auto-responder"
        context:
          message: "{{ trigger.message }}"
          user: "{{ trigger.message.from }}"
          chat_id: "{{ trigger.message.chat_id }}"
      output: response_result

    - id: audit_log
      action: audit_log
      params:
        action_type: "command_processed"
        trigger: "{{ trigger }}"
        parsed_command: "{{ parsed_command | default(null) }}"
        route_result: "{{ route_result | default(null) }}"
        execution_result: "{{ system_result | default(skill_result) | default(null) }}"
        log_file: "{{ config.audit.log_file }}"

    - id: save_state
      action: save_state
      params:
        file: "{{ config.state.file }}"
        state: "{{ state }}"

---
# Emergency Stop Handler

emergency_stop_handler:
  steps:
    - id: verify_authorization
      action: verify_admin
      params:
        user_id: "{{ trigger.message.from.id }}"
        admin_users: "{{ config.authorized_users.admin }}"
      on_unauthorized:
        action: reject
        notify: true

    - id: halt_all_skills
      action: foreach
      params:
        items: "{{ config.skills | dict_to_list }}"
        as: skill
      steps:
        - id: stop_skill
          action: stop_skill
          params:
            name: "{{ skill.name }}"

    - id: clear_pending_approvals
      action: clear_pending
      params:
        deny_all: true

    - id: notify_emergency
      action: telegram_send
      params:
        chat_id: "${TELEGRAM_ADMIN_CHAT_ID}"
        text: |
          **EMERGENCY STOP ACTIVATED**

          Initiated by: {{ trigger.message.from.first_name }} ({{ trigger.message.from.id }})
          Time: {{ now() }}

          All skills have been halted.
          All pending approvals have been denied.

          To restart, use: /restart

    - id: log_emergency
      action: audit_log
      params:
        action_type: "EMERGENCY_STOP"
        initiated_by: "{{ trigger.message.from }}"
        log_file: "{{ config.audit.log_file }}"

---
# System Command Handlers

system_commands:
  help:
    response: |
      **OpenClaw Bot - Available Commands**

      **System**
      /help - Show this help
      /status - System status
      /skills - List skills
      /pending - Pending approvals
      /logs - Recent audit logs

      **Monitoring** (No approval)
      /monitor [source] - Check monitors
      /check [target] - Health check

      **Data** (No approval)
      /process [pipeline] - Run data pipeline
      /fetch [source] - Fetch data

      **Responses** (Conditional approval)
      /notify [message] - Send notification
      /summary - Generate summary

      **DevOps** (Requires approval)
      /deploy [target] - Deploy container
      /backup [resource] - Create backup
      /run-script [name] - Execute script
      /scale [service] [n] - Scale service

      **Admin**
      /approve [id] - Approve action
      /deny [id] - Deny action
      /emergency-stop - Halt everything

  status:
    action: get_status
    response_template: |
      **System Status**

      Uptime: {{ uptime }}
      State: {{ state }}
      Active Skills: {{ active_skills | join(", ") }}

      **Rate Limits**
      Actions this minute: {{ rate_counts.minute }}
      Actions this hour: {{ rate_counts.hour }}

      **Pending Approvals**
      {{ pending_approvals | length }} pending

  skills:
    action: list_skills
    response_template: |
      **Available Skills**

      {% for skill in skills %}
      **{{ skill.name }}** {% if skill.enabled %}(Active){% else %}(Disabled){% endif %}
      Commands: {{ skill.commands | join(", ") }}
      Approval: {{ "Required" if skill.approval_required else "Not required" }}

      {% endfor %}

  pending:
    action: list_pending
    response_template: |
      **Pending Approvals**

      {% if pending | length == 0 %}
      No pending approvals.
      {% else %}
      {% for item in pending %}
      **[{{ item.id }}]** {{ item.action_type }}
      {{ item.description | truncate(100) }}
      Requested: {{ item.requested_at }}
      Expires: {{ item.expires_at }}

      {% endfor %}
      Use /approve [id] or /deny [id]
      {% endif %}

  logs:
    action: get_recent_logs
    params:
      limit: 10
    response_template: |
      **Recent Audit Logs**

      {% for log in logs %}
      [{{ log.timestamp }}] {{ log.action_type }}
      {{ log.summary }}
      {% endfor %}

---
# Approval Management

approval_manager:
  pending_store: "/data/openclaw/state/pending_approvals.json"

  approve:
    steps:
      - id: validate_id
        action: find_pending
        params:
          id: "{{ args.id }}"
        on_not_found:
          action: respond
          message: "Approval ID not found: {{ args.id }}"

      - id: verify_approver
        action: verify_admin
        params:
          user_id: "{{ user.id }}"
        on_unauthorized:
          action: reject

      - id: execute_approved_action
        action: resume_workflow
        params:
          approval_id: "{{ args.id }}"
          approved: true
          approved_by: "{{ user }}"
          reason: "{{ args.reason | default('Approved by admin') }}"

      - id: log_approval
        action: audit_log
        params:
          action_type: "approval_granted"
          approval_id: "{{ args.id }}"
          approved_by: "{{ user }}"

  deny:
    steps:
      - id: validate_id
        action: find_pending
        params:
          id: "{{ args.id }}"
        on_not_found:
          action: respond
          message: "Approval ID not found: {{ args.id }}"

      - id: verify_approver
        action: verify_admin
        params:
          user_id: "{{ user.id }}"

      - id: cancel_action
        action: resume_workflow
        params:
          approval_id: "{{ args.id }}"
          approved: false
          denied_by: "{{ user }}"
          reason: "{{ args.reason | default('Denied by admin') }}"

      - id: log_denial
        action: audit_log
        params:
          action_type: "approval_denied"
          approval_id: "{{ args.id }}"
          denied_by: "{{ user }}"
