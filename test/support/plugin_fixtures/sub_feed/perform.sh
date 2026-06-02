#!/bin/sh
WD="$1"
cat > "$WD/output.json.tmp" <<'JSON'
{"items":[{"url":"https://feed/1","metadata":{"title":"One"}}],"checkpoint":"etag-xyz"}
JSON
mv "$WD/output.json.tmp" "$WD/output.json"
