# Capabilities

The full detail behind each row of the README's capability table: caching, artifacts, action
outputs, and service containers.

## Caching

This orb caches three independent things, each on and off separately, because each is a genuinely
different artifact with a different cost/benefit tradeoff:

| Dimension | Parameter | Default | What's cached | Cache key |
|---|---|---|---|---|
| The `act` CLI binary itself | `cache-cli` | on | `<bin-dir>/act` | arch + resolved Act version (`"latest"` is resolved to a concrete tag via the GitHub API before being used as a key, so a `"latest"` pin still gets fresh cache hits/misses as new versions ship, rather than sticking to whatever "latest" meant on the first run) |
| Act's downloaded-actions directory | `cache-actions` | on | `~/.cache/act` (the actions/dependencies Act itself fetched) | arch + `cache-key-prefix` + CircleCI project ID + job name |
| The platform Docker image | `cache-images` | **off** | a `docker save`'d tar of the platform image (see `platform`) | arch + `platform` + `cache-key-prefix` |
| Act's own GitHub Actions cache-server storage | `cache-server-enabled` | on | `cache-server-path` (default `~/.cache/actcache`): everything a wrapped `actions/cache@v4`/`setup-*` call saved | arch + `cache-key-prefix` + CircleCI project ID + job name |

`cache-images` defaults to off, and this was measured, not assumed (see the CircleCI Labs
orb-family caching-defaults standard in [ROADMAP.md](ROADMAP.md#10-caching-defaults-standard-measured-2026-08):
default a cache to `true` only where it's measurably faster). A CircleCI cache restore is itself a
network download, so `cache-images` swaps a Docker Hub registry pull for a CircleCI cache pull and
adds `docker save`/`docker load` on top -- it only wins outright when the registry, not the cache
backend, is the bottleneck. Measured on real CircleCI (`catthehacker/ubuntu:act-latest`, ~567MB,
two independent pipeline runs; job numbers 2220-2222 and 2249-2251 on `CircleCI-Labs/act-orb`):

| | Cold registry pull only (`cache-images: false`) | Cold cache-miss (`cache-images: true`): pull + `docker save` + cache upload | Warm cache-hit (`cache-images: true`): cache restore + `docker load` |
|---|---|---|---|
| Run 1 | 13.6s | 34.7s (14.2s + 11.8s + 8.8s) | 16.6s (4.6s + 11.9s) |
| Run 2 | 14.0s | 35.6s (14.6s + 12.2s + 8.9s) | 16.5s (4.7s + 11.8s) |

The number that decides the default is the warm-cache-hit column against the plain-pull column:
across both runs the warm cache-hit path was **18-22% slower** than just pulling the image, because
`docker load` alone (~12s) costs more than the entire registry pull (~14s) did, and the cache
restore itself (~4.6s) is pure additional overhead on top. `cache-images` stays `false` by this
measurement. Turn it on only if your own `platform` image is either unusually large relative to
its `docker load` cost, or the registry it comes from is measurably rate-limiting or throttling you
(e.g. Docker Hub anonymous pulls) -- neither is true for the default `catthehacker/ubuntu:act-latest`
image against Docker Hub as measured above.

All four cache keys share the `cache-key-prefix` parameter (default `v1`) as a common prefix, so
bumping it busts every cache dimension at once if you ever need a clean slate across all of them.

**Upgrade note:** the `cache-actions` key format changed in this release (a stray double dash
before `{{ .Environment.CIRCLE_JOB }}` was fixed to a single dash). Cache keys are literal
strings, not patterns, so this is a one-time, self-healing change: your existing actions cache
under the old key becomes unreachable, `restore_cache` falls through to the unversioned prefix key
(or a cold cache on the very next run), and a fresh cache is saved under the corrected key from
then on. Expect one slower "Restoring cache for Act's Actions..." step after upgrading, not a
caching regression.

### Actions cache: a real `actions/cache@v4` backend, via Act's own cache server

A real `actions/cache@v4` call (or any `setup-*` action with built-in caching) inside a wrapped
action needs a real cache-service backend, or it silently gets Act's own ephemeral,
dies-with-the-container cache instead. **Act already ships its own built-in GitHub Actions cache
server** (`pkg/artifactcache`, on by default since Act v0.2.45). A real, unmodified
`actions/cache@v4` talks to it with zero orb-side protocol translation, verified end to end in
this orb's own CI (`test_act_cache_server_durable_hit_save`/`_restore` in
`.circleci/test-deploy.yml`).

What this orb adds is *persistence*: Act's cache server is ephemeral to one job's container, so
without help its storage dies with the VM exactly like Act's own actions/image caches would.
`cache-server-enabled` (on by default) tells Act where its storage lives (`cache-server-path`,
default `~/.cache/actcache`) and wraps that directory in native `restore_cache`/`save_cache`
calls, the same pattern this orb already uses for `cache-actions`/`cache-images` above.

```yaml
- act/act:
    uses: actions/cache/save@v4
    with: |
      path: node_modules
      key: my-cache-key-v1
- act/act:
    uses: actions/cache/restore@v4
    with: |
      path: node_modules
      key: my-cache-key-v1
```

No extra step is needed before `act/act`: `cache-server-enabled`'s default (`true`) is all the
wiring required, and there is no separate server for you to start yourself.

**The one honest tradeoff:** the cache key this orb saves under covers `cache-server-path` as a
whole directory, not one key per `actions/cache` entry. A change that, on real GitHub Actions,
would invalidate only one specific `actions/cache` key still causes *every* `actions/cache` entry
saved under this job's cache-server storage to be re-saved together the next time this job runs.
If your workflow saves several logically distinct caches in one job and only one of them should
ever be busted independently, that granularity isn't available here: the directory-level key is
the unit of invalidation.

**What happens if the cache server isn't reachable at all** (e.g. `cache-server-enabled: false`,
which passes `--no-cache-server`): `actions/cache`'s own client (`actions/toolkit`) treats a save
or restore failure as a **warning, not a build failure**. The step logs it and the job continues
cold, exactly as if nothing had been cached. Verified directly against `actions/toolkit`'s own
source, not assumed.

