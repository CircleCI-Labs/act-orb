#!/bin/bash
set -uo pipefail

# BEGIN GENERATED: is_true (from src/scripts/lib/is_true.sh -- do not hand-edit; regenerate with `bash src/scripts/sync-embedded-is-true.sh`)
# shellcheck shell=bash
# Bash-safe truthiness for orb boolean parameters -- both "1"/"0" (published
# orb) and "true"/"false" (inline job, per this project's own recorded
# boolean-parameter quirk) must be accepted. This file is a sourced/embedded
# fragment, not a standalone executable -- no shebang, hence the shellcheck
# directive above instead.
#
# SINGLE SOURCE OF TRUTH for this function. install.sh, run-act.sh,
# cache-shim-start.sh, and oidc-shim-start.sh each embed a mechanically
# generated, byte-identical copy of this file's body between "BEGIN
# GENERATED: is_true" / "END GENERATED: is_true" markers -- regenerate all
# four with `bash src/scripts/sync-embedded-is-true.sh` any time this file
# changes.
#
# Why embedded copies rather than a plain `<<include(scripts/lib/is_true.sh)>>`
# in each command's `command:` field: that was tried first and reverted --
# the circleci-cli baked into orb-tools/pack's own Docker image rejects more
# than one <<include(...)>> directive in a single YAML scalar, and each of
# these four commands' `command:` field already has one include for its own
# main script (see git history for the reproduced real-CI pack failure: "An
# unexpected error occurred: multiple include statements"). This mirrors the
# generate-and-embed pattern this repo already uses for the two embedded
# Python shim servers (cache_shim_server.py/oidc_shim_server.py -- see
# sync-embedded-cache-server.sh/sync-embedded-oidc-server.sh); test_is_true_no_drift
# in .circleci/test-deploy.yml is the real, working drift check for this one
# (regenerates all four from this file and asserts `git diff` is clean).
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}
# END GENERATED: is_true

if ! is_true "${ORB_VAL_ENABLED}"; then
    echo "oidc-shim: enabled=false, not starting. ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN will not be set for later steps."
    exit 0
fi

STATE_DIR="${ORB_VAL_STATE_DIR:-/tmp/.oidc-shim}"
SERVER_PY="${STATE_DIR}/server.py"
SERVER_LOG="${STATE_DIR}/server.log"
PID_FILE="${STATE_DIR}/server.pid"
mkdir -p "${STATE_DIR}"

