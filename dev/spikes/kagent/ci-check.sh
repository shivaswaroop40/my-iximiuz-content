#!/bin/bash
# A CI step: ask the on-call agent about a rollout and fail the job if it says UNHEALTHY.
#   KAGENT_URL=http://localhost:8083 KAGENT_TOKEN=... ./ci-check.sh payments payments-api
# Prints the agent's answer (for a PR comment) and exits 1 on VERDICT: UNHEALTHY, 2 if the agent can't be reached.
set -euo pipefail
ns=$1 workload=$2
url="${KAGENT_URL:-http://localhost:8083}/api/a2a/kagent/oncall/"
id() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
body=$(jq -n --arg mid "$(id)" --arg ctx "ci-$ns-$workload-${GITHUB_RUN_ID:-local}" \
  --arg text "A deploy just finished. Check the health of $workload in namespace $ns." \
  '{jsonrpc:"2.0", id:1, method:"message/send", params:{message:{role:"user", messageId:$mid, contextId:$ctx, parts:[{kind:"text", text:$text}]}}}')
reply=$(curl -sS -m 300 "$url" -H 'content-type: application/json' \
  ${KAGENT_TOKEN:+-H "authorization: Bearer $KAGENT_TOKEN"} -d "$body") || exit 2
answer=$(jq -r '.result.artifacts[]?.parts[]?.text // empty' <<<"$reply")
[ -n "$answer" ] || { echo "agent error: $(jq -c '.error // .' <<<"$reply")" >&2; exit 2; }
echo "$answer"
grep -q 'VERDICT: *UNHEALTHY' <<<"$answer" && exit 1
exit 0
