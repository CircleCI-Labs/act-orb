#!/usr/bin/env bash
# End-to-end test harness for the OIDC shim. Runs the REAL shipped script
# (src/scripts/oidc-shim-start.sh -- not a copy) against a fake `circleci`
# binary, drives it with a client that reproduces actions/toolkit's exact
# request shape, and asserts the response parses the way the toolkit would.
# Also exercises every failure path called out in the task requirements.
#
# Usage: ./run_tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Two levels up from test/oidc-shim/ to the repo root (act-orb's own
# src/ and test/ are siblings there), unlike the standalone spike this
# was ported from, where src/ and test/ sat directly under one shim-only
# root -- see test/cache-shim/run_tests.py's identical "../.." for the
# established convention this follows.
SHIM_DIR="$(cd "${HERE}/../.." && pwd)"
START_SCRIPT="${SHIM_DIR}/src/scripts/oidc-shim-start.sh"
SERVER_PY_CANONICAL="${SHIM_DIR}/src/scripts/oidc_shim_server.py"
CLIENT="${HERE}/toolkit_client.py"

WORKDIR="$(mktemp -d)"
PASS=0
FAIL=0
PIDS_TO_KILL=()

cleanup() {
    for pid in "${PIDS_TO_KILL[@]:-}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

section() { echo; echo "=== $* ==="; }

# -----------------------------------------------------------------------
section "Drift check: heredoc-embedded server == canonical server.py"
# -----------------------------------------------------------------------
EXTRACTED="${WORKDIR}/extracted_server.py"
awk '/^cat > "\$\{SERVER_PY\}" <<[ ]*.OIDC_SHIM_SERVER_PY_EOF.$/{flag=1; next} /^OIDC_SHIM_SERVER_PY_EOF$/{flag=0} flag' "${START_SCRIPT}" > "${EXTRACTED}"
if diff -q "${EXTRACTED}" "${SERVER_PY_CANONICAL}" >/dev/null 2>&1; then
    pass "heredoc in oidc-shim-start.sh is byte-for-byte identical to oidc_shim_server.py"
else
    fail "heredoc in oidc-shim-start.sh has DRIFTED from oidc_shim_server.py -- diff:"
    diff "${EXTRACTED}" "${SERVER_PY_CANONICAL}" || true
fi

# -----------------------------------------------------------------------
# Helper: start a shim instance with a given env, return via globals
# LAST_URL / LAST_TOKEN / LAST_PID / LAST_RC. Blocks until the start
# script itself returns (it does its own bounded readiness wait).
#
# Extra "NAME=value" args ("$@" after the name/port) are routed through
# `env` rather than placed directly in front of the final command: bash
# only recognizes literal "NAME=value" tokens in a simple command's own
# source text as environment assignments, not the *result* of expanding a
# variable like "$@" -- passing an already-expanded assignment straight
# through is parsed as an attempt to run a command literally named
# "ORB_VAL_X=value" ("command not found"). `env` takes the same tokens as
# plain arguments and sets them for its child regardless of where they
# came from, which is exactly what's needed here.
# -----------------------------------------------------------------------
start_shim() {
    local name="$1" port="$2"; shift 2
    local state_dir="${WORKDIR}/state-${name}"
    local bash_env="${WORKDIR}/bash_env-${name}"
    mkdir -p "${state_dir}"
    : > "${bash_env}"

    BASH_ENV="${bash_env}" \
    ORB_VAL_ENABLED=true \
    ORB_VAL_PORT="${port}" \
    ORB_VAL_BIND_HOST="127.0.0.1" \
    ORB_VAL_ADVERTISE_HOST="127.0.0.1" \
    ORB_VAL_AUDIENCE_ALLOWLIST="" \
    ORB_VAL_STARTUP_TIMEOUT=10 \
    ORB_VAL_MINT_TIMEOUT=5 \
    ORB_VAL_CIRCLECI_BIN="circleci" \
    ORB_VAL_STATE_DIR="${state_dir}" \
    env "$@" \
    bash "${START_SCRIPT}"
    LAST_RC=$?

    if [ -f "${state_dir}/server.pid" ]; then
        LAST_PID="$(cat "${state_dir}/server.pid")"
        PIDS_TO_KILL+=("${LAST_PID}")
    else
        LAST_PID=""
    fi

    LAST_URL="$(grep ACTIONS_ID_TOKEN_REQUEST_URL "${bash_env}" 2>/dev/null | sed -E "s/^export ACTIONS_ID_TOKEN_REQUEST_URL=//" | xargs -0 printf '%s' 2>/dev/null || true)"
    LAST_TOKEN="$(grep ACTIONS_ID_TOKEN_REQUEST_TOKEN "${bash_env}" 2>/dev/null | sed -E "s/^export ACTIONS_ID_TOKEN_REQUEST_TOKEN=//" | xargs -0 printf '%s' 2>/dev/null || true)"
}

# -----------------------------------------------------------------------
section "Test 1: happy path (fake circleci succeeds), single audience"
# -----------------------------------------------------------------------
PATH_OK="${HERE}/bin-ok:${PATH}"
PATH="${PATH_OK}" start_shim happy 18990
echo "  start script exit code: ${LAST_RC}"
echo "  advertised URL: ${LAST_URL}"
if [ "${LAST_RC}" -eq 0 ] && [ -n "${LAST_URL}" ] && [ -n "${LAST_TOKEN}" ]; then
    pass "start script succeeded and exported URL+TOKEN"
else
    fail "start script did not succeed / did not export URL+TOKEN"
fi

if [ -n "${LAST_URL:-}" ]; then
    OUT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "sts.amazonaws.com" 2>&1)"
    echo "  client output: ${OUT}"
    if echo "${OUT}" | grep -q '^ey' && echo "${OUT}" | python3 -c "
