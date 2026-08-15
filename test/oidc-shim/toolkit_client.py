#!/usr/bin/env python3
"""
Minimal re-implementation of actions/toolkit's OidcClient.getIDToken, used
ONLY to drive the shim under test with the exact request shape the real
toolkit sends. This is NOT copied from actions/toolkit's source (MIT
licensed, but not reused here) -- it is written from scratch against the
behavior verified by reading `packages/core/src/oidc-utils.ts` at
https://github.com/actions/toolkit:

  - Request URL: `${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encodeURIComponent(audience)}`
    if an audience is given, else `${ACTIONS_ID_TOKEN_REQUEST_URL}` unchanged.
  - Method: GET.
  - Header: `Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}`
    (BearerCredentialHandler).
  - User-Agent: "actions/oidc-client" (cosmetic; the shim doesn't care, but
    included for request-shape fidelity).
  - Response: JSON body; reads `.value`. Raises if missing, matching the
    toolkit's own "Response json body do not have ID Token field" error.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


class OidcClientError(Exception):
    pass


def get_id_token(request_url: str, request_token: str, audience: str | None = None) -> str:
    url = request_url
    if audience:
        url = f"{request_url}&audience={urllib.parse.quote(audience, safe='')}"

    # The real toolkit always sends this header (BearerCredentialHandler is
    # unconditional). The empty-string sentinel here is test-only plumbing
    # to model a request that omits it entirely -- e.g. a caller that never
    # had ACTIONS_ID_TOKEN_REQUEST_TOKEN in the first place -- so the test
    # suite can drive that case through this same client rather than a
    # separate one-off script.
    headers = {"User-Agent": "actions/oidc-client"}
    if request_token:
        headers["Authorization"] = f"Bearer {request_token}"

    req = urllib.request.Request(
        url,
        method="GET",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status = e.code
        body = e.read().decode("utf-8")

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as e:
        raise OidcClientError(f"non-JSON response (status {status}): {body!r}") from e

    if status < 200 or status >= 300:
        raise OidcClientError(
            f"Failed to get ID Token. \n Error Code : {status}\n Error Message: {parsed}"
        )

    value = parsed.get("value")
    if not value:
        raise OidcClientError("Response json body do not have ID Token field")
    return value


if __name__ == "__main__":
    # CLI form for shell-driven tests: toolkit_client.py <url> <token> [audience]
    request_url = sys.argv[1]
    request_token = sys.argv[2]
    audience = sys.argv[3] if len(sys.argv) > 3 else None
    try:
        token = get_id_token(request_url, request_token, audience)
        print(token)
    except OidcClientError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
