#!/usr/bin/env python3
"""
Local functional test for cache_shim_server.py.

This drives the REAL shipped server (src/scripts/cache_shim_server.py, not a
copy) against two fakes:
  - a fake /tmp/circleci-ts.sock-style task-token socket, and
  - a fake `runner_host` HTTP server that implements the FULL real contract
    (verified live against the real CircleCI API -- see
    cache_shim_server.py's module docstring): cache-save/cache-restore
    ticket negotiation, GET .../output/config and .../output/credentials,
    AND a fake S3 endpoint (path-style, since a loopback test server has no
    wildcard DNS/TLS for virtual-hosted-style addressing -- see
    cache_shim_server.py's `_s3_target()`) that the shim's real,
    from-scratch SigV4 signer PUTs/GETs against. This proves the shim's OWN
    client-side plumbing end to end -- Twirp translation, block-blob
    reassembly in the face of out-of-order/concurrent block PUTs, ticket
    redemption, SigV4 request signing, and auth enforcement -- independent
    of live network conditions. (SigV4 *cryptographic* correctness against
    real AWS is proven separately, on real CI against real S3 -- see the
    README's cache-shim section and .circleci/test-deploy.yml's
    test_cache_shim_durable_hit_save/restore jobs.)

A from-scratch client (not copied from actions/toolkit) drives the shim the
same way @actions/cache's real Azure BlockBlobClient does: CreateCacheEntry
-> N block PUTs, deliberately out of order -> one blocklist commit ->
FinalizeCacheEntryUpload -> GetCacheEntryDownloadURL.

Run: python3 test/cache-shim/run_tests.py
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_SRC = os.path.join(HERE, "..", "..", "src", "scripts", "cache_shim_server.py")

FAKE_BUCKET = "fake-bucket"
FAKE_ACCESS_KEY = "FAKEACCESSKEYID12345"
FAKE_SECRET_KEY = "FakeSecretAccessKey1234567890abcdefghij"
FAKE_SESSION_TOKEN = "FakeSessionToken.abc123"

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS: {name}")
    else:
        FAIL += 1
        print(f"FAIL: {name} {detail}")


def make_block_id(index):
    """48-byte-decoded block id shape actions/cache's own Azure SDK uses: a
    36-char UUID followed by the decimal index, padded to fill exactly 48
    bytes total (matches cache_shim_server.py's _decode_block_index()'s
    documented 48-byte branch, which parses only the LEADING digits of the
    12-byte tail).
    """
    uuid_part = "00000000-0000-0000-0000-000000000000"
    tail = str(index).ljust(12, "x")
    raw = (uuid_part + tail).encode("utf-8")
    assert len(raw) == 48, len(raw)
    return base64.b64encode(raw).decode("ascii")


class FakeRunnerBackend:
    """A correct, in-memory implementation of the FULL real contract this
    shim now speaks -- cache-save/cache-restore ticket negotiation, the
    config/credentials endpoints, and a fake S3 (path-style, see
    cache_shim_server.py's `_s3_target()`) that the shim's real SigV4 signer
    PUTs/GETs against. Verified against the real, live shape of each
    endpoint's JSON (see cache_shim_server.py's module docstring) -- this
    fake matches production, not a simplification of it.
    """

    def __init__(self):
        self.objects = {}  # s3 key -> bytes
        self.tags = {}  # s3 key -> {tag: value}
        self.tickets = {}  # (key,version) -> location
        self.fail_upload = False
        self.endpoint = ""  # filled in by start_fake_runner() once the port is known

    def _config(self):
        return {
            "type": "s3",
            "endpoint": self.endpoint,
            "region": "us-east-1",
            "bucket": FAKE_BUCKET,
        }

    def _credentials(self):
        return {
            "s3": {
                "AccessKeyID": FAKE_ACCESS_KEY,
                "SecretAccessKey": FAKE_SECRET_KEY,
                "SessionToken": FAKE_SESSION_TOKEN,
                "Expires": "2099-01-01T00:00:00Z",
            }
        }

    def app(self, raw_path, method, body, headers):
        parsed = urlparse(raw_path)
        path = parsed.path

        if path == "/api/v2/output/config" and method == "GET":
            return 200, json.dumps(self._config()).encode()

        if path == "/api/v2/output/credentials" and method == "GET":
            return 200, json.dumps(self._credentials()).encode()

        if path == "/api/v2/output/cache-save" and method == "POST":
            req = json.loads(body or b"{}")
            key, version = req.get("cache_key"), req.get("version")
            location = f"storage/caches/fake/{key}.tar.zst"
            if (key, version) in self.tickets:
                return 409, json.dumps({"message": "conflict"}).encode()
            self.tickets[(key, version)] = location
            return 200, json.dumps(
                {"method": "POST", "location": location, "tags": {"expiration_days": "15"}}
            ).encode()

        if path == "/api/v2/output/cache-restore" and method == "POST":
            req = json.loads(body or b"{}")
            key, version = req.get("cache_key"), req.get("version")
            location = f"storage/caches/fake/{key}.tar.zst"
            data = self.objects.get(location)
            if data:
                return 200, json.dumps(
                    {"exact": {"key": {"location": location}, "size": len(data), "metadata": None}}
                ).encode()
            return 200, json.dumps({"exact": None, "prefix": None}).encode()

        # Fake S3, path-style: /{bucket}/{key...}. Real production speaks
        # this over a real, SigV4-signed request against AWS -- this fake
        # checks that the shim actually sent SOMETHING SigV4-shaped
        # (Authorization: AWS4-HMAC-SHA256 ..., a security-token header
        # carrying the fake session token) without re-verifying the
        # signature bytes themselves (that correctness is what the real,
        # live S3 test in .circleci/test-deploy.yml proves).
        bucket_prefix = f"/{FAKE_BUCKET}/"
        if path.startswith(bucket_prefix):
            key = path[len(bucket_prefix):]
            auth = headers.get("Authorization", "")
            token = headers.get("X-Amz-Security-Token", "")
            if not auth.startswith("AWS4-HMAC-SHA256 ") or token != FAKE_SESSION_TOKEN:
                return 403, b"<Error><Code>SignatureDoesNotMatch</Code></Error>"

            if method == "PUT":
                if self.fail_upload:
                    return 404, b"<Error><Code>NoSuchBucket</Code></Error>"
                self.objects[key] = body
                tagging = headers.get("X-Amz-Tagging", "")
                if tagging:
                    self.tags[key] = dict(
                        p.split("=", 1) for p in tagging.split("&") if "=" in p
                    )
                return 200, b""

            if method == "GET":
                data = self.objects.get(key)
                if data is None:
                    return 404, b"<Error><Code>NoSuchKey</Code></Error>"
                return 200, data

        return 404, json.dumps({"message": "not found"}).encode()


def start_fake_runner(backend):
    class H(BaseHTTPRequestHandler):
        def _dispatch(self, method):
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length else b""
            status, resp = backend.app(self.path, method, body, self.headers)
            self.send_response(status)
            content_type = "application/json" if resp[:1] in (b"{", b"[") else "application/octet-stream"
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        def do_POST(self):
            self._dispatch("POST")

        def do_GET(self):
            self._dispatch("GET")

        def do_PUT(self):
            self._dispatch("PUT")

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    backend.endpoint = f"http://127.0.0.1:{port}"
    return server, port


def start_fake_task_socket(sock_path, token, runner_host):
    payload = json.dumps({"token": token, "runner_host": runner_host}).encode()

    def serve():
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(sock_path)
        srv.listen(16)
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            conn.sendall(payload)
            conn.close()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    return t


def http(method, url, body=None, headers=None):
    data = body if isinstance(body, bytes) else (body.encode() if body else None)
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def wait_healthy(base, deadline_s=5):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        try:
            status, _ = http("GET", f"{base}/healthz")
            if status == 200:
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.1)
    return False


def main():
    tmpdir = tempfile.mkdtemp(prefix="cache-shim-test-")
    sock_path = os.path.join(tmpdir, "circleci-ts.sock")
    task_token = "fake-task-token"
    request_token = "fake-request-token-for-this-test"

    backend = FakeRunnerBackend()
    runner_server, runner_port = start_fake_runner(backend)
    runner_host = f"http://127.0.0.1:{runner_port}"
    start_fake_task_socket(sock_path, task_token, runner_host)

    shim_port = 18991
    env = dict(os.environ)
    env.update(
        {
            "CACHE_SHIM_TASK_SOCKET": sock_path,
            "CACHE_SHIM_REQUEST_TOKEN": request_token,
            "CACHE_SHIM_HOST": "127.0.0.1",
            "CACHE_SHIM_PORT": str(shim_port),
            "CACHE_SHIM_ADVERTISE_HOST": "127.0.0.1",
            "CACHE_SHIM_ADVERTISE_PORT": str(shim_port),
            "CACHE_SHIM_RUNNER_TIMEOUT": "5",
        }
    )
    proc = subprocess.Popen(
        [sys.executable, SERVER_SRC],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    base = f"http://127.0.0.1:{shim_port}"

    try:
        ready = wait_healthy(base)
        check("server starts and answers /healthz", ready)
        if not ready:
            out = proc.stdout.read() if proc.stdout else ""
            print("server output:\n" + out)
            return 1

        # --- Test 1: auth enforcement on Twirp RPCs -----------------------
        twirp_url = f"{base}/twirp/github.actions.results.api.v1.CacheService/CreateCacheEntry"
        status, _ = http("POST", twirp_url, json.dumps({"key": "k", "version": "v1"}))
        check("no Authorization header -> 401", status == 401, f"got {status}")

        status, _ = http(
            "POST", twirp_url, json.dumps({"key": "k", "version": "v1"}),
            headers={"Authorization": "Bearer wrong-token", "Content-Type": "application/json"},
        )
        check("wrong bearer token -> 401", status == 401, f"got {status}")

        # --- Test 2: full save round trip, blocks sent OUT OF ORDER -------
        key, version = "cache-shim-test-key", "v1"
        auth_headers = {"Authorization": f"Bearer {request_token}", "Content-Type": "application/json"}
        status, body = http("POST", twirp_url, json.dumps({"key": key, "version": version}), auth_headers)
        check("CreateCacheEntry -> 200", status == 200, f"got {status} {body}")
        resp = json.loads(body)
        check("CreateCacheEntry response has ok:true and a signed_upload_url", resp.get("ok") and resp.get("signed_upload_url"), str(resp))

        upload_url = resp["signed_upload_url"]
        chunks = [b"AAAA", b"BBBB", b"CCCC", b"DDDD"]
        # Deliberately reversed order -- proves reassembly is by decoded
        # block index, not arrival order (real Azure uploads with
        # concurrency>1 can complete out of order).
        for i in reversed(range(len(chunks))):
            block_url = f"{upload_url}&comp=block&blockid={make_block_id(i)}"
            status, _ = http("PUT", block_url, chunks[i], {"Content-Type": "application/octet-stream"})
            check(f"block {i} PUT -> 201", status == 201, f"got {status}")

        blocklist_url = f"{upload_url}&comp=blocklist"
        status, body = http("PUT", blocklist_url, b"")
        check("blocklist commit -> 201 (fake backend accepts the upload)", status == 201, f"got {status} {body}")

        stored = backend.objects.get(f"storage/caches/fake/{key}.tar.zst")
        check(
            "reassembled blob is byte-correct despite out-of-order block PUTs",
            stored == b"".join(chunks),
            f"stored={stored!r} expected={b''.join(chunks)!r}",
        )
        check(
            "the real SigV4-signed PutObject carried the ticket's tags as x-amz-tagging",
            backend.tags.get(f"storage/caches/fake/{key}.tar.zst") == {"expiration_days": "15"},
            f"got tags={backend.tags.get(f'storage/caches/fake/{key}.tar.zst')!r}",
        )

        finalize_url = f"{base}/twirp/github.actions.results.api.v1.CacheService/FinalizeCacheEntryUpload"
        status, body = http("POST", finalize_url, json.dumps({"key": key, "version": version, "size_bytes": str(len(stored or b""))}), auth_headers)
        resp = json.loads(body)
        check("FinalizeCacheEntryUpload -> ok:true after a real commit", resp.get("ok") is True, str(resp))

        # --- Test 3: restore finds the real hit ----------------------------
        restore_url = f"{base}/twirp/github.actions.results.api.v1.CacheService/GetCacheEntryDownloadURL"
        status, body = http("POST", restore_url, json.dumps({"key": key, "version": version, "restore_keys": []}), auth_headers)
        resp = json.loads(body)
        check("GetCacheEntryDownloadURL -> a real hit against the fake backend", resp.get("ok") is True and resp.get("signed_download_url"), str(resp))

        if resp.get("signed_download_url"):
            # The download URL now points at THIS shim's own /download/<id>
            # proxy (not a bare object-store URL actions/cache could never
            # authenticate against on its own -- see cache_shim_server.py's
            # module docstring). Fetching it should trigger a real, signed
            # GetObject against the fake S3 and return the exact bytes
            # uploaded above.
            dl_status, dl_body = http("GET", resp["signed_download_url"])
            check("download proxy GET -> 200", dl_status == 200, f"got {dl_status} {dl_body!r}")
            check(
                "downloaded bytes match exactly what was uploaded",
                dl_body == b"".join(chunks),
                f"got={dl_body!r} expected={b''.join(chunks)!r}",
            )

            # No token -> 401, same auth discipline as the upload leg.
            no_token_url = resp["signed_download_url"].split("?")[0]
            status, _ = http("GET", no_token_url)
            check("GET /download/<id> with no token query param -> 401", status == 401, f"got {status}")

        # --- Test 4: a genuine miss on an unknown key ----------------------
        status, body = http("POST", restore_url, json.dumps({"key": "never-saved", "version": version, "restore_keys": []}), auth_headers)
        resp = json.loads(body)
        check("GetCacheEntryDownloadURL -> ok:false on a real miss", resp.get("ok") is False, str(resp))

        # --- Test 5: upload-leg failure surfaces as 500, not a crash -------
        backend.fail_upload = True
        key2 = "cache-shim-test-key-2"
        status, body = http("POST", twirp_url, json.dumps({"key": key2, "version": version}), auth_headers)
        resp = json.loads(body)
        upload_url2 = resp["signed_upload_url"]
        http("PUT", f"{upload_url2}&comp=block&blockid={make_block_id(0)}", b"data", {"Content-Type": "application/octet-stream"})
        status, body = http("PUT", f"{upload_url2}&comp=blocklist", b"")
        check("blocklist commit -> 500 when the backend upload 404s (matches real production)", status == 500, f"got {status} {body}")

        status, _ = http("GET", f"{base}/healthz")
        check("server is still alive and answering after a failed upload", status == 200, f"got {status}")

        # --- Test 6: /upload/<id> PUT requires the query token -------------
        status, _ = http("PUT", f"{base}/upload/whatever&comp=block&blockid={make_block_id(0)}", b"x")
        check("PUT /upload/<id> with no token query param -> 401", status == 401, f"got {status}")

        # --- Test 7: single-shot upload (no 'comp' param at all) ----------
        # @azure/storage-blob's BlockBlobClient only uses the block/blocklist
        # chunked protocol above maxSingleShotSize (128 MiB); anything
        # smaller -- the common case -- is one plain PUT with no comp=
        # param. Confirmed live: a real actions/cache/save@v4 call for an
        # 843-byte file hit exactly this path and got a 400 before this was
        # fixed.
        backend.fail_upload = False  # Test 5 above deliberately left this True
        key3 = "cache-shim-test-key-3"
        status, body = http("POST", twirp_url, json.dumps({"key": key3, "version": version}), auth_headers)
        resp = json.loads(body)
        upload_url3 = resp["signed_upload_url"]
        single_shot_payload = b"single-shot-upload-body"
        status, body = http("PUT", upload_url3, single_shot_payload, {"Content-Type": "application/octet-stream"})
        check("single-shot PUT (no comp param) -> 201", status == 201, f"got {status} {body}")
        stored3 = backend.objects.get(f"storage/caches/fake/{key3}.tar.zst")
        check(
            "single-shot upload stored the exact body, byte for byte",
            stored3 == single_shot_payload,
            f"stored={stored3!r} expected={single_shot_payload!r}",
        )

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            proc.kill()
        runner_server.shutdown()

    print(f"\n=== SUMMARY: {PASS} passed, {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
