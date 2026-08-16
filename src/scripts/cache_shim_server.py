#!/usr/bin/env python3
"""
CircleCI ecosystem-bridge Actions-cache shim server.

Purpose
-------
`actions/cache@v4` (and the dozens of `setup-*` actions with built-in
caching) talks to GitHub's cache-service v2 protocol: a small set of Twirp
(JSON-over-HTTP) RPCs at `${ACTIONS_RESULTS_URL}twirp/github.actions.results.
api.v1.CacheService/<Method>`, plus a block-blob-style chunked upload/download
against whatever URL those RPCs hand back (`@azure/storage-blob`'s
`BlockBlobClient`, driven by `actions/cache`'s own `uploadCacheArchiveSDK`/
`downloadCacheStorageSDK`). This server impersonates that whole surface, and
translates each call into CircleCI's own task-output cache API
(`$runner_host/api/v2/output/cache-save` / `cache-restore`, authenticated with
the per-job task token read from `/tmp/circleci-ts.sock` -- see
`read_task_token()` below).

Protocol, verified against the real `actions/toolkit` source (packages/cache
src/cache.ts, cacheTwirpClient.ts, uploadUtils.ts) -- not guessed:
  - Twirp request/response bodies are plain JSON (the real client always
    sends `Content-Type: application/json`; see cacheTwirpClient.ts's
    `CacheServiceClient.request()`).
  - `CreateCacheEntryRequest{key,version}` -> `{ok, signed_upload_url}`.
  - The actual bytes go through Azure Blob's block-blob wire protocol against
    `signed_upload_url`: for anything over `maxSingleShotSize` (128 MiB, per
    `uploadCacheArchiveSDK`'s own options), a sequence of `PUT
    ...?comp=block&blockid=<b64>` (or `appendBlock`) calls, each with a chunk
    of the archive, followed by one `PUT ...?comp=blocklist` that commits the
    upload. For anything smaller -- the common case, confirmed live against
    this shim's own CI test -- `@azure/storage-blob`'s `BlockBlobClient`
    instead does exactly ONE plain `PUT` of the whole body with NO `comp`
    query parameter at all. No separate presigned-PUT step either way -- the
    "URL" IS the thing bytes are PUT to.
  - `FinalizeCacheEntryUploadRequest{key,version,size_bytes}` ->
    `{ok, entry_id}`.
  - `GetCacheEntryDownloadURLRequest{key,restore_keys,version}` ->
    `{ok, signed_download_url, matched_key}` on a hit, `{ok:false}` on a
    miss. Unlike upload, a real download URL (once we have one) needs no
    shim proxying at all: `actions/cache`'s `downloadCache()` just does a
    plain GET against whatever URL this hands back (it only special-cases
    `*.blob.core.windows.net` hostnames for the Azure SDK path; anything
    else -- including a CircleCI URL -- goes through a plain HTTP GET). So
    this server can, in principle, hand back CircleCI's own presigned GET
    URL directly and step out of the way.

The real upload/download contract -- how the gap below was actually closed
----------------------------------------------------------------------------
An earlier version of this shim tried the obvious reading of the
`cache-save` ticket -- POST the archive bytes straight to
`$runner_host/<location>` -- and every construction 404'd, repeatedly,
across many real pipeline runs (see git history / the README's cache-shim
section for that full reproduced trail). The 404s were real, but the
diagnosis was wrong: `location` was never a route on `runner_host` at all.

Read directly from CircleCI's own `circleci/output` and
`circleci/task-agent-subcommand-cache` server/client source (the same
production code that backs Bazel/Gradle/Xcode-CAS/Turborepo remote caching
today), confirmed live against this shim's own CI job:
  - `GET {runner_host}/api/v2/output/config` (bearer = task token) returns
    `{"type":"s3","endpoint":"","region":"us-east-1","bucket":"circleci-
    tasks-prod",...}` on CircleCI's SaaS -- always `type=="s3"`; a
    `"pre-signed"` mode exists in the server's own code but is documented
    there as enterprise-only, never seen on SaaS.
  - `GET {runner_host}/api/v2/output/credentials?provider=s3` (same bearer)
    returns `{"s3":{"AccessKeyID":...,"SecretAccessKey":...,
    "SessionToken":...,"Expires":...}}` -- short-lived (~15 min observed),
    per-task AWS STS credentials via `AssumeRole`, IAM-scoped to this task's
    own storage prefixes only.
  - The cache-save ticket's `location` (e.g.
    `storage/caches/<projectID>/<key>.tar.zst`) is not a URL fragment at
    all -- it is a raw S3 *object key* in the bucket from `config`. The real
    upload is a normal, SigV4-signed S3 `PutObject` (with the ticket's
    `tags` sent as the `x-amz-tagging` header, an S3 lifecycle/retention
    hint, not a general metadata channel) using the temporary credentials
    from `credentials`. There is no separate presigned-PUT step and no
    plain unauthenticated POST to `runner_host` -- that's exactly why every
    prior attempt at the latter 404'd: no such route exists by design.
  - Download is symmetric: `cache-restore`'s `location` is the same kind of
    S3 key; fetching it is a SigV4-signed S3 `GetObject` with the same
    credentials call.

`_s3_put_object()`/`_s3_get_object()`/`_sigv4_authorization()` below
implement exactly this, in pure stdlib (`hmac`/`hashlib`, no boto3 -- same
zero-extra-install constraint as the rest of this shim; see "Why Python 3"
below). Because `actions/cache`'s real Azure `BlockBlobClient` only ever
talks to the URL `CreateCacheEntry` handed it, and that URL has to be
something reachable *without* AWS credentials (the wrapped action never
sees this shim's STS creds), the upload path stays a *local* proxy exactly
as before (`/upload/<id>`, this shim's own request-token auth) -- what
changed is what happens when that local proxy commits: it now does a real,
signed S3 `PutObject` instead of a plain unsigned POST to `runner_host`.
Download works the same way in reverse: `GetCacheEntryDownloadURL` now hands
back a URL pointing at this shim's own new `/download/<id>` endpoint (not a
raw S3 URL `actions/cache` could never authenticate against on its own),
which performs the signed S3 `GetObject` itself and streams the bytes back.

`actions/cache` still treats a save failure as a non-fatal `core.warning`
and a restore miss as `undefined` (cold build) -- unchanged from before, and
still the right safety net for whatever this shim cannot yet handle (e.g. a
job long enough to outlive the ~15-minute STS credential window; each S3
call fetches fresh credentials rather than caching them, which bounds but
does not eliminate that risk for a very long-running single upload).

Why Python 3, not bash+nc or a compiled Go binary
--------------------------------------------------
Identical reasoning to `act/oidc-shim`'s own `oidc_shim_server.py` (see that
file's module docstring for the full argument) -- ships on every `cimg/*`
image and Act's own default platform image with zero install step, and
`ThreadingHTTPServer` + `socket.settimeout` give bounded, concurrent handling
of several simultaneous cache RPCs for free.

Security
--------
Same discipline as `act/oidc-shim`, which was itself fixed after a real
security review caught it discarding its own auth header (see that file's
module docstring and the orb README's Security notes) -- applied here from
the start rather than re-learning the lesson:
  - This process binds wide (`0.0.0.0` by default) because Act's spawned
    action container is a SIBLING of whatever process starts this shim, in
    its own network namespace; a loopback-only bind would be unreachable
    from it (measured on real CircleCI infra for the OIDC shim; the same
    Docker topology applies here unchanged).
  - Because the bind can't be loopback-only, the REAL auth boundary is the
    per-job request token this server is started with
    (`CACHE_SHIM_REQUEST_TOKEN`, generated fresh per job with
    `secrets.token_urlsafe(32)` -- see `cache-shim-start.sh`). Every
    Twirp RPC must carry it as `Authorization: Bearer <token>` (checked with
    `hmac.compare_digest`, constant-time) -- and conveniently arrives there
    for free, because this same token is also what this shim tells
    `actions/cache` its `ACTIONS_RUNTIME_TOKEN` is. The block-blob upload
    PUTs carry no such header in real Azure semantics (the auth normally
    lives in the presigned URL's own query string), so this shim embeds the
    SAME token as a `token=` query parameter on the `signed_upload_url` it
    hands back and checks it there too, constant-time, closing the one gap
    real Azure semantics would otherwise leave on a wide bind.
  - `/healthz` stays unauthenticated by design (the startup probe polls it
    before any per-job token exists in a form that could authenticate) but
    returns nothing beyond a static `{"status":"ok"}`.
  - Neither the per-job request token nor the CircleCI task token read from
    `/tmp/circleci-ts.sock` is ever written to this process's own logs.
"""
import base64
import datetime
import hashlib
import hmac
import json
import os
import socket
import struct
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlparse

