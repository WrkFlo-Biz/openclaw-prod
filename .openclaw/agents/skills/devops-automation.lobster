# DevOps Automation Skill for OpenClaw
# Purpose: Deploy containers, run scripts, backup data, manage infrastructure
# Approval: REQUIRED for all actions (destructive operations)

name: devops-automation
description: Infrastructure management and deployment automation with mandatory approval gates
version: 1.0.0
approval_required: true  # ALL actions require approval

triggers:
  - type: command
    pattern: "/deploy {target}"
  - type: command
    pattern: "/backup {resource}"
  - type: command
    pattern: "/run-script {script_name}"
  - type: command
    pattern: "/scale {service} {replicas}"
  - type: webhook
    endpoint: /webhooks/devops
  - type: schedule
    cron: "0 2 * * *"  # Nightly backups at 2 AM

config:
  rate_limit:
    max_deployments_per_hour: 5
    max_scripts_per_hour: 10
    max_backups_per_day: 3

  approval:
    required: true
    timeout_minutes: 60
    notify_channel: "${TELEGRAM_ADMIN_CHAT_ID}"
    require_reason: true
    two_person_rule: false  # Enable for high-risk environments

  docker:
    enabled: true
    socket: "/var/run/docker.sock"
    registry: "${DOCKER_REGISTRY}"
    default_network: "openclaw-network"
    resource_limits:
      memory: "512m"
      cpus: "0.5"

  allowed_operations:
    deploy:
      - "openclaw-bot"
      - "openclaw-api"
      - "openclaw-worker"
    scripts:
      - "health-check.sh"
      - "cleanup-logs.sh"
      - "rotate-secrets.sh"
      - "sync-config.sh"
    backup:
      - "database"
      - "config"
      - "logs"

  blocked_operations:
    commands:
      - "rm -rf"
      - "mkfs"
      - "dd if=/dev"
      - "chmod 777"
      - "curl | sh"
      - "wget | bash"
    containers:
      - "--privileged"
      - "-v /:/host"
      - "--pid=host"

  backup:
    destination: "${BACKUP_DESTINATION}"
    encryption: true
    encryption_key: "${BACKUP_ENCRYPTION_KEY}"
    retention_days: 30
    compression: "gzip"

  rollback:
    enabled: true
    max_versions: 5
    auto_rollback_on_failure: true

---
# Workflow Definition

