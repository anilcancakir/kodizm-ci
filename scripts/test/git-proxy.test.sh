#!/usr/bin/env bash
# Fetches a real commit through the pool Worker's /git routes: ci-job's own
# fetch_source runs real git against a node http server that hands each
# request to the Worker module's fetch(request, env), and the Worker's
# GITHUB_WEB_BASE points at a loopback `git http-backend`. The upstream must
# see the path the ticket names and the Basic credential, never the edge key
# or the ticket. The revocation goes through the Worker's DELETE /gh-token the
# same way, to a loopback GITHUB_API_BASE.
#
# usage: bash scripts/test/git-proxy.test.sh   (needs node 20+, git, openssl, jq, curl)
#
# POOL_WORKER names the Worker module. Until it serves /git (v2) the test
# prints a SKIP line and exits 0.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pool_worker="${POOL_WORKER:-$HOME/Code/kodizm.com-worktrees/virtual-ci-phase5/resources/ci/pool-worker.js}"

if [ ! -f "$pool_worker" ] || ! grep -q 'git-upload-pack' "$pool_worker"; then
    echo "SKIP git-proxy.test.sh: no Worker with /git routes at $pool_worker (set POOL_WORKER)"
    exit 0
fi

work="$(mktemp -d)"
server_pid=''

cleanup() {
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

ticket_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
edge_key="edge-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
source_token="ghs_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

b64url() {
    base64 | tr '/+' '_-' | tr -d '=\n'
}

# usage: mint_ticket <key> <payload-json>
mint_ticket() {
    local payload
    local signature

    payload="$(printf '%s' "$2" | b64url)"
    signature="$(printf 'git|%s' "$payload" | openssl dgst -sha256 -hmac "$1" | awk '{ print $NF }')"
    printf 'v1.%s.%s\n' "$payload" "$signature"
}

# 1. The minting here must agree with the shared vectors, or a failure below
#    would only prove the harness wrong.
vectors="$(dirname "$pool_worker")/edge-vectors.json"
if [ -f "$vectors" ]; then
    expected="$(jq -r '.git_ticket.ticket' "$vectors")"
    segment="$(jq -r '.git_ticket.ticket | split(".")[1]' "$vectors" | tr '_-' '/+')"
    while [ $((${#segment} % 4)) -ne 0 ]; do
        segment+='='
    done
    payload_json="$(printf '%s' "$segment" | base64 -d)"
    [ "$(mint_ticket "$(jq -r '.ticket_key' "$vectors")" "$payload_json")" = "$expected" ] \
        || fail 'the harness mints tickets differently from edge-vectors.json'
    pass 'the harness mints the shared vector ticket'
fi

# 2. A bare upstream repository with one commit, served by git http-backend.
upstream="$work/upstream"
mkdir -p "$upstream/owner" "$work/seed"
git init --quiet "$work/seed"
echo 'proxied hello' >"$work/seed/README"
git -C "$work/seed" add README
GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.invalid \
    GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.invalid \
    git -C "$work/seed" -c commit.gpgsign=false commit --quiet -m seed
head_commit="$(git -C "$work/seed" rev-parse HEAD)"
git clone --quiet --bare "$work/seed" "$upstream/owner/repo.git"
git -C "$upstream/owner/repo.git" config uploadpack.allowReachableSHA1InWant true

cat >"$work/harness.mjs" <<'JS'
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import http from 'node:http';
import { Readable } from 'node:stream';
import { pathToFileURL } from 'node:url';

const { default: worker } = await import(pathToFileURL(process.env.POOL_WORKER).href);
const log = (entry) => appendFileSync(process.env.UPSTREAM_LOG, `${JSON.stringify(entry)}\n`);

const readBody = (req) =>
    new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', (chunk) => chunks.push(chunk));
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });

// Loopback github.com and api.github.com: git http-backend as a CGI for the
// git paths, 204 for the token revocation.
const upstream = http.createServer(async (req, res) => {
    const body = await readBody(req);
    const url = new URL(req.url, 'http://upstream');
    log({
        method: req.method,
        path: url.pathname,
        query: url.search,
        authorization: req.headers.authorization ?? null,
        edge_key: req.headers['x-edge-key'] ?? null,
        ticket: req.headers['x-ci-ticket'] ?? null,
    });

    if (req.method === 'DELETE' && url.pathname === '/installation/token') {
        res.writeHead(204);
        res.end();
        return;
    }

    const cgi = spawn(process.env.GIT_HTTP_BACKEND, [], {
        env: {
            PATH: process.env.PATH,
            GIT_PROJECT_ROOT: process.env.GIT_PROJECT_ROOT,
            GIT_HTTP_EXPORT_ALL: '1',
            GIT_PROTOCOL: req.headers['git-protocol'] ?? '',
            REQUEST_METHOD: req.method,
            PATH_INFO: url.pathname,
            QUERY_STRING: url.search.replace(/^\?/, ''),
            CONTENT_TYPE: req.headers['content-type'] ?? '',
            CONTENT_LENGTH: String(body.length),
            HTTP_CONTENT_ENCODING: req.headers['content-encoding'] ?? '',
            REMOTE_ADDR: '127.0.0.1',
        },
    });
    const output = [];
    cgi.stdout.on('data', (chunk) => output.push(chunk));
    cgi.stderr.on('data', (chunk) => process.stderr.write(chunk));
    cgi.on('close', () => {
        const raw = Buffer.concat(output);
        const split = raw.indexOf('\r\n\r\n');
        const head = raw.subarray(0, split).toString().split('\r\n');
        let status = 200;
        const headers = {};
        for (const line of head) {
            const [name, ...rest] = line.split(':');
            const value = rest.join(':').trim();
            if (name.toLowerCase() === 'status') {
                status = Number.parseInt(value, 10);
            } else {
                headers[name] = value;
            }
        }
        res.writeHead(status, headers);
        res.end(raw.subarray(split + 4));
    });
    cgi.stdin.end(body);
});

await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${upstream.address().port}`;

const env = {
    ORIGIN: 'http://127.0.0.1:9',
    EDGE_KEY: process.env.EDGE_KEY,
    TICKET_KEY: process.env.TICKET_KEY,
    EGRESS_KEY: '0'.repeat(64),
    RUNNER_REPO: 'owner/runner',
    INSTALLATION_ID: '1',
    GITHUB_WEB_BASE: base,
    GITHUB_API_BASE: base,
};

// What the Workers runtime does in front of fetch(request, env).
const front = http.createServer(async (req, res) => {
    const headers = new Headers();
    for (let index = 0; index < req.rawHeaders.length; index += 2) {
        headers.append(req.rawHeaders[index], req.rawHeaders[index + 1]);
    }
    const init = { method: req.method, headers };
    if (req.method !== 'GET' && req.method !== 'HEAD') {
        init.body = Readable.toWeb(req);
        init.duplex = 'half';
    }

    const response = await worker.fetch(new Request(`http://edge.invalid${req.url}`, init), env);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body === null) {
        res.end();
        return;
    }
    Readable.fromWeb(response.body).pipe(res);
});