import sys, json, base64
tok = sys.stdin.read().strip()
h, p, s = tok.split('.')
payload = json.loads(base64.b64decode(p + '=='))
assert payload['aud'] == 'sts.amazonaws.com', payload
print('aud round-tripped correctly:', payload['aud'])
"; then
        pass "GET ?audience=sts.amazonaws.com -> 200 {value: <jwt>}, aud round-tripped through the real subprocess call"
    else
        fail "response did not contain a correctly-shaped fake token with the right aud"
    fi
fi

# -----------------------------------------------------------------------
section "Test 2: no audience given (actions/toolkit's getIDToken() with no arg)"
# -----------------------------------------------------------------------
if [ -n "${LAST_URL:-}" ]; then
    OUT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" 2>&1)"
    RC=$?
    echo "  client output: ${OUT} (rc=${RC})"
    if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "Error Code : 400"; then
        pass "missing audience -> client sees HTTP 400, matches documented limitation"
    else
        fail "missing-audience case did not behave as documented"
    fi
fi

# -----------------------------------------------------------------------
section "Test 3: concurrency -- 5 parallel requests, distinct audiences"
# -----------------------------------------------------------------------
if [ -n "${LAST_URL:-}" ]; then
    declare -a CONC_PIDS
    declare -a CONC_OUT
    for i in 1 2 3 4 5; do
        python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "aud-${i}.example.com" > "${WORKDIR}/conc-${i}.out" 2> "${WORKDIR}/conc-${i}.err" &
        CONC_PIDS+=($!)
    done
    OK=true
    for i in 1 2 3 4 5; do
        wait "${CONC_PIDS[$((i - 1))]}" || OK=false
        TOK="$(cat "${WORKDIR}/conc-${i}.out")"
        AUD_SEEN="$(python3 -c "
import base64, json
h, p, s = '''${TOK}'''.split('.')
print(json.loads(base64.b64decode(p + '=='))['aud'])
" 2>/dev/null || echo "PARSE_FAILED")"
        if [ "${AUD_SEEN}" != "aud-${i}.example.com" ]; then
            OK=false
            echo "  request ${i}: expected aud-${i}.example.com, got '${AUD_SEEN}'"
        fi
    done
    if [ "${OK}" = "true" ]; then
        pass "5 concurrent requests for distinct audiences all returned the correct, non-mixed-up token"
    else
        fail "concurrent requests returned wrong/mixed audiences"
    fi