workflow:
  steps:
    - id: load_safety_rules
      action: read_config
      params:
        file: "/data/openclaw/.openclaw/agents/config/safety-rules.json"
      output: safety_config

    - id: validate_operation
      action: validate_devops_operation
      params:
        operation: "{{ trigger.command }}"
        target: "{{ trigger.params }}"
        allowed: "{{ config.allowed_operations }}"
        blocked: "{{ config.blocked_operations }}"
      on_blocked:
        action: reject
        notify_admin: true
        message: "Blocked operation attempted: {{ trigger.command }}"

    - id: check_rate_limit
      action: rate_limit_check
      params:
        operation_type: "{{ trigger.command | split(' ') | first }}"
        limits: "{{ config.rate_limit }}"
      on_exceeded:
        action: queue
        notify: true

    - id: prepare_operation
      action: prepare_devops_action
      params:
        command: "{{ trigger.command }}"
        params: "{{ trigger.params }}"
        config: "{{ config }}"
      output: operation_plan

    - id: security_scan
      action: security_check
      params:
        operation: "{{ operation_plan }}"
        blocked_patterns: "{{ safety_config.blocked_commands }}"
      on_violation:
        action: reject
        notify_admin: true

    - id: request_approval
      action: approval_gate
      params:
        action_type: "devops_{{ operation_plan.type }}"
        description: |
          Operation: {{ operation_plan.type }}
          Target: {{ operation_plan.target }}
          Details: {{ operation_plan.details }}

          Risk Level: {{ operation_plan.risk_level }}

          This action will:
          {{ operation_plan.effects | join("\n") }}
        require_reason: "{{ config.approval.require_reason }}"
        timeout_minutes: "{{ config.approval.timeout_minutes }}"
        notify_channel: "{{ config.approval.notify_channel }}"
      output: approval_result
      on_timeout:
        action: cancel
        notify: true
      on_denied:
        action: cancel
        log: true

    - id: create_backup_point
      condition: "{{ approval_result.approved and operation_plan.type in ['deploy', 'run_script'] }}"
      action: create_restore_point
      params:
        target: "{{ operation_plan.target }}"
        backup_config: "{{ config.backup }}"
      output: restore_point

    - id: execute_operation
      condition: "{{ approval_result.approved }}"
      action: switch
      params:
        value: "{{ operation_plan.type }}"
      cases:
        deploy:
          steps:
            - id: pull_image
              action: docker_pull
              params:
                image: "{{ operation_plan.image }}"
                registry: "{{ config.docker.registry }}"

            - id: stop_old_container
              action: docker_stop
              params:
                container: "{{ operation_plan.target }}"
                timeout: 30

            - id: start_new_container
              action: docker_run
              params:
                image: "{{ operation_plan.image }}"
                name: "{{ operation_plan.target }}"
                network: "{{ config.docker.default_network }}"
                env_file: "{{ operation_plan.env_file }}"
                volumes: "{{ operation_plan.volumes }}"
                resource_limits: "{{ config.docker.resource_limits }}"

            - id: health_check
              action: wait_for_healthy
              params:
                container: "{{ operation_plan.target }}"
                timeout_seconds: 120
                health_endpoint: "{{ operation_plan.health_endpoint }}"

        backup:
          steps:
            - id: create_backup
              action: backup_resource
              params:
                resource: "{{ operation_plan.target }}"
                destination: "{{ config.backup.destination }}"
                encryption: "{{ config.backup.encryption }}"
                compression: "{{ config.backup.compression }}"

            - id: verify_backup
              action: verify_backup
              params:
                backup_path: "{{ backup_result.path }}"

            - id: cleanup_old_backups
              action: cleanup_backups
              params:
                destination: "{{ config.backup.destination }}"
                retention_days: "{{ config.backup.retention_days }}"

        run_script:
          steps:
            - id: validate_script
              action: validate_script
              params:
                script_name: "{{ operation_plan.script }}"
                allowed_scripts: "{{ config.allowed_operations.scripts }}"

            - id: execute_script
              action: run_script
              params:
                script: "/data/openclaw/scripts/{{ operation_plan.script }}"
                args: "{{ operation_plan.args }}"
                timeout_seconds: 300
                capture_output: true

        scale:
          steps:
            - id: scale_service
              action: docker_scale
              params:
                service: "{{ operation_plan.service }}"
                replicas: "{{ operation_plan.replicas }}"

      output: execution_result

    - id: handle_failure
      condition: "{{ execution_result.status == 'failed' and config.rollback.auto_rollback_on_failure }}"
      action: rollback
      params:
        restore_point: "{{ restore_point }}"
        target: "{{ operation_plan.target }}"
      output: rollback_result

    - id: notify_result
      action: telegram_send
      params:
        chat_id: "{{ config.approval.notify_channel }}"
        text: |
          **DevOps Operation {{ execution_result.status | upper }}**

          Operation: {{ operation_plan.type }}
          Target: {{ operation_plan.target }}
          Approved by: {{ approval_result.approved_by }}
          Reason: {{ approval_result.reason }}

          {{ execution_result.summary }}

          {% if rollback_result %}
          Rollback: {{ rollback_result.status }}
          {% endif %}

    - id: audit_log
      action: audit_log
      params:
        action_type: "devops_{{ operation_plan.type }}"
        operation: "{{ operation_plan }}"
        approval: "{{ approval_result }}"
        execution: "{{ execution_result }}"
        rollback: "{{ rollback_result | default(null) }}"
        log_file: "{{ safety_config.audit.log_file }}"

---
# Operation Templates

operations:
  deploy:
    description: "Deploy or update a container"
    params:
      - name: target
        required: true
        description: "Container name to deploy"
      - name: image
        required: false
        description: "Docker image (defaults to latest)"
      - name: env_file
        required: false
        description: "Environment file path"
    risk_level: "high"
    effects:
      - "Stop existing container"
      - "Start new container with updated image"
      - "May cause brief downtime"

  backup:
    description: "Create backup of a resource"
    params:
      - name: resource
        required: true
        description: "Resource to backup (database, config, logs)"
    risk_level: "low"
    effects:
      - "Create backup archive"
      - "Upload to backup destination"
      - "Cleanup old backups per retention policy"

  run_script:
    description: "Execute an approved maintenance script"
    params:
      - name: script_name
        required: true
        description: "Name of script from allowed list"
      - name: args
        required: false
        description: "Arguments to pass to script"
    risk_level: "medium"
    effects:
      - "Execute script with provided arguments"
      - "Script output will be captured and logged"

  scale:
    description: "Scale a service to specified replicas"
    params:
      - name: service
        required: true
        description: "Service name to scale"
      - name: replicas
        required: true
        description: "Number of replicas"
    risk_level: "medium"
    effects:
      - "Adjust number of running containers"
      - "May affect resource usage and costs"