TASK_SOCKET_PATH = os.environ.get("CACHE_SHIM_TASK_SOCKET", "/tmp/circleci-ts.sock")
# The real auth boundary for this service -- see the module docstring's
# Security section. Required: main() refuses to start without it.
REQUEST_TOKEN = os.environ.get("CACHE_SHIM_REQUEST_TOKEN", "")
RUNNER_CALL_TIMEOUT = float(os.environ.get("CACHE_SHIM_RUNNER_TIMEOUT", "30"))
TWIRP_PREFIX = "/twirp/github.actions.results.api.v1.CacheService/"

# Populated once at startup by read_task_token() -- see main(). Never logged.
_TASK_TOKEN = None
_RUNNER_HOST = None

# In-memory state for uploads in flight. Guarded by _STATE_LOCK because
# ThreadingHTTPServer dispatches each connection on its own thread, and a
# real client (Azure's BlockBlobClient) uploads blocks with real
# concurrency (default 4 -- see actions/toolkit's UploadOptions).
_STATE_LOCK = threading.Lock()
_PENDING_UPLOADS = {}  # uploadId -> {"key","version","blocks":{index:bytes},"committed":bool}
_COMMITTED_BY_KEYVER = {}  # (key,version) -> {"uploadId","size"}
_UPLOAD_COUNTER = 0
_PENDING_DOWNLOADS = {}  # downloadId -> {"location": <s3 key>}
_DOWNLOAD_COUNTER = 0


