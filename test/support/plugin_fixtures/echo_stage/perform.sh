#!/bin/sh
WD="$1"
test -f "$WD/request.json" || { echo "missing request.json" 1>&2; exit 2; }
echo '{"event":"status","message":"starting"}'
echo '{"event":"progress","value":50}'
echo "a raw stderr log line" 1>&2
cat > "$WD/output.json.tmp" <<'JSON'
{"outcome":"produced","artifacts":[{"type":"article_markdown","labels":{},"filenames":["content.md"]}],"item_metadata":{"title":"Echo"},"provenance":{"tool":"echo"}}
JSON
mv "$WD/output.json.tmp" "$WD/output.json"
