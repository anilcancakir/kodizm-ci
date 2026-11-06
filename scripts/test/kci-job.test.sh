#!/usr/bin/env bash
# Checks kci-job's pure helpers without network or root: resolve_dir must
# refuse every way out of the checkout, and the summariser must turn a
# `flutter test --file-reporter json:` log into the results payload.
#
# usage: bash scripts/test/kci-job.test.sh   (macOS or Linux; needs php, jq)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "ok: $1"
}

# shellcheck source=scripts/kci-job
source "$here/../kci-job"

# Sourcing defines the functions and runs nothing; the globals they read are
# pointed at the scratch directory, and fd 3 (the public log) at nowhere.
exec 3>/dev/null
tree="$work/tree"
state="$work/state"
mkdir -p "$state" "$tree/backend/app" "$work/outside"
ln -s "$tree/backend" "$tree/link"
ln -s "$work/outside" "$tree/escape"
real_tree="$(realpath "$tree")"

expect_resolves() {
    local dir="$1"
    local expected="$2"
    local actual

    if ! actual="$(resolve_dir "$tree" "$dir")"; then
        fail "resolve_dir refused '$dir'"
    fi
    if [ "$actual" != "$expected" ]; then
        fail "resolve_dir '$dir' gave '$actual', expected '$expected'"
    fi
    pass "resolve_dir accepts '$dir'"
}

expect_refused() {
    local dir="$1"
    local label="$2"

    if resolve_dir "$tree" "$dir" >/dev/null; then
        fail "resolve_dir accepted $label"
    fi
    pass "resolve_dir refuses $label"
}

# 1. Directory resolution.
expect_resolves . "$real_tree"
expect_resolves backend "$real_tree/backend"
expect_resolves backend/app "$real_tree/backend/app"
expect_refused ../outside 'a parent-relative path'
expect_refused backend/../../outside 'a path climbing out through ..'
expect_refused "$tree/backend" 'an absolute path'
expect_refused / 'the filesystem root'
expect_refused link 'a symlink inside the tree'
expect_refused link/app 'a symlinked component'
expect_refused escape 'a symlink leading outside'
expect_refused missing 'a missing directory'
expect_refused $'backend\napp' 'a newline'
expect_refused '' 'an empty path'

# 2. Flutter's JSON reporter, as `flutter test --file-reporter json:` writes
#    it: one event per line. Hidden passing load tests are not tests; a
#    failing load test (a compile error) is an error with no line.
report="$work/flutter.json"
cat >"$report" <<JSON
{"protocolVersion":"0.1.1","runnerVersion":null,"pid":42,"type":"start","time":0}
{"suite":{"id":0,"platform":"vm","path":"$tree/test/widget_test.dart"},"type":"suite","time":0}
{"test":{"id":1,"name":"loading $tree/test/widget_test.dart","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":null,"column":null,"url":null},"type":"testStart","time":1}
{"testID":1,"result":"success","skipped":false,"hidden":true,"type":"testDone","time":90}
{"group":{"id":2,"suiteID":0,"parentID":null,"name":"","metadata":{"skip":false,"skipReason":null},"testCount":4,"line":null,"column":null,"url":null},"type":"group","time":91}
{"test":{"id":3,"name":"counter increments","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":10,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":92}
{"testID":3,"messageType":"print","message":"tapped","type":"print","time":95}
{"testID":3,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":100}
{"test":{"id":4,"name":"counter starts at zero","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":20,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":101}
{"testID":4,"error":"Expected: <0>\n  Actual: <1>","stackTrace":"package:app/main_test.dart 21:5","isFailure":true,"type":"error","time":110}
{"testID":4,"result":"failure","skipped":false,"hidden":false,"type":"testDone","time":111}
{"test":{"id":5,"name":"pending feature","suiteID":0,"groupIDs":[2],"metadata":{"skip":true,"skipReason":"later"},"line":30,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":112}
{"testID":5,"result":"success","skipped":true,"hidden":false,"type":"testDone","time":113}
{"test":{"id":6,"name":"shared helper throws","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":40,"column":5,"url":"file://$tree/test/helpers/shared.dart","root_line":33,"root_column":3,"root_url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":114}
{"testID":6,"error":"Bad state: no element","stackTrace":"dart:core Iterable.first","isFailure":false,"type":"error","time":120}
{"testID":6,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":121}
not a json line
{"suite":{"id":7,"platform":"vm","path":"$tree/test/broken_test.dart"},"type":"suite","time":122}
{"test":{"id":8,"name":"loading $tree/test/broken_test.dart","suiteID":7,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":null,"column":null,"url":null},"type":"testStart","time":123}
{"testID":8,"error":"Failed to load: compilation failed","stackTrace":"","isFailure":false,"type":"error","time":130}
{"testID":8,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":131}
{"success":false,"type":"done","time":140}
JSON

KCI_RUN_ID=01234567-89ab-cdef-0123-456789abcdef
status=failed
last_log='test'

if ! summarise flutter "$report"; then
    fail 'summarise flutter exited non-zero'
fi
build_payload
results="$state/results.json"

counts="$(jq -c '.counts' "$results")"
if [ "$counts" != '{"tests":5,"failures":1,"errors":2,"skipped":1}' ]; then
    fail "flutter counts are $counts"
fi
pass 'flutter counts: 5 tests, 1 failure, 2 errors, 1 skipped'

failures="$(jq -c '[.failures[] | [.file, .line, .name]]' "$results")"
expected='[["test/widget_test.dart",20,"counter starts at zero"],'
expected+='["test/widget_test.dart",33,"shared helper throws"],'
expected+='["test/broken_test.dart",0,"loading test/broken_test.dart"]]'
if [ "$failures" != "$expected" ]; then
    fail "flutter failures are $failures"
fi
pass 'flutter failures carry the repository-relative file and the root line'

if ! jq -e '.failures[0].message | contains("Expected: <0>") and contains("21:5")' "$results" >/dev/null; then
    fail 'the failure message lost the error or its stack trace'
fi
pass 'flutter failure message carries the error and the stack trace'

if ! jq -e '.ci_run_id == "01234567-89ab-cdef-0123-456789abcdef" and .status == "failed"' "$results" >/dev/null; then
    fail 'the payload lost the run id or the status'
fi
pass 'payload carries the run id and the status'