def read_task_token(sock_path):
    """Connect to the CircleCI task-token unix socket and read the raw JSON
    it writes on connect. Discovered live (not documented anywhere public):
    this is NOT an HTTP server -- no request line, no status line, it just
    writes `{"token":"...","runner_host":"..."}` and closes. A plain
    `http.client` GET against it fails with BadStatusLine whose exception
    text IS the JSON payload -- that's how this was found. Raises with a
    clear, actionable message on any failure; callers should treat that as
    fatal (see main()) rather than starting unauthenticated-against-nothing.
    """
    if not os.path.exists(sock_path):
        raise RuntimeError(
            f"{sock_path} does not exist. This shim requires CircleCI's task-token "
            "socket, present on CircleCI's own docker/machine executor images -- "
            "if you're seeing this, either this job isn't running on a "
            "CircleCI-provided executor, or a future CircleCI change removed/moved "
            "the socket. Self-hosted runners in particular may not have it; see "
            "the orb README's cache-shim section."
        )
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(sock_path)
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks).decode("utf-8", "replace")
    except OSError as exc:
        raise RuntimeError(f"could not read {sock_path}: {exc}") from exc
    finally:
        s.close()

    try:
        parsed = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"{sock_path} did not return valid JSON") from exc

    token = parsed.get("token", "")
    runner_host = parsed.get("runner_host", "")
    if not token or not runner_host:
        raise RuntimeError(
            f"{sock_path} returned JSON but was missing 'token' or 'runner_host'"
        )
    return token, runner_host


def _decode_block_index(block_id_b64):
    """Decode an Azure Blob block ID back to its sequence index.

    `@azure/storage-blob`'s `BlockBlobClient` generates these itself
    (actions/cache never sees or controls the format); this decode logic is
    the documented shape of the two block-ID encodings actually seen in
    practice (the same discovery `falcondev-oss/github-actions-cache-server`
    -- an unrelated, independently-built OSS project speaking this same
    protocol against real `actions/cache` clients -- records, re-derived
    here from first principles rather than copied): a 64-byte decode is
    docker-buildx's own block ID shape (a big-endian uint32 index at byte
    offset 16); a 48-byte decode is what `actions/cache` itself sends (a
    36-character UUID followed by the decimal index as trailing text).
    Concurrent uploads (`uploadConcurrency`, default 4) can complete blocks
    out of order, which is exactly why this decode -- not arrival order --
    determines final byte order.
    """
    decoded = base64.b64decode(block_id_b64)
    if len(decoded) == 64:
        return struct.unpack(">I", decoded[16:20])[0]
    if len(decoded) == 48:
        text = decoded.decode("utf-8", "replace")
        tail = text[36:]
        # Match JS's `Number.parseInt(decoded.slice(36))` semantics: parse
        # the LEADING run of digits and stop at the first non-digit byte
        # (the tail may be padded/terminated with non-digit filler), rather
        # than requiring the entire tail to be numeric.
        digits = ""
        for ch in tail:
            if ch.isdigit():
                digits += ch
            else:
                break
        if not digits:
            raise ValueError(f"48-byte block id has no leading digits in its tail: {tail!r}")
        return int(digits)
    raise ValueError(f"unrecognized block id length: {len(decoded)} bytes")


