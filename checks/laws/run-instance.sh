#!/bin/sh
# Stage 2 of the law harness: execute the pure core for one generated instance
# and record the result.
#
# A separate file rather than an inline heredoc so that it is readable and
# shellcheck-able on its own, and so `xargs` can invoke it directly -- a shell
# function cannot be exported into the `xargs` child.
#
# Usage: run-instance.sh <instances.json> <index> <outDir> <ai-usage.jq>
#
# Writes <outDir>/<index>.json = {instance, raw, status, doc}.
#   raw    exact stdout, so a determinism law can compare bytes
#   status the core's exit code, so totality is observable rather than fatal
#   doc    the parsed document, null when stdout was not valid JSON
#
# An instance carrying `feedback: "<metric>"` is executed a second time with the
# body replaced by that metric's value as the first run reported it, and the
# second result is written to <outDir>/<index>.feedback.json. That composition is
# the only way to state `norm . norm = norm` without splitting the core into a jq
# module, which would mean testing a different artefact than the one that ships.

set -u

instances=$1
index=$2
outDir=$3
program=$4

# Runs the core once. $1 = instance JSON, $2 = destination file.
# Sets `raw` for the caller.
run_core() {
  _instance=$1
  _dest=$2

  # `jq -j` writes the body with no trailing newline, and `--rawfile` reads it
  # back verbatim, so the core sees the byte string the orchestrator would pass.
  _bodyFile="$_dest.body"
  printf '%s' "$_instance" | jq -j '.body' >"$_bodyFile"

  _provider=$(printf '%s' "$_instance" | jq -c '.provider')
  _meta=$(printf '%s' "$_instance" | jq -c '.meta')

  # Resolve `from.expression` metrics the way `module/package.nix` does, with the
  # same collapse of a failing or unparsable filter to `null`. jq has no `eval`,
  # so the core receives values rather than filters (D-5), and a shipped filter is
  # only genuinely covered if a check executes it. The laws quantify over the real
  # shipped providers, so the harness has to run the real filters; an instance's
  # own `expressions` is layered on top, as an override for a value the
  # orchestrator can produce but a filter cannot be made to.
  _expressions='{}'
  for _m in $(printf '%s' "$_provider" |
    jq -r '(.metrics // {}) | to_entries[]
           | select(.value.from | has("expression")) | .key'); do
    _filter=$(printf '%s' "$_provider" | jq -r --arg m "$_m" '.metrics[$m].from.expression')
    _value=$(jq -c "$_filter" "$_bodyFile" 2>/dev/null) || _value=null
    printf '%s' "$_value" | jq -e . >/dev/null 2>&1 || _value=null
    _expressions=$(printf '%s' "$_expressions" |
      jq -c --arg m "$_m" --argjson v "$_value" '. + {($m): $v}')
  done
  _expressions=$(printf '%s' "$_expressions" |
    jq -c --argjson o "$(printf '%s' "$_instance" | jq -c '.expressions')" '. + $o')

  if raw=$(
    jq -n -c --from-file "$program" \
      --argjson provider "$_provider" \
      --rawfile body "$_bodyFile" \
      --argjson expressions "$_expressions" \
      --argjson meta "$_meta" \
      2>"$_dest.stderr"
  ); then
    _status=0
  else
    _status=$?
    raw=""
  fi

  jq -n -c \
    --argjson instance "$_instance" \
    --arg raw "$raw" \
    --argjson status "$_status" \
    '{instance: $instance,
      raw: $raw,
      status: $status,
      doc: ($raw | try fromjson catch null)}' >"$_dest"
}

instance=$(jq -c --argjson i "$index" '.[$i]' "$instances")
run_core "$instance" "$outDir/$index.json"

metric=$(printf '%s' "$instance" | jq -r '.feedback // ""')
if [ -n "$metric" ]; then
  value=$(printf '%s' "$raw" | jq -c --arg m "$metric" '.metrics[$m]' 2>/dev/null || true)
  [ -n "${value:-}" ] || value=null

  second=$(printf '%s' "$instance" | jq -c \
    --arg m "$metric" --argjson v "$value" \
    '.pairIndex = 1 | .feedback = null | .body = ({($m): $v} | tojson)')
  run_core "$second" "$outDir/$index.feedback.json"
fi