fi

# -----------------------------------------------------------------------
section "Test 4: audience-allowlist rejects a non-listed audience"
# -----------------------------------------------------------------------
PATH="${PATH_OK}" start_shim allowlist 18991 ORB_VAL_AUDIENCE_ALLOWLIST="sts.amazonaws.com"
if [ -n "${LAST_URL:-}" ]; then
    OUT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "not-on-the-list.example.com" 2>&1)"
    RC=$?
    echo "  client output: ${OUT} (rc=${RC})"
    if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "Error Code : 403"; then
        pass "disallowed audience -> 403"
    else
        fail "audience-allowlist did not reject a disallowed audience"
    fi
    OUT2="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "sts.amazonaws.com" 2>&1)"
    if echo "${OUT2}" | grep -q '^ey'; then
        pass "allow-listed audience still succeeds"
    else
        fail "allow-listed audience unexpectedly failed: ${OUT2}"
    fi
fi

# -----------------------------------------------------------------------
section "Test 5: missing 'circleci' binary -> HTTP 500 with clear message"
# -----------------------------------------------------------------------
# NOTE: must call the shell function directly with a plain PATH= prefix,
# not via `env` -- `env` execs a real binary named by its argv and has no
# visibility into this script's shell functions at all ("No such file or
# directory"), unlike the assignment-word case above which only breaks for
# *expanded* (not literal) assignment tokens.
PATH="/usr/bin:/bin" start_shim missingbin 18992 ORB_VAL_CIRCLECI_BIN="/definitely/does/not/exist/circleci"
if [ -n "${LAST_URL:-}" ]; then
    OUT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "sts.amazonaws.com" 2>&1)"
    RC=$?
    echo "  client output: ${OUT} (rc=${RC})"
    if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "binary not found on PATH"; then
        pass "missing circleci binary -> 500 with clear 'binary not found' message"
    else
        fail "missing-binary case did not produce the expected clear error"
    fi
fi

# -----------------------------------------------------------------------
section "Test 6: non-zero exit from mint command -> HTTP 500 with stderr included"
# -----------------------------------------------------------------------
PATH_FAIL="${HERE}/bin-fail:${PATH}"
PATH="${PATH_FAIL}" start_shim failbin 18993
if [ -n "${LAST_URL:-}" ]; then
    OUT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "sts.amazonaws.com" 2>&1)"
    RC=$?
    echo "  client output: ${OUT} (rc=${RC})"
    if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "simulated mint failure"; then
        pass "non-zero exit from mint command -> 500 with fake-circleci's own stderr included verbatim"
    else
        fail "non-zero-exit case did not surface stderr as expected"
    fi
fi

# -----------------------------------------------------------------------
section "Test 7: bounded startup wait -- port already occupied, never races"
# -----------------------------------------------------------------------
OCCUPY_PORT=18994
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', ${OCCUPY_PORT}))
s.listen(1)
time.sleep(30)
" &
OCCUPY_PID=$!
PIDS_TO_KILL+=("${OCCUPY_PID}")
sleep 0.3 # let the occupier actually bind before we race it

START_TS=$(date +%s)
state_dir="${WORKDIR}/state-occupied"
mkdir -p "${state_dir}"
bash_env="${WORKDIR}/bash_env-occupied"
: > "${bash_env}"
BASH_ENV="${bash_env}" \
ORB_VAL_ENABLED=true \
ORB_VAL_PORT="${OCCUPY_PORT}" \
ORB_VAL_BIND_HOST="127.0.0.1" \
ORB_VAL_ADVERTISE_HOST="127.0.0.1" \
ORB_VAL_AUDIENCE_ALLOWLIST="" \
ORB_VAL_STARTUP_TIMEOUT=2 \
ORB_VAL_MINT_TIMEOUT=5 \
ORB_VAL_CIRCLECI_BIN="circleci" \
ORB_VAL_STATE_DIR="${state_dir}" \
    bash "${START_SCRIPT}" >"${WORKDIR}/occupied.out" 2>&1
