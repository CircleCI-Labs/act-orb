# Mapping GitHub Actions to CircleCI

A concept-by-concept translation, with the reasoning behind each mapping, not just a
name-to-name table. If you already think in GitHub Actions, this is the fastest way to start
thinking in CircleCI without re-deriving it construct by construct.

| GitHub Actions concept | CircleCI concept | Why this mapping, not a different one |
|---|---|---|
| **Job** | **Job** | A like-for-like unit of one machine/container running a sequence of steps to completion. |
| **Step** | **Step** | Also a direct, like-for-like mapping: a step is a step. The interesting translation isn't the container concept, it's what a *specific kind* of step (`uses:`) becomes; see the next row. |
| **`uses:` (an action)** | **One `act/act` invocation, wrapping one `run:` step** | GitHub's own runner has native, first-class support for "resolve and execute this action." CircleCI's `run:` step is a shell command; there's no native "run a GitHub Action" primitive to map onto, so this orb builds one: it generates a one-step GitHub workflow file naming just that action, then runs it for real, inside Act's own container, via a `run:` step that invokes the `act` CLI. The action's own logic is never reimplemented or approximated. Act executes the real, unmodified action, in its own real (or emulated) runtime; this orb's job stops at getting Act invoked correctly. |
| **`GITHUB_OUTPUT`** (the file an action or `run:` step writes `key=value` lines to) | **`$BASH_ENV`** | GitHub's runner watches a well-known file path and threads its contents into `steps.<id>.outputs.*` for the rest of the *workflow run* to reference via expressions. CircleCI has no equivalent expression-evaluation layer over step outputs: `$BASH_ENV` is CircleCI's own mechanism for "a value computed in one step should be visible as a shell variable in later steps of the *same job*." This orb's `outputs`/`collect-outputs` bridges the two: it lets Act's own expression evaluation (`${{ steps.<id>.outputs.<key> }}`) resolve the value inside the container, writes it to a handoff file, then a later step exports it into `$BASH_ENV` for the rest of the CircleCI job. See [Capturing action outputs](CAPABILITIES.md#capturing-action-outputs) for the full mechanism and its two documented failure modes. |
| **`actions/cache@v4`** | Native `restore_cache`/`save_cache` wrapped around **Act's own built-in cache server** | Act already ships a complete, working implementation of GitHub's real cache-service protocol (`pkg/artifactcache`). This orb only had to expose the flags that let it point that server at a stable, known path, then persist that path across jobs the ordinary CircleCI way. See [Caching](CAPABILITIES.md#caching). |
| **`actions/upload-artifact`/`download-artifact`** | **`store_artifacts`**, via Act's own built-in artifact server | CircleCI's artifact concept (files attached to a job, browsable after the fact) is close enough to GitHub's that no protocol bridge was needed here. Act already ships a complete, working implementation of GitHub's real artifact-v4 protocol; this orb only had to expose the flag that turns it on and point a native `store_artifacts` step at the same directory. See [Artifacts](CAPABILITIES.md#artifacts). |

A whole-workflow compiler (mapping `needs:`/`strategy.matrix`/`runs-on:` concepts) and an OIDC
bridge (`core.getIDToken()`) were both built in earlier passes and are currently deferred to the
`feature/translation-layer` branch; see [`ROADMAP.md`](ROADMAP.md) items 4 and 9.
