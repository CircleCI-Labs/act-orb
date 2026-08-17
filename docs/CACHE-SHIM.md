# `act/cache-shim`: protocol detail, evidence, and security notes

This file holds the implementation-level detail behind the README's "Actions cache shim"
section: the real wire protocol `act/cache-shim` speaks on both sides, how an earlier "known
gap" was found and closed, and the shim's own security model. Read the README section first for
the quick start and the summary of what's proven; come here for the "how" and the receipts.

## How the protocol translation works

Verified directly against `actions/toolkit`'s real source (`packages/cache/src/cache.ts`,
`cacheTwirpClient.ts`, `uploadUtils.ts`), not guessed:

- `actions/cache`'s v2 client speaks Twirp -- plain JSON POSTs (always `Content-Type:
  application/json`, confirmed in the real client source) to
  `${ACTIONS_RESULTS_URL}twirp/github.actions.results.api.v1.CacheService/<Method>`, authenticated
  with `Authorization: Bearer ${ACTIONS_RUNTIME_TOKEN}`.
- `CreateCacheEntry{key,version}` gets back `{ok, signed_upload_url}`.
- The actual archive bytes go through Azure Blob's real block-blob wire protocol against that URL.
  For anything over `maxSingleShotSize` (128 MiB): a sequence of `PUT
  ...?comp=block&blockid=<base64>` calls (one per chunk, `uploadConcurrency` chunks in flight at
  once by default, so blocks can and do complete **out of order**), followed by one `PUT
  ...?comp=blocklist` that commits the upload. For anything smaller -- the common case, confirmed
  live against this shim's own CI test with an 843-byte file -- it's exactly **one** plain `PUT` of
  the whole body with **no `comp` parameter at all**; treating that as a 400 (this shim's first
  version did, until a real CI run caught it) breaks every small, everyday cache. Either way there
  is no separate "give me a presigned URL" round trip on top of this -- the URL from
  `CreateCacheEntry` *is* what receives the bytes. `cache_shim_server.py` decodes each block's real
  index from its `blockid` (the same two-format decode `falcondev-oss/github-actions-cache-server`
  -- an unrelated, independently-built OSS project speaking this same real protocol -- documents;
  re-derived here from first principles, not copied) and reassembles the archive in the correct
  order regardless of arrival order. Both paths are exercised in the local test suite (blocks are
  sent to the test server in reverse order on purpose; a separate case drives the no-`comp`
  single-shot path).
- `FinalizeCacheEntryUpload{key,version,size_bytes}` gets back `{ok, entry_id}`.
- `GetCacheEntryDownloadURL{key,restore_keys,version}` gets back `{ok, signed_download_url,
  matched_key}` on a hit, `{ok:false}` on a miss. `signed_download_url` points at this shim's own
  `/download/<id>` proxy, not a bare CircleCI/S3 URL -- see below for why.

Each RPC is translated into a call against CircleCI's own `$runner_host/api/v2/output/cache-save`
/ `cache-restore`, authenticated with the per-job task token read once, at this shim's own
startup, from `/tmp/circleci-ts.sock` (a plain, no-HTTP-framing unix socket that just writes
`{"token":...,"runner_host":...}` on connect and closes -- discovered live, confirmed against
`CircleCITestOrg/docker-agent-tester`'s own minimal Go reader for the same socket). Absence of
that socket is a fatal, clearly-messaged startup error, not a silent no-op -- self-hosted runners
or future CircleCI changes may not have it.

## The real upload/download contract, and how the old "known gap" was closed

An earlier version of this shim read `cache-save`'s response as a presigned-PUT-style ticket and
POSTed the archive bytes straight to `$runner_host/<location>`. Every construction of that
404'd, repeatedly, across many real pipeline runs (`POST`/`PUT`/`GET`/`HEAD`/`OPTIONS`, with and
without the `.tar.zst` suffix, with the path prefixed under `/api/v2/output/`,
`/api/v2/storage/`, `/api/v2/task/storage/` -- all 404). The 404s were real; the diagnosis was
wrong. `location` was never a route on `runner_host` at all.

Read directly from CircleCI's own `circleci/output` (the server behind `runner.circleci.com`) and
`circleci/task-agent-subcommand-cache` (a real, independent production consumer of the identical
API, used today for Bazel/Gradle/Xcode-CAS/Turborepo caching) source, then confirmed live against
this shim's own CI job:

- `GET {runner_host}/api/v2/output/config` (bearer = task token) returns, on real CircleCI SaaS:
  ```json
  {"type":"s3","endpoint":"","region":"us-east-1","bucket":"circleci-tasks-prod", ...}
  ```
  `type` is always `"s3"` on SaaS (a `"pre-signed"` mode exists in the server's own code but is
  documented there as enterprise-only).
- `GET {runner_host}/api/v2/output/credentials?provider=s3` (same bearer) returns short-lived
  (~15 minutes, observed live) per-task AWS STS credentials, scoped by IAM policy to this task's
  own storage prefixes only:
  ```json
  {"s3":{"AccessKeyID":"...","SecretAccessKey":"...","SessionToken":"...","Expires":"..."}}
  ```
- The cache-save ticket's `location` (e.g. `storage/caches/<projectID>/<key>.tar.zst`) is a raw
  **S3 object key** in the bucket from `config` -- not a URL fragment. The real upload is a
  normal, SigV4-signed S3 `PutObject` using the credentials above, with the ticket's `tags` sent
  as the `x-amz-tagging` header (an S3 lifecycle/retention hint, not a general metadata channel).
  Download is symmetric: `cache-restore`'s `location` is the same kind of key, fetched with a
  SigV4-signed S3 `GetObject`.

`cache_shim_server.py` implements AWS Signature Version 4 from scratch --
`_sigv4_authorization()`, `_s3_put_object()`, `_s3_get_object()` -- using only stdlib `hmac`/
`hashlib`, no boto3/botocore, matching this shim's existing zero-extra-install constraint. Because
`actions/cache`'s real Azure `BlockBlobClient` can't present AWS credentials of its own, the
upload path stays a *local* proxy exactly as before (`/upload/<id>`, this shim's own
request-token auth) -- what changed is what happens when that local proxy commits: a real, signed
S3 `PutObject` instead of a plain unsigned POST to `runner_host`. Download works the same way in
reverse: `GetCacheEntryDownloadURL` hands back a URL at this shim's own `/download/<id>`, which
performs the signed S3 `GetObject` itself and streams the bytes back -- `actions/cache` never
needs to see (or sign for) an S3 URL directly.

`actions/cache` still treats a save failure as a non-fatal warning and a restore miss as
`undefined` (cold build) -- unchanged, and still the right safety net for what this shim can't
yet handle (a job long enough to outlive the ~15-minute STS credential window during a single
huge upload; each S3 call fetches fresh credentials rather than caching them, which bounds but
does not eliminate that risk).

## Security notes

Same discipline `act/oidc-shim` was fixed to have after a real security review caught it
discarding its own auth header (see `docs/OIDC-SHIM.md`) -- applied here from the start:

- **Binds `0.0.0.0` by default, deliberately.** Act's spawned action container is a sibling of
  whatever process starts this shim, in its own network namespace; a loopback-only bind would be
  unreachable from it (the same measured Docker topology `docs/OIDC-SHIM.md` documents in detail
  applies unchanged here).
- **The real auth boundary is a per-job request token**, generated fresh with
  `secrets.token_urlsafe(32)`, checked with `hmac.compare_digest` (constant-time) on every
  request. It arrives on Twirp RPCs for free as `Authorization: Bearer <token>` (this shim tells
  `actions/cache` its own `ACTIONS_RUNTIME_TOKEN` *is* this token), and is additionally embedded
  as a `token=` query parameter on both the `signed_upload_url` AND `signed_download_url` this
  shim hands back, because real Azure block-blob semantics send no bearer header on the upload
  PUTs (and `actions/cache`'s own plain-GET download client sends no bearer header either) --
  without that query-param check, a wide bind would leave both proxy endpoints genuinely
  unauthenticated.
- **This shim's own AWS credentials never reach the wrapped action.** The STS credentials from
  `/api/v2/output/credentials` are used only inside this process, to sign the S3
  `PutObject`/`GetObject` calls `/upload/<id>`'s commit and `/download/<id>` make -- they are never
  written to a response body, a log line, or `$BASH_ENV`.
- `/healthz` stays unauthenticated by design but returns nothing beyond a static
  `{"status":"ok"}`.
- Neither the per-job request token, the CircleCI task token from `/tmp/circleci-ts.sock`, nor the
  AWS STS credentials from `/api/v2/output/credentials` are ever written to this process's own
  logs.
