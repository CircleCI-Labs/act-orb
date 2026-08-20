# Act Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/act-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/act-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/act.svg)](https://circleci.com/developer/orbs/orb/cci-labs/act) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/act-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

The Act Orb runs a real GitHub Action inside a CircleCI job, using the open-source
[Act CLI](https://nektosact.com/) so `uses:`/`with:`/`env:` behave exactly as they would on
GitHub. It exists so a config author can borrow a GitHub Action (caching, artifacts, and service
containers included) without hand-translating it into native CircleCI steps first.

This orb would not be possible without the contributors who have worked on the
[Act CLI](https://nektosact.com/).

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ✅ Used by real CircleCI customers
-   ❌ **not** officially supported by CircleCI support

---

## Table of contents

- [Quick Start](#quick-start)
- [Capabilities](#capabilities)
- [Limits](#limits)
- [Resources](#resources)
- [How to Contribute](#how-to-contribute)
- [How to Publish An Update](#how-to-publish-an-update)

**Deep dives**, split out of this README to keep it short:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how a call becomes a running action, the command pipeline, the mermaid diagram, and the defaults this orb overrides.
- [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md): a fuller walkthrough, covering executor choices, token setup, and the runnable examples.
- [docs/CAPABILITIES.md](docs/CAPABILITIES.md): caching, artifacts, action outputs, and service containers, in full.
- [docs/COMMANDS.md](docs/COMMANDS.md): every command/job and every parameter.
- [docs/MIGRATING.md](docs/MIGRATING.md): mapping GitHub Actions concepts onto CircleCI ones, with the reasoning.
- [docs/LIMITS.md](docs/LIMITS.md): the honest limits, gotchas, and security notes.
- [docs/ROADMAP.md](docs/ROADMAP.md): larger items deliberately scoped out, with the reasoning recorded.

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

That's it for the common case: `act/act` is a full job (checkout, install Act, generate a
one-step workflow file from `uses`/`with`/`env`, run it, cache what's cacheable). Use the `act/act`
**command** instead of the job if you need to run it inside your own executor/job (see
[Getting started](docs/GETTING-STARTED.md)).

## Capabilities

| Capability | Command(s) | Detail |
|---|---|---|
| Run one GitHub Action as a step | `act` (job or command) | [Quick Start](#quick-start) above |
| Cache the Act CLI, its actions dir, and platform images | `cache-cli` / `cache-actions` / `cache-images` | [docs/CAPABILITIES.md#caching](docs/CAPABILITIES.md#caching) |
| A real `actions/cache@v4` backend, via Act's own built-in cache server | `cache-server-*` params on `act`/`run-act` | [docs/CAPABILITIES.md#caching](docs/CAPABILITIES.md#caching) |
| `actions/upload-artifact`/`download-artifact@v4` | `artifact-server-path` param on `act`/`run-act` | [docs/CAPABILITIES.md#artifacts](docs/CAPABILITIES.md#artifacts) |
| Surface an action's own outputs to later native steps | `outputs` param on `act`/`run-act` | [docs/CAPABILITIES.md#capturing-action-outputs](docs/CAPABILITIES.md#capturing-action-outputs) |
| Pass a GitHub `services:` block straight through | `services` param on `act`/`run-act` | [docs/CAPABILITIES.md#service-containers](docs/CAPABILITIES.md#service-containers) |

Every command, job, and parameter, one line each: [docs/COMMANDS.md](docs/COMMANDS.md). How the
pieces fit together and why: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Mapping a GitHub
Actions workflow onto CircleCI concept by concept: [docs/MIGRATING.md](docs/MIGRATING.md).

A whole-workflow compiler and an OIDC-token issuance shim were both built in earlier passes and
are deferred to the `feature/translation-layer` branch for this orb's first public release; see
[docs/ROADMAP.md](docs/ROADMAP.md) items 4 and 9 for why and what's there.

## Limits

The full detail, with issue links and reasoning, is in [docs/LIMITS.md](docs/LIMITS.md). In brief:

- **`actions/upload-artifact`/`download-artifact@v4` fail outright inside `container:`-scoped jobs** ([nektos/act#2508](https://github.com/nektos/act/issues/2508), open); works fine outside `container:`.
- **No OIDC token issuance yet.** A working shim exists on `feature/translation-layer`, deferred rather than shipped in this orb's first public version.
- **Non-Linux `runs-on` targets aren't really emulated**, and reusable workflows (`workflow_call`) are poorly supported by Act itself; both are long-standing upstream Act limitations.
- **`with`/`env`/`services` are trusted, unescaped input**, and the env/secret/var files this orb generates for Act are opt-in secret, not opt-out. Review what your job's environment contains before relying on the defaults.

## Resources

- [CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/act): the official registry page of this orb for all versions, executors, commands, and jobs described.
- [CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration): docs for using, creating, and publishing CircleCI Orbs.
- [`docs/ROADMAP.md`](docs/ROADMAP.md): larger items deliberately scoped out of past passes (or deferred to `feature/translation-layer`), with the reasoning recorded.
- Runnable usage examples live under [`src/examples/`](src/examples/); see [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) for a guided tour.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/act-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/act-orb/pulls) against this repository!

Every script in `src/scripts/` is enforced clean by `shellcheck` (`severity: error`) and `shfmt
-i 4 -ci -sr` in CI.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's
`<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb
that can still pass `circleci orb validate`, a false green with no other symptom. Run
`scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack`
workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a
job parameter literally named `pre-steps` or `post-steps` outright; this only surfaces under
`orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it.
If you're adding a new job parameter, don't pick either name.

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
