#!/usr/bin/env bash
# Runs ci-post against router.php on a local `php -S` and checks that the
# bearer travels only as a request header, never in any process's argv, and
# that 401, 429 and 503 are retried while 422 is not, and that gzip mode (-z)
# sends the log upload's headers and time limit.
#
# usage: bash scripts/test/ci-post.test.sh   (macOS or Linux; needs php, curl)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci_post="$here/../ci-post"
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
        CI_TEST_STATE="$work/state" php -S "127.0.0.1:$port" "$here/router.php" >"$work/server.log" 2>&1 &
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

token="citest-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
config="$work/auth.curl"
(
    umask 077
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$config"
)
printf '{"ci_run_id":"%s"}' "00000000-0000-4000-8000-000000000000" >"$work/body.json"

if [ ! -x "$ci_post" ]; then
    fail "ci-post is missing or not executable at $ci_post"
fi

start_server
sample_argv &
sampler_pid=$!

# 1. A 401, a 429 and a 503 are all retried until the 200 arrives.
status=0
stdout="$("$ci_post" "http://127.0.0.1:$port/sequence" "$config" "$work/response.json" "$work/body.json")" || status=$?

[ "$status" -eq 0 ] || fail "ci-post exited $status on the retry sequence"
[ -z "$stdout" ] || fail 'ci-post wrote to stdout'
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

while IFS= read -r line; do
    [ "$line" = ci-job/1 ] || fail "a request had user agent '$line'"
done <"$work/state/user-agent.log"
pass 'every attempt carried the ci-job/1 user agent'

# 2. A 422 is final: one request, non-zero exit, status recorded.
status=0
"$ci_post" "http://127.0.0.1:$port/reject" "$config" "$work/reject.json" "$work/body.json" || status=$?

[ "$status" -ne 0 ] || fail 'ci-post exited 0 on a 422'
[ "$(cat "$work/reject.json.status")" = 422 ] || fail 'status file does not hold 422'
[ "$(wc -l <"$work/state/authorization.log" | tr -d ' ')" -eq 5 ] || fail 'a 422 was retried'
pass 'did not retry a 422'

# 3. Gzip mode: the body goes as application/gzip, byte for byte, with the
# run and job headers and a 120 s limit for an upload of up to 8 MiB.
printf 'phase log line\n' | gzip -c >"$work/logs.gz"
run_id=00000000-0000-4000-8000-000000000001
status=0
CI_RUN_ID="$run_id" CI_JOB_NAME='test (2)' \
    "$ci_post" -z "http://127.0.0.1:$port/created" "$config" "$work/logs.json" "$work/logs.gz" || status=$?

[ "$status" -eq 0 ] || fail "ci-post -z exited $status on a 201"
[ "$(cat "$work/logs.json.status")" = 201 ] || fail 'status file does not hold 201'
[ "$(tail -n 1 "$work/state/method.log")" = POST ] || fail 'gzip mode did not POST'
[ "$(tail -n 1 "$work/state/content-type.log")" = application/gzip ] || fail 'gzip mode did not send application/gzip'
[ "$(tail -n 1 "$work/state/ci-run.log")" = "$run_id" ] || fail 'gzip mode did not send X-Ci-Run'
[ "$(tail -n 1 "$work/state/ci-job.log")" = 'test (2)' ] || fail 'gzip mode did not send X-Ci-Job'
[ "$(tail -n 1 "$work/state/authorization.log")" = "Bearer $token" ] || fail 'gzip mode lost the bearer'
cmp -s "$work/state/last-body" "$work/logs.gz" || fail 'gzip mode changed the body'
pass 'gzip mode sends the body as application/gzip with X-Ci-Run and X-Ci-Job'

status=0
env -u CI_RUN_ID -u CI_JOB_NAME "$ci_post" -z "http://127.0.0.1:$port/created" "$config" "$work/logs.json" \
    "$work/logs.gz" 2>/dev/null || status=$?
[ "$status" -eq 2 ] || fail "ci-post -z without CI_RUN_ID and CI_JOB_NAME exited $status, expected 2"
status=0
CI_RUN_ID="$run_id" CI_JOB_NAME=lint "$ci_post" -z "http://127.0.0.1:$port/created" "$config" "$work/logs.json" \
    2>/dev/null || status=$?
[ "$status" -eq 2 ] || fail "ci-post -z without a body exited $status, expected 2"
pass 'gzip mode needs the run id, the job name and a body'

touch "$work/stop"
wait "$sampler_pid"
sampler_pid=''

# 4. The sampler must have seen ci-post's curl, or the argv check below
# proves nothing.
grep -q "curl.*127\.0\.0\.1:$port/sequence" "$work/argv.log" || fail 'the sampler never saw curl running'

grep -q "curl.*--max-time 120 .*127\.0\.0\.1:$port/created" "$work/argv.log" || fail 'gzip mode did not allow 120 s'
if grep -q "curl.*--max-time 120 .*127\.0\.0\.1:$port/sequence" "$work/argv.log"; then
    fail 'JSON mode lost its 60 s limit'
fi
pass 'gzip mode allows 120 s, JSON mode keeps 60 s'

if grep -qF -- "$token" "$work/argv.log"; then
    fail 'the bearer appeared in a process argv'
fi
pass 'the bearer never appeared in any process argv'

echo 'PASS ci-post.test.sh'
