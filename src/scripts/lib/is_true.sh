# shellcheck shell=bash
# Bash-safe truthiness for orb boolean parameters -- both "1"/"0" (published
# orb) and "true"/"false" (inline job, per this project's own recorded
# boolean-parameter quirk) must be accepted. This file is a sourced/embedded
# fragment, not a standalone executable -- no shebang, hence the shellcheck
# directive above instead.
#
# SINGLE SOURCE OF TRUTH for this function. install.sh and run-act.sh each
# embed a mechanically generated, byte-identical copy of this file's body
# between "BEGIN GENERATED: is_true" / "END GENERATED: is_true" markers --
# regenerate both with `bash src/scripts/sync-embedded-is-true.sh` any time
# this file changes. (Two more embedded copies, in cache-shim-start.sh and
# oidc-shim-start.sh, existed here until the cache/OIDC shims were split
# onto feature/translation-layer and the cache shim was removed outright;
# that branch still carries its own copy of this same generator for those
# two files.)
#
# Why embedded copies rather than a plain `<<include(scripts/lib/is_true.sh)>>`
# in each command's `command:` field: that was tried first and reverted --
# the circleci-cli baked into orb-tools/pack's own Docker image rejects more
# than one <<include(...)>> directive in a single YAML scalar, and each of
# these commands' `command:` field already has one include for its own main
# script (see git history for the reproduced real-CI pack failure: "An
# unexpected error occurred: multiple include statements"). test_is_true_no_drift
# in .circleci/test-deploy.yml is the real, working drift check for this one
# (regenerates both from this file and asserts `git diff` is clean).
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}
