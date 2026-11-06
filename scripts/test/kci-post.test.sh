#!/usr/bin/env bash
# Runs kci-post against router.php on a local `php -S` and checks that the
# bearer travels only as a request header, never in any process's argv, and
# that 401, 429 and 503 are retried while 422 is not.
#
# usage: bash scripts/test/kci-post.test.sh   (macOS or Linux; needs php, curl)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kci_post="$here/../kci-post"
work="$(mktemp -d)"
server_pid=''
sampler_pid=''

cleanup() {
    touch "$work/stop"
    if [ -n "$sampler_pid" ]; then
        wait "$sampler_pid" || true
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "ok: $1"
}

start_server() {
    local attempt

    mkdir -p "$work/state"

    for attempt in 1 2 3 4 5; do
        port=$((20000 + RANDOM % 20000))
        KCI_TEST_STATE="$work/state" php -S "127.0.0.1:$port" "$here/router.php" >"$work/server.log" 2>&1 &
        server_pid=$!

        for _ in $(seq 1 50); do
            if curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null; then
                return 0
            fi
            if ! kill -0 "$server_pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
        echo "server did not start on port $port (attempt $attempt)" >&2
    done

    fail 'php -S never started'
}

# Records the argv of every process until $work/stop exists. On Linux that is
# /proc/<pid>/cmdline, which any local user can read; on macOS `ps -o args`.
sample_argv() {
    local cmdline

    while [ ! -e "$work/stop" ]; do
        if [ -d /proc/self ]; then
            for cmdline in /proc/[0-9]*/cmdline; do
                { tr '\0' ' ' <"$cmdline"; echo; } 2>/dev/null || true
            done
        else
            ps -A -o args=
        fi >>"$work/argv.log"
    done
}

token="kcitest-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
config="$work/auth.curl"
(
    umask 077
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$config"
)
printf '{"ci_run_id":"%s"}' "00000000-0000-4000-8000-000000000000" >"$work/body.json"

if [ ! -x "$kci_post" ]; then
    fail "kci-post is missing or not executable at $kci_post"
fi

start_server
sample_argv &
sampler_pid=$!

# 1. A 401, a 429 and a 503 are all retried until the 200 arrives.
status=0
stdout="$("$kci_post" "http://127.0.0.1:$port/sequence" "$config" "$work/response.json" "$work/body.json")" || status=$?

[ "$status" -eq 0 ] || fail "kci-post exited $status on the retry sequence"
[ -z "$stdout" ] || fail 'kci-post wrote to stdout'
[ "$(cat "$work/response.json")" = '{"ok":true}' ] || fail 'response body was not the final 200 body'
[ "$(cat "$work/response.json.status")" = 200 ] || fail 'status file does not hold 200'
[ "$(wc -l <"$work/state/authorization.log" | tr -d ' ')" -eq 4 ] || fail 'expected exactly 4 requests'
pass 'retried 401, 429 and 503 and stopped at 200'

while IFS= read -r line; do
    [ "$line" = "Bearer $token" ] || fail 'a request arrived without the bearer header'
done <"$work/state/authorization.log"
pass 'bearer arrived as the Authorization header on every attempt'

while IFS= read -r line; do
    [ "$line" = POST ] || fail "a request used method $line"
done <"$work/state/method.log"

while IFS= read -r line; do
    [ "$line" = application/json ] || fail "a request had content type '$line'"
done <"$work/state/content-type.log"

while IFS= read -r line; do
    [ "$line" = "$(cat "$work/body.json")" ] || fail 'a request body differed from the body file'
done <"$work/state/body.log"
pass 'every attempt was a JSON POST of the body file'

# 2. A 422 is final: one request, non-zero exit, status recorded.
status=0
"$kci_post" "http://127.0.0.1:$port/reject" "$config" "$work/reject.json" "$work/body.json" || status=$?

[ "$status" -ne 0 ] || fail 'kci-post exited 0 on a 422'
[ "$(cat "$work/reject.json.status")" = 422 ] || fail 'status file does not hold 422'
[ "$(wc -l <"$work/state/authorization.log" | tr -d ' ')" -eq 5 ] || fail 'a 422 was retried'
pass 'did not retry a 422'

touch "$work/stop"
wait "$sampler_pid"
sampler_pid=''

# 3. The sampler must have seen kci-post's curl, or the argv check below
# proves nothing.
grep -q "curl.*127\.0\.0\.1:$port/sequence" "$work/argv.log" || fail 'the sampler never saw curl running'

if grep -qF -- "$token" "$work/argv.log"; then
    fail 'the bearer appeared in a process argv'
fi
pass 'the bearer never appeared in any process argv'

echo 'PASS kci-post.test.sh'
