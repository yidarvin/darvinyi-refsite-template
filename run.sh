#!/usr/bin/env bash
# run.sh -- stage-aware driver for the build-critique loop on a queue-driven refsite.
#
# A chapter moves pending -> draft -> done. The builder takes it from pending to
# draft (research, write, gate, commit). A separate critique pass, run in its own
# `claude -p` process with no memory of the build, takes it from draft to done by
# writing a verdict to content/critiques/<slug>.md; a "revise" verdict sends it
# back to the builder to resolve, which the driver always does before starting
# any new chapter. scripts/decide.py reads content/registry.json, prompts/queue.md,
# and every content/critiques/*.md to compute the single next stage; this script
# just runs it and gates the result.
#
# Usage:
#   ./run.sh                      same as: ./run.sh next
#   ./run.sh next     [options]   decide the single next stage and run it
#   ./run.sh loop [N] [options]   keep running stages (default: unbounded) until
#                                 done, a validation error, or a stall; N caps the
#                                 number of STAGES run, not chapters -- a chapter
#                                 typically costs 3+ stages (build, critique, and
#                                 any resolve rounds)
#   ./run.sh status               local dashboard (no claude invoked)
#   ./run.sh build    [options]   force one builder stage
#   ./run.sh critique [options]   force one critic stage
#
#   -m, --model MODEL    override BOTH $BUILD_MODEL and $CRITIC_MODEL for this run
#   -e, --effort LEVEL   claude effort (default: ultracode). One of low|medium|high|
#                        xhigh|max|ultracode. "ultracode" = xhigh + dynamic workflows
#                        and needs claude >= 2.1.203 (older builds ignore it).
#   -p, --prompt TEXT    override the stage's default prompt (build/critique only;
#                        the stage varies for next/loop, so -p is refused there)
#   -s, --settings VAL   path or JSON for claude --settings (default: none)
#   -t, --timeout SEC    kill a single claude run after SEC seconds (needs `timeout`
#                        or `gtimeout`; default: 0 = no limit)
#       --push           commit AND push each stage (default: commit only)
#       --no-check       skip the `npm run check` second gate (not recommended)
#       --allow-dirty    do not require a clean git working tree
#       --dry-run        print the resolved plan and command, then run nothing
#   -y, --yes            do not ask for confirmation before an unbounded loop
#   -h, --help           show this help and exit
#
# Env vars: BUILD_MODEL and CRITIC_MODEL (default claude-sonnet-5 for both) set
# the model per role; -m/--model overrides both for this invocation only.
#
# Exit status: 0 when the requested work finished cleanly (a stage completed, the
# loop reached "done", or the N-stage limit was reached); 1 when the loop stopped
# for review; 2 on a usage error; 130 on an interrupt.

BUILD_MODEL="${BUILD_MODEL:-claude-sonnet-5}"
CRITIC_MODEL="${CRITIC_MODEL:-claude-sonnet-5}"
# Under ultracode a stage can spawn long-running background workflows (review
# fleets, verification panels) that outlast the default 600s background-wait
# ceiling. When that ceiling trips, claude terminates its still-running work and
# returns exit 0 -- a false success: the stage is recorded as clean and the loop
# marches on having produced nothing. 0 = wait indefinitely for the stage's own
# background tasks to finish. Override with a millisecond ceiling if ever needed.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"

set -uo pipefail

# --- defaults ---------------------------------------------------------------
EFFORT='ultracode'   # effort level; ultracode = xhigh + dynamic workflows (claude >= 2.1.203)
MODEL_OVERRIDE=''    # -m/--model: overrides BOTH BUILD_MODEL and CRITIC_MODEL
SETTINGS=''          # optional path/JSON for claude --settings (empty = omit)
PROMPT_OVERRIDE=''
PROMPT_OVERRIDE_SET=0
PUSH=0
RUN_CHECK=1
ALLOW_DIRTY=0
DRY_RUN=0
ASSUME_YES=0
TIMEOUT=0            # seconds; 0 disables the per-stage wall-clock limit
TIMEOUT_BIN=''
LOOP_MAX=''          # empty means unbounded for `loop`

usage() { sed -n '2,/^# Exit status/{/^# Exit status/d;s/^# \{0,1\}//;p;}' "$0"; }

die() { printf '\033[31m%s\033[0m\n' "run.sh: $*" >&2; exit 2; }

