#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# Ordinary-user orchestration test for scripts/hardware/t480-lab-runner.sh.
# Mocked tools, a harmless dummy child (a python unix-socket sleeper, killed
# by the runner's own cleanup), real control flow: the actual t480_main runs
# in subshells so traps stay contained and exit statuses are observable.
# No camera, root, TPM, enrollment or installed-system operations: the
# "daemon" is a local socket sleeper, the "CLI" answers canned JSON, nothing
# is enrolled anywhere, and every fixture lives under mktemp dirs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${HERE}/../t480-lab-runner.sh"

command -v python3 >/dev/null || { echo "SKIP: python3 absent, socket mock impossible"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: jq absent"; exit 0; }

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
        echo "PASS: $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1 (expected [$2], got [$3])"
    fi
}

BASE="$(mktemp -d /tmp/t480-orchestration.XXXXXX)"
trap 'rm -rf -- "${BASE}"' EXIT

# Each scenario prints a header before it runs. The startup scenarios wait on
# real deadlines, so the header is what shows which one is in flight and that a
# slow scenario is waiting rather than hung.

HW="t480_hw_authenticate_isolated::t480_hw_authenticate_isolated"
USER_NOW="$(id -un)"

# One scenario fixture: mock bin dir with irlume/irlumed/test-bin/sudo shims,
# plus lab/state/config/keyring/recovery/emitter dirs and lab env exports.
# stdout: the scenario root. Nothing here touches hardware or the system.
orch_fixture() {
    local root="$1"
    mkdir -p "${root}/mocks" "${root}/bin" "${root}/lab" "${root}/evidence" \
        "${root}/state" "${root}/config" "${root}/keyring" "${root}/recovery" \
        "${root}/emitter-lock" "${root}/lab/emitter-lock"
    mkfifo "${root}/evidence/enroll-fifo" 2>/dev/null || true
    cat >"${root}/mocks/sudo" <<'EOF'
#!/bin/bash
# Dropping -u means the runner asked for the enrolling account's own view.
if [[ "${1:-}" == "-u" ]]; then shift 2; export MOCK_ACCOUNT_VIEW=1; fi
exec "$@"
EOF
    cat >"${root}/mocks/irlume" <<EOF
#!/bin/bash
if [[ "\${MOCK_IRLUME_FAIL_AT:-}" == "\$1:\$2" || "\${MOCK_IRLUME_FAIL_AT:-}" == "\$1" ]]; then
    exit 1
fi
case "\$1" in
    status)
        if [[ "\${MOCK_DAEMON_STAGE:-running}" == "starting" ]]; then
            echo '{"contract_version":1,"command":"status","ok":true,"data":{"daemon":"starting"}}'
        else
            echo '{"contract_version":1,"command":"status","ok":true,"data":{"daemon":"running"}}'
        fi
        exit 0 ;;
    split)
        case "\$2" in
            status) exit 0 ;;
            list)
                # The account view serves endpoint tokens, not node paths.
                if [[ -n "\${MOCK_ACCOUNT_VIEW:-}" && -n "\${MOCK_USER_LIST_JSON:-}" ]]; then
                    cat "\${MOCK_USER_LIST_JSON}"
                else
                    cat "\${MOCK_LIST_JSON}"
                fi
                exit 0 ;;
            add|select) exit 0 ;;
            *) exit 2 ;;
        esac ;;
    enroll)
        # Always record the call, so a scenario can assert enrollment was
        # never reached (the FIFO below adds the deterministic stall point).
        printf 'invoked\n' > "\${MOCK_EVIDENCE}/enroll-invoked"
        # Peer-dependent projection, as resolve_split_enrollment_choice does:
        # a root peer (no -u) must send the ROOT view's endpoints and proof;
        # an account peer (-u) must send the ACCOUNT view's.
        choice=""
        while [[ \$# -gt 0 ]]; do
            [[ "\$1" == "--split-camera-choice" ]] && { choice="\$2"; shift; }
            shift
        done
        if [[ -n "\${choice}" ]]; then
            view="\${MOCK_LIST_JSON}"
            if [[ -n "\${MOCK_ACCOUNT_VIEW:-}" && -n "\${MOCK_USER_LIST_JSON:-}" ]]; then
                view="\${MOCK_USER_LIST_JSON}"
            fi
            # Authorization must equal the calling view's, unchanged.
            if ! jq -e -s --argjson c "\${choice}" '.[0].authorization == \$ARGS.named.c.authorization' \\
                    "\${view}" >/dev/null 2>&1; then
                printf 'enroll refused: split enrollment choice changed or is unavailable\n'
                exit 1
            fi
            # Both endpoints must be the calling view's own endpoint values.
for role in rgb ir; do
                case "\${role}" in
                    rgb) field=".expected.rgb.endpoint" ;;
                    ir)  field=".expected.ir.endpoint" ;;
                esac
                ep="\$(printf '%s' "\${choice}" | jq -r "\${field} // empty")"
                if [[ -z "\${ep}" ]] || ! jq -e --arg ep "\${ep}" \
                        'any(.candidates[]; .guard.endpoint == \$ep)' "\${view}" >/dev/null 2>&1; then
                    printf 'enroll refused: split enrollment choice changed or is unavailable\n'
                    exit 1
                fi
            done
        fi
        [[ -n "\${MOCK_ENROLL_REPLY:-}" ]] && printf '%s\n' "\${MOCK_ENROLL_REPLY}"
        # Deterministic stall point: block on the scenario FIFO when asked,
        # so interruption tests land mid-enroll without wall-clock racing.
        if [[ -n "\${MOCK_ENROLL_FIFO:-}" ]]; then
            printf 'started\n' > "\${MOCK_EVIDENCE}/enroll-started"
            read -r _ < "\${MOCK_ENROLL_FIFO}"
        fi
        exit 0 ;;
    *) exit 2 ;;