# --- Materialize the server -------------------------------------------------
#
# The server itself is a single stdlib-only Python 3 file, written out here
# via heredoc so this command ships as the one script file act-orb's own
# commands convention expects (see e.g. install.sh / run-act.sh: one
# `<<include(scripts/X.sh)>>` per command). `src/scripts/oidc_shim_server.py`
# in this same directory is the SINGLE SOURCE OF TRUTH for the server; this
# heredoc is a mechanically generated copy of it, not hand-maintained --
# regenerate it with `bash src/scripts/sync-embedded-oidc-server.sh` any time
# `oidc_shim_server.py` changes. `test_embedded_server_no_drift` in
# .circleci/test-deploy.yml is the real, working drift check for this one
# (regenerates the embedded copy from the canonical file and asserts `git
# diff` is clean) -- it additionally diffs the two and fails loudly if they
# are ever out of sync (belt-and-suspenders: catches a hand-edit of either
# copy that skipped the sync script). See `oidc_shim_server.py`'s own
# module docstring for the full design rationale (why Python, the exact
# toolkit request/response contract, and the security posture) -- it is
# not repeated here.
cat > "${SERVER_PY}" << 'OIDC_SHIM_SERVER_PY_EOF'
#!/usr/bin/env python3
"""
CircleCI ecosystem-bridge OIDC shim server.

Purpose
-------
`actions/toolkit`'s `core.getIDToken(audience)` does a GET against
`${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=<audience>` with an
`Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}` header, and reads
exactly one field back: `res.result.value` (see `oidc-utils.ts`, verified
against the upstream source -- no JWT decode, no signature check, nothing
else). This server impersonates that endpoint: on each request it shells
out to CircleCI's own job-runtime CLI (`circleci run oidc get --claims
'{"aud":"<audience>"}'`, documented at
https://circleci.com/docs/oidc-tokens-with-custom-claims) to mint a REAL
CircleCI-signed OIDC token with the requested audience, and hands it back
in the exact `{"value": "<jwt>"}` shape the toolkit expects. Any action
using the standard `@actions/core` OIDC helper (e.g.
`aws-actions/configure-aws-credentials`) works unmodified against it.

NOTE on the CLI it shells out to: this is *not* the general-purpose,
locally-installable `circleci` CLI (the one orb authors run on their own
laptop). It's the CircleCI job-runtime CLI baked into CircleCI's own
docker/machine executor images -- present in the job's PATH by default,
no install step needed. If `circleci run oidc get` isn't on PATH inside a
job, that job isn't running on a CircleCI-provided executor image; this
server surfaces that plainly as a 500 rather than hanging or crashing (see
FileNotFoundError handling below).

Why Python 3, not bash+nc or a compiled Go binary
--------------------------------------------------
This has to run, with no extra install step, on whatever executor image
the CircleCI job already happens to use -- that's the whole "no extra
install" constraint the orb's other commands (see `install.sh`) already
work hard to satisfy for Act itself, and this shim needs to satisfy it too:
  - Python 3 ships on every `cimg/*` convenience image, every Ubuntu-based
    machine-executor image, and the `catthehacker/ubuntu:act-latest`
    platform image `run-act`/`act/act` use by default. It requires no
    `pip install` -- everything used here (`http.server`, `socketserver`
    via `ThreadingHTTPServer`, `subprocess`, `json`, `urllib.parse`, `hmac`)
    is stdlib.
  - Node is guaranteed *inside* Act's own spawned action container (Act
    needs it to run JS actions) but is NOT guaranteed on the *outer* job
    image this shim actually runs on -- e.g. a minimal non-Node docker
    executor image. Relying on Node here would silently reintroduce the
    exact "extra install" problem this orb avoids for Act itself.
  - bash+nc can't do concurrent connections, a bounded subprocess timeout,
    or structured JSON without real contortions (see requirement #2:
    several audiences may be requested concurrently, and a hung mint
    command must not hang the whole shim). `ThreadingHTTPServer` +
    `subprocess.run(..., timeout=...)` get both for free.
  - A compiled Go binary would need either a build step in the orb
    (defeating "no extra install") or a prebuilt binary asset shipped and
    version-pinned per-arch -- much more moving parts than a single
    stdlib-only Python file for a job this small.

Security
--------
- This process binds to whatever host/port it's told (see `main()`). The
  bind is deliberately wide (`0.0.0.0` by default) because, when
  `act/act`/`act/run-act` runs the wrapped action inside Act's own spawned
  Docker container, that container is a SIBLING of whatever process started
  this shim -- a different network namespace -- so a loopback-only bind
  here would simply be unreachable from it (measured directly on real
  CircleCI infra: a `docker executor` + `setup_remote_docker` job whose
  container bound `0.0.0.0` answered its OWN loopback fine, but a sibling
  container on the default bridge network could NOT reach it at all;
  only a sibling started with `--network host` could -- see the README's
  "Why not loopback" section for the full measured detail). Because the
  bind can't be narrowed to loopback, the real auth boundary has to be
  something else -- see the next point.
- Every token-minting request (anything other than `/healthz`) MUST carry
  `Authorization: Bearer <token>` matching the per-job request token this
  server was started with (`OIDC_SHIM_REQUEST_TOKEN`, generated fresh per
  job by the orb command -- see `oidc-shim-start.sh` -- with
  `secrets.token_urlsafe(32)` or an equivalently secure fallback, never a
  guessable value). The comparison uses `hmac.compare_digest` specifically
  to avoid a timing side-channel that could otherwise be used to recover
  the token byte-by-byte. A missing or mismatched token gets a 401 and
  nothing else happens -- in particular, the mint subprocess is never
  invoked, so a request that fails auth cannot burn a real CircleCI OIDC
  mint call. This token is the actual security boundary for this
  service: anything that cannot present it gets nothing, regardless of
  what it can reach on the network.
- The expected token is never echoed back in any response body or log
  line, including on a 401 (the response only says the check failed, not
  what would have passed).
- `/healthz` intentionally stays unauthenticated -- the orb command's
  startup probe polls it before any per-job token exists in the caller's
  hands in a way that would let it authenticate -- but it must never
  return anything beyond a static `{"status": "ok"}`. It performs no
  audience lookup, spawns no subprocess, and cannot be coaxed into
  minting or echoing anything sensitive.
- The minted JWT is never written to this process's own logs (see
  `Handler.log_message`) and never appears in any log line this script
  emits itself -- only in the HTTP response body, which is the one place
  it needs to be for the calling action to read it. The wrapping orb
  command must not echo the response body either.
"""
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MINT_TIMEOUT_SECONDS = float(os.environ.get("OIDC_SHIM_MINT_TIMEOUT", "20"))
CIRCLECI_BIN = os.environ.get("OIDC_SHIM_CIRCLECI_BIN", "circleci")
# The real auth boundary for this service -- see the module docstring's
# Security section. Required: main() refuses to start without it rather
# than silently running unauthenticated.
REQUEST_TOKEN = os.environ.get("OIDC_SHIM_REQUEST_TOKEN", "")
# Comma-separated exact-match allow-list. Empty means "allow any audience".
# Defense in depth only -- this bounds the blast radius of *which* tokens
# an already-authenticated caller (see REQUEST_TOKEN above) can mint.
_allowlist_raw = os.environ.get("OIDC_SHIM_AUDIENCE_ALLOWLIST", "").strip()
AUDIENCE_ALLOWLIST = (
    {a.strip() for a in _allowlist_raw.split(",") if a.strip()}
    if _allowlist_raw
    else None
)


