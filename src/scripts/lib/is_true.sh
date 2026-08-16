# shellcheck shell=bash
# Bash-safe truthiness for orb boolean parameters -- both "1"/"0" (published
# orb) and "true"/"false" (inline job, per this project's own recorded
# boolean-parameter quirk) must be accepted. This file is a sourced/embedded
# fragment, not a standalone executable -- no shebang, hence the shellcheck
# directive above instead.
#
# SINGLE SOURCE OF TRUTH for this function. install.sh, run-act.sh,
# cache-shim-start.sh, and oidc-shim-start.sh each embed a mechanically
# generated, byte-identical copy of this file's body between "BEGIN
# GENERATED: is_true" / "END GENERATED: is_true" markers -- regenerate all
# four with `bash src/scripts/sync-embedded-is-true.sh` any time this file
# changes.
#
# Why embedded copies rather than a plain `<<include(scripts/lib/is_true.sh)>>`
# in each command's `command:` field: that was tried first and reverted --
# the circleci-cli baked into orb-tools/pack's own Docker image rejects more
# than one <<include(...)>> directive in a single YAML scalar, and each of
# these four commands' `command:` field already has one include for its own
# main script (see git history for the reproduced real-CI pack failure: "An
# unexpected error occurred: multiple include statements"). This mirrors the
# generate-and-embed pattern this repo already uses for the two embedded
# Python shim servers (cache_shim_server.py/oidc_shim_server.py -- see
# sync-embedded-cache-server.sh/sync-embedded-oidc-server.sh); test_is_true_no_drift
# in .circleci/test-deploy.yml is the real, working drift check for this one
# (regenerates all four from this file and asserts `git diff` is clean).
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}
