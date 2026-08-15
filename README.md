# Act Orb (Unofficial) [![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/act-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/act-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/act.svg)](https://circleci.com/developer/orbs/orb/cci-labs/act) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/act-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

The Act Orb allows developers to run GitHub Actions directly on CircleCI using the [Act CLI](https://nektosact.com/). This orb bridges the gap between GitHub Actions and CircleCI, enabling seamless CI/CD workflows using GitHub Actions syntax while leveraging CircleCI’s powerful infrastructure.  

This orb would not be possible without the contributors who have worked on the [Act CLI](https://nektosact.com/). 

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ✅ Used by real CircleCI customers
-   ❌ **not** officially supported by CircleCI support

---

## Features
- Execute GitHub Actions workflows within CircleCI.
- Use familiar GitHub Actions syntax (`uses`, `with`, `env`), or the family-consistent `id`/`inputs` aliases if you're moving between CircleCI's other ecosystem-bridge orbs (Bitrise, Harness, Bitbucket Pipes, Buildkite).
- Integrate with existing CircleCI pipelines.
- Leverage CircleCI caching for faster runs.
- Surface the wrapped action's own outputs into `$BASH_ENV` for later native CircleCI steps (opt-in -- see [Capturing action outputs](#capturing-action-outputs)).
- Pass a `services:` block straight through to Act (see [Service containers](#service-containers)).
- Translate `actions/cache@v4`'s real protocol against CircleCI's own runner API (see
  [Actions cache shim](#actions-cache-shim) -- restore/negotiation proven, a durable save is a
  documented, in-progress gap, not silently pretended to work).
- Enable Act's own built-in artifact server for `actions/upload-artifact`/`download-artifact@v4`
  (see [Artifacts](#artifacts)).

## Quick Start

```yaml
version: 2.1
orbs:
  act: circleci/act@x.y.z
workflows:
  main:
    jobs:
      - act/act:
          name: "Hello World Javascript Action"
          uses: actions/hello-world-javascript-action@v1.1
          with: |
            who-to-greet: "Mona the Octocat"
          env: |
            hello-world: "example-value"
```

That's it for the common case -- `act/act` is a full job (checkout, install Act, generate a
one-step workflow file from `uses`/`with`/`env`, run it, cache what's cacheable). Use the `act/act`
**command** instead of the job if you need to run it inside your own executor/job (see
[Examples](#examples)).

## Defaults that deviate from Act

This orb intentionally overrides six of Act's own CLI defaults, tuned for CircleCI's
fresh-VM/container-per-job model rather than Act's own local-developer-loop assumptions. All six
are `additional-act-flags`-overridable and every one is a real, current default -- not a defect --
but they were previously undocumented, so a user reading only Act's own docs would be surprised:

| Flag | Act's own CLI default | This orb's default | Why |
|---|---|---|---|
| `--pull` | `true` | `false` | Avoid re-pulling the platform image on every single job when it was likely already pulled/cached this run. |
| `--rebuild` | `true` | `false` | Same reasoning as `--pull`. |
| `--reuse` | `false` | `true` | Keep container state across the (single) job invocation. |
| `--bind` | `false` | `true` | Share the checkout directory bidirectionally with Act's container rather than copying it -- also required for the `outputs` feature below. |
| `--detect-event` | `false` | `true` | The generated workflow always has exactly one event; auto-detecting it avoids an extra required parameter. |
| `--action-offline-mode` | `false` | `true` | Paired with this orb's own actions cache (`cache-actions`), which is expected to already hold what a prior run fetched. |

Override any of these via the matching orb parameter (`pull`, `rebuild`, `reuse`, `bind`,
`detect-event`, `action-offline-mode`) if your workflow needs Act's own default instead.

This table describes the `act`/`jobs/act` entry points, which pass all six explicitly. If you call
the lower-level `act/run-act` **command** directly (see the Quick Start note above on when to use
it), `pull` and `rebuild` fall back to Act's own default (`true`) rather than this table's `false`
when you don't set them -- `run-act` is a published command in its own right, so its standalone
default is kept stable rather than silently changed underneath any existing direct caller.

## Caching

This orb caches three independent things, each on and off separately, because each is a genuinely
different artifact with a different cost/benefit tradeoff:

| Dimension | Parameter | Default | What's cached | Cache key |
|---|---|---|---|---|
| The `act` CLI binary itself | `cache-cli` | on | `<bin-dir>/act` | arch + resolved Act version (`"latest"` is resolved to a concrete tag via the GitHub API before being used as a key, so a `"latest"` pin still gets fresh cache hits/misses as new versions ship, rather than sticking to whatever "latest" meant on the first run) |
| Act's downloaded-actions directory | `cache-actions` | on | `~/.cache/act` (the actions/dependencies Act itself fetched) | arch + `cache-key-prefix` + CircleCI project ID + job name |
| The platform Docker image | `cache-images` | **off** | a `docker save`'d tar of the platform image (see `platform`) | arch + `platform` + `cache-key-prefix` |

`cache-images` defaults to off because Docker image tars are large relative to the other two
artifacts and remote-docker/executor image pulls are often already fast on CircleCI's own image
cache -- turn it on if your platform image is unusually large or slow to pull in your environment.

All three cache keys share the `cache-key-prefix` parameter (default `v1`) as a common prefix, so
bumping it busts every cache dimension at once if you ever need a clean slate across all of them.

**Upgrade note:** the `cache-actions` key format changed in this release (a stray double dash
before `{{ .Environment.CIRCLE_JOB }}` was fixed to a single dash). Cache keys are literal
strings, not patterns, so this is a one-time, self-healing change: your existing actions cache
under the old key becomes unreachable, `restore_cache` falls through to the unversioned prefix key
(or a cold cache on the very next run), and a fresh cache is saved under the corrected key from
then on. Nothing breaks -- expect one slower "Restoring cache for Act's Actions..." step after
upgrading, not a caching regression.

## Actions cache shim

`act/cache-shim` translates GitHub's Actions-cache-service-v2 protocol -- what `actions/cache@v4`
(and every `setup-*` action with built-in caching) actually speaks -- into calls against
CircleCI's own runner API, so the wrapped action's cache calls hit a real server instead of
Act's own ephemeral, local-disk-only cache. It is a real, ~500-line protocol implementation
(`src/scripts/cache_shim_server.py`), not a stub, and it is exercised for real in this orb's own
CI (`test_cache_shim` in `.circleci/test-deploy.yml`) against the live CircleCI runner API on
every pipeline run.

**Be precise about what that proves and what it doesn't.** The RPC negotiation, auth enforcement,
and block-blob chunked-upload reassembly are all proven, both locally (`test/cache-shim/run_tests.py`,
18/18 passing against a correct fake backend -- run it yourself: `python3 test/cache-shim/run_tests.py`)
and against the real CircleCI API. What is **not yet proven** is a durable cross-run cache
**hit**: CircleCI's own `/api/v2/output/cache-save` endpoint does not hand back a usable upload
target from a plain job's task-token scope -- see "The known, real gap" below for the full,
reproduced evidence. `actions/cache` itself treats a save failure as a non-fatal warning (never a
build failure -- this is real GitHub Actions behavior too, caching is always best-effort), so
wiring this shim in today is safe; it just does not yet make your cache durable.

### Quick start

```yaml
version: 2.1
orbs:
  act: circleci/act@x.y.z

jobs:
  build_with_cache:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup_remote_docker
      - act/cache-shim
      - act/act:
          uses: actions/cache/save@v4
          with: |
            path: node_modules
            key: my-cache-key-v1
```

`act/cache-shim` must run in an earlier step of the **same job**, before `act/act`/`run-act`, for
the same reason `act/oidc-shim` does: it exports `ACTIONS_CACHE_SERVICE_V2`/`ACTIONS_RESULTS_URL`/
`ACTIONS_RUNTIME_TOKEN` into `$BASH_ENV`, which `act/act`'s own `create-env-var-secret-files` step
picks up automatically with zero call-site wiring -- the same seam the `github-token` parameter
and `act/oidc-shim` already use. It deliberately does **not** also export `GITHUB_SERVER_URL`:
an earlier version of this shim did (matching the naive reading of `actions/cache`'s own
`isGhes()` check, which treats a `*.localhost` hostname as "not GHES"), and that broke real jobs
outright -- Act's own action-resolution logic reads `GITHUB_SERVER_URL` from the exact same job
shell (since `$BASH_ENV` affects every later step, not just the wrapped action's container) to
decide where to `git clone` the wrapped action *from*, so a fake `*.localhost` value made Act try
to clone `actions/cache` itself from that fake host and fail immediately (measured live: `dial
tcp: lookup cache-shim.localhost: no such host`). Leaving the variable unset costs nothing:
`actions/cache`'s own `isGhes()` already defaults to `https://github.com` (i.e. "not GHES") when
it's absent.

### How the protocol translation works

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
  matched_key}` on a hit, `{ok:false}` on a miss. Unlike upload, a real download URL needs **no**
  shim proxying at all once one exists: `actions/cache`'s own `downloadCache()` only special-cases
  `*.blob.core.windows.net` hostnames for the Azure SDK path -- anything else, a CircleCI URL
  included, goes through a plain HTTP GET. So this shim can, in principle, hand back CircleCI's
  own presigned GET URL directly and step out of the way entirely for downloads.

Each RPC is translated into a call against CircleCI's own `$runner_host/api/v2/output/cache-save`
/ `cache-restore`, authenticated with the per-job task token read once, at this shim's own
startup, from `/tmp/circleci-ts.sock` (a plain, no-HTTP-framing unix socket that just writes
`{"token":...,"runner_host":...}` on connect and closes -- discovered live, confirmed against
`CircleCITestOrg/docker-agent-tester`'s own minimal Go reader for the same socket). Absence of
that socket is a fatal, clearly-messaged startup error, not a silent no-op -- self-hosted runners
or future CircleCI changes may not have it.

### The known, real gap

`$runner_host/api/v2/output/cache-save` does **not** return a presigned PUT URL the way
`actions/cache`'s own protocol would lead you to expect. It returns a small JSON *ticket*:

```json
{"method":"POST","location":"storage/caches/<id>/<key>.tar.zst","tags":{"expiration_days":"15"}}
```

The obvious reading -- POST the archive bytes to `$runner_host/<location>` -- was tested directly
against a real CircleCI job, repeatedly, across many separate pipeline runs, and **every
construction 404s**:

- `POST`/`PUT`/`GET`/`HEAD`/`OPTIONS` against `{runner_host}/{location}`, with and without the
  `.tar.zst` suffix, and with the `storage/...` path additionally prefixed under
  `/api/v2/output/`, `/api/v2/storage/`, `/api/v2/task/storage/` -- all 404, either a JSON
  `{"message":"Route Not Found"}` (a real router, just the wrong sub-path) or a bare `404 page
  not found` (a different framework entirely on some prefixes -- the two distinct 404 shapes are
  themselves evidence these are different services).
- The older, publicly-documented `POST /api/v2/task/storage/cache-save` (seen working, with a
  real `{url}` presigned-URL response, in `CircleCI-Public/circleci-steps-sdk-ts`'s
  `SaveCache.ts`) is itself `404 {"message":"routing error"}` on the live API -- that endpoint no
  longer exists.
- `OPTIONS` on `cache-save` itself (to see if a framework's default 405/404 leaks an `Allow:`
  header or a route list), an inline base64 `content` field on the save call itself, and half a
  dozen generic `/api/v2/output/upload`-shaped guesses were all tried too; none exists.

This strongly suggests `cache-save`'s task-token scope is **metadata-only** from a plain job
container: it can register a cache key/version, but the actual object bytes move through a
channel only CircleCI's own runner-agent process has, not something a job step (this shim
included) can reach over public HTTP. This is a real, reproduced finding from direct
experimentation against production, not a guess. `_redeem_cache_save_ticket()`/
`_resolve_download_url()` in `cache_shim_server.py` still make the documented-shape attempt
anyway (so this starts working automatically, with no code change, the moment CircleCI's backend
exposes the real path) but treat failure as the expected, logged, non-fatal outcome it is today.

**If you want to close this gap:** the mission that produced this shim was told
`circleci/task-agent-subcommand-cache` already ships exactly this architecture successfully for
Bazel/Gradle/Turborepo caching. That repo's source is the fastest path to the real answer -- it
was not reachable from this sandbox, but whoever has access to it should be able to read off the
correct way to redeem a `cache-save` ticket in minutes rather than re-deriving it through more
trial and error against production.

### Security notes

Same discipline `act/oidc-shim` was fixed to have after a real security review caught it
discarding its own auth header (see that section above) -- applied here from the start:

- **Binds `0.0.0.0` by default, deliberately.** Act's spawned action container is a sibling of
  whatever process starts this shim, in its own network namespace; a loopback-only bind would be
  unreachable from it (the same measured Docker topology `act/oidc-shim`'s own README documents in
  detail applies unchanged here).
- **The real auth boundary is a per-job request token**, generated fresh with
  `secrets.token_urlsafe(32)`, checked with `hmac.compare_digest` (constant-time) on every
  request. It arrives on Twirp RPCs for free as `Authorization: Bearer <token>` (this shim tells
  `actions/cache` its own `ACTIONS_RUNTIME_TOKEN` *is* this token), and is additionally embedded
  as a `token=` query parameter on the `signed_upload_url` this shim hands back, because real
  Azure block-blob semantics send no bearer header on the upload PUTs at all -- without that
  query-param check, a wide bind would leave the upload endpoint genuinely unauthenticated.
- `/healthz` stays unauthenticated by design but returns nothing beyond a static
  `{"status":"ok"}`.
- Neither the per-job request token nor the CircleCI task token from `/tmp/circleci-ts.sock` is
  ever written to this process's own logs.

## Artifacts

`actions/upload-artifact`/`download-artifact@v4` now work for jobs that don't use `container:` --
via a much smaller change than a from-scratch shim would have been. Investigating this surfaced
that **Act already ships a complete, working implementation of GitHub's real artifact-v4
protocol** (`pkg/artifacts` in `nektos/act`'s own source: the exact Twirp
`ArtifactService.{CreateArtifact,UploadArtifact,FinalizeArtifact,ListArtifacts,
GetSignedArtifactURL,DownloadArtifact}` routes, storing to local disk) -- it just never starts
that server unless you pass `--artifact-server-path`, a flag this orb never exposed. `run-act`
now has `artifact-server-path`/`artifact-server-addr`/`artifact-server-port` parameters (all
empty/off by default -- zero behavior change unless you set them) that pass straight through to
Act's own CLI flags of the same name. Once Act's runner sees `ArtifactServerPath != ""`, it
automatically injects `ACTIONS_RUNTIME_URL`/`ACTIONS_RESULTS_URL`/`ACTIONS_RUNTIME_TOKEN` into the
wrapped action's container itself (verified directly in `pkg/runner/run_context.go`) -- no orb
wiring needed beyond the one flag.

```yaml
- act/act:
    uses: actions/upload-artifact@v4
    with: |
      name: my-artifact
      path: some-file.txt
    artifact-server-path: /tmp/act-artifacts
- store_artifacts:
    path: /tmp/act-artifacts
    destination: gha-artifacts
```

This is real, tested in this orb's own CI (`test_artifacts` in `.circleci/test-deploy.yml`) end to
end: the file really lands on the CircleCI host's disk at the configured path, handed to a native
`store_artifacts` step. It does **not** fix `upload-artifact@v4` failing outright inside
`container:`-scoped jobs ([nektos/act#2508](https://github.com/nektos/act/issues/2508), open,
because the job's container image has no Node in it) -- that is an upstream Act limitation no
orb-side flag can work around, exactly as anticipated when this was originally scoped as deferred
(see `docs/ROADMAP.md` item 2).

## Capturing action outputs

Set `outputs` to a comma-separated list of the wrapped action's own output keys (matching its
`action.yml` `outputs:` block) to have this orb export them, verbatim by name, into `$BASH_ENV`
for a later, native CircleCI step in the same job to read as a plain shell variable:

```yaml
- act/act:
    uses: actions/hello-world-javascript-action@v1.1
    with: |
      who-to-greet: "Mona the Octocat"
    outputs: "time"
- run: echo "Greeted at $time"
```

This is opt-in and defaults to off (`outputs: ""`) -- existing jobs that don't set it see no
behavior change at all. It works by giving the generated action step a stable `id:` and appending
a second, same-job step that resolves each `${{ steps.<id>.outputs.<key> }}` expression and writes
it to a handoff file inside the (bound) checkout directory, which a `collect-outputs` step then
reads back on the CircleCI host. It does **not** read Act's `$GITHUB_OUTPUT` file directly --
that file lives inside Act's own per-step temp area, which is not shared with the CircleCI host
even with `bind` enabled, so `steps.*.outputs` expression evaluation (which Act supports natively)
is the mechanism that actually works. This means `outputs` only works when this orb is generating
the workflow file (`skip-create-workflow-file` unset) and `bind` stays enabled (the default). If
you bring your own workflow file, you can still reach `$BASH_ENV` yourself using the same pattern
this orb generates.

Violating either requirement does not error -- it fails silently, so know the actual behavior:

- **`bind: false` with `outputs` set:** the container's handoff-file write never reaches the
  CircleCI host, so `collect-outputs` finds nothing and no-ops. This orb logs a warning to that
  effect; no output is exported and no later step's use of the variable will resolve.
- **`skip-create-workflow-file: true` with `outputs` set:** nothing generates the output-capture
  step in your hand-written workflow, so Act never (re)writes the handoff file on this call. Every
  `act/act`/`run-act` invocation that requests `outputs` removes any handoff file left over from
  an *earlier* call in the same job/`directory` before it runs, specifically so this case can never
  silently re-export a previous call's stale value -- but it still cannot produce a *fresh* value
  from a workflow file that doesn't write one, since Act's own `$GITHUB_OUTPUT` per-step temp area
  isn't shared with the host even with `bind` on. Add the same "collect outputs for CircleCI" step
  this orb generates (see the source of `create-workflow-file.sh`) to your own workflow file if you
  need `outputs` alongside `skip-create-workflow-file`.

Output keys containing characters that aren't legal in a shell variable name (GitHub allows `-` in
output ids; bash does not) are exported under a sanitized name (dashes -> underscores) with a
loud warning in the step's log -- the action's own output name is unaffected, only the
CircleCI-side variable name differs.

## Service containers

Pass a GitHub Actions `services:` block straight through via the `services` parameter:

```yaml
- act/act:
    uses: actions/hello-world-javascript-action@v1.1
    services: |
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
```

This is a **verbatim passthrough** into the generated workflow file -- Act emulates `services:`
itself via its own Docker networking, which inherits Act's own known service-emulation issues
([nektos/act#1022](https://github.com/nektos/act/issues/1022),
[nektos/act#2607](https://github.com/nektos/act/issues/2607), both open at the time of writing).
A native translation to a CircleCI secondary Docker image (CircleCI's own equivalent primitive,
no Act emulation needed) is a larger, job-level design change -- see `docs/ROADMAP.md`.

## Security notes

**`with`/`env`/`services` are trusted, unescaped input.** This orb builds the generated workflow
file by embedding these parameters' raw string values directly into generated YAML (indented to
fit, but not otherwise escaped). This matches how `config.yml` itself already trusts a job's own
parameter values, but it's worth stating plainly now that `services` extends the same pattern to
a third parameter: if any of `with`/`env`/`services` are ever populated from a source you don't
control (e.g. a CircleCI pipeline parameter fed by a webhook payload or a PR title), a crafted
value could break out of its intended YAML block and inject arbitrary keys/steps into the
generated workflow. Treat these the same as any other config-author-trusted value -- don't wire
untrusted external input into them directly.

**`GITHUB_TOKEN` is a weaker substitute, not a drop-in one.** Real GitHub Actions' `GITHUB_TOKEN`
is a per-job GitHub App installation token, auto-scoped to exactly one repository and
auto-expiring when the job ends. There is no CircleCI primitive that mints anything like it. This
orb (and its `avoid_token_error` example) can only wire in a personal access token you create and
store as a CircleCI project/context env var -- which is broader in scope than the job needs, does
not auto-expire, is not automatically narrowed by a workflow's own `permissions:` block, and must
be rotated by you. Scope it to the minimum you actually need and rotate it on a schedule.

**The `github-token` parameter is a seam, not a mint.** By default it names `GITHUB_TOKEN` --
identical behavior to today. Point it at a *different* CircleCI env var name (e.g. one populated by
a future pipeline-scoped token-minting step) and this orb aliases that variable's value into the
secrets bucket under the literal key `GITHUB_TOKEN` for you, and keeps the source variable's own
name out of the plaintext `.env` file automatically -- so Act and the wrapped Action still see a
plain `GITHUB_TOKEN`, with zero interface change on either side. This orb implements only the
aliasing; it mints nothing itself. CircleCI's Sources of Change team already mints scoped GitHub
App installation tokens tied to pipeline-trigger time (`TokenRestrictions{Scopes, RepositoryIDs}`,
`CreateAndStoreTokenForPipeline` in `soc-integrations`) -- the only missing piece to get much
closer to real GitHub Actions' own per-job token behavior is exposing one of those into a job's
environment under some other env var name and pointing `github-token` at it. See
`docs/ROADMAP.md` for the fuller rationale.

**The env/secret/var files this orb generates for Act are opt-in secret, not opt-out.** By
default only `GITHUB_TOKEN` is treated as sensitive (the `secrets` parameter); every other
environment variable present in the job is written to the **plaintext** `.env` file Act reads
from, unless you explicitly list it in `secrets` or `variables`. Review what your job's
environment actually contains before running this orb, especially in a context with broad env
access. Multi-line values (SSH keys, JSON service-account credentials) are handled without
leaking fragments into the plaintext file even when correctly named as a secret, but are still
written unquoted -- Act's own dotenv-style parser may not round-trip an embedded newline
correctly; avoid multi-line secrets/vars, or pre-encode them (e.g. base64), if you must use one.

**Act's own installer script is fetched from a pinned commit and checksum-verified before it's
ever executed** (rather than piping a mutable branch ref straight into `sudo bash`) -- see the
comment block at the top of `src/scripts/install.sh` for the maintenance process if Act changes
that script upstream. The release *binary* Act's installer downloads is checksum-verified by
Act's own installer already; this orb doesn't duplicate that, only the installer-script fetch
itself.

## What does not work

- **`actions/cache` save does not durably persist yet -- restore works, save's upload leg has a
  real, reproduced gap in CircleCI's own backend.** See [Actions cache shim](#actions-cache-shim)
  below for the full design, what's proven, and the exact evidence trail. This orb now ships a
  real protocol-translation shim (`act/cache-shim`) rather than nothing, which is real progress
  over the prior "not attempted" state, but a genuine cross-run cache **hit** is not yet
  demonstrated -- be honest with yourself about that before relying on it.
- **`actions/upload-artifact`/`download-artifact` now work for non-`container:`-scoped jobs** --
  see [Artifacts](#artifacts) below: Act already ships a complete artifact-v4 server, this orb
  just now exposes the one flag (`artifact-server-path`) that turns it on. `upload-artifact@v4`
  still fails outright inside `container:`-scoped jobs
  ([nektos/act#2508](https://github.com/nektos/act/issues/2508), open) because the job's
  container image has no Node in it -- on real GitHub Actions this step runs at the runner level,
  outside the job container, specifically to avoid that; no shim can patch around an upstream Act
  limitation. See `docs/ROADMAP.md` item 2.
- **No OIDC token issuance.** Act does not implement GitHub's OIDC signer
  ([nektos/act#2500](https://github.com/nektos/act/issues/2500),
  [nektos/act#2262](https://github.com/nektos/act/issues/2262), both open); an action calling
  `core.getIDToken()` will error unless you pre-populate a fake value yourself. See
  `docs/ROADMAP.md` item 4.
- **Non-Linux `runs-on` targets aren't really emulated.** `runs-on: macos-*`/`windows-*` either
  silently runs on the wrong platform image or fails -- a long-standing Act limitation
  ([nektos/act#97](https://github.com/nektos/act/issues/97), open since 2020), not something this
  orb can fix.
- **Reusable workflows (`workflow_call`) are poorly supported by Act itself** -- matrix +
  reusable-workflow combinations, nested `if:` conditions, and related issues have several
  long-standing open reports upstream
  ([nektos/act#1114](https://github.com/nektos/act/issues/1114),
  [nektos/act#2003](https://github.com/nektos/act/issues/2003)).
- **GitHub-native security-tab integrations have no destination.** `github/codeql-action` and any
  action whose entire purpose is uploading into GitHub's own Code Scanning/Dependabot/Secret
  Scanning UI cannot work off-GitHub -- there is no equivalent surface to upload into, full stop.
- **One action per job/command invocation.** This orb (like its ecosystem-bridge siblings)
  generates one job, one step, one action per `act/act` call by design -- it is not a general
  GitHub Actions workflow executor. If you need a multi-step workflow, hand-write the workflow
  file and pass it via `skip-create-workflow-file: true` (see [Examples](#examples)), or, for a
  whole multi-job `.github/workflows` file, see the compiler below.

## GitHub Actions workflow compiler

`install-ghac`, `gha-compile`, and `gha-render-job` compile a real GitHub Actions workflow file
into a CircleCI config -- one CircleCI job per GitHub job, wired together with `requires:` and
`filters:` -- rather than requiring you to hand-translate it action by action. Each generated job
still runs its GitHub steps via `act/act` under the hood (see
[`render_and_run_github_job.yml`](src/examples/render_and_run_github_job.yml)); the compiler's job
is deciding what the CircleCI jobs and their wiring should be, not reimplementing what Act already
does correctly.

**MVP boundary: multi-job workflows connected only by `needs:` (and, within that, only the
`needs.<job>.outputs.<name>` form of cross-job data flow), plus `strategy.matrix` (a real CircleCI
`matrix:` job) and `runs-on: self-hosted` (a real CircleCI self-hosted runner resource class).**
Nothing about this is silently ignored -- every construct that isn't one of the specific supported
shapes below is **rejected by name**, with the exact unsupported construct quoted in the error, at
compile time. A workflow either compiles into something this orb has verified will run, or it
fails loudly telling you exactly which line stopped it. See `tools/ghac/README.md` for the full
design writeup and how the prototype's real-CLI, real-`act` validation was done.

### How it's wired

1. Commit a `setup: true` `.circleci/config.yml` that runs `act/gha-compile` against your
   `.github/workflows/*.yml` file and hands the result to
   [`circleci/continuation`](https://circleci.com/developer/orbs/orb/circleci/continuation)'s
   `continue` command -- see
   [`compile_github_workflow.yml`](src/examples/compile_github_workflow.yml) for the complete file.
2. Every job the compiler generates calls `act/gha-render-job` (which re-derives that one job's
   `needs:`-stripped workflow file from the same checked-out source -- see `tools/ghac/README.md`
   for why this happens per-job, at job runtime, rather than once in the setup job) followed by
   `act/act` with `skip-create-workflow-file: true`, pointed at the rendered file. This is not new
   behavior of `act/act` -- the `skip-create-workflow-file`/`workflow-file`/`job` combination
   already existed for hand-authored workflows; the compiler is just the thing generating that
   file for you now.

### What's supported, what's rejected, what's delegated

"Delegated" means Act resolves that construct itself, from the real, unmodified workflow file --
correctly, because it's Act's own job to do so, not something this compiler reimplements.

| Construct | Outcome |
|---|---|
| `runs-on:` (single string, in the built-in mapping table: `ubuntu-latest`/`ubuntu-22.04`/`ubuntu-24.04`) | **Supported** -- mapped to a CircleCI `machine:` executor + `act --platform` image |
| `runs-on:` (unmapped label, e.g. a custom name that isn't self-hosted) | **Rejected by name** |
| `runs-on: self-hosted` / `runs-on: [self-hosted, linux, x64]` (or other recognized labels) | **Supported** -- mapped to a CircleCI self-hosted runner `resource_class` once a runner namespace is configured (`--self-hosted-namespace`); see `tools/ghac/README.md`/`internal/compile/runson.go` for the exact naming convention your resource classes need to follow. **This is a migration selling point, not a limitation** -- your existing self-hosted jobs run on CircleCI runners. |
| `runs-on: [self-hosted, windows]` / `[self-hosted, macos]` / an unrecognized extra label | **Rejected by name** -- act needs a Linux Docker host regardless of which machine the runner is; an unrecognized label has nothing to map to and isn't guessed at |
| `runs-on: self-hosted` with no `--self-hosted-namespace` configured | **Rejected by name** -- there's no way to derive a resource class without knowing your organization's runner namespace |
| `runs-on: windows-latest` / `macos-latest` | **Rejected by name** -- explicit reason (Act/CircleCI executor mismatch) |
| `runs-on: ${{ matrix.* }}` (matrix-driven runs-on) | **Rejected by name** -- a fixed runs-on label is required even when `strategy.matrix` is used elsewhere in the job |
| `needs:` (string or list) | **Supported** -- becomes `requires:` (expanded to include any `strategy.matrix.include`-added job invocations too, see below) |
| `if: github.ref == 'refs/heads/X'` / `'refs/tags/X'` | **Supported** -- becomes `filters:` |
| `if: github.ref_name == 'X'` | **Supported** (treated as a branch name) |
| `if: startsWith(github.ref, 'refs/heads/'|'refs/tags/')` | **Supported** |
| `if:` (any other expression) | **Rejected by name** -- the raw expression text is quoted in the error |
| Step-level `if:` | **Delegated** |
| `jobs.<job>.outputs.<name>: ${{ steps.X.outputs.Y }}` | **Supported** -- captured via a synthetic step, wired through workspace |
| `jobs.<job>.outputs.<name>` (literal value, or any other expression shape) | **Rejected by name** |
| `${{ needs.<job>.outputs.<name> }}` (exact whole expression) | **Supported** -- rewritten to `${{ env.* }}`, threaded through `persist_to_workspace`/`attach_workspace` |
| `${{ needs.<job>.result }}` / `needs.*` combined with other operators or inside a function call | **Rejected by name** -- the expression-language wall; see `tools/ghac/README.md` |
| `strategy.matrix` (plain cross-product, e.g. `os: [...]`, `version: [...]`) | **Supported** -- becomes a real CircleCI `matrix:` job invocation (the generated job is parameterized; each matrix key becomes a job parameter) |
| `${{ matrix.<key> }}` (exact whole expression, in that job's own steps/env) | **Supported** -- rewritten to `${{ env.CCI_MATRIX_<KEY> }}`, set from `<< parameters.<key> >>` at CircleCI job runtime |
| `matrix.*` combined with other operators or inside a function call | **Rejected by name** |
| `strategy.matrix.exclude` | **Supported** -- fully expanded into exact combinations and passed to CircleCI's own `matrix.exclude` |
| `strategy.matrix.include` (entry specifies exactly the base matrix's own keys, adding one new combination) | **Supported** -- becomes a separate, explicit, non-matrix job invocation calling the same parameterized job |
| `strategy.matrix.include` (entry omits a base matrix key, or adds a key not already in the matrix) | **Rejected by name** -- GitHub's semantics there widen/augment existing cells, and this compiler won't guess which |
| `strategy.matrix` combined with `outputs:` on the same job | **Rejected by name** -- GitHub itself only exposes the last-finishing matrix cell for `needs.<job>.outputs.*`, an ordering-dependent result this compiler won't reproduce |
| `strategy.fail-fast` | **Accepted as a documented no-op** -- CircleCI runs every matrix cell to completion independently; it does not cancel sibling matrix jobs on a failure. Noted in the generated config's comments, not silently dropped |
| `strategy.max-parallel` | **Rejected by name** -- CircleCI has no per-matrix concurrency cap (same reason workflow-level `concurrency:` below is out of scope) |
| `services:` (job-level) | **Rejected by name** |
| `uses:` (job calls a reusable workflow) | **Rejected by name** |
| `permissions:` / `concurrency:` (workflow- or job-level) | **Rejected by name** |
| `environment:` (job-level deployment environments) | **Rejected by name** |
| `on:` (workflow trigger config) | **Not translated, by design** -- CircleCI's own pipeline triggers (in the setup config you commit) decide when the pipeline runs; documented here rather than left as a silent no-op |
| `env:` / `defaults:` / `container:` (workflow-, job-, step-level) | **Delegated** |
| `uses:`/`with:`/`run:`/`id:`/`name:`/`shell:`/`timeout-minutes:`/`continue-on-error:` (step-level) | **Delegated** |
| Any other `${{ }}` expression not mentioning `needs.*`/`matrix.*` (`github.*`, `secrets.*`, `vars.*`, `env.*`, `inputs.*`, same-job `steps.*.outputs.*`) | **Delegated** |

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/act) - The official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - Docs for using, creating, and publishing CircleCI Orbs.

## Examples

For the most up to date examples, please visit the the Orb Registry's [usage examples](https://circleci.com/developer/orbs/orb/cci-labs/act#usage-examples).

### Run a GitHub Action Using Act
```yaml
  version: 2.1
  orbs:
    act: circleci/act@x.y.z
  workflows:
    main:
      jobs:
        - act/act:
            name: "Hello World Javascript Action"
            uses: actions/hello-world-javascript-action@v1.1
            with: |
              who-to-greet: "Mona the Octocat"
            env: |
              hello-world: "example-value"

```

### Avoid GitHub Token Errors
```yaml
  version: 2.1
  orbs:
    act: circleci/act@x.y.z
  workflows:
    main:
      jobs:
        - act/act:
            uses: aquasecurity/trivy-action@master
            with: |
              scan-type: fs
              ignore-unfixed: true
              format: sarif
              output: report.sarif
              scanners: vuln,secret,misconfig,license
            platform: ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
            context: act

```

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/act-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/act-orb/pulls) against this repository!

Every script in `src/scripts/` is enforced clean by `shellcheck` (`severity: error`) and `shfmt
-i 4 -ci -sr` in CI. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for larger items that were
deliberately scoped out of past passes, with the reasoning recorded rather than lost.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's
`<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb
that can still pass `circleci orb validate` -- a false green with no other symptom. Run
`scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack`
workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a
job parameter literally named `pre-steps` or `post-steps` outright -- this only surfaces under
`orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it.
If you're adding a new job parameter, don't pick either name. (This orb has never had a
before/after-steps-style hook parameter to collide with this, but a future job parameter still
could.)

## How to Publish An Update
1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info cci-labs/act | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/act-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.