# A positive-integer argument, normalized (no leading zeros, no octal, no overflow).
parse_count() {
  local flag="$1" val="$2"
  case "$val" in ''|*[!0-9]*) die "$flag needs a positive integer, got '$val'";; esac
  [ "${#val}" -le 9 ] || die "$flag value '$val' is out of range"
  local n=$((10#$val))
  [ "$n" -ge 1 ] || die "$flag must be at least 1"
  printf '%s' "$n"
}

# --- parse verb + options together ---------------------------------------
# The verb (next|loop|status|build|critique) may appear anywhere among the
# flags, e.g. both `./run.sh --dry-run next` and `./run.sh next --dry-run`
# work: every flag below either takes no value or has a fixed arity, so a
# single pass can tell the verb apart from a flag's own value.
VERB=''
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)     [ $# -ge 2 ] || die "$1 needs a value"; MODEL_OVERRIDE="$2"; shift 2 ;;
    -e|--effort)    [ $# -ge 2 ] || die "$1 needs a value"; EFFORT="$2"; shift 2 ;;
    -p|--prompt)    [ $# -ge 2 ] || die "$1 needs a value"; PROMPT_OVERRIDE="$2"; PROMPT_OVERRIDE_SET=1; shift 2 ;;
    -s|--settings)  [ $# -ge 2 ] || die "$1 needs a value"; SETTINGS="$2"; shift 2 ;;
    -t|--timeout)   [ $# -ge 2 ] || die "$1 needs a value"; TIMEOUT="$(parse_count "$1" "$2")"; shift 2 ;;
    --push)         PUSH=1; shift ;;
    --no-check)     RUN_CHECK=0; shift ;;
    --allow-dirty)  ALLOW_DIRTY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --no-push)      printf '\033[33m%s\033[0m\n' "run.sh: --no-push is gone; not pushing is now the default. Pass --push to opt in." >&2; shift ;;
    -n|--count|-a|--all)
                    die "$1 is gone; use 'loop N' instead of -n/--count, and bare 'loop' instead of -a/--all" ;;
    -q|--queue)     die "-q/--queue is gone; state now lives in content/registry.json, prompts/queue.md, and content/critiques/" ;;
    --)             shift; break ;;
    next|loop|status|build|critique)
                    [ -z "$VERB" ] || die "verb given twice: '$VERB' and '$1'"
                    VERB="$1"; shift
                    # `loop` takes an optional trailing stage-count, e.g. `loop 6`.
                    if [ "$VERB" = "loop" ] && [ $# -gt 0 ]; then
                      case "$1" in
                        ''|*[!0-9]*) ;;  # not a number; leave it for this same loop
                        *) LOOP_MAX="$(parse_count 'loop N' "$1")"; shift ;;
                      esac
                    fi
                    ;;
    -*)             die "unknown option '$1' (try --help)" ;;
    *)              die "unexpected argument '$1' (try --help)" ;;
  esac
done
[ -n "$VERB" ] || VERB='next'

if [ "$PROMPT_OVERRIDE_SET" -eq 1 ] && { [ "$VERB" = "next" ] || [ "$VERB" = "loop" ]; }; then
  die "-p/--prompt is only valid with 'build' or 'critique' (the stage varies for next/loop)"
fi

if [ -n "$MODEL_OVERRIDE" ]; then
  BUILD_MODEL="$MODEL_OVERRIDE"
  CRITIC_MODEL="$MODEL_OVERRIDE"
fi

# Validate the effort level up front rather than let claude silently ignore a typo and
# run every stage at the default. "ultracode" (xhigh + automatic dynamic workflows) is
# a real --effort value, but only on claude >= 2.1.203; on older builds it is ignored
# and falls back to default effort, so warn instead of failing quietly. Skipped for
# `status`, which never invokes claude.
if [ "$VERB" != "status" ]; then
  case "$EFFORT" in
    low|medium|high|xhigh|max) ;;
    ultracode)
      ccver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      if [ -n "$ccver" ] && [ "$(printf '%s\n%s\n' 2.1.203 "$ccver" | sort -V | head -1)" != "2.1.203" ]; then
        printf '\033[33m%s\033[0m\n' "run.sh: claude $ccver predates --effort ultracode (needs >= 2.1.203); it will be ignored and default effort used. Pass -e xhigh for the reasoning half without workflows." >&2
      fi ;;
    *) die "invalid --effort '$EFFORT' (valid: low, medium, high, xhigh, max, ultracode)" ;;
  esac
fi

# --- move to the repo root (this script lives there) ------------------------
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || die "cannot resolve script directory"
cd "$SCRIPT_DIR" || die "cannot cd to $SCRIPT_DIR"

