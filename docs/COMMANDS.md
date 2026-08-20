# Command and job reference

Every command and job this orb ships, one line each. "Calls" means the aggregate composes that
command internally with no extra wiring at your call site; see
[Reach for the granular commands instead](#reach-for-the-granular-commands-instead-of-act-when)
below for when to call one of these directly instead of the aggregate.

| Name | Kind | What it does |
|---|---|---|
| `act` | command, job | The aggregate most users want (see the README's Quick Start): checkout, install, create-env-var-secret-files, create-workflow-file, run-act, in order. The job also picks the executor; the command runs inside whatever job/executor you already have. |
| `install` | command | Resolves and installs the Act CLI. Calls `restore-cli`/`cache-cli` itself when `cache-cli` is true (the default). |
| `restore-cli` | command | Restores the cached Act binary (arch + resolved version key: `"latest"` is resolved to a concrete tag first, see [Caching](CAPABILITIES.md#caching)). |
| `cache-cli` | command | Saves the Act binary to cache after a successful install. |
| `create-env-var-secret-files` | command | Snapshots the job's entire environment (`env -0`) into `.env`/`.secrets`/`.vars`, splitting by the `secrets`/`variables` allow-lists and the `github-token` seam. |
| `create-workflow-file` | command | Generates a one-action GitHub workflow YAML file from `uses`/`with`/`env`/`services`/`outputs`. Skipped entirely when you supply your own workflow file (`skip-create-workflow-file: true`). Its own parameter is named `action`, not `uses`; `act`/`act` (job/command) map `uses` onto it for you. |
| `run-act` | command | Restores/saves the actions, Docker-image, and Act-cache-server caches (`restore-actions`/`restore-image`/`restore-actcache` before, `cache-actions`/`cache-image`/`cache-actcache` after) around the actual `act` CLI invocation, then runs `collect-outputs` if `outputs` is set. The lowest-level command that actually invokes `act`; see the README's Quick Start note on when to call this instead of `act`. |
| `restore-actions` | command | Restores Act's downloaded-actions cache (`~/.cache/act`). |
| `cache-actions` | command | Saves Act's downloaded-actions cache after a run. |
| `restore-image` | command | Restores a cached, `docker save`'d platform image tar (only meaningful with `cache-images: true`). |
| `cache-image` | command | Saves the platform image tar to cache after a run (only meaningful with `cache-images: true`). |
| `restore-actcache` | command | Restores Act's own built-in GitHub Actions cache-server storage directory (only meaningful with `cache-server-enabled: true`, the default); see [Caching](CAPABILITIES.md#caching). |
| `cache-actcache` | command | Saves Act's own cache-server storage directory after a run (only meaningful with `cache-server-enabled: true`). |
| `collect-outputs` | command | Reads the action-output handoff file `run-act` produced and exports each value, verbatim by key name, into `$BASH_ENV`. Safe to call even if nothing was produced; see [Capturing action outputs](CAPABILITIES.md#capturing-action-outputs). |

## `act` (command and job) parameters

The full parameter surface. Every one of these is also exposed, under the same name, on the
granular commands that actually consume it (`install`, `create-env-var-secret-files`,
`create-workflow-file`, `run-act`); see each command's own description on the
[Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/act) for the
always-current, exhaustive list if this table and that page ever drift.

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `executor` *(job only)* | executor | `default` | Which executor runs Act; see [Defaults that deviate from Act](ARCHITECTURE.md#defaults-that-deviate-from-act) for why `machine`, not `docker`, is this orb's own default shape. |
| `checkout` | boolean | `true` | Check out the project first. |
| `uses` | string | `""` | The action to run (e.g. `actions/checkout@v2`). Alias of `id`; `uses` wins if both are set. |
| `id` | string | `""` | Family-consistent alias of `uses` (matches the sibling ecosystem-bridge orbs' vocabulary). |
| `with` | string | `""` | Key-value `with:` block for the action. Alias of `inputs`; `with` wins if both are set. |
| `inputs` | string | `""` | Family-consistent alias of `with`. |
| `env` | string | `""` | Key-value `env:` block for the action's step. |
| `services` | string | `""` | Verbatim `services:` block, passed straight through to Act with no translation; see [Service containers](CAPABILITIES.md#service-containers). |
| `outputs` | string | `""` | Comma-separated action output keys to surface into `$BASH_ENV`; see [Capturing action outputs](CAPABILITIES.md#capturing-action-outputs). Empty (default): zero behavior change. |
| `outputs-file` | string | `.act-orb-outputs.env` | Handoff filename (relative to checkout root) used to carry outputs out of Act's container. |
| `workflow-file` | string | `/tmp/workflow.yml` | Where the generated (or your own) workflow file lives. |
| `skip-create-workflow-file` | boolean | `false` | Skip generation; use your own workflow file at `workflow-file` instead (see [`passing_workflow_file.yml`](../src/examples/passing_workflow_file.yml)). |
| `workflow-name` / `workflow-event` / `job-name` / `runs-on-image` | string | `circleci` / `push` / `action` / `ubuntu-latest` | Cosmetic fields of the generated one-job workflow file. |
| `platform` | string | `ubuntu-latest=catthehacker/ubuntu:act-latest` | Act's `--platform` mapping (`runs-on:` value=image). |
| `github-token` | env_var_name | `GITHUB_TOKEN` | Which CircleCI env var names the GitHub token Act/the action should see; a seam, not a mint. See [Security notes](LIMITS.md#security-notes). |
| `secrets` | string | `GITHUB_TOKEN` | Comma-separated env vars written to the secrets bucket, not the plaintext `.env` file. |
| `variables` | string | `""` | Comma-separated env vars exposed to the action as `${{ vars.* }}`. |
| `env-file` / `secret-file` / `var-file` / `event-file` / `input-file` | string | `/tmp/act.env` / `/tmp/act.secrets` / `/tmp/act.vars` / `/tmp/act.event` / `.input` | Paths to the generated env/secret/var/event/input files Act reads. |
| `actor` | string | `nektos/act` | User that triggered the simulated event. |
| `bind` | boolean | `true` | Bind-mount (not copy) the working directory into Act's container. **Deviates from Act's own default (`false`)**; see [Defaults that deviate from Act](ARCHITECTURE.md#defaults-that-deviate-from-act). Required for `outputs`. |
| `verbose` | boolean | `false` | Detailed Act logging. |
| `detect-event` | boolean | `true` | Auto-detect the workflow's event type. **Deviates from Act's own default (`false`).** |
| `directory` | string | `.` | Working directory for the workflow. |
| `action-offline-mode` | boolean | `true` | Run without fetching actions from remote sources (pairs with `cache-actions`). **Deviates from Act's own default (`false`).** |
| `defaultbranch` | string | `main` | Default branch Act assumes. |
| `job` | string | `""` | Run only this job ID from the workflow file. |
| `pull` | boolean | `false` (`true` on `run-act` standalone) | Force-pull Docker images. **Deviates from Act's own default (`true`)** at the `act`/job layer only; see the table in [Defaults that deviate from Act](ARCHITECTURE.md#defaults-that-deviate-from-act). |
| `rebuild` | boolean | `false` (`true` on `run-act` standalone) | Rebuild local Docker images. Same deviation pattern as `pull`. |
| `remote-name` | string | `origin` | Git remote name used to resolve the repo URL. |
| `reuse` | boolean | `true` | Don't remove the container after a successful run. **Deviates from Act's own default (`false`).** |
| `additional-act-flags` | string | `""` | Extra flags passed verbatim to the `act` CLI (word-split, unlike every other parameter here). |
| `artifact-server-path` / `artifact-server-addr` / `artifact-server-port` | string | `""` / `""` / `""` | Turn on and configure Act's own built-in artifact-v4 server; see [Artifacts](CAPABILITIES.md#artifacts). Empty is a no-op. |
| `cache-server-enabled` | boolean | `true` | Persist Act's own built-in GitHub Actions cache server storage across jobs (`true`, the default), or disable Act's cache server entirely with `--no-cache-server` (`false`); see [Caching](CAPABILITIES.md#caching). |
| `cache-server-path` / `cache-server-addr` / `cache-server-port` | string | `~/.cache/actcache` / `""` / `""` | Configure Act's own built-in cache server; see [Caching](CAPABILITIES.md#caching). Only meaningful when `cache-server-enabled` is true. |
| `cache-cli` / `cache-actions` / `cache-images` | boolean | `true` / `true` / `false` | Per-dimension cache toggles; see [Caching](CAPABILITIES.md#caching). |
| `cache-key-prefix` | string | `v1` | Common prefix across all cache-key dimensions. |
| `force-install` | boolean | `false` | Reinstall Act even if a cached/existing binary is present. |
| `version` | string | `latest` | Act CLI version to install. |
| `debug` | boolean | `false` | Debug logging for the install step itself. |
| `bin-dir` | string | `/home/circleci/bin` | Where the Act binary is installed. |
| `skip-install` | boolean | `false` | Skip installing Act entirely (assume it's already on `PATH`). |
| `skip-create-env-var-secret-files` | boolean | `false` | Skip generating the env/secret/var files. |
| `step-name` *(command only)* | string | `Run Act` | Name of the step that actually invokes `act`. Not exposed on the `act` job. |

## Reach for the granular commands instead of `act` when...

- **You're chaining multiple actions in one job.** Each layer reads/writes plain files with no
  shared state to skip: give each `run-act` call its own `workflow-file`/`env-file`, and call
  `install` once, then `create-env-var-secret-files` -> `create-workflow-file` -> `run-act` again
  per action.
- **You already have a rendered workflow file** (e.g.
  [`passing_workflow_file.yml`](../src/examples/passing_workflow_file.yml)): skip straight to
  `run-act` with `workflow-file` pointed at it, and `skip-create-workflow-file` is irrelevant since
  you never call `create-workflow-file` at all.
- **You want native steps interleaved between stages**, e.g. inspecting the generated
  `.env`/`.secrets` files between `create-env-var-secret-files` and `run-act`.

## Worked example: composing the granular commands by hand

```yaml
version: 2.1
orbs:
  act: circleci/act@x.y.z
jobs:
  two_actions_one_job:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup_remote_docker
      - act/install
      - act/create-env-var-secret-files
      - act/create-workflow-file:
          workflow-file: /tmp/first.yml
          action: actions/hello-world-javascript-action@v1.1
          with: |
            who-to-greet: "Mona the Octocat"
      - act/run-act:
          workflow-file: /tmp/first.yml
      - act/create-workflow-file:
          workflow-file: /tmp/second.yml
          action: actions/setup-node@v4
          with: |
            node-version: "20"
      - act/run-act:
          workflow-file: /tmp/second.yml
      - run: echo "both actions ran in one job, sharing one Act install/cache"
workflows:
  main:
    jobs:
      - two_actions_one_job
```