def _get_output_config():
    """GET {runner_host}/api/v2/output/config. See the module docstring's
    "real upload/download contract" section for the exact shape observed
    live on SaaS: {"type":"s3","endpoint":"","region":...,"bucket":...}.
    """
    req = urllib.request.Request(
        f"{_RUNNER_HOST}/api/v2/output/config",
        headers={"Authorization": f"Bearer {_TASK_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=RUNNER_CALL_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def _get_output_credentials(provider="s3"):
    """GET {runner_host}/api/v2/output/credentials?provider=<provider>.
    Returns the `s3` sub-object directly: {"AccessKeyID":...,
    "SecretAccessKey":...,"SessionToken":...,"Expires":...} -- short-lived
    (~15 min observed live), fetched fresh for every S3 call rather than
    cached, specifically so a job that runs long between cache-shim startup
    and an actual save/restore doesn't sign with an expired credential (see
    module docstring).
    """
    req = urllib.request.Request(
        f"{_RUNNER_HOST}/api/v2/output/credentials?provider={provider}",
        headers={"Authorization": f"Bearer {_TASK_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=RUNNER_CALL_TIMEOUT) as resp:
        parsed = json.loads(resp.read().decode("utf-8", "replace"))
    creds = parsed.get(provider)
    if not creds:
        raise RuntimeError(f"credentials response had no '{provider}' key: {parsed}")
    return creds


def _s3_canonical_uri(key):
    """URI-encode an S3 key for use as a SigV4 canonical URI: each path
    segment is percent-encoded individually (unreserved chars only --
    letters/digits/-/./_/~ -- left alone), and the '/' separators themselves
    are never encoded. Real cache keys observed live
    (`storage/caches/<projectID>/<key>.tar.zst`) only ever contain that
    unreserved set plus '/', but this is written generically rather than
    assuming that.
    """
    return "/" + "/".join(quote(seg, safe="-_.~") for seg in key.split("/"))


def _s3_target(config, key):
    """Resolve the (url, host, canonical_uri, region) to sign an S3 request
    against for a given cache object key.

    On real CircleCI SaaS, GET .../output/config's `endpoint` field is
    always the empty string (verified live) -- meaning "use AWS's own
    regional endpoint", addressed virtual-hosted-style:
    `https://{bucket}.s3.{region}.amazonaws.com/{key}`. A non-empty
    `endpoint` is treated as an explicit override, addressed path-style
    instead (`{endpoint}/{bucket}/{key}`) -- used by this repo's own local
    test suite's fake S3 (see test/cache-shim/run_tests.py), since
    virtual-hosted-style addressing needs either wildcard DNS or a TLS cert
    matching an arbitrary test hostname, neither of which a loopback test
    server has.
    """
    bucket = config["bucket"]
    region = config.get("region") or "us-east-1"
    endpoint = (config.get("endpoint") or "").strip()
    key_uri = _s3_canonical_uri(key)
    if endpoint:
        base = endpoint if "://" in endpoint else f"http://{endpoint}"
        parsed = urlparse(base)
        canonical_uri = f"/{bucket}{key_uri}"
        url = f"{parsed.scheme}://{parsed.netloc}{canonical_uri}"
        host = parsed.netloc
    else:
        host = f"{bucket}.s3.{region}.amazonaws.com"
        canonical_uri = key_uri
        url = f"https://{host}{canonical_uri}"
    return url, host, canonical_uri, region


def _sigv4_authorization(method, host, canonical_uri, region, access_key, secret_key, session_token, payload_hash, extra_signed_headers=None):
    """Sign one S3 request with AWS Signature Version 4, from scratch --
    stdlib `hmac`/`hashlib` only, no boto3/botocore (same zero-extra-install
    constraint the rest of this shim already has -- see the module
    docstring's "Why Python 3" section). Implements the algorithm exactly as
    AWS documents it (docs.aws.amazon.com/IAM/latest/UserGuide/
    create-signed-request.html): build the canonical request, derive the
    scoped signing key via a 4-step HMAC chain, sign the string-to-sign, and
    assemble the Authorization header. Returns the full header dict to send
    (host, x-amz-date, x-amz-content-sha256, x-amz-security-token if a
    session token was given, any extra_signed_headers, and Authorization).
    Verified correct against real AWS S3, not just self-consistent: see the
    module docstring's real-CI evidence.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    headers = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if session_token:
        headers["x-amz-security-token"] = session_token
    if extra_signed_headers:
        headers.update(extra_signed_headers)

    signed_keys = sorted(headers.keys())
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in signed_keys)
    signed_headers = ";".join(signed_keys)

    canonical_request = "\n".join(
        [method, canonical_uri, "", canonical_headers, signed_headers, payload_hash]
    )
    credential_scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    def _hmac(key, msg):
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    k_date = _hmac(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region = _hmac(k_date, region)
    k_service = _hmac(k_region, "s3")
    k_signing = _hmac(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return headers


def _s3_put_object(config, creds, key, body, tags=None):
    """Real, SigV4-signed S3 PutObject. `tags` (the cache-save ticket's own
    `tags` field, e.g. {"expiration_days":"15"}) is sent as the
    `x-amz-tagging` header -- S3's own mechanism for setting object tags at
    upload time in one request, rather than a separate PutObjectTagging
    call (matches how the real `task-agent-subcommand-cache` Go client and
    the AWS SDK's `Tagging` field both do it -- see module docstring)."""
    url, host, canonical_uri, region = _s3_target(config, key)
    payload_hash = hashlib.sha256(body).hexdigest()
    extra = {"content-type": "application/octet-stream"}
    if tags:
        extra["x-amz-tagging"] = urlencode(tags)
    headers = _sigv4_authorization(
        "PUT", host, canonical_uri, region,
        creds["AccessKeyID"], creds["SecretAccessKey"], creds.get("SessionToken", ""),
        payload_hash, extra_signed_headers=extra,
    )
    req = urllib.request.Request(url, data=body, method="PUT", headers=headers)
    with urllib.request.urlopen(req, timeout=RUNNER_CALL_TIMEOUT):
        return


def _s3_get_object(config, creds, key):
    """Real, SigV4-signed S3 GetObject. Returns the object body bytes;
    raises urllib.error.HTTPError (404 on a missing key) or another
    exception on failure -- callers decide how to surface that."""
    url, host, canonical_uri, region = _s3_target(config, key)
    payload_hash = hashlib.sha256(b"").hexdigest()
    headers = _sigv4_authorization(
        "GET", host, canonical_uri, region,
        creds["AccessKeyID"], creds["SecretAccessKey"], creds.get("SessionToken", ""),
        payload_hash,
    )
    req = urllib.request.Request(url, method="GET", headers=headers)
    with urllib.request.urlopen(req, timeout=RUNNER_CALL_TIMEOUT) as resp:
        return resp.read()


def _redeem_cache_save_ticket(key, version, blob):
    """Ask CircleCI's cache-save for a ticket, then actually persist the
    bytes: a real, SigV4-signed S3 PutObject to the ticket's `location`
    (an S3 object key, not a URL fragment -- see module docstring), using
    fresh per-call STS credentials from /api/v2/output/credentials.

    Returns nothing on success. Raises RuntimeError on any failure, with
    enough detail (exact stage, key, HTTP status) for a caller to log it --
    callers treat that as a non-fatal outcome (see Handler.do_PUT), matching
    actions/cache's own best-effort save semantics.
    """
    body = json.dumps({"cache_key": key, "version": version}).encode("utf-8")
    save_req = urllib.request.Request(
        f"{_RUNNER_HOST}/api/v2/output/cache-save",
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {_TASK_TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(save_req, timeout=RUNNER_CALL_TIMEOUT) as resp:
            ticket = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(
            f"cache-save ticket request failed: HTTP {exc.code} {detail}"
        ) from exc

    location = ticket.get("location", "")
    if not location:
        raise RuntimeError(f"cache-save returned no 'location' in ticket: {ticket}")
    tags = ticket.get("tags") or None

    try:
        config = _get_output_config()
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"could not fetch /api/v2/output/config: {exc}") from exc

    if config.get("type") != "s3":
        raise RuntimeError(
            f"output storage type is '{config.get('type')}', not 's3' -- this shim only "
            "implements the S3-mode upload contract documented in cache_shim_server.py's "
            "module docstring (the alternative, 'pre-signed' mode, is enterprise-only)."
        )

    try:
        creds = _get_output_credentials(provider="s3")
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"could not fetch S3 credentials for cache-save: {exc}") from exc

    try:
        _s3_put_object(config, creds, location, blob, tags=tags)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(
            f"cache-save ticket redeemed but the signed S3 PutObject to key "
            f"'{location}' (bucket '{config.get('bucket')}') failed: HTTP {exc.code} {detail}"
        ) from exc
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"cache-save upload (S3 PutObject key='{location}') failed: {exc}"
        ) from exc


def _resolve_cache_restore(key, restore_keys, version):
    """Ask CircleCI's cache-restore for a match, trying `key` then each
    `restore_keys` entry in order (GitHub's own semantics: exact primary,
    then restore keys in the order given -- this shim does not additionally
    implement GitHub's prefix-matching-on-restore-keys behavior, only exact
    matches per candidate, since CircleCI's own match response for a never-
    saved key already independently matches by prefix on ITS side). Returns
    (matched_key, location) or (None, None) on a clean miss. A "prefix"
    match with size 0 is treated as a miss, not a hit: a 0-byte "hit" would
    make `actions/cache` try to extract an empty/corrupt archive.
    """
    for candidate in [key] + list(restore_keys or []):
        body = json.dumps({"cache_key": candidate, "version": version}).encode("utf-8")
        req = urllib.request.Request(
            f"{_RUNNER_HOST}/api/v2/output/cache-restore",
            data=body,
            method="POST",
            headers={"Authorization": f"Bearer {_TASK_TOKEN}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=RUNNER_CALL_TIMEOUT) as resp:
                result = json.loads(resp.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError:
            continue
        except Exception:  # noqa: BLE001
            continue

        exact = result.get("exact")
        if exact and (exact.get("size") or 0) > 0:
            location = (exact.get("key") or {}).get("location", "")
            if location:
                return candidate, location
    return None, None


class Handler(BaseHTTPRequestHandler):
    server_version = "cache-shim/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("cache-shim: " + (fmt % args) + "\n")

    def _send_json(self, status, obj, extra_headers=None):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _bearer_authorized(self):
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {REQUEST_TOKEN}"
        return hmac.compare_digest(supplied, expected)

    def _query_token_authorized(self, query):
        supplied = (query.get("token") or [""])[0]
        return hmac.compare_digest(supplied, REQUEST_TOKEN)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length else b""

    # -- Twirp RPCs --------------------------------------------------------

    def _twirp_create_cache_entry(self, req):
        key = req.get("key", "")
        version = req.get("version", "")
        if not key or not version:
            self._send_json(400, {"message": "missing 'key' or 'version'"})
            return

        global _UPLOAD_COUNTER
        with _STATE_LOCK:
            _UPLOAD_COUNTER += 1
            upload_id = hashlib.sha256(f"{key}:{version}:{_UPLOAD_COUNTER}:{os.urandom(8).hex()}".encode()).hexdigest()[:32]
            _PENDING_UPLOADS[upload_id] = {"key": key, "version": version, "blocks": {}, "committed": False}

        host, port = self.server.advertise_host, self.server.advertise_port
        upload_url = f"http://{host}:{port}/upload/{upload_id}?token={REQUEST_TOKEN}"
        self._send_json(200, {"ok": True, "signed_upload_url": upload_url})

    def _twirp_finalize_cache_entry_upload(self, req):
        key = req.get("key", "")
        version = req.get("version", "")
        with _STATE_LOCK:
            committed = _COMMITTED_BY_KEYVER.get((key, version))
        if not committed:
            # Real semantics: a finalize with nothing successfully committed
            # is a soft "not ok", not a hard error -- actions/cache logs and
            # moves on (see saveCacheV2's own catch-and-warn).
            self._send_json(200, {"ok": False, "message": "no committed upload for this key/version"})
            return
        entry_id = int(hashlib.sha256(f"{key}:{version}".encode()).hexdigest()[:8], 16)
        self._send_json(200, {"ok": True, "entry_id": entry_id})

    def _twirp_get_cache_entry_download_url(self, req):
        key = req.get("key", "")
        version = req.get("version", "")
        restore_keys = req.get("restore_keys") or []
        matched_key, location = _resolve_cache_restore(key, restore_keys, version)
        if not location:
            self._send_json(200, {"ok": False})
            return

        # Unlike upload, actions/cache's real downloadCache() just does a
        # plain GET against whatever URL this hands back -- but that GET
        # carries none of this shim's AWS credentials, so it can't go
        # straight to S3. Proxy it: register the S3 key locally (same
        # pattern as the upload leg's /upload/<id>) and hand back a URL
        # pointing at THIS shim's own new /download/<id>, which does the
        # real signed S3 GetObject itself when the request actually arrives.
        global _DOWNLOAD_COUNTER
        with _STATE_LOCK:
            _DOWNLOAD_COUNTER += 1
            download_id = hashlib.sha256(
                f"{location}:{_DOWNLOAD_COUNTER}:{os.urandom(8).hex()}".encode()
            ).hexdigest()[:32]
            _PENDING_DOWNLOADS[download_id] = {"location": location}

        host, port = self.server.advertise_host, self.server.advertise_port
        url = f"http://{host}:{port}/download/{download_id}?token={REQUEST_TOKEN}"
        self._send_json(200, {"ok": True, "signed_download_url": url, "matched_key": matched_key})

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path.startswith(TWIRP_PREFIX):
            if not self._bearer_authorized():
                self._send_json(401, {"message": "missing or invalid Authorization bearer token"})
                return
            method_name = parsed.path[len(TWIRP_PREFIX):]
            try:
                req = json.loads(self._read_body() or b"{}")
            except Exception:  # noqa: BLE001
                self._send_json(400, {"message": "invalid JSON body"})
                return

            if method_name == "CreateCacheEntry":
                self._twirp_create_cache_entry(req)
            elif method_name == "FinalizeCacheEntryUpload":
                self._twirp_finalize_cache_entry_upload(req)
            elif method_name == "GetCacheEntryDownloadURL":
                self._twirp_get_cache_entry_download_url(req)
            else:
                self._send_json(404, {"message": f"unknown CacheService method '{method_name}'"})
            return

        self._send_json(404, {"message": "not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if not parsed.path.startswith("/upload/"):
            self._send_json(404, {"message": "not found"})
            return

        if not self._query_token_authorized(query):
            # Reject before reading the body or touching any state -- an
            # unauthenticated caller must never cause a block write.
            self._send_json(401, {"message": "missing or invalid 'token' query parameter"})
            return

        upload_id = parsed.path[len("/upload/"):]
        with _STATE_LOCK:
            entry = _PENDING_UPLOADS.get(upload_id)
        if entry is None:
            self._send_json(404, {"message": "unknown or expired upload id"})
            return

        comp = (query.get("comp") or [""])[0]
        request_id_header = {"x-ms-request-id": os.urandom(16).hex()}

        if comp in ("block", "appendBlock"):
            block_id = (query.get("blockid") or [""])[0]
            try:
                index = _decode_block_index(block_id)
            except Exception as exc:  # noqa: BLE001
                self._send_json(400, {"message": f"could not decode block id: {exc}"})
                return
            data = self._read_body()
            with _STATE_LOCK:
                entry["blocks"][index] = data
            self._send_json(201, {"message": "accepted"}, request_id_header)
            return

        if comp == "blocklist" or comp == "":
            # comp=="" (no query param at all) is a REAL, common case, not a
            # malformed request: `@azure/storage-blob`'s BlockBlobClient only
            # uses the block/blocklist chunked protocol above
            # `maxSingleShotSize` (128 MiB in `uploadCacheArchiveSDK`'s own
            # options); for anything smaller -- the common case for most
            # real caches, and the one this shim's own live CI test exercises
            # -- it does a single plain PUT of the WHOLE body with no `comp`
            # parameter at all. Confirmed live: a real `actions/cache/save@v4`
            # call for an 843-byte file hit exactly this path and got a 400
            # before this fix ("unknown or missing 'comp' value: ''"), which
            # `uploadCacheArchiveSDK` then surfaced as a save failure.
            # Treat a single-shot PUT as a upload with exactly one block
            # (index 0, this request's own body) reusing the same commit
            # logic as a real blocklist commit.
            if comp == "":
                data = self._read_body()
                with _STATE_LOCK:
                    entry["blocks"][0] = data

            with _STATE_LOCK:
                blob = b"".join(entry["blocks"][i] for i in sorted(entry["blocks"]))
                key, version = entry["key"], entry["version"]
            try:
                _redeem_cache_save_ticket(key, version, blob)
            except Exception as exc:  # noqa: BLE001
                # actions/cache's uploadCacheArchiveSDK treats any non-2xx
                # here as a failed save; saveCacheV2's own caller catches it
                # and logs a warning rather than failing the build (see the
                # module docstring). Detail lands in the job's own act/Act
                # log, not silently swallowed here.
                self.log_message("commit failed for %s: %s", upload_id, exc)
                self._send_json(500, {"message": str(exc)})
                return
            with _STATE_LOCK:
                entry["committed"] = True
                _COMMITTED_BY_KEYVER[(key, version)] = {"uploadId": upload_id, "size": len(blob)}
                entry["blocks"] = {}  # free the buffered bytes now that we're done with them
            self._send_json(201, {"message": "committed"}, request_id_header)
            return

        self._send_json(400, {"message": f"unknown 'comp' value: {comp!r}"})

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/healthz":
            self._send_json(200, {"status": "ok"})
            return

        if parsed.path.startswith("/download/"):
            query = parse_qs(parsed.query)
            if not self._query_token_authorized(query):
                # Same reasoning as the upload leg's /upload/<id>: real
                # Azure/AWS download semantics carry auth in the URL itself,
                # not a bearer header, so the query-param token IS the real
                # check here. Reject before touching any state or making an
                # S3 call.
                self._send_json(401, {"message": "missing or invalid 'token' query parameter"})
                return

            download_id = parsed.path[len("/download/"):]
            with _STATE_LOCK:
                entry = _PENDING_DOWNLOADS.get(download_id)
            if entry is None:
                self._send_json(404, {"message": "unknown or expired download id"})
                return

            try:
                config = _get_output_config()
                creds = _get_output_credentials(provider="s3")
                data = _s3_get_object(config, creds, entry["location"])
            except Exception as exc:  # noqa: BLE001
                # actions/cache's downloadCache() treats a failed GET as a
                # thrown error, caught by its own best-effort restore
                # wrapper (a restore failure is never fatal to the build --
                # see module docstring) -- logged here, not swallowed.
                self.log_message("download failed for %s (location=%s): %s", download_id, entry["location"], exc)
                self._send_json(500, {"message": f"could not fetch cache object: {exc}"})
                return

            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        self._send_json(404, {"message": "not found"})

    def do_HEAD(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()


def main():
    global _TASK_TOKEN, _RUNNER_HOST

    if not REQUEST_TOKEN:
        sys.stderr.write(
            "cache-shim: ERROR: CACHE_SHIM_REQUEST_TOKEN is not set. This is the "
            "real auth boundary for this server (see module docstring's Security "
            "section) -- refusing to start unauthenticated.\n"
        )
        sys.exit(1)

    try:
        _TASK_TOKEN, _RUNNER_HOST = read_task_token(TASK_SOCKET_PATH)
    except RuntimeError as exc:
        sys.stderr.write(f"cache-shim: ERROR: {exc}\n")
        sys.exit(1)

    host = os.environ.get("CACHE_SHIM_HOST", "127.0.0.1")
    port = int(os.environ.get("CACHE_SHIM_PORT", "8991"))
    advertise_host = os.environ.get("CACHE_SHIM_ADVERTISE_HOST", host)
    advertise_port = int(os.environ.get("CACHE_SHIM_ADVERTISE_PORT", str(port)))

    server = ThreadingHTTPServer((host, port), Handler)
    server.advertise_host = advertise_host
    server.advertise_port = advertise_port
    sys.stderr.write(
        f"cache-shim: listening on {host}:{port}, advertising {advertise_host}:{advertise_port}, "
        f"runner_host={_RUNNER_HOST}\n"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
