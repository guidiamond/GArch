#!/usr/bin/env bash

# Outputs JSON array of recent notifications from dunst history.
# Format: [{"appname":"...", "summary":"...", "body":"...", "time":"..."}]

MAX_ITEMS=8

history=$(dunstctl history 2>/dev/null)

if [[ -z "$history" ]]; then
  echo "[]"
  exit 0
fi

echo "$history" | python3 -c "
import json, sys, time

data = json.load(sys.stdin)
items = data.get('data', [[]])[0]
result = []

for item in items[:$MAX_ITEMS]:
    appname = item.get('appname', {}).get('data', 'Unknown')
    summary = item.get('summary', {}).get('data', '')
    body = item.get('body', {}).get('data', '')
    ts = item.get('timestamp', {}).get('data', 0)

    # Clean HTML tags from body
    import re
    body = re.sub(r'<[^>]+>', '', body)

    # Truncate long body
    if len(body) > 80:
        body = body[:77] + '...'

    # Format timestamp
    if ts and ts > 0:
        # dunst timestamps are in microseconds
        ts_sec = ts / 1000000
        t = time.localtime(ts_sec)
        time_str = time.strftime('%H:%M', t)
    else:
        time_str = ''

    result.append({
        'appname': appname,
        'summary': summary,
        'body': body,
        'time': time_str
    })

print(json.dumps(result))
"
