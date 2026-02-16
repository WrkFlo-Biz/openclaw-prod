#!/bin/bash
set -euo pipefail

CONFIG_DIR="${1:-/data/openclaw/.openclaw}"
AGENT_ID="${2:-mo2darkbot}"
BRIEF_PROFILE_RAW="${3:-ops}"
BRIEF_PROFILE="$(printf '%s' "$BRIEF_PROFILE_RAW" | tr '[:upper:]' '[:lower:]')"
AGENT_SLUG="$(printf '%s' "$AGENT_ID" | tr -c 'a-zA-Z0-9._-' '-')"
CRON_DIR="${CONFIG_DIR}/cron"
JOBS_FILE="${CRON_DIR}/jobs.json"
TZ_NAME="America/Chicago"

mkdir -p "$CRON_DIR"
if [ ! -s "$JOBS_FILE" ]; then
  printf '%s\n' '{"version":1,"jobs":[]}' > "$JOBS_FILE"
fi

case "$BRIEF_PROFILE" in
  ops)
    PROFILE_LABEL="Chief of Staff"
    NAME_PREFIX="CoS BRIEF"
    ID_PREFIX="brief-${AGENT_SLUG}-ops"
    AM_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_OPS_AM:-30 7 * * *}"
    MIDDAY_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_OPS_MIDDAY:-30 12 * * *}"
    AFTERNOON_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_OPS_AFTERNOON:-30 16 * * *}"
    EOD_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_OPS_EOD:-30 20 * * *}"
    ;;
  marketing)
    PROFILE_LABEL="Chief Marketing Officer"
    NAME_PREFIX="CMO BRIEF"
    ID_PREFIX="brief-${AGENT_SLUG}-mkt"
    AM_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_MKT_AM:-45 8 * * *}"
    MIDDAY_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_MKT_MIDDAY:-45 13 * * *}"
    AFTERNOON_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_MKT_AFTERNOON:-45 17 * * *}"
    EOD_CRON_EXPR="${OPENCLAW_BRIEF_SCHEDULE_MKT_EOD:-45 21 * * *}"
    ;;
  *)
    echo "Unsupported brief profile '${BRIEF_PROFILE_RAW}'. Use: ops | marketing" >&2
    exit 1
    ;;
esac

load_heredoc() {
  local var_name="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "$tmp_file"
  printf -v "$var_name" '%s' "$(cat "$tmp_file")"
  rm -f "$tmp_file"
}

load_heredoc COMMON_PROMPT <<'EOF'
ROLE: You are my Multi-Brief Daily Operator.
OUTPUT: Use the brief template exactly. Bold headers, short bullets, checkboxes for tasks. No filler.
STATE: Maintain last_brief_timestamp, meeting_index, task_index (dedupe across runs).

DATA SOURCES:
- Emails since last_brief_timestamp (extract meeting invites + action requests).
- Current task list (from previous briefs + active backlog).
- Upcoming meetings list (built from email invites).

PROCESS:
1. Pull emails since last brief; classify as meeting / action / info.
2. Extract meetings; mark new/updated/canceled; list next horizon window.
3. Cross-reference meetings <-> tasks; dedupe; generate prep + follow-ups.
4. Output the brief with Delta, Meetings, Tasks, Email Action Queue, Risks, Next checkpoint.
5. Update state and output STATE_UPDATE at the very bottom.

BRIEF TEMPLATE (Bot Output) - use this every run
{BRIEF NAME} - {Day, MMM DD, YYYY | HH:MM CT}
Window covered: {since_last_brief_timestamp -> now}
Focus for next block: {1 sentence}

1) DELTA SINCE LAST BRIEF
Completed: {#} | In progress: {#} | Blocked: {#}
New inbound: {# emails} | New/changed meetings: {#} | New tasks created: {#}

2) MEETINGS (From Email/Invites) - Next {X} Hours
{HH:MM-HH:MM} | {Meeting Title} - {who/where}
Purpose: {1 line}
Prep (15 min):
- [ ] {prep item}
Decisions needed: {yes/no or A/B}
Artifacts/links: {doc/threads}

3) TASKS - CROSS-REFERENCED & DEDUPED
P0 (Must do before next meeting block):
- [ ] {task} - Why now: {meeting/deadline} - Deliverable: {...} - ETA: {time}
P1 (Today):
- [ ] {task} - Owner: {...} - Next action: {...}
P2 (Parked):
- [ ] {task} - Unblock condition: {...}

