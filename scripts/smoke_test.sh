#!/usr/bin/env bash
#
# Smoke test for a built Cham release.
#
# Required env:
#   FIREWORKS_API_KEY   Fireworks API key for LLM plugins
#   POSTGRES_URL        e.g. postgres://cham:cham@localhost:5432 (no database segment)
#
# Optional env:
#   CHAM_RELEASE_DIR    path to built release (default: _build/prod/rel/cham)
#   SMOKE_PORT          port for the smoke server (default: 4010)
#
# Prerequisites:
#   - `cham` CLI installed on PATH (pipx install ./cli)
#   - `mix release` has been run
#   - `jq`, `curl`, `envsubst` on PATH
#   - Postgres reachable at POSTGRES_URL
#
# Exits 0 on success, non-zero on failure. Tears down server and scratch data
# on exit (including Ctrl-C).

set -euo pipefail

: "${FIREWORKS_API_KEY:?FIREWORKS_API_KEY must be set}"
: "${POSTGRES_URL:?POSTGRES_URL must be set (no db segment, e.g. postgres://user:pass@host:5432)}"

CHAM_RELEASE_DIR="${CHAM_RELEASE_DIR:-_build/prod/rel/cham}"
SMOKE_PORT="${SMOKE_PORT:-4010}"
SMOKE_DB="cham_smoke_test"

ARTICLE_URL="https://blog.jean-francois.im/posts/building-a-simple-air-quality-monitor/index.en.html"
PDF_URL="https://files.jfim.dev/cham-test-data/Report_ERA24FA058_193491_3_6_2026_6_17_24_PM.pdf"
VIDEO_URL="https://files.jfim.dev/cham-test-data/output.mp4"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHAM_BIN="${REPO_ROOT}/${CHAM_RELEASE_DIR}/bin/cham"

if [ ! -x "$CHAM_BIN" ]; then
  echo "Error: $CHAM_BIN not found or not executable. Run 'MIX_ENV=prod mix release' first." >&2
  exit 1
fi

for tool in jq curl envsubst psql; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

SCRATCH="$(mktemp -d -t cham-smoke.XXXXXX)"
SERVER_LOG="$SCRATCH/server.log"
SERVER_PID=""
DB_CREATED=0

cleanup() {
  local exit_code=$?
  set +e
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "→ stopping server (pid $SERVER_PID)"
    "$CHAM_BIN" stop >/dev/null 2>&1 || kill "$SERVER_PID" 2>/dev/null
    sleep 1
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  if [ "$DB_CREATED" = "1" ]; then
    echo "→ dropping $SMOKE_DB"
    psql "$POSTGRES_URL/postgres" -c "DROP DATABASE IF EXISTS $SMOKE_DB WITH (FORCE);" >/dev/null 2>&1 || true
  fi
  if [ "$exit_code" != "0" ] && [ -f "$SERVER_LOG" ]; then
    echo
    echo "========= server log (last 80 lines) ========="
    tail -n 80 "$SERVER_LOG" || true
    echo "=============================================="
  fi
  rm -rf "$SCRATCH"
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
step() { echo; echo "── $* ──"; }

# ── setup ──────────────────────────────────────────────────────────────────

step "creating database $SMOKE_DB"
psql "$POSTGRES_URL/postgres" -c "DROP DATABASE IF EXISTS $SMOKE_DB WITH (FORCE);" >/dev/null
psql "$POSTGRES_URL/postgres" -c "CREATE DATABASE $SMOKE_DB;" >/dev/null
DB_CREATED=1

step "rendering smoke config"
envsubst < "$REPO_ROOT/config/cham.toml.smoke.template" > "$SCRATCH/cham.toml"

ARCHIVE_ROOT="$SCRATCH/archive"
mkdir -p "$ARCHIVE_ROOT"

SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 | tr -d '=+/' | head -c 64)"

export DATABASE_URL="$POSTGRES_URL/$SMOKE_DB"
export ARCHIVE_ROOT
export CHAM_CONFIG_PATH="$SCRATCH/cham.toml"
export SECRET_KEY_BASE
export PHX_SERVER=true
export PORT="$SMOKE_PORT"
export PHX_HOST=localhost
export CHAM_URL="http://localhost:$SMOKE_PORT"

step "running migrations"
"$CHAM_BIN" eval 'Cham.Release.migrate()' >>"$SERVER_LOG" 2>&1 || fail "migrations failed"

step "starting server on port $SMOKE_PORT"
"$CHAM_BIN" start >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# wait for /health to respond 200
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:$SMOKE_PORT/health" >/dev/null 2>&1; then
    echo "server ready after ${i}s"
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "server died during startup"
  fi
  sleep 1
