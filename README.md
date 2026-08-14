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

**`GITHUB_TOKEN` is a weaker substitute, not a drop-in one.** Real GitHub Actions' `GITHUB_TOKEN`
is a per-job GitHub App installation token, auto-scoped to exactly one repository and
auto-expiring when the job ends. There is no CircleCI primitive that mints anything like it. This
orb (and its `avoid_token_error` example) can only wire in a personal access token you create and
store as a CircleCI project/context env var -- which is broader in scope than the job needs, does
not auto-expire, is not automatically narrowed by a workflow's own `permissions:` block, and must
be rotated by you. Scope it to the minimum you actually need and rotate it on a schedule.

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

- **`actions/cache` (and any `setup-*` action with built-in caching) does not persist across
  runs.** Act's own cache server is ephemeral and local-disk-only; it is not backed by this orb's
  `cache-actions`/`cache-images` commands, which only cache *Act's own* state (the actions/images
  it downloaded), not the workflow's own cache calls. See `docs/ROADMAP.md` item 1.
- **`actions/upload-artifact`/`download-artifact` do not land in CircleCI's artifacts UI**, and
  `upload-artifact@v4` fails outright inside `container:`-scoped jobs
  ([nektos/act#2508](https://github.com/nektos/act/issues/2508), open) because the job's
  container image has no Node in it -- on real GitHub Actions this step runs at the runner level,
  outside the job container, specifically to avoid that. See `docs/ROADMAP.md` item 2.
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
  file and pass it via `skip-create-workflow-file: true` (see [Examples](#examples)).

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