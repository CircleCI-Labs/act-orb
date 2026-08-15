# ghac — GitHub Actions workflow → CircleCI config compiler

This directory vendors the source of `ghac`, the compiler that backs the
orb's `act/install-ghac`, `act/gha-compile`, and `act/gha-render-job`
commands (see `../src/commands/`).

## Provenance

Copied verbatim (unmodified) from the working prototype at
`gha-capability-spikes/workflow-compiler`, commit `a8df007` ("Tidy and land
four ecosystem-bridge GHA capability spikes"). That repo's own README has
the full design writeup, the fixture-by-fixture proof against the real
CircleCI CLI, and the honest limits table this orb's README section
(see the top-level `README.md`, "GitHub Actions workflow compiler") is a
condensed version of.

## Why source AND a prebuilt binary are both committed

`ghac` needs to run inside a CircleCI job with no control over what's
preinstalled beyond a generic `cimg/base`/`ubuntu` image — including inside
*every single compiled job*, not just once in the setup job (see the main
README section for why: a `setup:true` workflow does not share a workspace
with the pipeline it continues into). A network-fetched interpreter
(`pip install`/`npm install` on every job, forever) or a `go build` on every
job (needing a Go toolchain in every executor) were both rejected for that
reason — see the main README's packaging rationale.

Instead: a static binary, prebuilt here and fetched via a pinned-commit,
checksum-verified `curl` (`src/scripts/install-ghac.sh`), the exact same
supply-chain pattern this orb's own `install.sh` already uses for the
`act` binary itself. The source lives here too so the binary is
reproducible and auditable, not a mystery blob — see `build.sh`.

## Rebuilding

```
cd tools/ghac
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o ../../dist/ghac/ghac_linux_amd64 ./cmd/ghac
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o ../../dist/ghac/ghac_linux_arm64 ./cmd/ghac
```

or just run `./build.sh`. After rebuilding, `src/scripts/install-ghac.sh`'s
pinned `GHAC_*_SHA256` values must be updated to match (the script verifies
the fetched bytes against them and refuses to run a mismatch), and the
`GHAC_PINNED_COMMIT` must be bumped to a commit that has actually been
pushed and contains the new binaries at `dist/ghac/` — see that script's
own header comment.

## Known interim limitation: distribution via pinned commit, not a release

`nektos/act` (and every other upstream binary this orb fetches) ships real
GitHub Releases; `install-ghac.sh` instead fetches
`dist/ghac/ghac_linux_<arch>` from a pinned **commit** of this repo via
`raw.githubusercontent.com`, because this branch's own working agreement
was "no tags, no releases, no production publish." Once this lands on
`main` (or gets its own tagged release), the honest next step is to move
`install-ghac.sh` to fetch a real release asset instead — a pinned commit
on a public repo is a legitimate, working distribution mechanism (this is
still a checksum-verified, immutable fetch) but a tagged release is the
more conventional and discoverable place to keep it. Tracked, not silently
left as the permanent design.

## Test coverage

`go test ./internal/compile/...` (this vendored copy's own unit tests) and
`../test/gha-compile-fixture/` (the orb-level integration test wired into
`.circleci/test-deploy.yml`) both exercise this code — see the main
README section for current pass/fail state.
