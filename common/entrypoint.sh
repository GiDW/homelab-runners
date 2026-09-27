#!/bin/sh
# Register one ephemeral just-in-time (JIT) runner for a repository and run it.
#
# Authenticates as a GitHub App: signs a JWT with the App's private key, looks
# up the App's installation on the repository, mints an installation token
# (limited to that repository and to Administration: write), asks for a JIT
# runner config, revokes the token, drops to the `runner` user and execs
# run.sh. The runner takes exactly one job and exits; the container manager
# then starts a fresh container.
#
# Environment (see deploy/env/example.env):
#   GITHUB_APP_ID        App ID or Client ID of the GitHub App (required)
#   RUNNER_REPOSITORY    owner/repo to register the runner for (required)
#   GITHUB_APP_KEY_FILE  private key (PEM), default /run/secrets/github-app-key
#   RUNNER_LABELS        comma-separated, default self-hosted,Linux,<arch>,home
#   RUNNER_GROUP_ID      default 1 (the default group, repository runners)
#   RUNNER_NAME_PREFIX   default home-<repo>
#   GITHUB_API_URL       default https://api.github.com
#   RUNNER_FAIL_DELAY    seconds to wait before exiting on error, default 30
set -eu

log() { printf 'entrypoint: %s\n' "$*" >&2; }

die() {
	printf 'entrypoint: ERROR: %s\n' "$*" >&2
	# The container is restarted on exit; don't hammer the API in a loop.
	sleep "${RUNNER_FAIL_DELAY:-30}"
	exit 1
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# api METHOD PATH TOKEN [JSON]: sets $status, $body and $msg (the API's
# error message, if any). The token goes to curl on stdin, not in argv.
api() {
	_method=$1 _url=$api_url$2 _token=$3 _data=${4-}
	set -- -X "$_method" "$_url"
	if [ -n "$_data" ]; then
		set -- "$@" -H 'Content-Type: application/json' --data-binary "$_data"
	fi
	_out=$(printf 'header = "Authorization: Bearer %s"\n' "$_token" |
		curl -sS -K - \
			-H 'Accept: application/vnd.github+json' \
			-H 'X-GitHub-Api-Version: 2022-11-28' \
			-H 'User-Agent: homelab-runners' \
			--connect-timeout 10 --max-time 60 --retry 3 \
			-w '\n%{http_code}' "$@") ||
		die "$_method $2: request failed (network, DNS or egress filter?)"
	status=$(printf '%s\n' "$_out" | tail -n 1)
	body=$(printf '%s\n' "$_out" | sed '$d')
	msg=$(printf '%s' "$body" | jq -r '.message? // empty' 2>/dev/null || true)
}

# expect STATUS WHAT HINT: fail with the API's message unless $status matches.
expect() {
	[ "$status" = "$1" ] && return 0
	die "$2 failed: HTTP $status${msg:+: $msg}${3:+
  hint: $3}"
}

# --- configuration -----------------------------------------------------------

api_url=${GITHUB_API_URL:-https://api.github.com}
app_id=${GITHUB_APP_ID:-}
key_file=${GITHUB_APP_KEY_FILE:-/run/secrets/github-app-key}
repo=${RUNNER_REPOSITORY:-}
group_id=${RUNNER_GROUP_ID:-1}

case $(uname -m) in
x86_64) arch=X64 ;;
aarch64 | arm64) arch=ARM64 ;;
*) arch=$(uname -m) ;;
esac
labels=${RUNNER_LABELS:-self-hosted,Linux,$arch,home}

case $app_id in
'') die "GITHUB_APP_ID is not set (the GitHub App's App ID or Client ID)" ;;
*[!A-Za-z0-9.]*) die "GITHUB_APP_ID contains unexpected characters: '$app_id'" ;;
esac
case $repo in
'') die "RUNNER_REPOSITORY is not set (owner/repo)" ;;
*/*/* | /* | */ | *[!A-Za-z0-9._/-]*) die "RUNNER_REPOSITORY must be owner/repo, got '$repo'" ;;
*/*) ;;
*) die "RUNNER_REPOSITORY must be owner/repo, got '$repo'" ;;
esac
case $group_id in
'' | *[!0-9]*) die "RUNNER_GROUP_ID must be a number, got '$group_id'" ;;
esac
[ -r "$key_file" ] ||
	die "cannot read the GitHub App private key at $key_file (is the podman secret mounted?)"

name_prefix=${RUNNER_NAME_PREFIX:-home-${repo#*/}}
name=$name_prefix-$(date -u +%Y%m%d%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')

labels_json=$(jq -cn --arg l "$labels" \
	'$l | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
[ "$labels_json" != "[]" ] || die "RUNNER_LABELS is empty"

# --- sanity checks that only warn ---------------------------------------------

if [ "$(id -u)" = 0 ]; then
	# The key must not be readable by `runner` (i.e. by jobs).
	perm=$(stat -Lc '%u %a' "$key_file")
	case $perm in
	'0 400' | '0 600') ;;
	*) log "WARNING: $key_file has owner/mode '$perm'; jobs may be able to read it (use uid=0,mode=0400)" ;;
	esac