# --- preflight --------------------------------------------------------------
[ -f prompts/queue.md ] || die "prompts/queue.md not found (run from a refsite repo)"
[ -r prompts/queue.md ] || die "prompts/queue.md is not readable"
[ -f content/registry.json ] || printf '\033[33m%s\033[0m\n' "run.sh: warning: content/registry.json not found; is this a refsite repo?" >&2
command -v python3 >/dev/null 2>&1 || die "'python3' is not on PATH (needed for scripts/decide.py)"

if [ "$VERB" != "status" ]; then
  command -v claude >/dev/null 2>&1 || die "the 'claude' CLI is not on PATH"
  if [ "$RUN_CHECK" -eq 1 ]; then
    command -v npm >/dev/null 2>&1 || die "'npm' is not on PATH (needed for the check gate; pass --no-check to skip)"
  fi
  if [ "$TIMEOUT" -gt 0 ]; then
    if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
    elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
    else die "--timeout needs 'timeout' or 'gtimeout' on PATH (brew install coreutils)"; fi
  fi
fi

# Is this a git work tree? The commit/push and clean-tree guards only apply if so.
HAVE_GIT=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && HAVE_GIT=1
tree_dirty() { [ -n "$(git status --porcelain 2>/dev/null)" ]; }

# An auto-committing loop must start from a clean tree, or it can fold stray local
# changes into an unrelated chapter's commit.
if [ "$VERB" != "status" ] && [ "$HAVE_GIT" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 0 ] && tree_dirty; then
  die "working tree has uncommitted changes. Commit or stash them first, or pass --allow-dirty."
fi

mkdir -p .pipeline

# --- fingerprint: HEAD + working tree + every state surface -----------------
# Two consecutive `loop` iterations that decide the same action AND leave this
# fingerprint unchanged mean the stage ran but produced no committed progress
# (a clean no-op, or a stage that silently swallowed its own failure).
fingerprint() {
  { git rev-parse HEAD 2>/dev/null || echo none
    git status --porcelain 2>/dev/null | grep -v '^.. \.pipeline/'
    shasum content/registry.json prompts/queue.md 2>/dev/null
    find content/critiques -name '*.md' 2>/dev/null | sort | xargs shasum 2>/dev/null
  } | shasum | awk '{print $1}'
}

# --- counts helper ------------------------------------------------------
# Pull one field out of `decide.py counts`'s "k=v k=v ..." line. Anchored on a
# leading space or string-start so "draft=" never matches inside "approved_draft=".
count_field() {
  local v
  v="$(printf '%s' "$1" | grep -oE "(^|[[:space:]])$2=[0-9]+" | grep -oE '[0-9]+$')"
  printf '%s' "${v:-0}"
}

# A stage is only progress if it moved the state machine forward. Replaces the
# old DONE+SKIPPED-going-up counter, which is meaningless now that a build no
# longer flips the queue row -- it goes to registry 'draft', not queue 'DONE'.
progressed() {
  local stage="$1" before="$2" after="$3" b a
  case "$stage" in
    build)
      b=$(( $(count_field "$before" draft) + $(count_field "$before" done) ))
      a=$(( $(count_field "$after" draft) + $(count_field "$after" done) ))
      [ "$a" -gt "$b" ] ;;
    resolve)
      b="$(count_field "$before" revise)"; a="$(count_field "$after" revise)"
      [ "$a" -lt "$b" ] ;;
    critique)
      local b_rd a_rd b_un a_un
      b_rd=$(( $(count_field "$before" revise) + $(count_field "$before" done) ))
      a_rd=$(( $(count_field "$after" revise) + $(count_field "$after" done) ))
      b_un="$(count_field "$before" unreviewed)"; a_un="$(count_field "$after" unreviewed)"
      [ "$a_rd" -gt "$b_rd" ] || [ "$a_un" -lt "$b_un" ] ;;
    *) return 0 ;;
  esac
}

# --- stage model/prompt --------------------------------------------------
stage_model() {
  case "$1" in critique) printf '%s' "$CRITIC_MODEL" ;; *) printf '%s' "$BUILD_MODEL" ;; esac
}

stage_prompt() {
  local tail='commit the changes.'
  [ "$PUSH" -eq 1 ] && tail='commit and push the changes.'
  case "$1" in
    build)    printf '%s' "run the next one. $tail" ;;
    resolve)  printf '%s' "resolve open critiques. $tail" ;;
    critique) printf '%s' "critique the next built chapter. $tail" ;;
  esac
}

