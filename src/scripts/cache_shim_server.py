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
    `signed_upload_url`: a sequence of `PUT ...?comp=block&blockid=<b64>`
    (or `appendBlock`) calls, each with a chunk of the archive, followed by
    one `PUT ...?comp=blocklist` that commits the upload. No separate
    presigned-PUT step -- the "URL" IS the thing the blocks are PUT to.
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

Known, real gap -- read before assuming this shim persists a cache
------------------------------------------------------------------
`$runner_host/api/v2/output/cache-save` does NOT return a presigned PUT URL.
It returns a small JSON *ticket*: `{"method":"POST","location":"storage/
caches/<id>/<key>.tar.zst","tags":{"expiration_days":"15"}}`. The obvious
reading -- POST the archive bytes to `$runner_host/<location>` -- was tested
directly against a real CircleCI job, repeatedly, across many pipeline runs,
and every variant 404s:
  - `POST/PUT/GET/HEAD/OPTIONS {runner_host}/{location}` (with and without
    the `.tar.zst` suffix, with and without the `storage/` prefix duplicated
    under `/api/v2/output/`, `/api/v2/storage/`, `/api/v2/task/storage/`) --
    all 404, either a JSON `{"message":"Route Not Found"}` (a real router,
    wrong sub-path) or a bare `404 page not found` (a different framework
    entirely on some prefixes).
  - The older, publicly-documented `POST /api/v2/task/storage/cache-save`
    (seen in `CircleCI-Public/circleci-steps-sdk-ts`'s `SaveCache.ts`, which
    DOES return a real `{url}` presigned URL) is itself 404 on the live API
    -- that endpoint is gone.
  - `OPTIONS` on `cache-save` itself, an inline base64 `content` field on
    the save call, and half a dozen generic `/api/v2/output/upload`-shaped
    guesses were all tried too; none exists.
This strongly suggests `/api/v2/output/cache-save`'s task-token scope is
metadata-only from a plain job container: it can *register* a cache
key/version, but the actual object bytes move through a channel only
CircleCI's own runner-agent process has (not something this shim, running
as an ordinary job step, can reach). This is a real, reproducible finding,
not a guess -- see the orb README's cache-shim section for the full,
reproduced evidence trail (every URL/method tried and its exact response).

Given that, `_redeem_cache_save_ticket()`/`_resolve_download_url()` below
still DO attempt the documented-shape follow-up call (so this shim starts
working automatically, with no code change, the moment CircleCI's backend
either fixes the location format or exposes the real upload path) but treat
failure as an ordinary, expected outcome: `actions/cache` itself treats a
save failure as a non-fatal `core.warning` (see `saveCacheV2` in the real
`cache.ts`) and a restore miss as `undefined` (build proceeds cold), so
wiring this shim in is safe today even though it does not yet demonstrate a
real cross-run cache hit -- it fails the way real GitHub Actions caching
fails when the backend is unavailable, not by crashing the build.

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
from urllib.parse import parse_qs, urlparse

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


def _redeem_cache_save_ticket(key, version, blob):
    """POST the negotiated cache-save ticket's bytes to CircleCI's backend.

    Returns nothing on success. Raises RuntimeError, with the exact URL and
    HTTP status tried, on failure -- see the module docstring's "Known, real
    gap" section: this is EXPECTED to raise today, every time, because the
    ticket's `location` is not reachable via any URL construction tried
    against a real CircleCI job. Kept as a real attempt (not a stub) so a
    future fix on CircleCI's side needs no code change here to start
    working.
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

    method = ticket.get("method", "POST")
    location = ticket.get("location", "")
    if not location:
        raise RuntimeError(f"cache-save returned no 'location' in ticket: {ticket}")

    upload_url = f"{_RUNNER_HOST}/{location.lstrip('/')}"
    put_req = urllib.request.Request(
        upload_url,
        data=blob,
        method=method,
        headers={"Authorization": f"Bearer {_TASK_TOKEN}", "Content-Type": "application/octet-stream"},
    )
    try:
        with urllib.request.urlopen(put_req, timeout=RUNNER_CALL_TIMEOUT):
            return
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        # This is the expected failure -- see module docstring. Surfaced with
        # the exact URL/status so anyone reading a job log (or this
        # exception, wrapped into a 500 the calling actions/cache tolerates
        # as a non-fatal warning) can see precisely what was tried.
        raise RuntimeError(
            f"cache-save ticket redeemed ({method} {upload_url}) but the byte "
            f"upload itself failed: HTTP {exc.code} {detail}. This is a known, "
            "reproduced gap -- see cache_shim_server.py's module docstring "
            "'Known, real gap' section and the orb README's cache-shim notes."
        ) from exc
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"cache-save upload to {upload_url} failed: {exc}") from exc


def _resolve_download_url(key, restore_keys, version):
    """Ask CircleCI's cache-restore for a match, trying `key` then each
    `restore_keys` entry in order (GitHub's own semantics: exact primary,
    then restore keys in the order given -- this shim does not additionally
    implement GitHub's prefix-matching-on-restore-keys behavior, only exact
    matches per candidate, since CircleCI's own match response for a never-
    saved key already independently matches by prefix on ITS side -- see the
    module docstring). Returns (matched_key, download_url) or (None, None)
    on a clean miss. A "prefix" match with size 0 (what this API returns for
    ANY key that was never actually backed by real bytes -- see the module
    docstring's gap) is treated as a miss, not a hit: a 0-byte "hit" would
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
        entry = exact
        if entry and (entry.get("size") or 0) > 0:
            location = (entry.get("key") or {}).get("location", "")
            if location:
                # See module docstring: unlike upload, a real download URL
                # needs no shim proxying -- actions/cache GETs it directly.
                # Whether {runner_host}/{location} is itself fetchable this
                # way is exactly the same open gap as the upload leg.
                return candidate, f"{_RUNNER_HOST}/{location.lstrip('/')}"
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
        matched_key, url = _resolve_download_url(key, restore_keys, version)
        if url:
            self._send_json(200, {"ok": True, "signed_download_url": url, "matched_key": matched_key})
        else:
            self._send_json(200, {"ok": False})

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

        if comp == "blocklist":
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
                self.log_message("blocklist commit failed for %s: %s", upload_id, exc)
                self._send_json(500, {"message": str(exc)})
                return
            with _STATE_LOCK:
                entry["committed"] = True
                _COMMITTED_BY_KEYVER[(key, version)] = {"uploadId": upload_id, "size": len(blob)}
                entry["blocks"] = {}  # free the buffered bytes now that we're done with them
            self._send_json(201, {"message": "committed"}, request_id_header)
            return

        self._send_json(400, {"message": f"unknown or missing 'comp' value: {comp!r}"})

    def do_GET(self):
        if self.path == "/healthz":
            self._send_json(200, {"status": "ok"})
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