await new Promise((resolve) => front.listen(0, '127.0.0.1', resolve));
console.log(`READY ${front.address().port}`);
JS

: >"$work/upstream.log"
: >"$work/harness.out"
POOL_WORKER="$pool_worker" \
    UPSTREAM_LOG="$work/upstream.log" \
    GIT_HTTP_BACKEND="$(git --exec-path)/git-http-backend" \
    GIT_PROJECT_ROOT="$upstream" \
    EDGE_KEY="$edge_key" \
    TICKET_KEY="$ticket_key" \
    node "$work/harness.mjs" >"$work/harness.out" 2>"$work/harness.err" &
server_pid=$!

front_port=''
for _ in $(seq 1 100); do
    front_port="$(awk '$1 == "READY" { print $2 }' "$work/harness.out")"
    if [ -n "$front_port" ]; then
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || fail "the harness died: $(cat "$work/harness.err")"
    sleep 0.1
done
[ -n "$front_port" ] || fail 'the harness never listened'

# 3. ci-job's own fetch, as prepare runs it with features.git_proxy on.
# shellcheck source=scripts/ci-job
source "$here/../ci-job"
PATH="$here/..:$PATH"
exec 3>"$work/public.log"
tree="$work/tree"
secret="$work/secret"
state="$work/state"
mkdir -p "$secret" "$state"
api="http://127.0.0.1:$front_port"
git_proxy=true
head_sha="$head_commit"
base_sha=''
ticket="$(mint_ticket "$ticket_key" "{\"r\":\"owner/repo\",\"e\":$(($(date +%s) + 600))}")"
printf '%s' "$source_token" >"$secret/github-token"
printf '%s' "$ticket" >"$secret/git-ticket"
{
    printf 'header = "Authorization: Bearer %s"\n' "$source_token"
    printf 'header = "X-Ci-Ticket: %s"\n' "$ticket"
} >"$secret/github.curl"
git init --quiet "$tree"
printf '[remote "origin"]\n\turl = %s/git\n' "$api" >>"$tree/.git/config"

if ! fetch_source; then
    fail "fetch through the Worker failed: $(cat "$work/harness.err")"
fi
[ "$(cat "$tree/README")" = 'proxied hello' ] || fail 'the checkout does not hold the upstream commit'
[ "$(git -C "$tree" rev-parse HEAD)" = "$head_commit" ] || fail 'the checkout is not the requested commit'
pass 'git fetch --depth 1 through the Worker checks out the commit'

basic="Basic $(printf 'x-access-token:%s' "$source_token" | base64 | tr -d '\n')"
jq -se --arg basic "$basic" '
    map(select(.path | startswith("/owner/repo.git/"))) as $git
    | ($git | length) >= 2
    and ($git | any(.method == "GET" and .path == "/owner/repo.git/info/refs" and .query == "?service=git-upload-pack"))
    and ($git | any(.method == "POST" and .path == "/owner/repo.git/git-upload-pack"))
    and ($git | all(.authorization == $basic and .edge_key == null and .ticket == null))
' "$work/upstream.log" >/dev/null || fail "the upstream saw: $(cat "$work/upstream.log")"
pass 'the upstream saw the ticket path and the Basic credential, never the edge key or the ticket'

# 4. The revocation through the Worker's DELETE /gh-token.
revoke_token || fail 'the revocation through the Worker failed'
jq -se --arg bearer "Bearer $source_token" '
    map(select(.path == "/installation/token"))
    | length == 1 and .[0].method == "DELETE" and .[0].authorization == $bearer
    and .[0].edge_key == null and .[0].ticket == null
' "$work/upstream.log" >/dev/null || fail "the revocation reached the upstream as: $(cat "$work/upstream.log")"
[ ! -e "$secret/git-ticket" ] && [ ! -e "$secret/github-token" ] || fail 'the revocation left a secret behind'
pass 'the revocation goes through DELETE /gh-token with the token and without the ticket'

for value in "$source_token" "$ticket" owner/repo; do
    if grep -qF -- "$value" "$work/public.log"; then
        fail 'a secret or the repository reached the public log'
    fi
done
pass 'the public log carries no token, ticket or repository name'

echo 'PASS git-proxy.test.sh'
