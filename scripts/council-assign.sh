#!/bin/sh
# Risk-based task assignment for a final plan.
#
# Usage: council-assign.sh PLAN [--root DIR] [--out FILE]
#   PLAN        the final plan, written after arbitration
#   --root DIR  the context root the assigner may read to check facts.
#               Default: the current directory.
#   --out FILE  where the table goes. Default: assignment.md beside PLAN.
#
# The roster is read from the agent definitions' frontmatter (the plugin's
# own agents plus COUNCIL_AGENT_DIRS), so the models in the table are the
# models the agents are actually pinned to. The assigner is the configured
# arbiter function: read-only, answer on stdout.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,13p' "$SCRIPT_DIR/council-assign.sh" | sed 's/^# \{0,1\}//'; }

PLAN=""
ROOT="."
OUTFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || council_die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --out)  [ $# -ge 2 ] || council_die "--out needs a file"; OUTFILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) council_die "unknown option: $1" ;;
    *) [ -z "$PLAN" ] || council_die "only one plan"; PLAN=$1; shift ;;
  esac
done
[ -n "$PLAN" ] || { usage >&2; exit 2; }

PLAN=$(council_absfile "$PLAN") || council_die "plan not found: $PLAN"
[ -s "$PLAN" ] || council_die "plan is empty: $PLAN"
ROOT=$(council_absdir "$ROOT") || council_die "context root not found: $ROOT"
[ -n "$OUTFILE" ] || OUTFILE="$(dirname "$PLAN")/assignment.md"
OUTDIR=$(council_absdir "$(dirname "$OUTFILE")") || council_die "output directory not found: $(dirname "$OUTFILE")"
OUTFILE="$OUTDIR/$(basename "$OUTFILE")"
[ ! -e "$OUTFILE" ] || council_die "$OUTFILE exists; move it or pass --out"

council_load_config "$ROOT" "$PLUGIN_ROOT"
type arbiter >/dev/null 2>&1 || council_die "no arbiter function in $COUNCIL_CONFIG_USED"

# frontmatter FILE KEY -> value of KEY in the file's YAML frontmatter.
frontmatter() {
  tr -d '\r' < "$1" \
    | awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside' \
    | sed -n "s/^$2:[[:space:]]*//p" | head -n 1
}

STAGE=$(council_stage "$ROOT")
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 130' INT TERM

ROSTER="$STAGE/roster.md"
printf '| Agent | Model | Tools | For |\n|---|---|---|---|\n' > "$ROSTER"
NAMES=" "
for dir in "$PLUGIN_ROOT/agents" $COUNCIL_AGENT_DIRS; do
  [ -d "$dir" ] || { council_say "agent directory not found, skipped: $dir"; continue; }
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    name=$(frontmatter "$f" name)
    model=$(frontmatter "$f" model)
    tools=$(frontmatter "$f" tools)
    desc=$(frontmatter "$f" description)
    [ -n "$name" ] || continue
    if [ -z "$model" ] || [ "$model" = "inherit" ]; then
      council_say "agent '$name' pins no model; left out of the roster"
      continue
    fi
    printf '| %s | %s | %s | %s |\n' "$name" "$model" "${tools:-all}" "$desc" >> "$ROSTER"
    NAMES="$NAMES$name "
  done
done
[ "$NAMES" != " " ] || council_die "no agent with a pinned model found"
case "$NAMES" in
  *" $COUNCIL_RISK_FLOOR "*) ;;
  *) council_die "risk floor '$COUNCIL_RISK_FLOOR' is not an agent in the roster:$NAMES" ;;
esac

{
  cat "$PLUGIN_ROOT/prompts/assign.md"
  printf '\n# Roster\n\n'
  cat "$ROSTER"
  printf '\n**Risk floor: %s.** No task whose unnoticed failure touches data integrity, silent data loss, security or production goes to an agent weaker than this one.\n' "$COUNCIL_RISK_FLOOR"
  printf '\n---\n\n# The final plan\n\n'
  cat "$PLAN"
  printf '\n'
} > "$STAGE/prompt-assign.md"

council_say "assigning tasks (assigner: the configured arbiter, from $ROOT)"
council_run_parallel "$ROOT" "$STAGE" "assign:arbiter"
STATUS=$?
council_keep_logs "$STAGE" "$OUTDIR" "assign-"
[ "$STATUS" -eq 0 ] || council_die "assignment failed"
cp "$STAGE/answer-assign.md" "$OUTFILE"

if grep -Eq '[0-9]+([.,][0-9]+)?[[:space:]]*%' "$OUTFILE"; then
  council_say "WARNING: the table contains a percentage. Success rates are never measured; check that it is not one."
fi
council_say "assignment: $OUTFILE"
printf '%s\n' "$OUTFILE"
