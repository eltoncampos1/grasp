#!/bin/sh
# Stands in for the Claude Code CLI in tests: prints a canned stream-json run whose result
# echoes the argv, so tests can assert on the flags the runner passed. A prompt containing
# FAIL exits non-zero after writing to stderr; SLOW keeps the run alive long enough for a
# second prompt or a stop to land while it is still running, and HANG outlives any test that
# does not kill it. With FAKE_CLAUDE_PID_FILE set it records its own pid there, so a test can
# prove the process is gone rather than only that the transcript says so.
args="$*"

if [ -n "$FAKE_CLAUDE_PID_FILE" ]; then
  echo $$ > "$FAKE_CLAUDE_PID_FILE"
fi

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
# One turn is Markdown — a fence, an id the fixture index holds and one it does not, and a
# raw script tag — so the panel's rendering and sanitising are exercised end to end. Its
# JSON string carries \n escapes, which echo would expand into real newlines and break the
# object across lines, so this line is printed rather than echoed.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"\n\nIt calls **greet** in `SampleApp.Greeter.greet/2`, not `Nope.Missing.fun/1`.\n\n```elixir\nSampleApp.Greeter.greet(name, greeting)\n```\n\n<script>alert(1)</script>\n"}]}}'

case "$args" in
  *HANG*) sleep 5 ;;
  *SLOW*) sleep 1 ;;
esac

# The argv is folded onto one line before escaping: the system prompt spans several lines,
# and sed's ^/$ anchors would otherwise quote each of them separately.
escaped=$(printf '%s' "$args" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.01,"session_id":"fake-1","result":"%s"}\n' "$escaped"