class Handler(BaseHTTPRequestHandler):
    server_version = "oidc-shim/1.0"

    def log_message(self, fmt, *args):
        # Overridden only to prefix/route output predictably under test;
        # still never logs a response body or the Authorization header
        # (see module docstring's Security section).
        sys.stderr.write("oidc-shim: " + (fmt % args) + "\n")

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _is_authorized(self):
        # Constant-time comparison -- a plain `==` short-circuits on the
        # first mismatched byte, which leaks how many leading bytes of an
        # attacker-supplied header happen to match the real token to
        # anyone who can measure response timing. hmac.compare_digest
        # does not have that leak.
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {REQUEST_TOKEN}"
        return hmac.compare_digest(supplied, expected)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/healthz":
            # Cheap, no subprocess, unauthenticated by design -- exists so
            # the orb command's bounded startup wait (requirement #2)
            # doesn't burn mint attempts just to confirm the socket is up.
            # Must never expose anything beyond this static body.
            self._send_json(200, {"status": "ok"})
            return

        if not self._is_authorized():
            # Reject before doing anything else: no audience parsing, no
            # allowlist check, and -- critically -- no subprocess call.
            # An unauthenticated caller can never cause a real OIDC mint.
            # The expected token is never included here or anywhere else.
            self._send_json(
                401,
                {
                    "message": (
                        "missing or invalid Authorization bearer token. "
                        "This shim only mints tokens for requests carrying "
                        "the exact per-job request token it generated for "
                        "this job (exported as "
                        "ACTIONS_ID_TOKEN_REQUEST_TOKEN); this request did "
                        "not present it."
                    )
                },
            )
            return

        qs = parse_qs(parsed.query)
        audience = (qs.get("audience") or [""])[0]

        if not audience:
            self._send_json(
                400,
                {
                    "message": (
                        "missing 'audience' query parameter. This shim mints "
                        "a CircleCI OIDC token with a custom 'aud' claim per "
                        "request; actions/toolkit only sends 'audience' when "
                        "the calling action passes one to core.getIDToken(aud). "
                        "An action that omits it is not supported by this shim."
                    )
                },
            )
            return

        if AUDIENCE_ALLOWLIST is not None and audience not in AUDIENCE_ALLOWLIST:
            self._send_json(
                403,
                {
                    "message": (
                        f"audience '{audience}' is not on this shim's "
                        "audience-allowlist"
                    )
                },
            )
            return

        claims = json.dumps({"aud": audience})
        cmd = [CIRCLECI_BIN, "run", "oidc", "get", "--claims", claims]

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=MINT_TIMEOUT_SECONDS,
            )
        except FileNotFoundError:
            self._send_json(
                500,
                {
                    "message": (
                        f"'{CIRCLECI_BIN}' binary not found on PATH inside "
                        "this job. This shim requires CircleCI's built-in "
                        "job-runtime CLI, which ships by default on "
                        "CircleCI's own docker/machine executor images -- "
                        "see the act-orb README's OIDC section for details."
                    )
                },
            )
            return
        except subprocess.TimeoutExpired:
            self._send_json(
                500,
                {
                    "message": (
                        f"'{CIRCLECI_BIN} run oidc get' did not finish within "
                        f"{MINT_TIMEOUT_SECONDS}s"
                    )
                },
            )
            return
        except Exception as exc:  # noqa: BLE001 -- last resort: always answer, never let the server die on one bad request.
            self._send_json(
                500, {"message": f"unexpected error invoking mint command: {exc}"}
            )
            return

        if proc.returncode != 0:
            # The stderr detail MUST live inside the "message" string itself,
            # not a sibling JSON field: @actions/http-client's
            # _processResponse() only ever reads `obj.message` for its thrown
            # error's text (see _processResponse in http-client-index.ts.reference)
            # -- anything placed next to it as its own key is silently
            # dropped from what the wrapped action actually sees/catches.
            stderr = proc.stderr.strip()
            self._send_json(
                500,
                {
                    "message": (
                        f"mint command exited {proc.returncode}"
                        + (f": {stderr}" if stderr else " (no stderr output)")
                    )
                },
            )
            return

        token = proc.stdout.strip()
        if not token:
            self._send_json(
                500,
                {"message": "mint command exited 0 but printed no token to stdout"},
            )
            return

        # Exact shape actions/toolkit's oidc-utils.ts expects: it does
        # `httpclient.getJson<TokenResponse>(url)` where
        # `interface TokenResponse { value?: string }`, then reads
        # `res.result?.value`. Verified against the upstream source.
        self._send_json(200, {"value": token})

    def do_HEAD(self):
        self.do_GET()