announce_plan() {
  local stage="$1" model prompt args=()
  model="$(stage_model "$stage")"
  if [ "$PROMPT_OVERRIDE_SET" -eq 1 ]; then prompt="$PROMPT_OVERRIDE"; else prompt="$(stage_prompt "$stage")"; fi
  args=( -p "$prompt" --model "$model" --effort "$EFFORT" --dangerously-skip-permissions )
  [ -n "$SETTINGS" ] && args+=( --settings "$SETTINGS" )
  printf '\033[1m%s\033[0m\n' "run.sh plan"
  printf '  verb:     %s\n' "$VERB"
  printf '  stage:    %s\n' "$stage"
  printf '  models:   build=%s critic=%s\n' "$BUILD_MODEL" "$CRITIC_MODEL"
  printf '  effort:   %s\n' "$EFFORT"
  [ -n "$SETTINGS" ] && printf '  settings: %s\n' "$SETTINGS"
  printf '  timeout:  %s\n' "$([ "$TIMEOUT" -gt 0 ] && echo "${TIMEOUT}s (${TIMEOUT_BIN})" || echo 'none')"
  printf '  gate:     %s\n' "$([ "$RUN_CHECK" -eq 1 ] && echo 'npm run check after the stage' || echo 'skipped (--no-check)')"
  printf '  push:     %s\n' "$([ "$PUSH" -eq 1 ] && echo 'yes (--push)' || echo 'no (commit only)')"
  printf '  command:  claude %s\n' "$(printf '%q ' "${args[@]}")"
}

