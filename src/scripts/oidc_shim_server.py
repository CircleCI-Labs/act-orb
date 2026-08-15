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
