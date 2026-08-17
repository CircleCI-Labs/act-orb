#!/usr/bin/env python3
"""
TEMPORARY diagnostic, not part of the shim itself. Reads the real per-job
task token from /tmp/circleci-ts.sock (same socket cache_shim_server.py
reads) and prints the raw JSON returned by:
  - GET  {runner_host}/api/v2/output/config
  - GET  {runner_host}/api/v2/output/credentials?provider=s3

Purpose: earlier research into CircleCI's own runner-side output API
established the SHAPE of the real cache-save upload contract (config ->
STS-style credentials -> signed S3 PutObject) but not the exact JSON field
names/casing these two HTTP endpoints actually emit on the wire. This
script exists to capture that, once, from a real job, so
cache_shim_server.py's S3 client can be built against real data instead of
a guess. Delete this file (and the temporary run step that invokes it) once
that's captured and implemented -- or leave it as a standing diagnostic if
a future protocol change needs re-probing.

Run: python3 test/cache-shim/probe_output_api.py
"""
import json
import socket
import sys
import urllib.error
import urllib.request

TASK_SOCKET_PATH = "/tmp/circleci-ts.sock"


def read_task_token(sock_path):
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
    finally:
        s.close()
    parsed = json.loads(raw)
    return parsed["token"], parsed["runner_host"]


# Values whose contents must never be printed. /api/v2/output/credentials returns
# live, task-scoped AWS credentials; printing the raw body would put a real
# SecretAccessKey and SessionToken into the CircleCI job log in plaintext, and this
# repo is public -- so anyone copying this diagnostic would leak their own. The
# shape is what this tool exists to reveal, and the shape is fully visible with the
# values redacted.
SECRET_KEYS = frozenset(
    {"SecretAccessKey", "SessionToken", "AccessKeyID", "Token", "token"}
)


def _redact(value):
    """Recursively replace secret-bearing leaf values with a length-only summary."""
    if isinstance(value, dict):
        return {
            k: (f"<redacted, {len(str(v))} chars>" if k in SECRET_KEYS else _redact(v))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [_redact(v) for v in value]
    return value


def get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", "replace")
            print(f"=== GET {url} -> {resp.status} ===")
            try:
                parsed = json.loads(body)
            except Exception:  # noqa: BLE001
                # Not JSON, so it can't be structurally redacted. Print only the
                # length rather than risk emitting a secret in an unexpected shape.
                print(f"<non-JSON body, {len(body)} chars, withheld>")
                return None
            print(json.dumps(_redact(parsed), indent=2, sort_keys=True))
            return parsed
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        print(f"=== GET {url} -> HTTP {exc.code} ===")
        try:
            print(json.dumps(_redact(json.loads(detail)), indent=2, sort_keys=True))
        except Exception:  # noqa: BLE001
            print(f"<non-JSON error body, {len(detail)} chars, withheld>")
        return None
    except Exception as exc:  # noqa: BLE001
        print(f"=== GET {url} -> EXCEPTION: {exc} ===")
        return None


def main():
    token, runner_host = read_task_token(TASK_SOCKET_PATH)
    print(f"runner_host={runner_host}")
    print(f"token length={len(token)}")

    config = get(f"{runner_host}/api/v2/output/config", token)
    creds = get(f"{runner_host}/api/v2/output/credentials?provider=s3", token)

    print("=== parsed keys ===")
    print("config keys:", sorted(config.keys()) if isinstance(config, dict) else config)
    print("credentials keys:", sorted(creds.keys()) if isinstance(creds, dict) else creds)


if __name__ == "__main__":
    sys.exit(main())
