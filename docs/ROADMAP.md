# Roadmap / deferred design decisions

This file records the things a full audit of act-orb (2026-08) found worth doing, but that this
pass deliberately did **not** build, and why -- so the decision is visible in the repo instead of
living only in a chat transcript or a PR description that ages out.

None of the items below are secretly half-built. If you pick one up, treat this as the starting
brief, not a patch to apply.

## 1. Actions-cache-service shim (`ACTIONS_CACHE_URL`/`ACTIONS_RESULTS_URL`) -- STATUS UPDATE (2026-08): built, protocol proven, save-persistence gap real and documented

This item was picked up in a later pass (family-parity work vs. `buildkite-gha`). What follows is
that pass's own record, kept alongside the original entry above for history.

**What shipped:** `act/cache-shim` (`src/commands/cache-shim.yml`, `src/scripts/
cache_shim_server.py` + `cache-shim-start.sh`) -- a real, ~500-line Twirp-protocol
translation server, not a stub. It implements `CreateCacheEntry`/`FinalizeCacheEntryUpload`/
`GetCacheEntryDownloadURL`, the real Azure block-blob chunked-upload wire format (including
correct reassembly of out-of-order blocks, verified with `uploadConcurrency`-style concurrent
sends in `test/cache-shim/run_tests.py`), and the same wide-bind-plus-per-job-token security
posture `act/oidc-shim` was fixed to have after its own security review. See the README's
[Actions cache shim](../README.md#actions-cache-shim) section for the full design.

**What is proven, with evidence, and what is not:**
- Twirp negotiation, auth enforcement, and block reassembly: proven, both locally (18/18 in
  `test/cache-shim/run_tests.py` against a correct fake backend) and against the real CircleCI
  runner API in this orb's own CI (`test_cache_shim`).
- A durable, cross-run cache **hit**: **not proven.** `$runner_host/api/v2/output/cache-save`
  returns a `{"method","location","tags"}` ticket, not a presigned URL, and every construction of
  an actual upload target from that ticket 404s when tried from a real job -- tested exhaustively
  (bare location, every plausible path-prefix combination, the older now-dead
  `/api/v2/task/storage/cache-save` endpoint, an inline-content field, generic upload-endpoint
  guesses, `OPTIONS` probing) across many separate real pipeline runs. See the README's "The
  known, real gap" subsection for the complete, reproduced evidence trail. The working hypothesis:
  a plain job's task-token scope is metadata-only for this endpoint; the real object-storage
  channel belongs to CircleCI's own runner-agent process, not something a job step can reach.

**Why this wasn't fully closed this pass:** the mission that produced this shim was told
`circleci/task-agent-subcommand-cache` already does this successfully for Bazel/Gradle/Turborepo
caching -- but that repo's source was not reachable from the sandbox this work was done in.
Reading it is very likely the fastest path to the actual answer (the correct way to redeem a
`cache-save` ticket, or the actual endpoint/channel real cache bytes move through) -- faster than
more trial-and-error probing against production.

**If someone picks this up:** read `task-agent-subcommand-cache`'s own upload-redemption code
first. If it truly uses `/api/v2/output/cache-save` the same way this shim does, the missing piece
is almost certainly either (a) a header/field this pass didn't try, or (b) evidence the real
channel is not public HTTP at all, in which case the honest scope of this shim is "restore-only,
formally" and the README should say so even more plainly than it already does.

## 2. Artifact-service shim (native `store_artifacts` interception) -- STATUS UPDATE (2026-08): built, much smaller than originally scoped

**What shipped:** `run-act`'s new `artifact-server-path`/`artifact-server-addr`/
`artifact-server-port` parameters (all off by default), which just pass through to flags Act's
own CLI *already has*. Investigating this surfaced that the original premise below --
"requires an independent protocol implementation" -- was wrong: **Act already ships a complete,
working implementation of GitHub's real artifact-v4 protocol** (`pkg/artifacts` in `nektos/act`'s
own source -- the real Twirp `ArtifactService` routes, storing to local disk), gated behind a
single `--artifact-server-path` flag this orb simply never passed. Once set, Act's own runner
(`pkg/runner/run_context.go`) automatically injects `ACTIONS_RUNTIME_URL`/`ACTIONS_RESULTS_URL`/
`ACTIONS_RUNTIME_TOKEN` into the wrapped action's container -- no shim, no protocol translation,
no orb-side server. See the README's [Artifacts](../README.md#artifacts) section.

