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

echo "Which copy is running"
MYVER=$(tr -d '\r' < "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
ok "this one: $PLUGIN_ROOT (version ${MYVER:-unknown})"
# Other copies matter because ${CLAUDE_PLUGIN_ROOT} does not resolve, so the
# commands fall back to a Glob under ~/.claude/plugins/ -- and that returns the
# installed version, the marketplace clone, AND every older release still in
# the cache. Measured 2026-11-14: three copies, one of them a previous release.
# An uninstall does not clear the cache, so the stale one outlives it.
HOMEDIR=${HOME:-${USERPROFILE:-}}
if [ -n "$HOMEDIR" ] && [ -d "$HOMEDIR/.claude/plugins" ]; then
  COPYLIST=$(mktemp 2>/dev/null || mktemp -t plancouncil) || COPYLIST=""
  if [ -n "$COPYLIST" ]; then
    find "$HOMEDIR/.claude/plugins" -name 'council-doctor.sh' 2>/dev/null > "$COPYLIST"
    OTHERS=0
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      odir=$(dirname "$(dirname "$other")")
      [ "$odir" = "$PLUGIN_ROOT" ] && continue
      over=$(tr -d '\r' < "$odir/.claude-plugin/plugin.json" 2>/dev/null \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      note "another copy: $odir (version ${over:-unknown})"
      OTHERS=$((OTHERS + 1))
      # The dangerous case the version rule cannot catch: two copies that
      # declare the SAME version and hold DIFFERENT code. Measured 2026-11-14:
      # a fix was merged without raising the version, so "claude plugin update"
      # answered "already at the latest version" and refreshed nothing, while
      # the marketplace clone did carry the fix. The installed copy and the
      # published one then differed under one version number, and "prefer the
      # installed version, else the highest" selects the stale one.
      if [ -n "$over" ] && [ "$over" = "${MYVER:-}" ]; then
        SAMEVER_DIFFERS=0
        for f in scripts/lib.sh scripts/council-doctor.sh; do
          if [ -f "$odir/$f" ] && [ -f "$PLUGIN_ROOT/$f" ]; then
            cmp -s "$odir/$f" "$PLUGIN_ROOT/$f" || SAMEVER_DIFFERS=1
          fi
        done
        if [ "$SAMEVER_DIFFERS" -eq 1 ]; then
          bad "that copy declares the same version as this one ($over) but its code"
          bad "DIFFERS. You cannot tell from the version which code you are running,"
          bad "and 'claude plugin update' compares versions, not content, so it will"
          bad "refuse to refresh. Fix it by raising the version and republishing, or"
          bad "by uninstalling and reinstalling the plugin."
        fi
      fi
    done < "$COPYLIST"
    rm -f "$COPYLIST"
    if [ "$OTHERS" -gt 0 ]; then
      note "$OTHERS other copy/copies here. A Glob for a script name under"
      note "~/.claude/plugins/ can return any of them, a previous release included,"
      note "and running the wrong one runs old code without saying so. The commands"
      note "prefer the installed version; if you resolve a script by hand, check which"
      note "version you picked. Old releases can be deleted from the plugin cache."
    else
      ok "no other copy of plan-council on this machine"
    fi
  fi
fi

echo "Config"
council_load_config "$ROOT" "$PLUGIN_ROOT"
ok "loaded $COUNCIL_CONFIG_USED"
if [ -f "$ROOT/.claude/plan-council.conf" ] || [ -n "${COUNCIL_CONFIG:-}" ]; then
  ok "the config is one you chose"
else
  note "this is the shipped DEFAULT, not a choice you made: it names Opus because"
  note "that is the broadest entitlement, not because it is your best model."
  note "Run /council-setup once, or council-detect.sh to see what this machine has."
fi
( council_check_planners ) 2>/dev/null && ok "planners: $COUNCIL_PLANNERS" || bad "planners: run council-plan.sh to see why ($COUNCIL_PLANNERS)"
type arbiter >/dev/null 2>&1 && ok "arbiter function defined" || bad "no arbiter function"
[ -n "$COUNCIL_RISK_FLOOR" ] && ok "risk floor: $COUNCIL_RISK_FLOOR" || bad "COUNCIL_RISK_FLOOR is empty"
ok "effort: plan $COUNCIL_PLANNER_EFFORT, attack $COUNCIL_ATTACK_EFFORT, arbitrate $COUNCIL_ARBITER_EFFORT, assign $COUNCIL_ASSIGN_EFFORT"
if [ -n "$COUNCIL_BUDGET_USD" ]; then
  ok "budget cap: \$$COUNCIL_BUDGET_USD per child run"
else
  note "no budget cap set (COUNCIL_BUDGET_USD empty); a run spends what the models spend"
fi

echo "Blindness rule"
FNS="arbiter"
for p in $COUNCIL_PLANNERS; do FNS="$FNS planner_$p"; done
if council_check_deny_used "$FNS" 2>/dev/null; then
  ok "every claude planner and the arbiter pass \$COUNCIL_DENY to their CLI"
else
  bad "a claude function drops \$COUNCIL_DENY: it can read the run directory, and"
  bad "with it which planner wrote which plan. Add \"\$COUNCIL_DENY\" to its"
  bad "--disallowedTools, as config/council.conf does."
fi
if [ -n "${COUNCIL_DENY_UNCOVERED:-}" ]; then
  note "the deny rule is a Claude Code permission rule and cannot reach:$COUNCIL_DENY_UNCOVERED"
  note "with one of those as a planner, the attack phase's blindness rests on the"
  note "prompt rather than on the code. Run council-detect.sh to prove the rule works"
  note "where it does apply."
fi
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    command -v cygpath >/dev/null 2>&1 \
      && ok "cygpath present: deny rules can be written in the form the CLI honours" \
      || bad "cygpath missing: a deny rule may be written as an MSYS path, which the CLI ignores silently"
    note "PowerShell has no 'sh' on PATH. From there, run these scripts as:"
    note "  & \"C:\\Program Files\\Git\\bin\\sh.exe\" \"scripts/council-plan.sh\" <brief> --root <dir>"
    note "'bash' on Windows is usually WSL, which mangles Windows paths silently."
    ;;
esac

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
  # The configured models come from the resolved settings, not from grepping
  # the file: the functions now name a variable, so the ID is only known after
  # the config has been loaded.
  MODELS=$( {
    printf '%s\n' "$COUNCIL_MODEL_CLAUDE" "$COUNCIL_MODEL_CLAUDE_ALT" "$COUNCIL_MODEL_ARBITER"
    grep -v '^[[:space:]]*#' "$COUNCIL_CONFIG_USED" | sed -n 's/.*--model[[:space:]]\{1,\}\([A-Za-z0-9._-]*\).*/\1/p'
    for f in "$PLUGIN_ROOT"/agents/*.md; do
      tr -d '\r' < "$f" | sed -n 's/^model:[[:space:]]*//p' | head -n 1
    done
  } | grep -v '^$' | grep -v '^\$' | sort -u )
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