4) EMAIL ACTION QUEUE (Non-meeting)
Reply/Send now (<=10 min):
- [ ] {who} - {one-line ask}
Delegate:
- [ ] {who} - {assignment + due}
Read later:
- [ ] {email thread} - {reason}

5) RISKS / BLOCKERS / GAPS
Blocker: {...} -> Unblock step: {...}
Risk: {...} -> Mitigation: {...}
Missing info: {...} -> Question to answer: {...}

6) NEXT CHECKPOINT
By {time}: [ ] {definition of done for next block}
Escalations needed: {who + what}

Email -> Meetings extraction rules
- Inputs: emails since last brief.
- Detect meeting items via:
  - Calendar invites (.ics), "invitation", "accepted/updated/canceled", "rescheduled",
    Zoom/Meet links, "When:" blocks, or "Proposed times".
- For each meeting, extract:
  - Start/end time (timezone), title, organizer, attendees, location/link,
    agenda/context, attachments/links.
- Status: new / updated / canceled.
- Confidence: high if .ics, medium if plain text proposal.

Meeting <-> Task cross-reference rules
- If a meeting has prep, create task: "Prep: {meeting}" due 30-60 min before.
- If a meeting implies deliverable, create/attach task: "{deliverable} for {meeting}".
- If email contains commitment ("I will...", "Can you...", "Please send..."), create task
  and link it to relevant meeting/thread.
- Dedupe keys: same meeting title + time + organizer OR same email thread id.
- If task already exists, update with due time, link, and "why now".

Always surface this checklist
- Decision points with defaults (A/B + recommended).
- Prep for next meeting block (15-min list).
- Follow-ups generated from latest threads.
- Blockers + explicit next unblock step.
- Drop list (one thing to defer to protect P0).

Sanity checks every run
- No duplicate meetings listed (same title/time).
- Every meeting in next block has prep OR explicitly says "No prep needed".
- Every "Please/Can you/I will" email line becomes task (or explicitly dismissed).
- P0 list is <= 3 items; everything else goes to P1/P2.
EOF
 
if [ "$BRIEF_PROFILE" = "ops" ]; then
  load_heredoc ROLE_GUARDRAILS <<'EOF'
ROLE GUARDRAILS (MANDATORY)
- Active role: Chief of Staff (operations, execution, prioritization, accountability).
- Do not perform brand/campaign creative execution as primary work. If marketing execution is required, create a handoff task to CMO.
- If a request is out of scope for CoS, create exactly one handoff item in SHARED_KANBAN.md and continue only with CoS-owned work.
- Namespace discipline (same Google Workspace account): use OPS-prefixed titles/tags.
  - Calendar summary prefix: "OPS:"
  - Docs title prefix: "OPS_"
  - Task tags: [OPS], [EXEC], [ADMIN]
- Never rewrite CMO backlog items unless marked "Needs CoS unblock".
EOF
else
  load_heredoc ROLE_GUARDRAILS <<'EOF'
ROLE GUARDRAILS (MANDATORY)
- Active role: CMO (marketing strategy, campaigns, content, narrative, growth).
- Do not perform CoS operational ownership as primary work. If ops execution is required, create a handoff task to CoS.
- If a request is out of scope for CMO, create exactly one handoff item in SHARED_KANBAN.md and continue only with CMO-owned work.
- Namespace discipline (same Google Workspace account): use MKT-prefixed titles/tags.
  - Calendar summary prefix: "MKT:"
  - Docs title prefix: "MKT_"
  - Task tags: [MKT], [CONTENT], [GROWTH]
- Never rewrite CoS backlog items unless marked "Needs CMO input".
EOF
fi


load_heredoc AM_VARIANT <<'EOF'
Brief type behavior
- BRIEF 1 - AM Plan (07:30 CT)
- Emphasis: top outcomes, time blocks, what to prep first.
- Add this section before section 1:

0) TOP 3 OUTCOMES (Today)
- {Outcome} - Metric: {...}
- {Outcome} - Metric: {...}
- {Outcome} - Metric: {...}
EOF
 

load_heredoc MIDDAY_VARIANT <<'EOF'
Brief type behavior
- BRIEF 2 - Midday Replan (12:30 CT)
- Emphasis: progress, reprioritization, prep for next 4-6 hours.
- Add this section before section 1:

