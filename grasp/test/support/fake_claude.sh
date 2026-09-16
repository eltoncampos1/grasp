#!/bin/sh
# Stands in for the Claude Code CLI in tests: prints a canned stream-json run whose result
# echoes the argv, so tests can assert on the flags the runner passed. A prompt containing
# FAIL exits non-zero after writing to stderr; one containing SLOW keeps the run alive long
# enough for a second prompt or a stop to land while it is still running.
args="$*"

case "$args" in
  *FAIL*)
    echo '{"type":"system","subtype":"init","session_id":"fake-fail","mcp_servers":[{"name":"grasp","status":"failed"}]}'
    echo 'something went wrong on stderr' 1>&2
    exit 3
    ;;
esac

echo '{"type":"system","subtype":"init","session_id":"fake-1","mcp_servers":[{"name":"grasp","status":"connected"}]}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the flow."}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__grasp__search_functions","input":{"query":"greet","limit":5}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"[]"}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":" Done."}]}}'

case "$args" in
  *SLOW*) sleep 1 ;;
esac

# The argv is folded onto one line before escaping: the system prompt spans several lines,
# and sed's ^/$ anchors would otherwise quote each of them separately.
escaped=$(printf '%s' "$args" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.01,"session_id":"fake-1","result":"%s"}\n' "$escaped"