# --- signal handling and the claude runner ----------------------------------
# Track the child so a Ctrl-C or a `kill` of a detached loop tears down the
# running claude too, instead of orphaning it to keep committing on its own.
CHILD_PID=''
on_signal() {
  printf '\n\033[33m%s\033[0m\n' "run.sh: interrupted; stopping."
  if [ -n "$CHILD_PID" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  exit 130
}
trap on_signal INT TERM

# Runs the stage in CLAUDE_ARGS. stdin is detached from /dev/null so no tool can
# block on or steal input, and the run is backgrounded with a tracked pid (see
# on_signal). Returns claude's exit status; 124 signals a timeout when --timeout
# is in effect.
run_claude() {
  if [ "$TIMEOUT" -gt 0 ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" claude "${CLAUDE_ARGS[@]}" </dev/null &
  else
    claude "${CLAUDE_ARGS[@]}" </dev/null &
  fi
  CHILD_PID=$!
  wait "$CHILD_PID"
  local rc=$?
  CHILD_PID=''
  return "$rc"
}

# Runs one stage end to end: announce, (dry-run stops here), invoke claude, gate
# on a clean commit, gate on `npm run check`, gate on the state machine having
# actually moved. $1 = stage (build|resolve|critique), $2 = slug for the log
# (optional; "-" when the driver did not choose it, e.g. a forced verb).
run_stage() {
  local stage="$1" slug="${2:--}" model prompt args=()
  announce_plan "$stage"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n\033[33m%s\033[0m\n' "dry run: nothing was executed."
    return 0
  fi

  model="$(stage_model "$stage")"
  if [ "$PROMPT_OVERRIDE_SET" -eq 1 ]; then prompt="$PROMPT_OVERRIDE"; else prompt="$(stage_prompt "$stage")"; fi
  args=( -p "$prompt" --model "$model" --effort "$EFFORT" --dangerously-skip-permissions )
  [ -n "$SETTINGS" ] && args+=( --settings "$SETTINGS" )
  CLAUDE_ARGS=( "${args[@]}" )
  export CLAUDE_CODE_SUBAGENT_MODEL="$model"

  printf '\n\033[1m\033[36m==== running: %s  (%s) ====\033[0m\n' "$stage" "$(date '+%Y-%m-%d %H:%M:%S')"

  local before_counts
  before_counts="$(python3 scripts/decide.py counts 2>/dev/null || true)"

  run_claude; local rc=$?
  printf '%s stage=%s slug=%s rc=%s\n' "$(date '+%F %T')" "$stage" "$slug" "$rc" >> .pipeline/log

  if [ "$rc" -ne 0 ]; then
    if [ "$TIMEOUT" -gt 0 ] && [ "$rc" -eq 124 ]; then
      printf '\n\033[31m%s\033[0m\n' "claude exceeded the ${TIMEOUT}s timeout on stage '$stage'; stopping for review."
    else
      printf '\n\033[31m%s\033[0m\n' "claude exited $rc on stage '$stage'; stopping for review."
    fi
    return 1
  fi

  # After a successful stage the tree should be clean (the stage was committed).
  # A dirty tree means the stage worked but did not commit; do not build on it.
  if [ "$HAVE_GIT" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 0 ] && tree_dirty; then
    printf '\n\033[31m%s\033[0m\n' "stage '$stage' left uncommitted changes; stopping for review."
    return 1
  fi

  if [ "$RUN_CHECK" -eq 1 ]; then
    if ! npm run check; then
      printf '\n\033[31m%s\033[0m\n' "npm run check failed after stage '$stage'; stopping for review."
      return 1
    fi
  fi

  local after_counts
  after_counts="$(python3 scripts/decide.py counts 2>/dev/null || true)"
  if ! progressed "$stage" "$before_counts" "$after_counts"; then
    printf '\n\033[31m%s\033[0m\n' "no progress on stage '$stage'; stopping to avoid an infinite loop."
    printf '  before: %s\n  after:  %s\n' "$before_counts" "$after_counts"
    return 1
  fi

  return 0
}

# --- decide.py wrapper ----------------------------------------------------
DECIDED_ACTION=''
DECIDED_SLUG=''
DECIDED_REASON=''

decide_and_print() {
  local out
  out="$(python3 scripts/decide.py next)" || die "scripts/decide.py failed to run"
  printf '%s\n' "$out"
  DECIDED_ACTION="$(printf '%s' "$out" | awk '{print $2}')"
  DECIDED_SLUG="$(printf '%s' "$out" | awk '{print $3}')"
  DECIDED_REASON="${out#*:: }"
}

# --- dispatch ---------------------------------------------------------------
case "$VERB" in
  status)
    python3 scripts/decide.py status
    exit 0
    ;;

  next)
    decide_and_print
    case "$DECIDED_ACTION" in
      done)  printf '\n\033[32m%s\033[0m\n' "nothing left to do: $DECIDED_REASON"; exit 0 ;;
      error) printf '\n\033[31m%s\033[0m\n' "$DECIDED_REASON"; exit 1 ;;
      *)     run_stage "$DECIDED_ACTION" "$DECIDED_SLUG" || exit 1; exit 0 ;;
    esac
    ;;

  build|critique)
    run_stage "$VERB" '-' || exit 1
    exit 0
    ;;

  loop)
    # An unbounded, permission-skipping loop is a big commitment; confirm when a
    # human is watching. Redirected/headless invocations (no TTY) proceed without
    # prompting, which is the whole point of an unattended loop.
    if [ -z "$LOOP_MAX" ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
      printf '\n%s\n' "outstanding: $(python3 scripts/decide.py counts)"
      printf '%s ' "About to loop with no limit, running build/critique/resolve stages with --dangerously-skip-permissions until done. Continue? [y/N]"
      read -r reply
      case "$reply" in [Yy]|[Yy][Ee][Ss]) ;; *) echo "aborted."; exit 0 ;; esac
    fi

    prev_key=''
    i=0
    while :; do
      if [ -n "$LOOP_MAX" ] && [ "$i" -ge "$LOOP_MAX" ]; then
        printf '\n\033[32m%s\033[0m\n' "reached limit of $LOOP_MAX stage(s)."
        exit 0
      fi
      i=$((i + 1))
      printf '\n\033[1m\033[36m==== loop step %d%s ====\033[0m\n' "$i" "$([ -n "$LOOP_MAX" ] && echo "/$LOOP_MAX" || echo '')"

      decide_and_print
      case "$DECIDED_ACTION" in
        done)
          printf '\n\033[32m%s\033[0m\n' "queue drained and every chapter critique-approved. Ran $((i - 1)) stage(s)."
          exit 0 ;;
        error)
          printf '\n\033[31m%s\033[0m\n' "$DECIDED_REASON"
          exit 1 ;;
      esac

      if [ "$DRY_RUN" -eq 1 ]; then
        run_stage "$DECIDED_ACTION" "$DECIDED_SLUG"
        exit 0
      fi

      key="$DECIDED_ACTION $DECIDED_SLUG|$(fingerprint)"
      if [ "$key" = "$prev_key" ]; then
        printf '\n\033[31m%s\033[0m\n' "no progress: '$DECIDED_ACTION $DECIDED_SLUG' would run again with nothing changed. Stopping instead of burning another stage. Investigate with:"
        printf '  ./run.sh status\n  tail .pipeline/log\n'
        exit 1
      fi
      prev_key="$key"

      run_stage "$DECIDED_ACTION" "$DECIDED_SLUG" || exit 1
    done
    ;;
esac