0) MIDDAY SCOREBOARD
On track: {...}
At risk: {...}
Kill/Defer: {one thing to drop}
EOF
 

load_heredoc AFTERNOON_VARIANT <<'EOF'
Brief type behavior
- BRIEF 3 - Afternoon Prep & Follow-ups (16:30 CT)
- Emphasis: convert meetings -> tasks, capture follow-ups, clear inbox.
- Add this section before section 1:

0) FOLLOW-UPS GENERATED (From meetings + threads)
- [ ] {follow-up} - To: {person} - Due: {time} - Context: {meeting/thread}
EOF
 

load_heredoc EOD_VARIANT <<'EOF'
Brief type behavior
- BRIEF 4 - EOD Closeout (20:30 CT)
- Emphasis: wins, open loops, tomorrow setup.
- Add this section after section 6:

7) EOD REPORT
Wins: {...}
Open loops: {...}
Tomorrow Top 3 (preloaded):
- [ ] {...}
- [ ] {...}
- [ ] {...}
EOF
 

build_prompt() {
  local brief_type="$1"
  local horizon="$2"
  local variant="$3"

  printf '%s\n\n%s\n\n%s\n\nRUN CONTEXT:\nProfile: %s\nAgent: %s\nBrief type: %s\nTime horizon for meetings: %s\nToday theme: pull from SHARED_KANBAN.md + SHARED_SECOND_BRAIN.md.\n\nAt the very bottom as a single line:\nSTATE_UPDATE: last_brief_timestamp=...\n' \
    "$COMMON_PROMPT" "$ROLE_GUARDRAILS" "$variant" "$PROFILE_LABEL" "$AGENT_ID" "$brief_type" "$horizon"
}

AM_PROMPT="$(build_prompt "AM Plan" "8h" "$AM_VARIANT")"
MIDDAY_PROMPT="$(build_prompt "Midday Replan" "6h" "$MIDDAY_VARIANT")"
AFTERNOON_PROMPT="$(build_prompt "Afternoon Prep" "6h" "$AFTERNOON_VARIANT")"
EOD_PROMPT="$(build_prompt "EOD Closeout" "rest_of_day" "$EOD_VARIANT")"

NOW_MS="$(($(date +%s) * 1000))"
TMP_FILE="$(mktemp)"

