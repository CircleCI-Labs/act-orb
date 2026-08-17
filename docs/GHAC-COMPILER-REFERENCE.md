# GitHub Actions workflow compiler: construct-by-construct reference

This is the complete supported/rejected/delegated table behind the README's "GitHub Actions
workflow compiler" section. Read that section first for how the compiler is wired into a
pipeline; come here for exactly what happens to a specific GitHub Actions construct when it
compiles.

"Delegated" means Act resolves that construct itself, from the real, unmodified workflow file --
correctly, because it's Act's own job to do so, not something this compiler reimplements.
"Rejected by name" means the compiler fails loudly at compile time, quoting the exact unsupported
construct in the error -- nothing here is silently ignored.

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

See `tools/ghac/README.md` for the full design writeup and how the prototype's real-CLI, real-`act`
validation was done.
