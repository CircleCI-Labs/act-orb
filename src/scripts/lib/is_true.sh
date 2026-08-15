# shellcheck shell=bash
# This file has no shebang of its own -- it is never run standalone. Every
# command that uses it (`install`, `run-act`, `cache-shim`, `oidc-shim`)
# prepends it, via `<<include(scripts/lib/is_true.sh)>>`, ahead of that
# command's own script (which does carry the real `#!/bin/bash`), and every
# local test harness that runs one of those scripts directly (not through a
# packed orb command) sources this file and `export -f is_true`s it first --
# see test/oidc-shim/run_tests.sh and .circleci/test-deploy.yml's
# test_run_act_booleans job for the two examples of that pattern.
#
# Bash-safe truthiness for orb boolean parameters -- both "1"/"0" (a published orb renders its
# boolean parameters this way) and "true"/"false" (an inline job renders them this way instead;
# see docs/ROADMAP.md / this project's own recorded boolean-parameter quirk) must be accepted.
# Single source of truth: install.sh, run-act.sh, cache-shim-start.sh, and oidc-shim-start.sh all
# used to carry independent, copy-pasted definitions of this exact function -- included here
# instead so there is exactly one definition to keep in sync. Test coverage:
# test_run_act_booleans in .circleci/test-deploy.yml exercises this exact function (via
# run-act.sh) against both encodings.
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}