jq \
  --argjson now "$NOW_MS" \
  --arg agent "$AGENT_ID" \
  --arg tz "$TZ_NAME" \
  --arg id_prefix "$ID_PREFIX" \
  --arg name_prefix "$NAME_PREFIX" \
  --arg profile "$PROFILE_LABEL" \
  --arg am_expr "$AM_CRON_EXPR" \
  --arg midday_expr "$MIDDAY_CRON_EXPR" \
  --arg afternoon_expr "$AFTERNOON_CRON_EXPR" \
  --arg eod_expr "$EOD_CRON_EXPR" \
  --arg am "$AM_PROMPT" \
  --arg midday "$MIDDAY_PROMPT" \
  --arg afternoon "$AFTERNOON_PROMPT" \
  --arg eod "$EOD_PROMPT" \
  '
  def managed_ids($prefix): [
    ($prefix + "-am-plan"),
    ($prefix + "-midday-replan"),
    ($prefix + "-afternoon-prep"),
    ($prefix + "-eod-closeout")
  ];
  def managed_names($prefix): [
    ($prefix + " 1 - AM Plan"),
    ($prefix + " 2 - Midday Replan"),
    ($prefix + " 3 - Afternoon Prep & Follow-ups"),
    ($prefix + " 4 - EOD Closeout")
  ];
  def legacy_ids: ["brief-am-plan","brief-midday-replan","brief-afternoon-prep","brief-eod-closeout"];
  def legacy_names: [
    "Morning Email Briefing (7am CST)",
    "Midday Email Briefing (12pm CST)",
    "Evening Email Briefing (5pm CST)",
    "Night Email Briefing (10pm CST)",
    "BRIEF 1 - AM Plan",
    "BRIEF 2 - Midday Replan",
    "BRIEF 3 - Afternoon Prep & Follow-ups",
    "BRIEF 4 - EOD Closeout"
  ];
  def existing_by_id($root; $id):
    (first(($root.jobs // [])[]? | select(.id == $id)) // {});
  def mkjob($root; $id; $name; $expr; $message):
    (existing_by_id($root; $id)) as $old
    | {
        id: $id,
        agentId: $agent,
        name: $name,
        description: ("Auto-managed " + $profile + " daily brief cadence (America/Chicago)"),
        enabled: true,
        deleteAfterRun: false,
        createdAtMs: ($old.createdAtMs // $now),
        updatedAtMs: $now,
        schedule: { kind: "cron", expr: $expr, tz: $tz },
        sessionTarget: "isolated",
        wakeMode: "next-heartbeat",
        payload: {
          kind: "agentTurn",
          message: $message,
          thinking: "low",
          timeoutSeconds: 1200,
          deliver: true,
          channel: "last",
          bestEffortDeliver: true
        },
        isolation: {
          postToMainPrefix: "Cron",
          postToMainMode: "summary",
          postToMainMaxChars: 8000
        },
        state: ($old.state // {})
      };

  . as $root
  | .version = 1
  | .jobs = (
      ($root.jobs // [])
      | map(
          select(
            (
              (.id as $job_id | (managed_ids($id_prefix) | index($job_id)) == null)
            )
            and
            (
              ((.id as $job_id | (legacy_ids | index($job_id)) == null) or ((.agentId // "") != $agent))
            )
            and
            (
              ((.name // "") as $job_name | (managed_names($name_prefix) | index($job_name)) == null)
              or ((.agentId // "") != $agent)
            )
            and
            (
              ((.name // "") as $legacy_name | (legacy_names | index($legacy_name)) == null)
              or ((.agentId // "") != $agent)
            )
          )
        )
      + [
          mkjob($root; ($id_prefix + "-am-plan"); ($name_prefix + " 1 - AM Plan"); $am_expr; $am),
          mkjob($root; ($id_prefix + "-midday-replan"); ($name_prefix + " 2 - Midday Replan"); $midday_expr; $midday),
          mkjob($root; ($id_prefix + "-afternoon-prep"); ($name_prefix + " 3 - Afternoon Prep & Follow-ups"); $afternoon_expr; $afternoon),
          mkjob($root; ($id_prefix + "-eod-closeout"); ($name_prefix + " 4 - EOD Closeout"); $eod_expr; $eod)
        ]
    )
  ' "$JOBS_FILE" > "$TMP_FILE"

# Validate the candidate JSON and avoid churn if nothing actually changed.
jq '.' "$TMP_FILE" >/dev/null

CANON_OLD="$(mktemp)"
CANON_NEW="$(mktemp)"
jq -S -c '.' "$JOBS_FILE" > "$CANON_OLD" 2>/dev/null || printf '%s\n' '' > "$CANON_OLD"
jq -S -c '.' "$TMP_FILE" > "$CANON_NEW" 2>/dev/null || printf '%s\n' '' > "$CANON_NEW"

if cmp -s "$CANON_OLD" "$CANON_NEW"; then
  rm -f "$TMP_FILE" "$CANON_OLD" "$CANON_NEW"
  echo "Daily brief cron jobs already up to date in ${JOBS_FILE}"
  exit 0
fi

rm -f "$CANON_OLD" "$CANON_NEW"

SNAPSHOT="${JOBS_FILE}.pre-brief.$(date +%s).bak"
cp "$JOBS_FILE" "$SNAPSHOT" 2>/dev/null || true

mv "$TMP_FILE" "$JOBS_FILE"
jq '.' "$JOBS_FILE" >/dev/null

# Keep the cron directory tidy: retain only a small tail of pre-brief snapshots.
shopt -s nullglob
snapshots=( "$CRON_DIR"/jobs.json.pre-brief.*.bak )
if [ "${#snapshots[@]}" -gt 5 ]; then
  IFS=$'\n' sorted=( $(printf '%s\n' "${snapshots[@]}" | sort) )
  unset IFS
  delete_count=$((${#sorted[@]} - 5))
  for ((i=0; i<delete_count; i++)); do
    rm -f "${sorted[$i]}" 2>/dev/null || true
  done
fi
shopt -u nullglob

echo "Configured daily brief cron jobs (4x/day, ${TZ_NAME}) in ${JOBS_FILE}"
echo "Profile: ${PROFILE_LABEL} | Agent: ${AGENT_ID} | Prefix: ${ID_PREFIX}"
echo "Backup snapshot: ${SNAPSHOT}"