def main():
    if not REQUEST_TOKEN:
        sys.stderr.write(
            "oidc-shim: ERROR: OIDC_SHIM_REQUEST_TOKEN is not set. This is "
            "the real auth boundary for this server (see module docstring's "
            "Security section) -- refusing to start unauthenticated rather "
            "than silently serving mint requests to anything that can reach "
            "the socket.\n"
        )
        sys.exit(1)

    host = os.environ.get("OIDC_SHIM_HOST", "127.0.0.1")
    port = int(os.environ.get("OIDC_SHIM_PORT", "8990"))
    server = ThreadingHTTPServer((host, port), Handler)
    sys.stderr.write(f"oidc-shim: listening on {host}:{port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
OIDC_SHIM_SERVER_PY_EOF

# --- Pick the address to advertise ------------------------------------------
#
# The socket always binds ${ORB_VAL_BIND_HOST} (0.0.0.0 by default), but the
# address we put in ACTIONS_ID_TOKEN_REQUEST_URL -- the one the *action's own
# process* will actually connect to -- needs more thought than "loopback".
# When `act/act`/`act/run-act` runs the action inside Act's own spawned
# container (the normal case -- see act-orb's README "Quick Start"), that
# container is a SIBLING of whatever process started this shim, not the same
# network namespace, so 127.0.0.1 in the action's container is *that
# container's own* loopback -- never this shim. This was directly measured
# on real CircleCI infra (docker executor + setup_remote_docker), not just
# reasoned about: a job container bound 0.0.0.0 answered its own loopback
# with 200, but a sibling container on the default bridge network could NOT
# reach it (connection failed) -- only a sibling started with
# `--network host` could. So: bind wide (0.0.0.0) -- narrowing this to
# loopback would make the shim unreachable from Act's sibling container in
# the common case -- and separately advertise the narrowest address that
# sibling containers can actually reach, auto-detected in the order below
# unless overridden. Because the bind can't be loopback-only, the real auth
# boundary is the per-job request token generated below and enforced by
# every non-`/healthz` request the server handles (see
# `oidc_shim_server.py`'s module docstring, Security section) -- not the
# network position of the socket.
detect_advertise_host() {
    if [ -n "${ORB_VAL_ADVERTISE_HOST:-}" ] && [ "${ORB_VAL_ADVERTISE_HOST}" != "auto" ]; then
        echo "${ORB_VAL_ADVERTISE_HOST}"
        return 0
    fi

    # Tier 1: we ARE the Docker host (default `machine` executor topology --
    # Act uses this host's own local Docker daemon to spawn its containers).
    # Those containers reach the host at the bridge network's gateway
    # address, which -- because we bind 0.0.0.0 -- this shim is listening on
    # too.
    if command -v docker > /dev/null 2>&1; then
        gw="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2> /dev/null || true)"
        if [ -n "${gw}" ]; then
            echo "${gw}"
            return 0
        fi
    fi

    # Tier 2: `docker executor` + `setup_remote_docker` topology -- this
    # shim runs inside the CircleCI job's own container, and Act's spawned
    # containers are its siblings on the remote-docker environment's shared
    # bridge (the bind-mounted host Docker socket makes `docker inspect`
    # reachable from in here). Ask for THIS container's own bridge IP.
    if command -v docker > /dev/null 2>&1; then
        cid="$(cat /etc/hostname 2> /dev/null || true)"
        if [ -n "${cid}" ]; then
            ip="$(docker inspect "${cid}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2> /dev/null || true)"
            if [ -n "${ip}" ]; then
                echo "${ip}"
                return 0
            fi
        fi
    fi

    # Tier 3: last resort -- first non-loopback IPv4 address on this host.
    # UNVERIFIED as a general solution: correct on a plain `machine`
    # executor VM (no docker CLI available at all is unlikely there, so
    # this tier mostly exists for topologies this script's author didn't
    # anticipate). Flagged loudly rather than silently trusted.
    ip="$(hostname -I 2> /dev/null | awk '{print $1}')"
    if [ -z "${ip}" ]; then
        ip="$(python3 -c 'import socket; print(socket.gethostbyname(socket.gethostname()))' 2> /dev/null || true)"
    fi
    if [ -n "${ip}" ]; then
        echo "oidc-shim: WARNING: could not detect a docker-bridge address via 'docker network inspect' or 'docker inspect'; falling back to this host's primary interface IP (${ip}). This has NOT been verified to be reachable from Act's spawned action container in every topology -- if actions/toolkit's GET to ACTIONS_ID_TOKEN_REQUEST_URL fails to connect, set the 'advertise-host' parameter explicitly." >&2
        echo "${ip}"
        return 0
    fi

    echo "oidc-shim: ERROR: could not determine any address to advertise (tried docker bridge gateway, own container IP, and host primary IP, all failed). Set the 'advertise-host' parameter explicitly." >&2
    return 1
}