**What's proven:** `test_artifacts` in `.circleci/test-deploy.yml` runs a real
`actions/upload-artifact@v4` through `act/act` with this flag set and asserts the file lands on
the CircleCI host's disk, then hands it to a real `store_artifacts` step -- end to end, for real,
not simulated.

**What's still true from the original scoping below, unchanged:** `upload-artifact@v4` still
fails outright inside `container:`-scoped jobs
([nektos/act#2508](https://github.com/nektos/act/issues/2508), still open) because the job's
container image has no Node in it. This is an upstream Act limitation; enabling Act's own
artifact server does nothing for that case, exactly as anticipated when this item was first
scoped (see the original entry immediately below, kept for history).

**If someone picks this up:** the remaining gap is entirely upstream (nektos/act#2508), not
something an orb-side change can address. `persist_to_workspace` on the same
`artifact-server-path` directory is the natural next addition if cross-job artifact flow (rather
than just landing in the CircleCI artifacts UI) turns out to matter for real usage.

---

**Original scoping (kept for history -- see the STATUS UPDATE above each for what actually
shipped and what didn't):**

**What it would do:** let `actions/cache@v4` (and the dozens of `setup-*` actions with built-in
caching) inside a wrapped action actually persist across CircleCI runs, instead of getting Act's
own ephemeral, local-disk-only cache server that dies with the VM.

**Why it's deferred:** verified directly against Act's own source (`cmd/root.go`) that there is no
CLI flag that gets you this "for free." Act's `--cache-server-*` flags only configure Act's *own*
embedded cache server (or its externally-reachable hostname if it's behind a proxy) -- none of
them let you point `actions/cache` at an arbitrary backend. The one real hook is that Act skips
starting its own server if `ACTIONS_CACHE_URL` is already set in the environment before Act
starts, which means a shim is *pluggable*, but Act provides zero help *implementing* one: the
shim would have to independently implement GitHub's real cache-service wire protocol (v1
`ACTIONS_CACHE_URL` and/or v2 `ACTIONS_RESULTS_URL`, bearer-authed with
`ACTIONS_RUNTIME_TOKEN`) and translate its calls into CircleCI's `save_cache`/`restore_cache` (or
direct S3). That is a standalone long-running local HTTP service plus a protocol translation
layer -- real, scoped engineering, not a config change to this orb. Building it partially (e.g.
handling only the common GET/PUT paths of the protocol) would silently break on the paths it
doesn't cover, which is worse than the current, honestly-documented gap.

**What shipped instead:** the README's "What does not work" section states plainly that
`actions/cache` calls inside a wrapped action get Act's own ephemeral cache, distinct from (and
not backed by) this orb's own `cache-actions`/`cache-images` commands, which only cache Act's own
state (the actions it downloaded, the images it pulled) -- not the *workflow's* own cache calls.

**If someone picks this up:** scope it as its own project with its own review, not a patch to this
orb. Minimum shape: a small always-running local HTTP server (could run as a background step in
this orb, started before `run-act` and stopped after), a translation layer for the subset of the
cache-service protocol `actions/cache` actually uses in practice, and wiring
`ACTIONS_CACHE_URL`/`ACTIONS_RUNTIME_TOKEN` into the env-file before Act starts.

**What it would do:** let `actions/upload-artifact`/`download-artifact` inside a wrapped action
land in CircleCI's own artifacts UI instead of vanishing when the ephemeral VM exits.

**Why it's deferred:** same shape of problem as the cache shim -- `ACTIONS_RUNTIME_TOKEN`-authed
HTTP protocol, no CLI flag shortcut, requires an independent protocol implementation. And even a
fully-built shim would not fix the worse of the two known failure modes: `upload-artifact@v4`
fails outright inside `container:`-scoped jobs because the container image the workflow specified
has no Node in it (confirmed live: [nektos/act#2508](https://github.com/nektos/act/issues/2508),
state **open** as of this pass) -- on real GitHub Actions, `upload-artifact` runs at the runner
level, *outside* the job's container, precisely to avoid this; Act does not preserve that
distinction, and that's an upstream Act limitation this orb cannot patch around regardless of
what we shim.

**What shipped instead:** the README's "What does not work" section states this plainly and links
the open issue, rather than implying artifacts work.

**If someone picks this up:** defer until (or unless) nektos/act changes how `container:` jobs
handle out-of-container operations; until then, a shim only fixes the non-container-job case,
which should be explicit in the shim's own scope statement, not discovered by a confused user.

## 3. Native `services:` -> CircleCI secondary-Docker-image translation

**What it would do:** map a workflow's `services:` block onto CircleCI's own secondary Docker
images (the `docker` executor's native multi-image support) instead of Act's own Docker-network
emulation -- this is the one place in the whole bridge where CircleCI has a *better* native
primitive than what Act does, per the research spike's own assessment (near-identical
"extra containers on the job's network, addressable by name" model, zero translation logic
conceptually needed).

**Why it's deferred:** doing this properly means the orb has to know about `services:` *before*
generating the Act invocation and shape the *calling job itself* accordingly (secondary images are
declared on the job, not injected mid-job) -- a job-level design change, not a command-level
parameter. That's a bigger conversation (does it require its own job variant? a new executor
shape? how does it interact with `executor:` overrides?) than this pass's scope.

**What shipped instead:** a cheap, additive `services` parameter on `create-workflow-file` (and
`act`/`jobs/act`) that passes the block straight through into the generated workflow file
verbatim, inheriting Act's own known service-emulation bugs
([nektos/act#1022](https://github.com/nektos/act/issues/1022),
[nektos/act#2607](https://github.com/nektos/act/issues/2607), both **open**). Documented as
inherited, not presented as solved.

**If someone picks this up:** this is the highest-value deferred item precisely because CircleCI
already has the primitive -- it's a design/API-shape question, not a build-a-protocol-server
question like #1/#2 above.

## 4. OIDC token shimming

**What it would do:** let an action that calls `core.getIDToken()` / reads
`ACTIONS_ID_TOKEN_REQUEST_URL` get a token instead of erroring outright (Act does not implement
GitHub's OIDC signer at all today: [nektos/act#2500](https://github.com/nektos/act/issues/2500),
[nektos/act#2262](https://github.com/nektos/act/issues/2262)).

**Why it's deferred:** shimmable at the *protocol* level (CircleCI has its own OIDC issuer and
could serve a CircleCI-signed token in GitHub's env-var contract) but not at the *trust-policy*
level -- the cloud-side IAM trust policy (AWS/Azure/GCP/Vault) has to be reconfigured to trust
CircleCI's issuer and claim shape instead of GitHub's, which is a customer-side change no orb can
paper over. This wasn't raised as urgent for this pass and the customer-side prerequisite means
"flag and defer" is the right call regardless of orb-side effort.

**What shipped instead:** the README's OIDC/`GITHUB_TOKEN` limitations section states this
plainly rather than silently doing nothing with no explanation.

## 5. shfmt verification

This pass added a pinned `mvdan/shfmt:v3.13.1-alpine` CI job (`shfmt-check` in
`.circleci/config.yml`) enforcing `shfmt -i 4 -ci -sr` on every script in `src/scripts/`, and every
script in this repo was verified locally against that exact binary/flag combination before this
branch was committed. This is not deferred -- it's called out here only so a future contributor
knows the gate is real and was actually exercised, not just declared.

## 6. `GITHUB_*` -> `CIRCLE_*` context-variable translation

**What it would do:** map CircleCI's own build-context env vars (`CIRCLE_SHA1`, `CIRCLE_BRANCH`,
`CIRCLE_PROJECT_REPONAME`, etc.) onto the `GITHUB_*` context vars
(`GITHUB_SHA`, `GITHUB_REF`, `GITHUB_REPOSITORY`, `GITHUB_ACTOR`, ...) a wrapped action or its
`env:`/`with:` expressions might expect, the same way a real GitHub Actions runner would populate
them.

**Why it's deferred (for now), not built:** this orb sets zero `GITHUB_*` variables itself --
confirmed by grepping every script and command YAML in `src/` for `GITHUB_`. It doesn't need to:
Act's own runner emulation already populates the common ones (`GITHUB_ACTIONS`, `GITHUB_WORKSPACE`,
`GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_REF`, `GITHUB_ACTOR`, `GITHUB_EVENT_NAME`,
`GITHUB_EVENT_PATH`, ...) itself, derived from the real git checkout this orb hands it (`checkout`
+ `--bind`) and the `actor`/`workflow-event`/event-file parameters already exposed on `act/act`.
Nothing in this repo previously recorded *that this was considered* versus simply never noticed --
this entry closes that silent gap. A caller who needs a `GITHUB_*` var Act doesn't set on its own
(e.g. something derived from a GitHub-specific concept CircleCI has no equivalent of, like
`GITHUB_RUN_ID` semantics tied to GitHub's own run numbering) can still set it explicitly via this
command's `env` parameter today -- no orb change needed for that case either.

**If someone picks this up:** the actual work here isn't building a translation layer, it's an
audit -- diff the full `GITHUB_*` context-variable list
([docs.github.com — variables reference](https://docs.github.com/en/actions/learn-github-actions/variables))
against what Act's runner emulation actually sets (verify by running a probe action that dumps
`env | grep ^GITHUB_` through `act/act` and comparing), and only then decide whether any specific
gap is worth an orb parameter versus just documenting "set it yourself via `env`."

## 7. Skipping the installer round-trip on a full `cache-cli` hit

**What it would do:** when `cache-cli` fully restores the `act` binary and `version` is pinned
(not `"latest"`) with `force-install: false`, skip fetching/checksumming/`sudo`-running the
installer script entirely instead of invoking it and letting it no-op after its own version check.

**Why it's deferred:** the reinstall-skip logic this would need to reimplement --
`check_installed_version()` in nektos/act's own `install.sh` -- already exists, and is exactly the
feature this project's own maintainer wrote and upstreamed in
[nektos/act#2575](https://github.com/nektos/act/pull/2575) (see the supply-chain audit above for
the history). Duplicating that check inside this orb's `install.sh` means re-parsing `act
--version` output and re-implementing "latest"-vs-pinned comparison logic a second time, in a
second place, that can silently drift from upstream's own if either side's version-string handling
changes -- for a modest win (skip one small, already-pinned-and-checksummed script fetch plus one
`sudo bash` invocation that itself does almost nothing on a cache hit). Not worth the duplication
risk for this pass.

**What shipped instead:** nothing extra -- the existing pinned+checksummed fetch (see the
supply-chain section of `install.sh` itself) already keeps the per-job cost small (one small file
fetch, checksum-verified, then a `sudo bash` invocation that itself no-ops quickly once inside
nektos/act's own installer), and `cache-cli` already avoids the actual binary download on a hit.

**If someone picks this up:** the safer version of this optimization is upstream, not here -- e.g.
`check_installed_version()` short-circuiting before even reading its own network-fetch code path
when the binary present matches `-v` faster than it does today -- rather than a second,
orb-side copy of the same check that has to be kept in sync by hand.

## 8. `github-token` parameter: a seam for a future platform-minted token, not a mint

**What shipped:** an additive `github-token` parameter (type `env_var_name`, default
`GITHUB_TOKEN`) on `act`/`jobs/act`/`create-env-var-secret-files`. At its default, behavior is
byte-for-byte identical to before this parameter existed. Pointed at a different CircleCI env var
name, `create-env-var-secret-files.sh` aliases that variable's *value* into the secrets bucket
under the literal key `GITHUB_TOKEN` (and keeps the source variable's own name out of the plaintext
`.env` file), so Act and the wrapped Action still see a plain `GITHUB_TOKEN` with zero interface
change on either side.

**Why the seam exists, not just "because someone might want it":** CircleCI's Sources of Change
team already mints scoped GitHub App installation tokens tied to pipeline-trigger time --
`TokenRestrictions{Scopes, RepositoryIDs}` passed into `CreateAndStoreTokenForPipeline` in
`soc-integrations`. That is materially closer to real GitHub Actions' own per-job `GITHUB_TOKEN`
behavior (auto-scoped, tied to a specific trigger) than the static personal-access-token workaround
this orb's README already documents as a "weaker substitute, not a drop-in one." The only piece
that mechanism doesn't yet do is expose one of those minted tokens into a CircleCI job's
environment under some env var name a config author can reference.

**What was deliberately NOT built in this pass:** any minting logic, any call into
`soc-integrations`, any new CircleCI platform feature. This orb has no way to originate a
pipeline-scoped token itself, and building that is a platform-level project, not an orb change.
This pass only adds the *consumption* side of that future integration -- the aliasing seam -- so
that whenever (if ever) a minted token becomes available as a job env var by some other mechanism,
pointing `github-token` at its name is the entire integration step required on this orb's side.

**If someone picks this up:** the actual work is on the platform side (exposing a
`CreateAndStoreTokenForPipeline`-minted token into a job's environment, and deciding the trust
boundary/scoping UX for who can request one for a given pipeline) -- not here. Once that exists,
this orb needs no further change; `github-token` already does its half of the job.
