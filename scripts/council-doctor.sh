#!/bin/sh
# Checks that plan-council can actually run here, and which models answer.
#
# Usage: council-doctor.sh [--root DIR] [--no-model-check]
#   --root DIR        the context root whose config to check. Default: .
#   --no-model-check  skip the live model probe (it makes one tiny request
#                     per distinct Claude model and costs a little)
#
# The model probe exists because a pinned model that silently falls back to
# another is the failure model pinning is meant to prevent. It asks each
# model for one word with JSON output and prints every model ID the CLI
# reports having used, so you can see whether the one you asked for is there.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,12p' "$SCRIPT_DIR/council-doctor.sh" | sed 's/^# \{0,1\}//'; }

ROOT="."
PROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || council_die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --no-model-check) PROBE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) council_die "unknown option: $1" ;;
  esac
done
ROOT=$(council_absdir "$ROOT") || council_die "context root not found: $ROOT"

PROBLEMS=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '  note  %s\n' "$*"; }

echo "Scripts"
for s in "$SCRIPT_DIR"/*.sh; do
  if command -v bash >/dev/null 2>&1; then
    bash -n "$s" 2>/dev/null && ok "bash -n $(basename "$s")" || bad "bash -n $(basename "$s")"
  else
    sh -n "$s" 2>/dev/null && ok "sh -n $(basename "$s")" || bad "sh -n $(basename "$s")"
  fi
done

echo "Config"
council_load_config "$ROOT" "$PLUGIN_ROOT"
ok "loaded $COUNCIL_CONFIG_USED"
( council_check_planners ) 2>/dev/null && ok "planners: $COUNCIL_PLANNERS" || bad "planners: run council-plan.sh to see why ($COUNCIL_PLANNERS)"
type arbiter >/dev/null 2>&1 && ok "arbiter function defined" || bad "no arbiter function"
[ -n "$COUNCIL_RISK_FLOOR" ] && ok "risk floor: $COUNCIL_RISK_FLOOR" || bad "COUNCIL_RISK_FLOOR is empty"

echo "Tools"
for tool in claude codex; do
  if grep -v '^[[:space:]]*#' "$COUNCIL_CONFIG_USED" | grep -q "$tool "; then
    used=1
  else
    used=0
  fi
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool: $("$tool" --version 2>/dev/null | head -n 1)"
  elif [ "$used" -eq 1 ]; then
    case " $COUNCIL_PLANNERS " in
      *" $tool "*) bad "$tool is a configured planner but is not installed (see the no-Codex setup in the README)" ;;
      *) note "$tool is not installed (not a configured planner)" ;;
    esac
  else
    note "$tool is not installed"
  fi
done
for t in git awk sed mktemp cmp; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || bad "$t is missing"
done

echo "Agents (models pinned in frontmatter)"
for f in "$PLUGIN_ROOT"/agents/*.md; do
  m=$(tr -d '\r' < "$f" | sed -n 's/^model:[[:space:]]*//p' | head -n 1)
  [ -n "$m" ] && ok "$(basename "$f" .md): $m" || bad "$(basename "$f" .md) pins no model"
done

if [ "$PROBE" -eq 1 ] && command -v claude >/dev/null 2>&1; then
  echo "Model probe (asked for -> reported in usage)"
  MODELS=$( {
    grep -v '^[[:space:]]*#' "$COUNCIL_CONFIG_USED" | sed -n 's/.*--model[[:space:]]\{1,\}\([A-Za-z0-9._-]*\).*/\1/p'
    for f in "$PLUGIN_ROOT"/agents/*.md; do
      tr -d '\r' < "$f" | sed -n 's/^model:[[:space:]]*//p' | head -n 1
    done
  } | sort -u )
  for m in $MODELS; do
    json=$(printf 'Reply with the single word ok.' | claude -p --model "$m" --output-format json 2>&1)
    reported=$(printf '%s' "$json" | grep -o '"claude-[A-Za-z0-9._-]*"' | tr -d '"' | sort -u | tr '\n' ' ')
    case " $reported" in
      *" $m"*) ok "$m -> $reported" ;;
      *)
        if [ -z "$reported" ]; then
          bad "$m -> no model ID found in the JSON output. First 200 chars: $(printf '%s' "$json" | tr '\n' ' ' | cut -c1-200)"
        else
          bad "$m -> $reported (the requested ID is not among them: check for a fallback or an alias)"
        fi ;;
    esac
  done
  note "Other models in the list (often a small one) are the CLI's own background calls, not a fallback."
  note "To check by hand: printf 'ok' | claude -p --model <id> --output-format json"
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
  echo "plan-council: all checks passed"
else
  echo "plan-council: $PROBLEMS problem(s) found"
  exit 1
fi