**Set `cache-server-addr` explicitly if the default auto-detection picks the wrong interface.**
Act auto-detects an outbound IP to advertise to the wrapped action's container. On a real CircleCI
`machine` executor (a real local Docker daemon, the same topology this orb already recommends for
anything needing `--bind`; see [Defaults that deviate from Act](ARCHITECTURE.md#defaults-that-deviate-from-act))
this is expected to work and is exercised for real in this orb's own CI. On a machine with
multiple or unusual network interfaces (observed: a developer laptop with an active VPN adapter),
auto-detection can pick the wrong one; set `cache-server-addr` explicitly (and consider
`--network host` via `additional-act-flags`) if a cache step silently misses when you'd expect a
hit.

## Artifacts

`actions/upload-artifact`/`download-artifact@v4` work for jobs that don't use `container:`, via a
much smaller change than a from-scratch shim would have been. Investigating this surfaced that
**Act already ships a complete, working implementation of GitHub's real artifact-v4 protocol**
(`pkg/artifacts` in `nektos/act`'s own source: the exact Twirp `ArtifactService.{CreateArtifact,
UploadArtifact,FinalizeArtifact,ListArtifacts,GetSignedArtifactURL,DownloadArtifact}` routes,
storing to local disk). It just never starts that server unless you pass
`--artifact-server-path`, a flag this orb never exposed. `run-act` now has
`artifact-server-path`/`artifact-server-addr`/`artifact-server-port` parameters (all empty/off by
default, so this is zero behavior change unless you set them) that pass straight through to Act's
own CLI flags of the same name. Once Act's runner sees `ArtifactServerPath != ""`, it automatically
injects `ACTIONS_RUNTIME_URL`/`ACTIONS_RESULTS_URL`/`ACTIONS_RUNTIME_TOKEN` into the wrapped
action's container itself (verified directly in `pkg/runner/run_context.go`); no orb wiring is
needed beyond the one flag.

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
because the job's container image has no Node in it). That's an upstream Act limitation no
orb-side flag can work around, exactly as anticipated when this was originally scoped as deferred
(see [`ROADMAP.md`](ROADMAP.md) item 2).

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

This is opt-in and defaults to off (`outputs: ""`), so existing jobs that don't set it see no
behavior change at all. It works by giving the generated action step a stable `id:` and appending
a second, same-job step that resolves each `${{ steps.<id>.outputs.<key> }}` expression and writes
it to a handoff file inside the (bound) checkout directory, which a `collect-outputs` step then
reads back on the CircleCI host. It does **not** read Act's `$GITHUB_OUTPUT` file directly: that
file lives inside Act's own per-step temp area, which isn't shared with the CircleCI host even
with `bind` enabled, so `steps.*.outputs` expression evaluation (which Act supports natively) is
the mechanism that actually works. This means `outputs` only works when this orb is generating the
workflow file (`skip-create-workflow-file` unset) and `bind` stays enabled (the default). If you
bring your own workflow file, you can still reach `$BASH_ENV` yourself using the same pattern this
orb generates.

Violating either requirement doesn't error; it fails silently, so know the actual behavior:

- **`bind: false` with `outputs` set:** the container's handoff-file write never reaches the
  CircleCI host, so `collect-outputs` finds nothing and no-ops. This orb logs a warning to that
  effect; no output is exported and no later step's use of the variable will resolve.
- **`skip-create-workflow-file: true` with `outputs` set:** nothing generates the output-capture
  step in your hand-written workflow, so Act never (re)writes the handoff file on this call. Every
  `act/act`/`run-act` invocation that requests `outputs` removes any handoff file left over from
  an *earlier* call in the same job/`directory` before it runs, specifically so this case can
  never silently re-export a previous call's stale value, but it still can't produce a *fresh*
  value from a workflow file that doesn't write one, since Act's own `$GITHUB_OUTPUT` per-step
  temp area isn't shared with the host even with `bind` on. Add the same "collect outputs for
  CircleCI" step this orb generates (see the source of `create-workflow-file.sh`) to your own
  workflow file if you need `outputs` alongside `skip-create-workflow-file`.

Output keys containing characters that aren't legal in a shell variable name (GitHub allows `-` in
output ids; bash does not) are exported under a sanitized name (dashes become underscores) with a
loud warning in the step's log. The action's own output name is unaffected; only the CircleCI-side
variable name differs.

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

This is a **verbatim passthrough** into the generated workflow file. Act emulates `services:`
itself via its own Docker networking, which inherits Act's own known service-emulation issues
([nektos/act#1022](https://github.com/nektos/act/issues/1022),
[nektos/act#2607](https://github.com/nektos/act/issues/2607), both open at the time of writing).
A native translation to a CircleCI secondary Docker image (CircleCI's own equivalent primitive, no
Act emulation needed) is a larger, job-level design change; see [`ROADMAP.md`](ROADMAP.md) item 3.
