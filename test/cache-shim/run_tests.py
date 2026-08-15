#!/usr/bin/env python3
"""
Local functional test for cache_shim_server.py.

This drives the REAL shipped server (src/scripts/cache_shim_server.py, not a
copy) against two fakes:
  - a fake /tmp/circleci-ts.sock-style task-token socket, and
  - a fake `runner_host` HTTP server that implements the cache-save/
    cache-restore contract CORRECTLY (unlike the real, live CircleCI API --
    see cache_shim_server.py's own module docstring's "Known, real gap"
    section) -- specifically so this test can prove the shim's OWN
    client-side plumbing (Twirp translation, block-blob reassembly in the
    face of out-of-order/concurrent block PUTs, ticket redemption, auth
    enforcement) is correct, independent of whether the real production API
    happens to expose a working upload path today.

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

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_SRC = os.path.join(HERE, "..", "..", "src", "scripts", "cache_shim_server.py")

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
    """A correct, in-memory implementation of the cache-save/cache-restore
    contract this shim expects -- used to prove the shim's own client code
    is right, independent of whether the real API's upload leg works."""

    def __init__(self):
        self.objects = {}  # location -> bytes
        self.tickets = {}  # (key,version) -> location
        self.fail_upload = False

    def app(self, path, method, body, headers):
        if path == "/api/v2/output/cache-save" and method == "POST":
            req = json.loads(body or b"{}")
            key, version = req.get("cache_key"), req.get("version")
            location = f"storage/caches/fake/{key}.tar.zst"
            if (key, version) in self.tickets:
                return 409, json.dumps({"message": "conflict"}).encode()
            self.tickets[(key, version)] = location
            return 200, json.dumps({"method": "POST", "location": location, "tags": {}}).encode()

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

        # The upload leg: real production 404s here (see module docstring);
        # this fake implements it correctly so the plumbing can be verified.
        if path.startswith("/storage/caches/") and method == "POST":
            if self.fail_upload:
                return 404, json.dumps({"message": "Route Not Found"}).encode()
            self.objects[path.lstrip("/")] = body
            return 200, b"{}"

        return 404, json.dumps({"message": "not found"}).encode()


def start_fake_runner(backend):
    class H(BaseHTTPRequestHandler):
        def _dispatch(self, method):
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length else b""
            status, resp = backend.app(self.path, method, body, self.headers)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        def do_POST(self):
            self._dispatch("POST")

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


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
            dl_status, dl_body = http("GET", resp["signed_download_url"])
            # The fake backend only implements POST for uploads; GET on the
            # object path isn't wired in this minimal fake, so just confirm
            # the shim handed back a URL that at least targets the right
            # object path rather than asserting byte content here.
            check(
                "download URL targets the exact stored object location",
                f"storage/caches/fake/{key}.tar.zst" in resp["signed_download_url"],
                resp["signed_download_url"],
            )

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
