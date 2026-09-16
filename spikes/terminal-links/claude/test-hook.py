import json
import subprocess
import sys
from pathlib import Path

hook = Path(__file__).with_name("hook.py")
event = {"session_id": "test-session-001", "delta": "MARKDOWN src/target.ts:7:3\nRAWOSC src/target.ts:8:1"}
result = subprocess.run([sys.executable, str(hook)], input=json.dumps(event), text=True,
                        capture_output=True, check=True)
payload = json.loads(result.stdout)
content = payload["hookSpecificOutput"]["displayContent"]
assert payload["hookSpecificOutput"]["hookEventName"] == "MessageDisplay"
assert "[src/target.ts:7:3](file:///tmp/link-spike-20260916/project/src/target.ts#L7C3)" in content
assert "https://example.com" in content
assert "\x1b]8;;file:///tmp/link-spike-20260916/project/src/target.ts#L8C1" in content
assert result.stderr == ""
print("PASS: Claude hook emitted valid JSON and fixed transformations")
