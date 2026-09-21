#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cargo build --manifest-path server/Cargo.toml
binary="$(cargo metadata --manifest-path server/Cargo.toml --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"] + "/debug/adhocly-server")')"
tmp="$(mktemp -d)"
pid=""
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
port="${ADHOCLY_TEST_PORT:-39373}"
export ADHOCLY_TEST_URL="http://localhost:$port"
export ADHOCLY_TEST_TOKEN="$(uuidgen)"
DATABASE_URL="sqlite://$tmp/test.db?mode=rwc" API_BIND="127.0.0.1:$port" API_TOKEN="$ADHOCLY_TEST_TOKEN" \
    "$binary" > "$tmp/server.log" 2>&1 &
pid=$!
ready=false
for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then cat "$tmp/server.log"; exit 1; fi
    if curl --fail --silent -H "Authorization: Bearer $ADHOCLY_TEST_TOKEN" "$ADHOCLY_TEST_URL/api/sync" > /dev/null; then
        ready=true
        break
    fi
    sleep 0.1
done
if [ "$ready" != true ]; then cat "$tmp/server.log"; exit 1; fi
cd apple
swift test
