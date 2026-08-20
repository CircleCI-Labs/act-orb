# Getting started

A fuller walkthrough beyond the README's Quick Start: executor choices, token setup, and the
runnable examples under [`src/examples/`](../src/examples/).

## Executor choices

The `act` job defaults to a `machine` executor (a real local Docker daemon). That's the topology
this orb's own defaults assume: it's what makes `--bind` and Act's own cache server's address
auto-detection work without extra configuration (see
[Defaults that deviate from Act](ARCHITECTURE.md#defaults-that-deviate-from-act)).

If you'd rather use the `docker` executor, enable `setup_remote_docker` first: see
[`run_on_remote_docker.yml`](../src/examples/run_on_remote_docker.yml). You can also override the
machine executor's own image, resource class, or Docker layer caching directly: see
[`override_executor.yml`](../src/examples/override_executor.yml).

## Avoid GitHub token errors

Some actions read `GITHUB_TOKEN` even when they don't strictly need GitHub API access. Point
`github-token` (or just set `GITHUB_TOKEN` directly) at a CircleCI project or context env var
holding a personal access token:

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

See [Security notes](LIMITS.md#security-notes) for why this token is a weaker substitute for
GitHub's own auto-scoped, auto-expiring `GITHUB_TOKEN`, not a drop-in replacement.

## More examples

Every file under [`src/examples/`](../src/examples/) is a complete, runnable `.circleci/config.yml`
snippet, and the same set is published on the
[Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/act#usage-examples):

| Example | What it shows |
|---|---|
| [`simple_act_usage.yml`](../src/examples/simple_act_usage.yml) | The `act` job, the common case. |
| [`simple_command_usage.yml`](../src/examples/simple_command_usage.yml) | The `act` command inside your own job/executor. |
| [`inline_action_among_native_steps.yml`](../src/examples/inline_action_among_native_steps.yml) | One action sandwiched between native CircleCI steps in an otherwise native job. |
| [`avoid_token_error.yml`](../src/examples/avoid_token_error.yml) | Wiring a personal access token in as `GITHUB_TOKEN`. |
| [`override_default_platform_image.yml`](../src/examples/override_default_platform_image.yml) | Pointing `platform` at a different runner image. |
| [`override_executor.yml`](../src/examples/override_executor.yml) | Customizing the machine executor's image, resource class, and Docker layer caching. |
| [`run_on_remote_docker.yml`](../src/examples/run_on_remote_docker.yml) | Using the `docker` executor with `setup_remote_docker` instead of the default `machine` executor. |
| [`passing_workflow_file.yml`](../src/examples/passing_workflow_file.yml) | Skipping workflow-file generation and running your own pre-written workflow file. |
| [`capture_action_outputs.yml`](../src/examples/capture_action_outputs.yml) | Reading an action's own outputs into `$BASH_ENV`; see [Capturing action outputs](CAPABILITIES.md#capturing-action-outputs). |
| [`service_containers.yml`](../src/examples/service_containers.yml) | Passing a `services:` block through to Act; see [Service containers](CAPABILITIES.md#service-containers). |

For composing the granular commands by hand instead of the `act` aggregate, see the
[worked example](COMMANDS.md#worked-example-composing-the-granular-commands-by-hand) in the
command reference.
