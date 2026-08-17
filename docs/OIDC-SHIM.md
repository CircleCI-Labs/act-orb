# `act/oidc-shim`: evidence trail and security notes

This file holds the implementation-level detail behind the README's "OIDC token issuance for
wrapped Actions" section: exactly what is proven where, and the shim's own security model. Read
the README section first for the quick start and the one-time cloud-side setup; come here for the
"how do I know this works" and the security reasoning.

## What's proven, and what isn't

The request/response contract, auth enforcement, and every documented failure path (missing
token, unknown audience, the CircleCI CLI missing from `PATH`, a hung mint call) are proven
locally against the real, shipped script: `test/oidc-shim/run_tests.sh` drives
`src/scripts/oidc-shim-start.sh` (not a copy) with a fake `circleci` binary and a client that
reproduces `actions/toolkit`'s exact request shape -- run it yourself:
`bash test/oidc-shim/run_tests.sh`.

`test_oidc_shim` in `.circleci/test-deploy.yml` closes the live-CI gap this section used to flag:
it starts the shim via the real `act/oidc-shim` command (not the raw script) in a real CircleCI
job, requests a token through it with a client that reproduces `actions/toolkit`'s exact request
shape, and asserts the auth gate actually rejects both a missing and a wrong bearer token before
proving the happy path mints a real, well-formed, correct-audience JWT through the real
`circleci run oidc get` CLI -- the same real-mint, real-auth-gate proof `act/cache-shim` has for
its own protocol (`test_cache_shim` in the same file).

What that job does **not** yet prove: an actual wrapped GitHub Action, run through a real
`act/act` invocation inside Act's spawned container, calling `core.getIDToken()` and using the
resulting token against a real cloud API (the way `configure-aws-credentials` would call
`sts.amazonaws.com`). `test_oidc_shim` talks to the shim directly with a script that mimics the
toolkit client, rather than running Act at all -- so the shim's own contract and the real mint are
proven end to end, but a full Action-in-container round trip through `act/act` is not yet. Treat
those as the separate, honest claims they are.

## Security notes

Same discipline `act/cache-shim` was built with from the start, because this shim was fixed to
have it after its own security review caught it discarding its own auth header early in
development:

- **Binds `0.0.0.0` by default, deliberately.** Act's spawned action container is a sibling of
  whatever process starts this shim, in its own network namespace; a loopback-only bind would be
  unreachable from it -- measured directly on real CircleCI infra (a `docker` executor +
  `setup_remote_docker` job whose container bound `0.0.0.0` answered its own loopback fine, but a
  sibling container on the default bridge network could not reach it at all; only a sibling
  started with `--network host` could).
- **The real auth boundary is a per-job request token**, generated fresh with
  `secrets.token_urlsafe(32)`, checked with `hmac.compare_digest` (constant-time) on every
  request. It arrives for free as the `Authorization: Bearer <token>` header
  `actions/toolkit`'s own OIDC client already sends (this shim tells the action its
  `ACTIONS_ID_TOKEN_REQUEST_TOKEN` *is* this token) -- network position is not the security
  boundary here, since the bind can't be narrowed to loopback.
- **`audience-allowlist` is defense in depth only**, layered on top of the per-job token above,
  not a substitute for it: an unauthenticated request is rejected before the audience is even
  looked at, so a caller that can't present the token can never reach the allowlist check or
  trigger a real mint call.
- `/healthz` stays unauthenticated by design but returns nothing beyond a static
  `{"status": "ok"}`.
- The minted JWT and the per-job request token are never written to this process's own logs.
