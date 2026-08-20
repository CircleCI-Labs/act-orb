# Limits, gotchas, and security notes

The honest boundaries of what this orb does, and what to know before trusting it with secrets.

## What does not work

- **`actions/upload-artifact`/`download-artifact` now work for non-`container:`-scoped jobs.** See
  [Artifacts](CAPABILITIES.md#artifacts): Act already ships a complete artifact-v4 server, this
  orb just exposes the one flag (`artifact-server-path`) that turns it on. `upload-artifact@v4`
  still fails outright inside `container:`-scoped jobs
  ([nektos/act#2508](https://github.com/nektos/act/issues/2508), open) because the job's
  container image has no Node in it. On real GitHub Actions this step runs at the runner level,
  outside the job container, specifically to avoid that; no shim can patch around an upstream Act
  limitation. See [`ROADMAP.md`](ROADMAP.md) item 2.
- **No OIDC token issuance.** Act does not implement GitHub's OIDC signer
  ([nektos/act#2500](https://github.com/nektos/act/issues/2500),
  [nektos/act#2262](https://github.com/nektos/act/issues/2262), both open); an action calling
  `core.getIDToken()` will error unless you pre-populate a fake value yourself. A working shim
  for this exists on the `feature/translation-layer` branch, deferred rather than shipped in this
  orb's first public version; see [`ROADMAP.md`](ROADMAP.md) item 4.
- **Non-Linux `runs-on` targets aren't really emulated.** `runs-on: macos-*`/`windows-*` either
  silently runs on the wrong platform image or fails; a long-standing Act limitation
  ([nektos/act#97](https://github.com/nektos/act/issues/97), open since 2020), not something this
  orb can fix.
- **Reusable workflows (`workflow_call`) are poorly supported by Act itself.** Matrix and
  reusable-workflow combinations, nested `if:` conditions, and related issues have several
  long-standing open reports upstream
  ([nektos/act#1114](https://github.com/nektos/act/issues/1114),
  [nektos/act#2003](https://github.com/nektos/act/issues/2003)).
- **GitHub-native security-tab integrations have no destination.** `github/codeql-action` and any
  action whose entire purpose is uploading into GitHub's own Code Scanning, Dependabot, or Secret
  Scanning UI cannot work off-GitHub. There is no equivalent surface to upload into, full stop.

See [Scope](ARCHITECTURE.md#scope-one-action-per-jobcommand-invocation) for the one-action-per-call
boundary itself; it isn't repeated here since it isn't a limitation so much as this orb's own
design boundary. A larger-scoped, whole-workflow compiler that lifts this boundary was built in an
earlier pass and is currently deferred to the `feature/translation-layer` branch; see
[`ROADMAP.md`](ROADMAP.md) item 9.

## Security notes

**`with`/`env`/`services` are trusted, unescaped input.** This orb builds the generated workflow
file by embedding these parameters' raw string values directly into generated YAML (indented to
fit, but not otherwise escaped). This matches how `config.yml` itself already trusts a job's own
parameter values, but it's worth stating plainly that `services` extends the same pattern to a
third parameter: if any of `with`/`env`/`services` are ever populated from a source you don't
control (e.g. a CircleCI pipeline parameter fed by a webhook payload or a PR title), a crafted
value could break out of its intended YAML block and inject arbitrary keys/steps into the
generated workflow. Treat these the same as any other config-author-trusted value: don't wire
untrusted external input into them directly.

**`GITHUB_TOKEN` is a weaker substitute, not a drop-in one.** Real GitHub Actions' `GITHUB_TOKEN`
is a per-job GitHub App installation token, auto-scoped to exactly one repository and
auto-expiring when the job ends. There is no CircleCI primitive that mints anything like it. This
orb (and its `avoid_token_error` example) can only wire in a personal access token you create and
store as a CircleCI project/context env var, which is broader in scope than the job needs, doesn't
auto-expire, isn't automatically narrowed by a workflow's own `permissions:` block, and must be
rotated by you. Scope it to the minimum you actually need and rotate it on a schedule.

**The `github-token` parameter is a seam, not a mint.** By default it names `GITHUB_TOKEN`,
identical behavior to today. Point it at a *different* CircleCI env var name (e.g. one populated
by a future pipeline-scoped token-minting step) and this orb aliases that variable's value into
the secrets bucket under the literal key `GITHUB_TOKEN` for you, and keeps the source variable's
own name out of the plaintext `.env` file automatically, so Act and the wrapped Action still see a
plain `GITHUB_TOKEN`, with zero interface change on either side. This orb implements only the
aliasing; it mints nothing itself. CircleCI's Sources of Change team already mints scoped GitHub
App installation tokens tied to pipeline-trigger time (`TokenRestrictions{Scopes, RepositoryIDs}`,
`CreateAndStoreTokenForPipeline` in `soc-integrations`); the only missing piece to get much closer
to real GitHub Actions' own per-job token behavior is exposing one of those into a job's
environment under some other env var name and pointing `github-token` at it. See
[`ROADMAP.md`](ROADMAP.md) item 8 for the fuller rationale.

**The env/secret/var files this orb generates for Act are opt-in secret, not opt-out.** By default
only `GITHUB_TOKEN` is treated as sensitive (the `secrets` parameter); every other environment
variable present in the job is written to the **plaintext** `.env` file Act reads from, unless
you explicitly list it in `secrets` or `variables`. Review what your job's environment actually
contains before running this orb, especially in a context with broad env access. Multi-line
values (SSH keys, JSON service-account credentials) are handled without leaking fragments into the
plaintext file even when correctly named as a secret, but are still written unquoted: Act's own
dotenv-style parser may not round-trip an embedded newline correctly. Avoid multi-line
secrets/vars, or pre-encode them (e.g. base64), if you must use one.

**Act's own installer script is fetched from a pinned commit and checksum-verified before it's
ever executed**, rather than piping a mutable branch ref straight into `sudo bash`. See the
comment block at the top of `src/scripts/install.sh` for the maintenance process if Act changes
that script upstream. The release *binary* Act's installer downloads is checksum-verified by Act's
own installer already; this orb doesn't duplicate that, only the installer-script fetch itself.
This orb implements action execution by installing and shelling out to
[nektos/act](https://github.com/nektos/act)'s own MIT-licensed CLI locally; it does not read,
copy, or fork that CLI's source.