ADVERTISE_HOST="$(detect_advertise_host)" || exit 1
ADVERTISE_URL_BASE="http://${ADVERTISE_HOST}:${ORB_VAL_PORT}/?"

# --- Generate the per-job request token -------------------------------------
#
# This is the REAL auth boundary (see the "Pick the address to advertise"
# comment above and oidc_shim_server.py's Security section) -- the socket
# can't be narrowed to loopback, so every non-/healthz request must present
# this exact value as `Authorization: Bearer <token>` or the server rejects
# it with 401 before minting anything. It MUST come from a cryptographically
# secure source with real entropy, never from a guessable value like a pid
# or timestamp -- a weak token here would make the auth check theater.
REQUEST_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2> /dev/null || true)"
if [ -z "${REQUEST_TOKEN}" ]; then
    # No python3 (shouldn't happen -- the server itself requires it -- but
    # guard anyway): fall back to reading raw entropy from the kernel CSPRNG
    # directly, NOT $$/date (guessable, not a fix for anything). 32 bytes
    # hex-encoded, same order of entropy as the primary path above.
    REQUEST_TOKEN="$(head -c 32 /dev/urandom 2> /dev/null | od -An -tx1 2> /dev/null | tr -d ' \n')"
fi
if [ -z "${REQUEST_TOKEN}" ]; then
    echo "oidc-shim: ERROR: could not generate a cryptographically secure request token (no python3 'secrets' module and no /dev/urandom). Refusing to start with a weak/guessable token -- that would defeat the one real auth boundary this shim has." >&2
    exit 1
fi

# --- Launch ------------------------------------------------------------------
OIDC_SHIM_HOST="${ORB_VAL_BIND_HOST}" \
    OIDC_SHIM_PORT="${ORB_VAL_PORT}" \
    OIDC_SHIM_MINT_TIMEOUT="${ORB_VAL_MINT_TIMEOUT}" \
    OIDC_SHIM_CIRCLECI_BIN="${ORB_VAL_CIRCLECI_BIN}" \
    OIDC_SHIM_AUDIENCE_ALLOWLIST="${ORB_VAL_AUDIENCE_ALLOWLIST:-}" \
    OIDC_SHIM_REQUEST_TOKEN="${REQUEST_TOKEN}" \
    nohup python3 "${SERVER_PY}" > "${SERVER_LOG}" 2>&1 &