fi
# Nested rootless podman maps runner's sub-IDs (100000-165535) from the
# outer container, which therefore needs at least 165536 uids.
mapped=$(awk '{ n += $3 } END { print n + 0 }' /proc/self/uid_map)
if [ "$mapped" -lt 165536 ]; then
	log "WARNING: only $mapped uids mapped into this container; nested podman/buildah needs 165536 (enlarge the host user's /etc/subuid range)"
fi
if command -v getcap >/dev/null && ! getcap /usr/bin/newuidmap | grep -q cap_setuid; then
	log "WARNING: /usr/bin/newuidmap has no cap_setuid file capability; nested podman/buildah will fail"
fi

# --- GitHub App JWT (RS256, iat 60 s in the past, exp < 10 min) ---------------

# iss: a numeric App ID is sent as a JSON number, a Client ID as a string.
case $app_id in
*[!0-9]*) iss="\"$app_id\"" ;;
*) iss=$app_id ;;
esac
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$((now - 60))" "$((now + 540))" "$iss" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" |
	openssl dgst -sha256 -sign "$key_file" -binary | b64url)
[ -n "$sig" ] || die "signing the JWT with $key_file failed (not an RSA private key in PEM format?)"
jwt=$header.$payload.$sig

# --- installation -> installation token -> JIT config ------------------------

api GET "/repos/$repo/installation" "$jwt"
case $status in
401) expect 200 "authenticating as the GitHub App" \
	"check that GITHUB_APP_ID and the private key belong to the same App, and that the host clock is correct" ;;
404) expect 200 "looking up the App installation on $repo" \
	"install the App on $repo (Settings > Applications, or the App's page > Install)" ;;
*) expect 200 "looking up the App installation on $repo" ;;
esac
installation_id=$(printf '%s' "$body" | jq -r '.id')

# Scope the token down to this one repository and the one permission needed.
api POST "/app/installations/$installation_id/access_tokens" "$jwt" \
	"$(jq -cn --arg r "${repo#*/}" '{repositories: [$r], permissions: {administration: "write"}}')"
expect 201 "creating an installation token for $repo" \
	"the App needs the repository permission 'Administration: Read and write', and the installation must include $repo"
token=$(printf '%s' "$body" | jq -r '.token')

api POST "/repos/$repo/actions/runners/generate-jitconfig" "$token" \
	"$(jq -cn --arg n "$name" --argjson g "$group_id" --argjson l "$labels_json" \
		'{name: $n, runner_group_id: $g, labels: $l}')"
expect 201 "generating a JIT runner config for $repo" \
	"a 409 means a runner named '$name' already exists; a 404 usually means a wrong RUNNER_GROUP_ID or missing permission"
jit=$(printf '%s' "$body" | jq -r '.encoded_jit_config')
runner_id=$(printf '%s' "$body" | jq -r '.runner.id')
if [ -z "$jit" ] || [ "$jit" = null ]; then
	die "the JIT config response has no encoded_jit_config"
fi

# The token is no longer needed; revoking it is best effort.
api DELETE /installation/token "$token"
[ "$status" = 204 ] || log "WARNING: revoking the installation token returned HTTP $status (it expires within an hour anyway)"

log "registered JIT runner '$name' (id $runner_id) for $repo with labels $labels_json"

# --- hand over to the runner ---------------------------------------------------

unset jwt token sig body _out header payload \
	GITHUB_APP_ID GITHUB_APP_KEY_FILE RUNNER_REPOSITORY RUNNER_LABELS \
	RUNNER_GROUP_ID RUNNER_NAME_PREFIX GITHUB_API_URL RUNNER_FAIL_DELAY

cd /home/runner
# XDG_RUNTIME_DIR stays unset: nested podman then uses /tmp/podman-run-<uid>.
export HOME=/home/runner USER=runner LOGNAME=runner

if [ "$(id -u)" = 0 ]; then
	# Drop to runner; the capability bounding set is kept so that the file
	# capabilities on newuidmap/newgidmap (and chroot in nested builds) work.
	exec setpriv --reuid=runner --regid=runner --init-groups --inh-caps=-all \
		./run.sh --jitconfig "$jit"
fi

log "WARNING: not started as root; the App key stays readable by jobs"
exec ./run.sh --jitconfig "$jit"