done
curl -fsS "http://localhost:$SMOKE_PORT/health" >/dev/null || fail "server did not become healthy within 60s"

# ── tests ──────────────────────────────────────────────────────────────────

dump_item() {
  local slug="$1"
  echo "── item detail ($slug) ──"
  cham item show "$slug" --json | jq '{status, content_type, error_message,
    artifacts: [.artifacts[] | {stage, status, labels}],
    stage_executions: [.stage_executions[] | {stage, status, attempt, error, duration_ms}]}' || true
}

wait_complete() {
  local slug="$1" timeout="${2:-300}"
  for i in $(seq 1 "$timeout"); do
    local status
    status="$(cham item show "$slug" --json | jq -r '.status')"
    case "$status" in
      complete) return 0 ;;
      failed|incomplete|cancelled)
        dump_item "$slug" >&2
        fail "item $slug terminated with status=$status"
        ;;
    esac
    sleep 1
  done
  dump_item "$slug" >&2
  fail "item $slug did not complete within ${timeout}s"
}

fetch_summary() {
  local slug="$1"
  local fname
  fname="$(cham item show "$slug" --json \
    | jq -r '.artifacts[] | select(.stage=="summarize_ollama") | .filenames[0] // empty' \
    | head -n1)"
  [ -n "$fname" ] || fail "no summarize_ollama artifact for $slug"
  curl -fsS "http://localhost:$SMOKE_PORT/api/v1/items/$slug/files/$fname"
}

step "adding article"
ARTICLE_JSON="$(cham item add --json "$ARTICLE_URL")"
ARTICLE_SLUG="$(echo "$ARTICLE_JSON" | jq -r '.slug // .id')"
[ -n "$ARTICLE_SLUG" ] && [ "$ARTICLE_SLUG" != "null" ] || fail "no slug/id returned from add"
echo "article slug: $ARTICLE_SLUG"
wait_complete "$ARTICLE_SLUG" 180

TITLE="$(cham item show "$ARTICLE_SLUG" --json | jq -r '.title // ""')"
echo "title: $TITLE"
echo "$TITLE" | grep -qi "air quality" || fail "title did not match 'air quality': $TITLE"

SUMMARY1="$(fetch_summary "$ARTICLE_SLUG")"
echo "$SUMMARY1" | grep -qiE "sensor|air quality|esp8266|sensair|senseair" \
  || fail "summary did not mention expected keywords: $SUMMARY1"
echo "$SUMMARY1" > "$SCRATCH/summary1.txt"

step "reprocessing summarize_ollama"
cham item reprocess "$ARTICLE_SLUG" --invalidate summarize_ollama --json >/dev/null
wait_complete "$ARTICLE_SLUG" 180

SUMMARY2="$(fetch_summary "$ARTICLE_SLUG")"
echo "$SUMMARY2" > "$SCRATCH/summary2.txt"
if cmp -s "$SCRATCH/summary1.txt" "$SCRATCH/summary2.txt"; then
  fail "summaries identical before/after reprocess — LLM likely wasn't called"
fi

step "adding PDF"
PDF_JSON="$(cham item add --json "$PDF_URL")"
PDF_SLUG="$(echo "$PDF_JSON" | jq -r '.slug // .id')"
echo "pdf slug: $PDF_SLUG"
wait_complete "$PDF_SLUG" 300

PDF_SHOW="$(cham item show "$PDF_SLUG" --json)"
echo "$PDF_SHOW" | jq -e '.artifacts[] | select(.stage=="extract_pdf")' >/dev/null \
  || fail "no extract_pdf artifact for PDF item"

step "adding video"
VIDEO_JSON="$(cham item add --json "$VIDEO_URL")"
VIDEO_SLUG="$(echo "$VIDEO_JSON" | jq -r '.slug // .id')"
echo "video slug: $VIDEO_SLUG"
wait_complete "$VIDEO_SLUG" 600

VIDEO_SHOW="$(cham item show "$VIDEO_SLUG" --json)"
TRANSCRIPT_FNAME="$(echo "$VIDEO_SHOW" \
  | jq -r '.artifacts[] | select(.stage=="transcribe_whisper") | .filenames[0] // empty' \
  | head -n1)"
[ -n "$TRANSCRIPT_FNAME" ] || fail "no transcribe_whisper artifact for video"
TRANSCRIPT="$(curl -fsS "http://localhost:$SMOKE_PORT/api/v1/items/$VIDEO_SLUG/files/$TRANSCRIPT_FNAME")"
echo "$TRANSCRIPT" | grep -qi "potato" || fail "transcript did not contain 'potato': $TRANSCRIPT"

echo
echo "SMOKE OK"