SERVER_PID=$!
echo "${SERVER_PID}" > "${PID_FILE}"
disown "${SERVER_PID}" 2> /dev/null || true

# --- Bounded startup wait (requirement: never race the server) -------------
# Poll /healthz -- not a real mint -- from loopback, which always reaches a
# 0.0.0.0-bound local socket on its own bind port regardless of which
# address we advertise externally.
READY=false
DEADLINE=$(($(date +%s) + ORB_VAL_STARTUP_TIMEOUT))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if ! kill -0 "${SERVER_PID}" 2> /dev/null; then
        echo "oidc-shim: ERROR: server process (pid ${SERVER_PID}) exited during startup. Log:" >&2
        cat "${SERVER_LOG}" >&2
        exit 1
    fi
    if command -v curl > /dev/null 2>&1; then
        # --connect-timeout/--max-time are load-bearing, not defensive
        # styling: if some OTHER process is already listening on this port
        # (a leftover shim from a prior run, anything else) curl's TCP
        # connect succeeds immediately, and with no per-call timeout it
        # then blocks forever waiting for an HTTP response that never
        # comes -- which silently turns this "bounded" startup wait into
        # an unbounded one, exactly the failure mode this loop exists to
        # prevent. Caught by this repo's own test suite (test/run_tests.sh
        # Test 7): before this fix, an occupied port made the whole start
        # script hang for as long as whatever was occupying the port kept
        # running, regardless of startup-timeout.
        if curl -fsS --connect-timeout 1 --max-time 1 -o /dev/null "http://127.0.0.1:${ORB_VAL_PORT}/healthz" 2> /dev/null; then
            READY=true
            break
        fi
    else
        if python3 -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:${ORB_VAL_PORT}/healthz', timeout=1)" 2> /dev/null; then
            READY=true
            break
        fi
    fi
    sleep 0.2
done

if [ "${READY}" != "true" ]; then
    echo "oidc-shim: ERROR: server did not become ready within ${ORB_VAL_STARTUP_TIMEOUT}s. Log:" >&2
    cat "${SERVER_LOG}" >&2
    kill "${SERVER_PID}" 2> /dev/null || true
    exit 1
fi

# --- Export for later steps in this same job --------------------------------
#
# A `run` step's own `environment:` block only scopes env vars to THAT step,
# and the values here (the advertise address, the per-run request token) are
# only known at runtime -- they can't be a static `environment:` value
# resolved from a parameter at config-compile time. So, same convention this
# orb already uses for `collect-outputs`/`outputs`: append `export` lines to
# $BASH_ENV, which CircleCI sources at the start of every subsequent step's
# shell in this job. In particular, `create-env-var-secret-files` (composed
# into `act/act`/`act/run-act`) snapshots the *entire* job environment via
# `env -0` -- so ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN reach Act's own env file,
# and from there Act's spawned action container, the same way the existing
# `github-token` seam already flows a value through -- automatically, with
# no wiring required at the `act/act` call site, as long as this command
# runs in an earlier step of the same job.
if [ -z "${BASH_ENV:-}" ]; then
    echo "oidc-shim: ERROR: \$BASH_ENV is not set. CircleCI always sets this for every job -- if you're seeing this, you're running this script outside a real CircleCI job (e.g. local testing) without exporting BASH_ENV yourself first." >&2
    exit 1
fi

# REQUEST_TOKEN was already generated above, before the server was started,
# so the running server was launched with OIDC_SHIM_REQUEST_TOKEN set to
# this same value from the start -- it is exported here purely so later
# steps in this job (and the wrapped action) receive it too.
{
    printf 'export ACTIONS_ID_TOKEN_REQUEST_URL=%q\n' "${ADVERTISE_URL_BASE}"
    printf 'export ACTIONS_ID_TOKEN_REQUEST_TOKEN=%q\n' "${REQUEST_TOKEN}"
} >> "${BASH_ENV}"

echo "oidc-shim: ready (pid ${SERVER_PID}), advertising ${ADVERTISE_URL_BASE} to later steps in this job."
