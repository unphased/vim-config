import json, sys
event = json.load(sys.stdin)
delta = event.get('delta', '')
markdown_url = 'file:///tmp/link-spike-20260916/project/src/target.ts#L7C3'
raw_url = 'file:///tmp/link-spike-20260916/project/src/target.ts#L8C1'
content = delta.replace('MARKDOWN', 'HOOKED-MARKDOWN [WEB](https://example.com)')
content = content.replace('src/target.ts:7:3', '[src/target.ts:7:3](' + markdown_url + ')')
content = content.replace('src/target.ts:8:1', '\x1b]8;;' + raw_url + '\x1b\\src/target.ts:8:1\x1b]8;;\x1b\\')
json.dump({'hookSpecificOutput': {'hookEventName': 'MessageDisplay', 'displayContent': content}}, sys.stdout)