RC=$?
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo "  exit code: ${RC}, elapsed: ${ELAPSED}s"
cat "${WORKDIR}/occupied.out"
kill "${OCCUPY_PID}" >/dev/null 2>&1 || true

if [ "${RC}" -ne 0 ] && [ "${ELAPSED}" -le 6 ]; then
    pass "occupied port -> start script fails within its bounded startup-timeout instead of hanging or racing"
else
    fail "occupied-port case did not fail promptly and boundedly (rc=${RC}, elapsed=${ELAPSED}s)"
fi

# -----------------------------------------------------------------------
section "Test 8: enabled=false is a no-op"
# -----------------------------------------------------------------------
state_dir="${WORKDIR}/state-disabled"
mkdir -p "${state_dir}"
bash_env="${WORKDIR}/bash_env-disabled"
: > "${bash_env}"
BASH_ENV="${bash_env}" ORB_VAL_ENABLED=false ORB_VAL_STATE_DIR="${state_dir}" \
    ORB_VAL_PORT=18995 ORB_VAL_BIND_HOST=127.0.0.1 ORB_VAL_ADVERTISE_HOST=127.0.0.1 \
    ORB_VAL_AUDIENCE_ALLOWLIST="" ORB_VAL_STARTUP_TIMEOUT=2 ORB_VAL_MINT_TIMEOUT=2 \
    ORB_VAL_CIRCLECI_BIN=circleci \
    bash "${START_SCRIPT}"
RC=$?
if [ "${RC}" -eq 0 ] && [ ! -s "${bash_env}" ] && [ ! -f "${state_dir}/server.pid" ]; then
    pass "enabled=false exits 0 cleanly, starts nothing, exports nothing"
else
    fail "enabled=false was not a clean no-op"
fi

# -----------------------------------------------------------------------
section "Test 9: Authorization enforcement -- missing/wrong/correct token, no mint on failure"
# -----------------------------------------------------------------------
MINT_LOG="${WORKDIR}/mint-calls-auth.log"
PATH="${PATH_OK}" start_shim auth 18996 OIDC_SHIM_TEST_MINT_LOG="${MINT_LOG}"
if [ -n "${LAST_URL:-}" ]; then
    # 9a: no Authorization header at all (empty-string sentinel to the test
    # client means "omit the header entirely" -- see toolkit_client.py).
    OUT_NOAUTH="$(python3 "${CLIENT}" "${LAST_URL}" "" "sts.amazonaws.com" 2>&1)"
    RC_NOAUTH=$?
    echo "  no-auth-header output: ${OUT_NOAUTH} (rc=${RC_NOAUTH})"
    if [ "${RC_NOAUTH}" -ne 0 ] && echo "${OUT_NOAUTH}" | grep -q "Error Code : 401"; then
        pass "request with NO Authorization header -> 401"
    else
        fail "request with no Authorization header did not get 401"
    fi

    # 9b: a wrong bearer token
    OUT_WRONG="$(python3 "${CLIENT}" "${LAST_URL}" "not-the-real-token-abc123" "sts.amazonaws.com" 2>&1)"
    RC_WRONG=$?
    echo "  wrong-token output: ${OUT_WRONG} (rc=${RC_WRONG})"
    if [ "${RC_WRONG}" -ne 0 ] && echo "${OUT_WRONG}" | grep -q "Error Code : 401"; then
        pass "request with WRONG bearer token -> 401"
    else
        fail "request with wrong bearer token did not get 401"
    fi

    # Neither failed-auth request should have caused a mint attempt.
    if [ ! -s "${MINT_LOG}" ]; then
        pass "no mint command was invoked for either failed-auth request (mint log empty)"
    else
        fail "a mint command WAS invoked despite failed auth -- mint log:"
        cat "${MINT_LOG}"
    fi

    # 9c: the 401 body's "message" field carries a useful, actionable reason
    # -- this is the one field @actions/http-client's _processResponse()
    # actually reads, so this is what the wrapped action would see.
    if echo "${OUT_WRONG}" | grep -qi "Authorization" && echo "${OUT_WRONG}" | grep -qi "request token"; then
        pass "401 body's 'message' field explains the failure in a way the toolkit would surface"
    else
        fail "401 body did not contain a useful 'message' explanation"
    fi

    # ... and it must never leak the real expected token value, on either
    # failure path.
    if echo "${OUT_NOAUTH}" | grep -qF "${LAST_TOKEN}" || echo "${OUT_WRONG}" | grep -qF "${LAST_TOKEN}"; then
        fail "401 response LEAKED the real request token"
    else
        pass "401 response does not leak the real request token"
    fi

    # 9d: the CORRECT token -> 200 and a well-formed {"value": "<jwt>"}
    OUT_CORRECT="$(python3 "${CLIENT}" "${LAST_URL}" "${LAST_TOKEN}" "sts.amazonaws.com" 2>&1)"
    RC_CORRECT=$?
    echo "  correct-token output: ${OUT_CORRECT} (rc=${RC_CORRECT})"
    if [ "${RC_CORRECT}" -eq 0 ] && echo "${OUT_CORRECT}" | grep -q '^ey'; then
        pass "request with the CORRECT token -> 200 and a well-formed JWT value"
    else
        fail "request with the correct token did not succeed as expected"
    fi

    # Exactly one mint call total: the two failed-auth requests above must
    # not have reached the mint binary; only this one authenticated request
    # should have.
    if [ -s "${MINT_LOG}" ] && [ "$(wc -l < "${MINT_LOG}")" -eq 1 ]; then
        pass "exactly one mint command was invoked, for the single successfully-authenticated request"
    else
        fail "unexpected number of mint invocations after the one authenticated request: $(cat "${MINT_LOG}" 2>/dev/null || echo '<no log>')"
    fi