esac
EOF
    cat >"${root}/bin/irlumed" <<'EOF'
#!/bin/bash
echo $$ > "${MOCK_PIDFILE}"
exec python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(3600)' "${MOCK_SOCK}"
EOF
    cat >"${root}/mocks/testbin" <<EOF
#!/bin/bash
if [[ " \$* " == *" --list "* ]]; then
    printf '%s: test\n' "${HW}"
    printf 'other::test: test\n'
    exit 0
fi
printf 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n'
exit 0
EOF
    chmod 0755 "${root}/mocks/sudo" "${root}/mocks/irlume" "${root}/bin/irlumed" "${root}/mocks/testbin"
    # The runner addresses the candidate CLI at the bin dir, like the lab's
    # copied artifacts; the mock sudo/test-bin stay reachable via PATH/position.
    cp "${root}/mocks/irlume" "${root}/bin/irlume"
    chmod 0755 "${root}/bin/irlume"
    cat >"${root}/list.json" <<'EOF'
{"supervisor_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":7,"authorization":{"generation":3,"token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"candidates":[{"role":"rgb","guard":{"instance_id":"cccccccccccccccccccccccccccccccc","generation":1,"endpoint":"/dev/video0"},"facts":{"Root":{"identity":"5986:2113:sn","path":"/dev/video0","controller":"0000:00:14.0","domain":"usb2","ports":[8]}}},{"role":"ir","guard":{"instance_id":"dddddddddddddddddddddddddddddddd","generation":2,"endpoint":"/dev/video1"},"facts":{"Root":{"identity":"5986:1141:sn","path":"/dev/video1","controller":"0000:00:14.0","domain":"usb2","ports":[5]}}}],"records":[{"key":"split1;a|c|usb2|1;b|c|usb2|2","rgb":{"Root":{"identity":"5986:2113:sn"}},"ir":{"Root":{"identity":"5986:1141:sn"}}}],"selected":null}
EOF
    # The account view of the SAME store, as a non-root caller sees it: the
    # supervisor/revision and each candidate's role, instance_id and generation
    # agree with the root view, but each endpoint is an account token rather
    # than a node path, and the authorization is the account's own proof.
    cat >"${root}/user-list.json" <<'EOF'
{"supervisor_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":7,"authorization":{"generation":4,"token":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"candidates":[{"role":"rgb","guard":{"instance_id":"cccccccccccccccccccccccccccccccc","generation":1,"endpoint":"a916d7fb038aa603"},"facts":{"Root":{"identity":"5986:2113:sn"}}},{"role":"ir","guard":{"instance_id":"dddddddddddddddddddddddddddddddd","generation":2,"endpoint":"567c66f141cc63de"},"facts":{"Root":{"identity":"5986:1141:sn"}}}],"records":[{"key":"split1;a|c|usb2|1;b|c|usb2|2","rgb":{"Root":{"identity":"5986:2113:sn"}},"ir":{"Root":{"identity":"5986:1141:sn"}}}],"selected":null}
EOF
    printf '%s' "${root}"
}

# Export the lab environment for one scenario root (dummy model/ORT values:
# the mocks never read them; only presence is checked).
orch_env() {
    local root="$1"
    export MOCK_EVIDENCE="${root}/evidence"
    export MOCK_PIDFILE="${root}/lab/daemon.pid"
    export MOCK_SOCK="${root}/lab/irlume.sock"
    export MOCK_LIST_JSON="${root}/list.json"
    export MOCK_USER_LIST_JSON="${root}/user-list.json"
    export IRLUME_TCTI="swtpm:host=127.0.0.1,port=9"
    export IRLUME_STATE_DIR="${root}/state"
    export IRLUME_CONFIG_DIR="${root}/config"
    export IRLUME_EMITTER_LOCK_DIR="${root}/lab/emitter-lock"
    export IRLUME_IR_EMITTER_CONF="${root}/config/ir_emitter.conf"
    export IRLUME_KEYRING_DIR="${root}/keyring"
    export IRLUME_RECOVERY_DIR="${root}/recovery"
    export IRLUME_DET_MODEL="${root}/det.onnx"
    export IRLUME_MODEL="${root}/model.onnx"
    export IRLUME_MESH_MODEL="${root}/mesh.onnx"
    export IRLUME_BLAZE_MODEL="${root}/blaze.onnx"
    export IRLUME_VIT_PAD_MODEL="${root}/vit.onnx"
    export IRLUME_PAD_IR_MODEL="${root}/flir.onnx"
    export ORT_DYLIB_PATH="${root}/lib.so"
    export IRLUME_NPU=0
    export IRLUME_MODELS_STRICT=1
    export PATH="${root}/mocks:/usr/bin:/bin"
}

daemon_dead() {
    ! kill -0 "$(cat "$1")" 2>/dev/null
}

# Reaped-or-reaping: missing/unreadable pidfile, dead pid, or a zombie
# (reaped by init next). Poll-bounded callers absorb teardown latency instead
# of asserting on a single instant.
daemon_gone() {
    local pid
    pid="$(cat "$1" 2>/dev/null)" || return 0
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
    kill -0 "${pid}" 2>/dev/null || return 0
    local state
    state="$(ps -o stat= -p "${pid}" 2>/dev/null || echo gone)"
    [[ "${state}" == "gone" || "${state}" == Z* ]]
}

# Poll up to ~15s for the daemon to be gone (covers the trap's bounded
# terminate-and-wait loop after an interruption).
await_daemon_gone() {
    local i
    for i in $(seq 1 150); do
        daemon_gone "$1" && return 0
        sleep 0.1
    done
    return 1
}

# Run t480_main with -e active inside it and record its status in a file.
# Used only where no signals are involved (scenarios 1-3). Two shell pitfalls
# are avoided here at once (bash manual, -e):
#   1. Never call it as `( t480_main ... ) && rc=0 || rc=$?`: a function
#      invoked in an &&/|| condition runs with set -e silently disabled for
#      its whole body, so a failing stage falls through instead of aborting.
#   2. Never add another wrapper layer between a signal and this call: the
#      inner subshell below is the process running t480_main's traps, so any
#      scenario that delivers signals must address that process (scenario 4
#      inlines the same shape instead, with its own process group).
# The inner subshell enables -e explicitly, runs t480_main as a plain
# statement, and always records rc, independent of the caller's -e state.
run_main_to_file() {
    local rcfile="$1"
    shift
    set +e
    ( set -e; t480_main "$@" )
    echo "$?" >"${rcfile}"
    set -e
}

# Scenario 1: full success through the mock flow.
echo "--- Scenario 1 ---"
S1="$(orch_fixture "${BASE}/s1")"
(
    orch_env "${S1}"
    export PATH="${S1}/mocks:/usr/bin:/bin"
    run_main_to_file "${S1}/rc" "${S1}/lab" "${S1}/bin" "${S1}/evidence" "${S1}/lab/irlume.sock" \
        "${S1}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc1="$(cat "${S1}/rc")"
check "success exits 0" "0" "${rc1}"
check "status ready evidence exists" "0" "$([[ -f "${S1}/evidence/status-ready.json" ]] && echo 0 || echo 1)"
check "choice evidence exists" "0" "$([[ -f "${S1}/evidence/split-choice.json" ]] && echo 0 || echo 1)"
check "enrollment invoked with an authorized choice" "0" "$([[ -f "${S1}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
grep -q '"authorization"' "${S1}/evidence/split-choice.json" && auth1=0 || auth1=1
check "authorized choice carries the authorization" "0" "${auth1}"
check "run log reports the pass" "1 passed" "$(grep -E '^test result:' "${S1}/evidence/hw-test-run.txt" | tail -n 1 | grep -o '[0-9] passed' || echo missing)"
if await_daemon_gone "${S1}/lab/daemon.pid"; then gone1=0; else gone1=1; fi
check "successful exit reaps the dummy daemon" "0" "${gone1}"

# Scenario 2: a missing helper (jq shadowed by a failing shim) aborts early.
echo "--- Scenario 2 ---"
mkdir -p "${BASE}/s2shim"
printf '#!/bin/bash\necho "jq: command not found" >&2\nexit 127\n' >"${BASE}/s2shim/jq"
chmod 0755 "${BASE}/s2shim/jq"
S2="$(orch_fixture "${BASE}/s2")"
(
    orch_env "${S2}"
    export PATH="${S2}/mocks:${BASE}/s2shim:/usr/bin:/bin"
    run_main_to_file "${S2}/rc" "${S2}/lab" "${S2}/bin" "${S2}/evidence" "${S2}/lab/irlume.sock" \
        "${S2}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc2="$(cat "${S2}/rc")"
check "missing helper fails the run" "1" "$([[ "${rc2}" != "0" ]] && echo 1 || echo 0)"
if await_daemon_gone "${S2}/lab/daemon.pid"; then gone2=0; else gone2=1; fi
check "missing helper still reaps the dummy daemon" "0" "${gone2}"

# Scenario 3: enroll refusal fails the run without reaching the probe.
echo "--- Scenario 3 ---"
S3="$(orch_fixture "${BASE}/s3")"
(
    orch_env "${S3}"
    export PATH="${S3}/mocks:/usr/bin:/bin"
    export MOCK_IRLUME_FAIL_AT="enroll"
    run_main_to_file "${S3}/rc" "${S3}/lab" "${S3}/bin" "${S3}/evidence" "${S3}/lab/irlume.sock" \
        "${S3}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc3="$(cat "${S3}/rc")"
check "enroll refusal exits 1" "1" "${rc3}"
if await_daemon_gone "${S3}/lab/daemon.pid"; then gone3=0; else gone3=1; fi
check "enroll refusal reaps the dummy daemon" "0" "${gone3}"
check "enroll refusal never reaches the probe" "0" "$([[ ! -f "${S3}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"

# Scenario 4: interruption exits instead of resuming the workflow. The mock
# enroll blocks on a FIFO, so SIGTERM deterministically lands mid-enroll;
# releasing the FIFO afterwards lets any orphaned mock exit on its own.
echo "--- Scenario 4 ---"
S4="$(orch_fixture "${BASE}/s4")"
# NOTE: no run_main_to_file wrapper here: the background subshell below must
# itself be the process running t480_main's traps (see run_main_to_file).
# Job control is scoped to this scenario so the flow gets its own process
# group: the interruption below goes to the whole group (as a terminal
# Ctrl-C would), tearing down the blocked foreground pipeline together with
# the trapped shell instead of orphaning it.
set -m
(
    orch_env "${S4}"
    export PATH="${S4}/mocks:/usr/bin:/bin"
    export MOCK_ENROLL_FIFO="${S4}/evidence/enroll-fifo"
    set -e
    t480_main "${S4}/lab" "${S4}/bin" "${S4}/evidence" "${S4}/lab/irlume.sock" \
        "${S4}/mocks/testbin" "${USER_NOW}" "${HW}"
) &
runner_pid=$!
set +m
started=0
for _ in $(seq 1 200); do
    [[ -f "${S4}/evidence/enroll-started" ]] && { started=1; break; }
    kill -0 "${runner_pid}" 2>/dev/null || break
    sleep 0.1
done
if [[ "${started}" != "1" ]]; then
    kill -KILL "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" 2>/dev/null || true
    timeout 10 bash -c ': > "'"${S4}"'/evidence/enroll-fifo"' 2>/dev/null || true
    check "interruption reaches the enroll stall" "1" "0"
else
    kill -TERM -- "-${runner_pid}" 2>/dev/null || true
    # Bounded join: never hang the suite if the child misbehaves.
    joined=0
    for _ in $(seq 1 300); do
        kill -0 "${runner_pid}" 2>/dev/null || { joined=1; break; }
        sleep 0.1
    done
    if [[ "${joined}" != "1" ]]; then
        kill -KILL -- "-${runner_pid}" 2>/dev/null || true
    fi
    wait "${runner_pid}" && rc4=0 || rc4=$?
    # Release any mock still blocked on the FIFO so nothing lingers.
    timeout 10 bash -c ': > "'"${S4}"'/evidence/enroll-fifo"' 2>/dev/null || true
    check "interruption exits nonzero" "1" "$([[ "${rc4}" != "0" ]] && echo 1 || echo 0)"
    if await_daemon_gone "${S4}/lab/daemon.pid"; then gone4=0; else gone4=1; fi
    check "interruption reaps the dummy daemon" "0" "${gone4}"
    check "interruption never reaches the probe" "0" "$([[ ! -f "${S4}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
fi
# Hygiene sweep (not asserted): leave no mock processes behind whatever path
# above ran. The reap assertion above already judged the runner's cleanup.
kill -9 "$(cat "${S4}/lab/daemon.pid" 2>/dev/null)" 2>/dev/null || true

# Scenario 5: split status succeeds during Starting, but status --json
# reports starting: runner must NOT proceed and must fail on deadline.
echo "--- Scenario 5 ---"
S5="$(orch_fixture "${BASE}/s5")"
(
    orch_env "${S5}"
    export PATH="${S5}/mocks:/usr/bin:/bin"
    export MOCK_DAEMON_STAGE="starting"
    export T480_STARTUP_TIMEOUT=2
    run_main_to_file "${S5}/rc" "${S5}/lab" "${S5}/bin" "${S5}/evidence" "${S5}/lab/irlume.sock" \
        "${S5}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc5="$(cat "${S5}/rc")"
check "starting stage timeout exits 1" "1" "${rc5}"
if await_daemon_gone "${S5}/lab/daemon.pid"; then gone5=0; else gone5=1; fi
check "starting stage timeout reaps the dummy daemon" "0" "${gone5}"
check "starting stage timeout never reaches the probe" "0" "$([[ ! -f "${S5}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
check "starting stage timeout never created split-add" "0" "$([[ ! -f "${S5}/evidence/split-add.txt" ]] && echo 0 || echo 1)"

# Scenario 6: candidate daemon dies during startup: runner must abort on the
# liveness check, not wait out the deadline. The CLI keeps reporting
# "starting" so readiness can never win the race with the daemon's death.
echo "--- Scenario 6 ---"
S6="$(orch_fixture "${BASE}/s6")"
cat >"${S6}/bin/irlumed" <<'EOF'
#!/bin/bash
echo $$ > "${MOCK_PIDFILE}"
# Bind the socket, then die while the CLI still reports "starting".
exec python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(0.5)' "${MOCK_SOCK}"
EOF
chmod 0755 "${S6}/bin/irlumed"
started6="${SECONDS}"
(
    orch_env "${S6}"
    export PATH="${S6}/mocks:/usr/bin:/bin"
    export MOCK_DAEMON_STAGE="starting"
    export T480_STARTUP_TIMEOUT=30
    run_main_to_file "${S6}/rc" "${S6}/lab" "${S6}/bin" "${S6}/evidence" "${S6}/lab/irlume.sock" \
        "${S6}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc6="$(cat "${S6}/rc")"
check "daemon death during startup exits 1" "1" "${rc6}"
check "daemon death never reaches the probe" "0" "$([[ ! -f "${S6}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
check "daemon death aborts on liveness, not the deadline" "1" "$([[ $(( SECONDS - started6 )) -lt 10 ]] && echo 1 || echo 0)"
if await_daemon_gone "${S6}/lab/daemon.pid"; then gone6=0; else gone6=1; fi
check "daemon death reaps the dummy daemon" "0" "${gone6}"

# Scenario 7: Ready is reached, but candidates list is empty:
# runner must emit distinct inventory diagnostic, not another startup wait.
echo "--- Scenario 7 ---"
S7="$(orch_fixture "${BASE}/s7")"
cat >"${S7}/list.json" <<'EOF'
{"supervisor_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":7,"authorization":null,"candidates":[],"records":[],"selected":null,"store_state":"Absent"}
EOF
(
    orch_env "${S7}"
    export PATH="${S7}/mocks:/usr/bin:/bin"
    export MOCK_DAEMON_STAGE="running"
    run_main_to_file "${S7}/rc" "${S7}/lab" "${S7}/bin" "${S7}/evidence" "${S7}/lab/irlume.sock" \
        "${S7}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc7="$(cat "${S7}/rc")"
check "empty candidates exits 1" "1" "${rc7}"
if await_daemon_gone "${S7}/lab/daemon.pid"; then gone7=0; else gone7=1; fi
check "empty candidates reaps daemon" "0" "${gone7}"
check "empty candidates never reaches the probe" "0" "$([[ ! -f "${S7}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
check "status ready was reached before candidate check" "0" "$([[ -f "${S7}/evidence/status-ready.json" ]] && echo 0 || echo 1)"

# Scenario 8: the ACCOUNT listing carries no authorization. The initial add
# stage must tolerate that (an absent store has none), but the later split
# enrollment choice must refuse it, before enrollment is ever invoked.
echo "--- Scenario 8 ---"
S8="$(orch_fixture "${BASE}/s8")"
cat >"${S8}/list.json" <<'EOF'
{"supervisor_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":7,"candidates":[{"role":"rgb","guard":{"instance_id":"cccccccccccccccccccccccccccccccc","generation":1,"endpoint":"/dev/video0"},"facts":{"Root":{"identity":"5986:2113:sn","path":"/dev/video0","controller":"0000:00:14.0","domain":"usb2","ports":[8]}}},{"role":"ir","guard":{"instance_id":"dddddddddddddddddddddddddddddddd","generation":2,"endpoint":"/dev/video1"},"facts":{"Root":{"identity":"5986:1141:sn","path":"/dev/video1","controller":"0000:00:14.0","domain":"usb2","ports":[5]}}}],"records":[{"key":"split1;a|c|usb2|1;b|c|usb2|2","rgb":{"Root":{"identity":"5986:2113:sn"}},"ir":{"Root":{"identity":"5986:1141:sn"}}}],"selected":null}
EOF
jq 'del(.authorization)' "${S8}/user-list.json" > "${S8}/user-list-noauth.json"
(
    orch_env "${S8}"
    export PATH="${S8}/mocks:/usr/bin:/bin"
    export MOCK_DAEMON_STAGE="running"
    export MOCK_USER_LIST_JSON="${S8}/user-list-noauth.json"
    run_main_to_file "${S8}/rc" "${S8}/lab" "${S8}/bin" "${S8}/evidence" "${S8}/lab/irlume.sock" \
        "${S8}/mocks/testbin" "${USER_NOW}" "${HW}"
)
rc8="$(cat "${S8}/rc")"
check "absent account authorization exits 1" "1" "${rc8}"
check "absent account authorization reached enrollment" "0" "$([[ ! -f "${S8}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
check "absent account authorization reached the probe" "0" "$([[ ! -f "${S8}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
check "absent account authorization recorded no choice" "0" "$([[ ! -f "${S8}/evidence/split-choice.json" ]] && echo 0 || echo 1)"
if await_daemon_gone "${S8}/lab/daemon.pid"; then gone8=0; else gone8=1; fi
check "absent account authorization reaps daemon" "0" "${gone8}"

# ------------------------------------------------------------------
# Account-choice mapping regressions (synthetic endpoints and tokens).
# The root view and the account view always disagree on endpoint: node
# paths versus account tokens. Only role + instance_id + generation are
# shared, inside the same supervisor/revision.
# ------------------------------------------------------------------

# Run one scenario; the caller reads "${root}/rc". Runner stdout stays on the
# console so the refusal diagnostics remain visible.
choice_scenario() {
    local root="$1" rootlist="${2:-}" userlist="${3:-}" mode="${4:-}"
    (
        orch_env "${root}"
        export PATH="${root}/mocks:/usr/bin:/bin"
        export MOCK_DAEMON_STAGE="running"
        [[ -n "${rootlist}" ]] && export MOCK_LIST_JSON="${rootlist}"
        [[ -n "${userlist}" ]] && export MOCK_USER_LIST_JSON="${userlist}"
        [[ "${mode}" == "diag" ]] && export T480_DIAG_ENROLL_AS_ROOT=1
        [[ "${mode}" == "diag" ]] && export MOCK_ENROLL_REPLY="capture failed: /dev/video0 timed out while guard 2fb61394b28ecf0f1c0f5a70e2020aba was held"
        run_main_to_file "${root}/rc" "${root}/lab" "${root}/bin" "${root}/evidence" "${root}/lab/irlume.sock" \
            "${root}/mocks/testbin" "${USER_NOW}" "${HW}"
    )
}

# Scenario 9: matching shared identity with DIFFERENT root/account endpoints
# succeeds, and the constructed choice keeps the ACCOUNT endpoints and the
# ACCOUNT authorization rather than anything from the root view.
echo "--- Scenario 9: shared identity maps across differing endpoints ---"
S9="$(orch_fixture "${BASE}/s9")"
choice_scenario "${S9}"
rc9="$(cat "${S9}/rc")"
check "differing endpoints with shared identity exits 0" "0" "${rc9}"
check "choice recorded" "0" "$([[ -f "${S9}/evidence/split-choice.json" ]] && echo 0 || echo 1)"
check "choice keeps the account rgb endpoint" "a916d7fb038aa603" "$(jq -r '.expected.rgb.endpoint' "${S9}/evidence/split-choice.json")"
check "choice keeps the account ir endpoint" "567c66f141cc63de" "$(jq -r '.expected.ir.endpoint' "${S9}/evidence/split-choice.json")"
check "choice carries no root node path" "0" "$(jq -e '[.expected.rgb.endpoint,.expected.ir.endpoint]|all(startswith("/dev/")|not)' "${S9}/evidence/split-choice.json" >/dev/null && echo 0 || echo 1)"
check "choice carries the account authorization generation" "4" "$(jq -r '.authorization.generation' "${S9}/evidence/split-choice.json")"
check "choice carries the account authorization token" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$(jq -r '.authorization.token' "${S9}/evidence/split-choice.json")"
# Identity fields must pass through untouched: compare against the account
# view itself rather than a transcribed literal.
want_ident="$(jq -r '[(.candidates[]|select(.role=="rgb")|.guard.instance_id),(.candidates[]|select(.role=="ir")|.guard.instance_id)]|join("/")' "${S9}/user-list.json")"
got_ident="$(jq -r '[.expected.rgb.instance_id,.expected.ir.instance_id]|join("/")' "${S9}/evidence/split-choice.json")"
check "choice identity fields unchanged by the mapping" "${want_ident}" "${got_ident}"
check "choice keeps the store supervisor and revision" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/7" \
    "$(jq -r '[.expected.supervisor_id,(.expected.revision|tostring)]|join("/")' "${S9}/evidence/split-choice.json")"

# Scenario 10: the account sees a different instance_id for the same role.
echo "--- Scenario 10: changed instance_id refuses ---"
S10="$(orch_fixture "${BASE}/s10")"
jq '(.candidates[]|select(.role=="rgb").guard.instance_id)="ffffffffffffffffffffffffffffffff"' \
    "${S10}/user-list.json" > "${S10}/user-list-badid.json"
choice_scenario "${S10}" "" "${S10}/user-list-badid.json"
rc10="$(cat "${S10}/rc")"
check "changed instance_id exits 1" "1" "${rc10}"
check "changed instance_id never enrolls" "0" "$([[ ! -f "${S10}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
check "changed instance_id records no choice" "0" "$([[ ! -f "${S10}/evidence/split-choice.json" ]] && echo 0 || echo 1)"

# Scenario 11: the account sees a different generation for the same role.
echo "--- Scenario 11: changed generation refuses ---"
S11="$(orch_fixture "${BASE}/s11")"
jq '(.candidates[]|select(.role=="ir").guard.generation)=9' \
    "${S11}/user-list.json" > "${S11}/user-list-badgen.json"
choice_scenario "${S11}" "" "${S11}/user-list-badgen.json"
rc11="$(cat "${S11}/rc")"
check "changed generation exits 1" "1" "${rc11}"
check "changed generation never enrolls" "0" "$([[ ! -f "${S11}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# Scenario 12: the account view describes a different store.
echo "--- Scenario 12: supervisor/revision mismatch refuses ---"
S12a="$(orch_fixture "${BASE}/s12a")"
jq '.supervisor_id="99999999999999999999999999999999"' \
    "${S12a}/user-list.json" > "${S12a}/user-list-badsup.json"
choice_scenario "${S12a}" "" "${S12a}/user-list-badsup.json"
rc12a="$(cat "${S12a}/rc")"
check "supervisor mismatch exits 1" "1" "${rc12a}"
check "supervisor mismatch never enrolls" "0" "$([[ ! -f "${S12a}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
S12b="$(orch_fixture "${BASE}/s12b")"
jq '.revision=99' "${S12b}/user-list.json" > "${S12b}/user-list-badrev.json"
choice_scenario "${S12b}" "" "${S12b}/user-list-badrev.json"
rc12b="$(cat "${S12b}/rc")"
check "revision mismatch exits 1" "1" "${rc12b}"
check "revision mismatch never enrolls" "0" "$([[ ! -f "${S12b}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# Scenario 13: a candidate arrives without the identifying fields.
echo "--- Scenario 13: missing identifying fields refuse ---"
S13="$(orch_fixture "${BASE}/s13")"
jq 'del((.candidates[]|select(.role=="rgb").guard).instance_id)' \
    "${S13}/user-list.json" > "${S13}/user-list-noid.json"
choice_scenario "${S13}" "" "${S13}/user-list-noid.json"
rc13="$(cat "${S13}/rc")"
check "missing instance_id exits 1" "1" "${rc13}"
check "missing instance_id never enrolls" "0" "$([[ ! -f "${S13}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
S13b="$(orch_fixture "${BASE}/s13b")"
jq 'del((.candidates[]|select(.role=="ir").guard).generation)' \
    "${S13b}/user-list.json" > "${S13b}/user-list-nogen.json"
choice_scenario "${S13b}" "" "${S13b}/user-list-nogen.json"
rc13b="$(cat "${S13b}/rc")"
check "missing generation exits 1" "1" "${rc13b}"
# Root side missing an identifying field: refuse before any account mapping.
S13c="$(orch_fixture "${BASE}/s13c")"
jq 'del((.candidates[]|select(.role=="rgb").guard).instance_id)' \
    "${S13c}/list.json" > "${S13c}/list-noid.json"
choice_scenario "${S13c}" "${S13c}/list-noid.json"
rc13c="$(cat "${S13c}/rc")"
check "missing root-side instance_id exits 1" "1" "${rc13c}"
check "missing root-side instance_id never enrolls" "0" "$([[ ! -f "${S13c}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# Scenario 14: zero matches (the account cannot see that camera at all).
echo "--- Scenario 14: zero matches refuses ---"
S14="$(orch_fixture "${BASE}/s14")"
jq 'del(.candidates[]|select(.role=="ir"))' \
    "${S14}/user-list.json" > "${S14}/user-list-noir.json"
choice_scenario "${S14}" "" "${S14}/user-list-noir.json"
rc14="$(cat "${S14}/rc")"
check "zero matches exits 1" "1" "${rc14}"
check "zero matches never enrolls" "0" "$([[ ! -f "${S14}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# Scenario 15: two account candidates share one identity (ambiguous).
echo "--- Scenario 15: multiple matches refuses ---"
S15="$(orch_fixture "${BASE}/s15")"
jq '.candidates += [(.candidates[]|select(.role=="rgb")|.role="rgb")]' \
    "${S15}/user-list.json" > "${S15}/user-list-dup.json"
choice_scenario "${S15}" "" "${S15}/user-list-dup.json"
rc15="$(cat "${S15}/rc")"
check "multiple matches exits 1" "1" "${rc15}"
check "multiple matches never enrolls" "0" "$([[ ! -f "${S15}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# Scenario 16: the authorization is present but unusable as a proof.
echo "--- Scenario 16: invalid authorization refuses ---"
S16a="$(orch_fixture "${BASE}/s16a")"
jq '.authorization.token=""' "${S16a}/user-list.json" > "${S16a}/user-list-notoken.json"
choice_scenario "${S16a}" "" "${S16a}/user-list-notoken.json"
rc16a="$(cat "${S16a}/rc")"
check "empty authorization token exits 1" "1" "${rc16a}"
check "empty authorization token never enrolls" "0" "$([[ ! -f "${S16a}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"
S16b="$(orch_fixture "${BASE}/s16b")"
jq 'del(.authorization.generation)' "${S16b}/user-list.json" > "${S16b}/user-list-nogenauth.json"
choice_scenario "${S16b}" "" "${S16b}/user-list-nogenauth.json"
rc16b="$(cat "${S16b}/rc")"
check "authorization without generation exits 1" "1" "${rc16b}"
S16c="$(orch_fixture "${BASE}/s16c")"
jq '.authorization="not-an-object"' "${S16c}/user-list.json" > "${S16c}/user-list-badauth.json"
choice_scenario "${S16c}" "" "${S16c}/user-list-badauth.json"
rc16c="$(cat "${S16c}/rc")"
check "non-object authorization exits 1" "1" "${rc16c}"
check "non-object authorization never enrolls" "0" "$([[ ! -f "${S16c}/evidence/enroll-invoked" ]] && echo 0 || echo 1)"

# ------------------------------------------------------------------
# Diagnostic enroll-as-root mode. Off by default; refuses outside the
# lab directory; never an acceptance run.
# ------------------------------------------------------------------

echo "--- Scenario 17: flag off keeps the account path unchanged ---"
S17="$(orch_fixture "${BASE}/s17")"
check "diagnostic flag is off by default" "1" "$( (unset T480_DIAG_ENROLL_AS_ROOT; t480_diag_enroll_as_root) && echo 0 || echo 1)"
check "flag 1 enables it" "0" "$( (T480_DIAG_ENROLL_AS_ROOT=1; t480_diag_enroll_as_root) && echo 0 || echo 1)"
check "any other value stays off" "1" "$( (T480_DIAG_ENROLL_AS_ROOT=yes; t480_diag_enroll_as_root) && echo 0 || echo 1)"

# Flag off: the account path still runs and the probe still runs.
choice_scenario "${S17}"
rc17="$(cat "${S17}/rc")"
check "flag off exits 0 on the account path" "0" "${rc17}"
check "flag off uses the account enroll evidence" "0" "$([[ -f "${S17}/evidence/enroll.txt" ]] && echo 0 || echo 1)"
check "flag off writes no diagnostic reply" "0" "$([[ ! -f "${S17}/evidence/enroll-diag-root.txt" ]] && echo 0 || echo 1)"
check "flag off still runs the probe" "0" "$([[ -f "${S17}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"

echo "--- Scenario 18: flag on selects the root diagnostic path ---"
S18="$(orch_fixture "${BASE}/s18")"
choice_scenario "${S18}" "" "" "diag"
rc18="$(cat "${S18}/rc")"
check "flag on exits 0" "0" "${rc18}"
check "flag on writes the diagnostic reply" "0" "$([[ -f "${S18}/evidence/enroll-diag-root.txt" ]] && echo 0 || echo 1)"
check "diagnostic reply is mode 0600" "600" "$(stat -c '%a' "${S18}/evidence/enroll-diag-root.txt" 2>/dev/null)"
check "flag on skips the Authenticate probe" "0" "$([[ ! -f "${S18}/evidence/hw-test-run.txt" ]] && echo 0 || echo 1)"
check "flag on skips the list gate" "0" "$([[ ! -f "${S18}/evidence/hw-test-list.txt" ]] && echo 0 || echo 1)"
check "flag on still builds the guarded choice" "0" "$([[ -f "${S18}/evidence/split-choice.json" ]] && echo 0 || echo 1)"
check "flag on still ran the account listing" "0" "$([[ -f "${S18}/evidence/split-list-user.txt" ]] && echo 0 || echo 1)"
# The full reply keeps its real text; only the printed summary is redacted.
check "diagnostic file keeps the real reason" "0" "$(grep -q '2fb61394b28ecf0f1c0f5a70e2020aba' "${S18}/evidence/enroll-diag-root.txt" && echo 0 || echo 1)"
summary18="$(cat "${S18}/evidence/enroll-diag-root.txt" | wc -l | tr -d ' ')"
check "diagnostic reply file is non-empty evidence" "0" "$([[ -s "${S18}/evidence/enroll-diag-root.txt" ]] && echo 0 || echo 1)"

echo "--- Scenario 19: the diagnostic choice is the ROOT view ---"
check "root choice carries the root authorization" "3" \
    "$(jq -r '.authorization.generation' "${S18}/evidence/split-choice-diag-root.json")"
check "root choice carries root rgb node path" "/dev/video0" \
    "$(jq -r '.expected.rgb.endpoint' "${S18}/evidence/split-choice-diag-root.json")"
check "root choice carries root ir node path" "/dev/video1" \
    "$(jq -r '.expected.ir.endpoint' "${S18}/evidence/split-choice-diag-root.json")"
check "root choice carries no account token endpoint" "0" \
    "$(jq -e '[.expected.rgb.endpoint,.expected.ir.endpoint]|all(startswith("/dev/"))' "${S18}/evidence/split-choice-diag-root.json" >/dev/null && echo 0 || echo 1)"
check "account choice is untouched by diagnostic mode" "a916d7fb038aa603" \
    "$(jq -r '.expected.rgb.endpoint' "${S18}/evidence/split-choice.json")"
check "fresh root listing taken for the diagnostic" "0" \
    "$([[ -f "${S18}/evidence/split-list-diag-root.txt" ]] && echo 0 || echo 1)"

echo "--- Scenario 20: refuses outside the lab directory ---"
S20="$(orch_fixture "${BASE}/s20")"
mkdir -p "${BASE}/outside" "${S20}/lab-other"
# The guard also requires a real socket, so bind one in the lab dir.
python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1])' "${S20}/lab/irlume.sock"
check "socket under the lab dir is accepted" "0" "$(t480_socket_is_in_lab_dir "${S20}/lab" "${S20}/lab/irlume.sock" && echo 0 || echo 1)"
check "socket outside the lab dir refuses" "1" "$(t480_socket_is_in_lab_dir "${S20}/lab" "${BASE}/outside/irlume.sock" && echo 0 || echo 1)"
check "installed socket path refuses" "1" "$(t480_socket_is_in_lab_dir "${S20}/lab" "/run/irlume/irlume.sock" && echo 0 || echo 1)"
check "sibling dir with a shared prefix refuses" "1" "$(t480_socket_is_in_lab_dir "${S20}/lab" "${S20}/lab-other/irlume.sock" && echo 0 || echo 1)"
check "lab dir itself is not a socket" "1" "$(t480_socket_is_in_lab_dir "${S20}/lab" "${S20}/lab" && echo 0 || echo 1)"

echo "--- Scenario 21: peer-dependent mock refuses the wrong view ---"
S21="$(orch_fixture "${BASE}/s21")"
# Build both choices exactly as the two callers would.
root_choice="$(t480_build_root_choice "$(cat "${S21}/list.json")" \
    "$(jq -r '.supervisor_id' "${S21}/list.json")" "$(jq -r '.revision' "${S21}/list.json")" \
    "$(jq -r '.candidates[]|select(.role=="rgb").guard.instance_id' "${S21}/list.json")" \
    "$(jq -r '.candidates[]|select(.role=="rgb").guard.generation' "${S21}/list.json")" \
    "$(jq -r '.candidates[]|select(.role=="ir").guard.instance_id' "${S21}/list.json")" \
    "$(jq -r '.candidates[]|select(.role=="ir").guard.generation' "${S21}/list.json")")"
acct_choice="$(jq -c '{expected:{supervisor_id:.supervisor_id,revision:.revision,
    rgb:(.candidates[]|select(.role=="rgb").guard),ir:(.candidates[]|select(.role=="ir").guard)},
    authorization:.authorization}' "${S21}/user-list.json")"
check "root and account choices differ" "1" "$([[ "${root_choice}" != "${acct_choice}" ]] && echo 1 || echo 0)"

run_mock_enroll() {
    # $1 = fixture root, $2 = choice, $3 = account view ("" for root caller)
    local r="$1" ch="$2" acct="${3:-}"
    (
        export MOCK_LIST_JSON="${r}/list.json"
        export MOCK_USER_LIST_JSON="${r}/user-list.json"
        export MOCK_EVIDENCE="${r}/evidence"
        export MOCK_ENROLL_FIFO=""
        [[ -n "${acct}" ]] && export MOCK_ACCOUNT_VIEW=1
        export PATH="${r}/mocks:/usr/bin:/bin"
        "${r}/mocks/irlume" enroll --user "${USER_NOW}" --split-camera-choice "${ch}"
    ) >/dev/null 2>&1
    echo $?
}
check "root caller sending the ACCOUNT choice is refused" "1" "$(run_mock_enroll "${S21}" "${acct_choice}")"
check "root caller sending the ROOT choice succeeds" "0" "$(run_mock_enroll "${S21}" "${root_choice}")"
check "account caller sending the ACCOUNT choice succeeds" "0" "$(run_mock_enroll "${S21}" "${acct_choice}" acct)"
check "account caller sending the ROOT choice is refused" "1" "$(run_mock_enroll "${S21}" "${root_choice}" acct)"

echo "--- Scenario 22: t480_build_root_choice refuses partial input ---"
S22="$(orch_fixture "${BASE}/s22")"
sup="$(jq -r '.supervisor_id' "${S22}/list.json")"; rev="$(jq -r '.revision' "${S22}/list.json")"
ri="$(jq -r '.candidates[]|select(.role=="rgb").guard.instance_id' "${S22}/list.json")"
rg="$(jq -r '.candidates[]|select(.role=="rgb").guard.generation' "${S22}/list.json")"
ii="$(jq -r '.candidates[]|select(.role=="ir").guard.instance_id' "${S22}/list.json")"
ig="$(jq -r '.candidates[]|select(.role=="ir").guard.generation' "${S22}/list.json")"
check "valid root listing builds a choice" "0" "$(t480_build_root_choice "$(cat "${S22}/list.json")" "$sup" "$rev" "$ri" "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"
check "no authorization refuses" "1" "$(t480_build_root_choice "$(jq 'del(.authorization)' "${S22}/list.json")" "$sup" "$rev" "$ri" "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"
check "zero rgb match refuses" "1" "$(t480_build_root_choice "$(jq 'del(.candidates[]|select(.role=="rgb"))' "${S22}/list.json")" "$sup" "$rev" "$ri" "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"
check "duplicate rgb match refuses" "1" "$(t480_build_root_choice "$(jq '.candidates += [(.candidates[]|select(.role=="rgb"))]' "${S22}/list.json")" "$sup" "$rev" "$ri" "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"
check "wrong instance_id refuses" "1" "$(t480_build_root_choice "$(cat "${S22}/list.json")" "$sup" "$rev" '"ffffffffffffffffffffffffffffffff"' "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"
check "empty root listing refuses" "1" "$(t480_build_root_choice '' "$sup" "$rev" "$ri" "$rg" "$ii" "$ig" >/dev/null && echo 0 || echo 1)"

echo "t480-lab-orchestration-checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" == "0" ]]