else
    fail "Test 9 setup: shim did not start"
fi

# -----------------------------------------------------------------------
section "Test 10: /healthz answers without auth and leaks nothing sensitive"
# -----------------------------------------------------------------------
if [ -n "${LAST_URL:-}" ]; then
    # Passed via env, not string-interpolated into the Python source: LAST_URL
    # can contain a literal backslash (an artifact of the %q-encoded
    # bash_env round-trip -- see start_shim above), which would otherwise
    # land inside a Python string literal and trip an escape-sequence
    # warning for no functional reason.
    HEALTHZ_URL="$(LAST_URL="${LAST_URL}" python3 -c "
import os, urllib.parse
u = urllib.parse.urlsplit(os.environ['LAST_URL'])
print(urllib.parse.urlunsplit((u.scheme, u.netloc, '/healthz', '', '')))
")"
    HEALTHZ_OUT="$(curl -fsS "${HEALTHZ_URL}" 2>&1)"
    RC_HEALTHZ=$?
    echo "  /healthz output: ${HEALTHZ_OUT} (rc=${RC_HEALTHZ})"
    if [ "${RC_HEALTHZ}" -eq 0 ] && echo "${HEALTHZ_OUT}" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        pass "/healthz answered 200 with no Authorization header sent"
    else
        fail "/healthz did not answer cleanly without auth"
    fi
    if echo "${HEALTHZ_OUT}" | grep -qF "${LAST_TOKEN}"; then
        fail "/healthz LEAKED the real request token"
    else
        pass "/healthz response does not leak the real request token"
    fi
    # Exact-body check: must be *only* the documented shape, nothing extra.
    if [ "$(echo "${HEALTHZ_OUT}" | tr -d '[:space:]')" = '{"status":"ok"}' ]; then
        pass "/healthz body is exactly {\"status\": \"ok\"}, nothing more"
    else
        fail "/healthz body has unexpected shape: ${HEALTHZ_OUT}"
    fi
else
    fail "Test 10 setup: shim did not start"
fi

echo
echo "=== SUMMARY: ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
