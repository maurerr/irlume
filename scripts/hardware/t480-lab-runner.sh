#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# T480 private-lab runner: the attended hardware stages of
# t480-private-lab.sh, as a literal protected file (never an interpolated
# `bash -c` string). Invoked only via scripts/with-swtpm.sh, which owns
# IRLUME_TCTI for the whole run:
#
#   ./scripts/with-swtpm.sh bash scripts/hardware/t480-lab-runner.sh \
#       LAB_DIR BIN_DIR EVIDENCE_DIR SOCK_PATH TEST_BIN LAB_USER HW_TEST
#
# Standard input is never redirected here: the attended enroll/OS-approval
# prompts keep the terminal. Standard output of each stage is tee'd to its
# evidence file. Sourced by scripts/hardware/tests/t480-lab-script-checks.sh
# for hardware-free unit tests of the pure helpers; only main() executes the
# lab, guarded at the bottom of this file.

set -euo pipefail

STARTUP_TIMEOUT="${T480_STARTUP_TIMEOUT:-180}"
SPLIT_TIMEOUT="${T480_SPLIT_TIMEOUT:-120}"
ENROLL_TIMEOUT="${T480_ENROLL_TIMEOUT:-600}"
TEST_TIMEOUT="${T480_TEST_TIMEOUT:-600}"

# Cleanup state that survives a successful main return: a file-scope global,
# never a function local (locals vanish on return, and the EXIT trap fires
# after main() has returned, which is exactly when the owned child must die).
T480_DAEMON_PID=""

t480_die() {
    echo "t480-lab-runner: $1" >&2
    return 1
}

# Refuse empty, null/empty-object, or multi-line values (zero-match and
# ambiguous-match protection for every jq extraction).
t480_refuse_blank_or_multi() {
    local value="$1"
    if [[ -z "${value}" || "${value}" == "null" || "${value}" == "{}" ]]; then
        return 1
    fi
    if [[ "${value}" == *$'\n'* ]]; then
        return 1
    fi
    return 0
}

# Count exact occurrences of a full test name in --list output.
t480_count_list_matches() {
    local list_text="$1"
    local name="$2"
    printf '%s\n' "${list_text}" | grep -c -F "${name}" || true
}

# Parse one libtest result line into "passed failed ignored", or INVALID.
t480_parse_test_result() {
    local line="$1"
    if [[ "${line}" =~ ^test\ result:\ (ok|FAILED)\.\ ([0-9]+)\ passed\;\ ([0-9]+)\ failed\;\ ([0-9]+)\ ignored ]]; then
        printf '%s %s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        printf 'INVALID\n'
    fi
}

# The attended probe must report exactly one pass, no failures.
t480_require_single_pass() {
    local parsed="$1"
    [[ "${parsed}" == "1 0 0" ]]
}

# Every named file must exist as a non-empty regular file under dir.
t480_require_files() {
    local dir="$1"
    shift
    local name
    for name in "$@"; do
        [[ -f "${dir}/${name}" && -s "${dir}/${name}" ]] || return 1
    done
    return 0
}

# Compose a split mutation guard from verified listing parts.
t480_build_guard() {
    local supervisor="$1"
    local revision="$2"
    local rgb="$3"
    local ir="$4"
    jq -cn --arg sup "${supervisor}" --argjson rev "${revision}" \
        --argjson rgb "${rgb}" --argjson ir "${ir}" \
        '{supervisor_id:$sup,revision:$rev,rgb:$rgb,ir:$ir}'
}

# Resolve exactly one irlumed/irlume bin artifact each from a
# --message-format=json build log. Prints two lines:
#   irlumed <exe-or-empty> <features-csv-or-UNVERIFIED-or-DUPLICATE>
#   irlume  <exe-or-empty> <features-csv-or-UNVERIFIED-or-DUPLICATE>
# A missing features array reports UNVERIFIED (the caller refuses: fail
# closed, never assumed).
t480_resolve_bins() {
    python3 -c '
import json, sys
want = {"irlumed": None, "irlume": None}
feats = {}
with open(sys.argv[1]) as handle:
    for line in handle:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if msg.get("reason") != "compiler-artifact":
            continue
        target = msg.get("target") or {}
        name = target.get("name")
        kinds = target.get("kind") or []
        if name in want and "bin" in kinds:
            exe = msg.get("executable")
            if exe:
                if want[name] is not None:
                    want[name] = "DUPLICATE"
                    feats[name] = "DUPLICATE"
                else:
                    want[name] = exe
                    raw = msg.get("features")
                    feats[name] = ",".join(raw) if isinstance(raw, list) else "UNVERIFIED"
for name in ("irlumed", "irlume"):
    if name in feats:
        reported = feats[name]
    else:
        reported = "UNVERIFIED"
    print(name + " " + (want[name] or "") + " " + reported)
' "$1"
}

# Gate a recorded release feature tree: require the daemon, auth and camera
# t480-experimental records, forbid any test-support record.
t480_check_release_features() {
    local tree_file="$1"
    grep -qF 'irlume-daemon feature "t480-experimental"' "${tree_file}" || return 1
    grep -qF 'irlume-auth feature "t480-experimental"' "${tree_file}" || return 1
    grep -qF 'irlume-camera feature "t480-experimental"' "${tree_file}" || return 1
    if grep -qF 'test-support' "${tree_file}"; then
        return 1
    fi
    return 0
}

# Refuse a feature record that is missing (UNVERIFIED) or lacks the required
# feature. An empty record is valid: it verifies as genuinely empty.
t480_require_feature() {
    local record="$1"
    local feature="$2"
    [[ -n "${record}" && "${record}" != "UNVERIFIED" ]] || return 1
    [[ "${record}" == *"${feature}"* ]]
}

# Refuse a feature record that carries a forbidden feature. An empty
# record passes (verified absent); a missing record (UNVERIFIED) refuses.
t480_forbid_feature() {
    local record="$1"
    local feature="$2"
    [[ "${record}" != "UNVERIFIED" ]] || return 1
    [[ "${record}" != *"${feature}"* ]]
}

# Verify every selected weight against the pinned manifest before launch.
t480_verify_manifest() {
    local models_dir="$1"
    local manifest="$2"
    [[ -f "${manifest}" ]] || return 1
    (cd "${models_dir}" && sha256sum -c "${manifest}")
}

# Opt-in diagnostic: run the split enroll step as root against the lab daemon
# so the Engine's own reason survives the non-root reply projection. Never an
# acceptance path. The flag is off unless explicitly set to 1.
t480_diag_enroll_as_root() {
    [[ "${T480_DIAG_ENROLL_AS_ROOT:-0}" == "1" ]]
}

# The diagnostic must never aim at the installed daemon: refuse unless the
# socket lives under the fresh lab directory this run created.
t480_socket_is_in_lab_dir() {
    local lab_dir="$1" sock_path="$2"
    [[ "${sock_path}" == "${lab_dir}/"* ]] || return 1
    [[ -S "${sock_path}" ]]
}

# A root peer's split enrollment is NOT the account's choice. The daemon's
# resolve_split_enrollment_choice accepts, for peer_uid == 0, only the node
# path (main.rs:5077) and only the authorization held in the selection
# (main.rs:5050), and verify_split_guard independently requires the endpoint to
# be one of the publication's endpoint paths. So the diagnostic choice is built
# from a FRESH root listing, never from the account listing, and every part
# must be present and unambiguous.
t480_build_root_choice() {
    local root_list="$1" sup2="$2" rev2="$3" rgb_iid="$4" rgb_gen="$5" ir_iid="$6" ir_gen="$7"
    local choice
    choice="$(printf '%s' "${root_list}" | jq -c \
        --arg sup "${sup2}" --arg rev "${rev2}" \
        --arg rgb_iid "${rgb_iid}" --argjson rgb_gen "${rgb_gen}" \
        --arg ir_iid "${ir_iid}" --argjson ir_gen "${ir_gen}" '
        def side($role; $iid; $gen):
          [.candidates[] | select(.role == $role
                                  and .guard.instance_id == $iid
                                  and .guard.generation == $gen) | .guard];
        (side("rgb"; $rgb_iid; $rgb_gen)) as $rgb
        | (side("ir"; $ir_iid; $ir_gen)) as $ir
        | if ($rgb | length) != 1 or ($ir | length) != 1 then empty
          else {expected:{supervisor_id:$sup, revision:($rev|tonumber), rgb:$rgb[0], ir:$ir[0]},
                authorization:.authorization}
          end')" || return 1
    [[ -n "${choice}" ]] || return 1
    # Refuse on any missing part rather than sending a partial choice.
    printf '%s' "${choice}" | jq -e '
        (.expected.supervisor_id | type == "string" and length > 0)
        and (.expected.revision | type == "number" and . > 0)
        and (.expected.rgb.instance_id | type == "string" and length > 0)
        and (.expected.rgb.generation | type == "number" and . > 0)
        and (.expected.rgb.endpoint | type == "string" and length > 0)
        and (.expected.ir.instance_id | type == "string" and length > 0)
        and (.expected.ir.generation | type == "number" and . > 0)
        and (.expected.ir.endpoint | type == "string" and length > 0)
        and (.authorization | type == "object")
        and (.authorization.generation | type == "number")
        and (.authorization.token | type == "string" and length > 0)
    ' >/dev/null || return 1
    printf '%s' "${choice}"
}

t480_main() {
    if [[ $# -ne 7 ]]; then
        t480_die "usage: t480-lab-runner.sh LAB_DIR BIN_DIR EVIDENCE_DIR SOCK_PATH TEST_BIN LAB_USER HW_TEST"
        return 1
    fi
    command -v jq >/dev/null || { t480_die "jq is required"; return 1; }
    command -v timeout >/dev/null || { t480_die "timeout is required"; return 1; }
    local lab_dir="$1" bin_dir="$2" evidence_dir="$3" sock_path="$4"
    local test_bin="$5" lab_user="$6" hw_test="$7"

    local required_env="IRLUME_STATE_DIR IRLUME_CONFIG_DIR IRLUME_EMITTER_LOCK_DIR IRLUME_IR_EMITTER_CONF IRLUME_DET_MODEL IRLUME_MODEL IRLUME_MESH_MODEL IRLUME_BLAZE_MODEL IRLUME_VIT_PAD_MODEL IRLUME_PAD_IR_MODEL ORT_DYLIB_PATH IRLUME_NPU IRLUME_MODELS_STRICT IRLUME_KEYRING_DIR IRLUME_RECOVERY_DIR"
    local var
    for var in ${required_env}; do
        if [[ -z "${!var:-}" ]]; then
            t480_die "required lab variable unset: ${var}"
            return 1
        fi
    done

    # One lab environment for the daemon AND every client: explicit
    # assignments in an array (never a word-split string), plus an explicit
    # unset list for inherited camera-selection/force overrides that must not
    # leak in from the operator shell.
    local lab_env=(
        "IRLUME_SOCKET=${sock_path}"
        "IRLUME_STATE_DIR=${IRLUME_STATE_DIR}"
        "IRLUME_CONFIG_DIR=${IRLUME_CONFIG_DIR}"
        "IRLUME_EMITTER_LOCK_DIR=${IRLUME_EMITTER_LOCK_DIR}"
        "IRLUME_IR_EMITTER_CONF=${IRLUME_IR_EMITTER_CONF}"
        "IRLUME_DET_MODEL=${IRLUME_DET_MODEL}"
        "IRLUME_MODEL=${IRLUME_MODEL}"
        "IRLUME_MESH_MODEL=${IRLUME_MESH_MODEL}"
        "IRLUME_BLAZE_MODEL=${IRLUME_BLAZE_MODEL}"
        "IRLUME_VIT_PAD_MODEL=${IRLUME_VIT_PAD_MODEL}"
        "IRLUME_PAD_IR_MODEL=${IRLUME_PAD_IR_MODEL}"
        "ORT_DYLIB_PATH=${ORT_DYLIB_PATH}"
        "IRLUME_NPU=${IRLUME_NPU}"
        "IRLUME_MODELS_STRICT=${IRLUME_MODELS_STRICT}"
        "IRLUME_KEYRING_DIR=${IRLUME_KEYRING_DIR}"
        "IRLUME_RECOVERY_DIR=${IRLUME_RECOVERY_DIR}"
    )
    local lab_unset=(
        -u IRLUME_RGB_DEVICE -u IRLUME_IR_DEVICE -u IRLUME_FORCE_NO_IR
        -u IRLUME_TEST_ALLOW_VIRTUAL_CAMERA -u IRLUME_DEV
    )

    # The swtpm wrapper preserves the caller environment apart from
    # IRLUME_TCTI, but trust is verified, not assumed.
    if [[ "${IRLUME_EMITTER_LOCK_DIR}" != "${lab_dir}/emitter-lock" ]] || [[ ! -d "${IRLUME_EMITTER_LOCK_DIR}" ]]; then
        t480_die "IRLUME_EMITTER_LOCK_DIR did not propagate (${IRLUME_EMITTER_LOCK_DIR:-<unset>})"
        return 1
    fi
    if [[ -z "${IRLUME_TCTI:-}" ]]; then
        t480_die "IRLUME_TCTI unset: the swtpm wrapper must own TPM selection"
        return 1
    fi

    t480_cleanup() {
        if [[ -n "${T480_DAEMON_PID}" ]] && kill -0 "${T480_DAEMON_PID}" 2>/dev/null; then
            kill "${T480_DAEMON_PID}" 2>/dev/null || true
            local i
            for i in $(seq 1 50); do
                kill -0 "${T480_DAEMON_PID}" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "${T480_DAEMON_PID}" 2>/dev/null; then
                kill -9 "${T480_DAEMON_PID}" 2>/dev/null || true
            fi
            wait "${T480_DAEMON_PID}" 2>/dev/null || true
        fi
        T480_DAEMON_PID=""
    }
    # Signal handlers terminate the run: they reap the owned child, then exit
    # with the conventional status instead of resuming the workflow. The EXIT
    # trap covers normal return and error paths (cleanup is idempotent).
    trap 't480_cleanup; exit 130' INT
    trap 't480_cleanup; exit 143' TERM
    trap t480_cleanup EXIT

    # The daemon reads its socket path from IRLUME_SOCKET (no --socket flag).
    env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlumed" >"${evidence_dir}/irlumed.log" 2>&1 &
    T480_DAEMON_PID=$!

    # One bounded deadline covers socket appearance AND completed startup.
    # Readiness is the real completed-startup state (.data.daemon == "running"
    # in public status JSON), which proves models are loaded, the engine is
    # built, and the worker is attached. Do not use socket existence, exit 0,
    # or split status/list alone: those succeed during Starting while background
    # model loading is still in progress.
    # Read the override at call time, not at source time: the check suite
    # sources this file once and then sets the per-scenario value.
    local startup_timeout="${T480_STARTUP_TIMEOUT:-${STARTUP_TIMEOUT}}"
    local startup_deadline=$(( $(date +%s) + startup_timeout ))
    local daemon_state=""
    local socket_bound=0
    while [[ $(date +%s) -lt ${startup_deadline} ]]; do
        kill -0 "${T480_DAEMON_PID}" 2>/dev/null || { t480_die "daemon died during startup"; return 1; }
        if [[ -S "${sock_path}" ]]; then
            socket_bound=1
            local status_json
            if status_json="$(timeout 5 env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" status --json 2>/dev/null)"; then
                daemon_state="$(printf '%s' "${status_json}" | jq -r '.data.daemon // empty')" || {
                    t480_die "jq failed during readiness parse"
                    return 1
                }
                if [[ "${daemon_state}" == "running" ]]; then
                    printf '%s\n' "${status_json}" >"${evidence_dir}/status-ready.json"
                    break
                fi
            fi
        fi
        sleep 1
    done
    if [[ "${daemon_state}" != "running" ]]; then
        if [[ "${socket_bound}" -eq 0 ]]; then
            t480_die "daemon never bound ${sock_path} within ${startup_timeout}s"
        fi
        t480_die "daemon failed to reach running state within ${startup_timeout}s (last state: '${daemon_state:-unreachable}')"
        return 1
    fi

    timeout "${SPLIT_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split list >"${evidence_dir}/split-list-root.txt" 2>&1
    local root_list supervisor revision rgb_guard ir_guard rgb_facts ir_facts guard
    root_list="$(cat "${evidence_dir}/split-list-root.txt")"

    # Distinct diagnostic when candidates list is empty after engine ready:
    # do not confuse inventory unreadiness or missing cameras with a startup hang.
    local num_candidates
    num_candidates="$(printf '%s' "${root_list}" | jq '.candidates | length' 2>/dev/null || echo 0)"
    if [[ "${num_candidates}" -eq 0 ]]; then
        local store_state
        store_state="$(printf '%s' "${root_list}" | jq -r '.store_state // "unknown"')"
        t480_die "inventory diagnostic: 0 candidates listed after engine ready (store_state: ${store_state}); no eligible endpoints discovered in inventory"
        return 1
    fi

    supervisor="$(printf '%s' "${root_list}" | jq -r .supervisor_id)"
    revision="$(printf '%s' "${root_list}" | jq -r .revision)"
    rgb_guard="$(printf '%s' "${root_list}" | jq -c '.candidates[] | select(.role=="rgb" and (.facts.Root.identity | contains("5986:2113"))) | .guard')"
    ir_guard="$(printf '%s' "${root_list}" | jq -c '.candidates[] | select(.role=="ir" and (.facts.Root.identity | contains("5986:1141"))) | .guard')"
    rgb_facts="$(printf '%s' "${root_list}" | jq -c '.candidates[] | select(.role=="rgb" and (.facts.Root.identity | contains("5986:2113"))) | .facts.Root')"
    ir_facts="$(printf '%s' "${root_list}" | jq -c '.candidates[] | select(.role=="ir" and (.facts.Root.identity | contains("5986:1141"))) | .facts.Root')"
    for value in "${supervisor}" "${revision}" "${rgb_guard}" "${ir_guard}" "${rgb_facts}" "${ir_facts}"; do
        t480_refuse_blank_or_multi "${value}" || { t480_die "5986:2113/5986:1141 pair not listed among candidates (eligibility refusal)"; return 1; }
    done
    guard="$(t480_build_guard "${supervisor}" "${revision}" "${rgb_guard}" "${ir_guard}")"
    # Progress-gating pipelines check PIPESTATUS explicitly: neither set -e
    # nor pipefail can be assumed when this function is sourced and called
    # from another shell's condition, and tee's own status must never mask
    # the stage behind it.
    timeout "${SPLIT_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split add --guard "${guard}" --rgb "${rgb_facts}" --ir "${ir_facts}" 2>&1 | tee "${evidence_dir}/split-add.txt"
    [[ "${PIPESTATUS[0]}" == "0" ]] || { t480_die "split add failed"; return 1; }
    timeout "${SPLIT_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split list >"${evidence_dir}/split-list-root-2.txt" 2>&1
    local root_list2 guard2 pair_key
    root_list2="$(cat "${evidence_dir}/split-list-root-2.txt")"
    guard2="$(printf '%s' "${root_list2}" | jq -c '{supervisor_id:.supervisor_id,revision:.revision,rgb:(.candidates[] | select(.role=="rgb" and (.facts.Root.identity | contains("5986:2113"))) | .guard),ir:(.candidates[] | select(.role=="ir" and (.facts.Root.identity | contains("5986:1141"))) | .guard)}')"
    pair_key="$(printf '%s' "${root_list2}" | jq -r '.records[] | select((.rgb.Root.identity // "" | contains("5986:2113")) and (.ir.Root.identity // "" | contains("5986:1141"))) | .key // empty')"
    t480_refuse_blank_or_multi "${guard2}" || { t480_die "fresh guard missing after add (zero-match refused)"; return 1; }
    t480_refuse_blank_or_multi "${pair_key}" || { t480_die "pair key missing after add (zero-match refused)"; return 1; }
    timeout "${SPLIT_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split select "${pair_key}" --guard "${guard2}" 2>&1 | tee "${evidence_dir}/split-select.txt"
    [[ "${PIPESTATUS[0]}" == "0" ]] || { t480_die "split select failed"; return 1; }

    # The account listing carries endpoint tokens (a root listing shows node
    # paths, which a non-root enroll refuses), so the choice is built from the
    # enrolling account's own listing, back to back with enroll. The two views
    # agree on supervisor/revision and on each candidate's role, instance_id
    # and generation, but the endpoint is a node path in the root view and an
    # account token in the account view, so whole-guard equality never matches.
    # Map by role + instance_id + generation within the same
    # supervisor/revision, and copy the COMPLETE account guard (endpoint
    # included) into expected. Never substitute a root endpoint: that would
    # hand enroll a node path the account view deliberately withholds.
    timeout "${SPLIT_TIMEOUT}" sudo -u "${lab_user}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split list >"${evidence_dir}/split-list-user.txt" 2>&1
    local user_list choice choice_expected choice_authorization
    local sup2 rev2 rgb_iid rgb_gen ir_iid ir_gen
    user_list="$(cat "${evidence_dir}/split-list-user.txt")"
    sup2="$(printf '%s' "${guard2}" | jq -r '.supervisor_id // empty')"
    rev2="$(printf '%s' "${guard2}" | jq -r '.revision // empty')"
    rgb_iid="$(printf '%s' "${guard2}" | jq -r '.rgb.instance_id // empty')"
    rgb_gen="$(printf '%s' "${guard2}" | jq -r '.rgb.generation // empty')"
    ir_iid="$(printf '%s' "${guard2}" | jq -r '.ir.instance_id // empty')"
    ir_gen="$(printf '%s' "${guard2}" | jq -r '.ir.generation // empty')"
    # Every identifying field must be present and non-null on the root side,
    # or the mapping below would silently match on an absent key.
    local ident
    for ident in "${sup2}" "${rev2}" "${rgb_iid}" "${rgb_gen}" "${ir_iid}" "${ir_gen}"; do
        t480_refuse_blank_or_multi "${ident}" || { t480_die "root guard identifying field missing or null (mapping cannot be built)"; return 1; }
    done

    # Same supervisor and revision, or the account view describes a different
    # store and its candidates are not the pair that was just selected.
    local user_sup user_rev
    user_sup="$(printf '%s' "${user_list}" | jq -r '.supervisor_id // empty')"
    user_rev="$(printf '%s' "${user_list}" | jq -r '.revision // empty')"
    if [[ "${user_sup}" != "${sup2}" || "${user_rev}" != "${rev2}" ]]; then
        t480_die "account listing supervisor/revision mismatch (${user_sup:-none}/${user_rev:-none} vs ${sup2}/${rev2})"
        return 1
    fi

    # Exactly one account candidate per role may carry the shared identity;
    # zero means the account cannot see that camera, more than one is ambiguous.
    local rgb_n ir_n rgb_g3 ir_g3
    rgb_n="$(printf '%s' "${user_list}" | jq --arg iid "${rgb_iid}" --argjson gen "${rgb_gen}" '[.candidates[] | select(.role=="rgb" and .guard.instance_id==$iid and .guard.generation==$gen)] | length')"
    ir_n="$(printf '%s' "${user_list}" | jq --arg iid "${ir_iid}" --argjson gen "${ir_gen}" '[.candidates[] | select(.role=="ir" and .guard.instance_id==$iid and .guard.generation==$gen)] | length')"
    if [[ "${rgb_n}" != "1" || "${ir_n}" != "1" ]]; then
        t480_die "account candidate identity match not unique for the 5986 pair (rgb=${rgb_n:-0}, ir=${ir_n:-0})"
        return 1
    fi
    # COMPLETE account guards, each keeping its own account endpoint.
    rgb_g3="$(printf '%s' "${user_list}" | jq -c --arg iid "${rgb_iid}" --argjson gen "${rgb_gen}" 'first(.candidates[] | select(.role=="rgb" and .guard.instance_id==$iid and .guard.generation==$gen) | .guard)')"
    ir_g3="$(printf '%s' "${user_list}" | jq -c --arg iid "${ir_iid}" --argjson gen "${ir_gen}" 'first(.candidates[] | select(.role=="ir" and .guard.instance_id==$iid and .guard.generation==$gen) | .guard)')"
    # The account's own authorization proof, copied unchanged.
    choice="$(printf '%s' "${user_list}" | jq -c --arg sup "${sup2}" --arg rev "${rev2}" --argjson rgb "${rgb_g3}" --argjson ir "${ir_g3}" '{expected:{supervisor_id:$sup,revision:($rev|tonumber),rgb:$rgb,ir:$ir},authorization:.authorization}')"
    t480_refuse_blank_or_multi "${choice}" || { t480_die "account choice for the 5986 pair missing (zero-match refused)"; return 1; }
    # Split enrollment is the authorization-bearing stage: unlike the initial
    # add, which needs no authorization for an absent store, the account
    # enrollment choice must carry the account's own authorization. Validate
    # the two members separately, since a non-empty choice object with
    # "authorization":null would otherwise pass the whole-object check above.
    choice_expected="$(printf '%s' "${choice}" | jq -c '.expected')"
    choice_authorization="$(printf '%s' "${choice}" | jq -c '.authorization')"
    t480_refuse_blank_or_multi "${choice_expected}" || { t480_die "account choice expected pair missing (zero-match refused)"; return 1; }
    t480_refuse_blank_or_multi "${choice_authorization}" || { t480_die "account split authorization missing (enrollment requires authorization)"; return 1; }
    # The proof must be a real object carrying both halves, and each expected
    # guard must keep the account endpoint that was matched, not a node path.
    printf '%s' "${choice_authorization}" | jq -e 'type=="object" and (.generation|type=="number") and (.token|type=="string" and length>0)' >/dev/null || {
        t480_die "account split authorization is not a usable proof (generation and token required)"
        return 1
    }
    printf '%s' "${choice_expected}" | jq -e '.rgb.endpoint != null and .ir.endpoint != null and (.rgb.endpoint|startswith("/dev/")|not) and (.ir.endpoint|startswith("/dev/")|not)' >/dev/null || {
        t480_die "expected guards do not carry account endpoints (root node path in the enrollment choice)"
        return 1
    }
printf '%s' "${choice}" >"${evidence_dir}/split-choice.json"

    local diag=0
    if t480_diag_enroll_as_root; then
        # Refuse before anything runs if the socket is not this run's lab one.
        t480_socket_is_in_lab_dir "${lab_dir}" "${sock_path}" || {
            t480_die "diagnostic enroll refused: ${sock_path} is not inside this run's lab directory"
            return 1
        }
        diag=1
    fi

    if [[ "${diag}" == "1" ]]; then
        # DIAGNOSTIC ONLY, NOT ACCEPTANCE. A root peer is NOT the account: the
        # daemon accepts root's node-path endpoints and the selection's proof,
        # so the choice is rebuilt from a FRESH root listing taken immediately
        # before the enroll. The account listing above stays untouched.
        echo "DIAGNOSTIC - not acceptance: split enroll as root, Authenticate probe skipped"
        local fresh_root="${evidence_dir}/split-list-diag-root.txt"
        timeout "${SPLIT_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" split list >"${fresh_root}" 2>&1
        local diag_choice
        diag_choice="$(t480_build_root_choice "$(cat "${fresh_root}")" "${sup2}" "${rev2}" \
            "${rgb_iid}" "${rgb_gen}" "${ir_iid}" "${ir_gen}")" || {
            t480_die "diagnostic root choice is missing or ambiguous (refused)"
            return 1
        }
        printf '%s' "${diag_choice}" >"${evidence_dir}/split-choice-diag-root.json"

        local enroll_full="${evidence_dir}/enroll-diag-root.txt"
        : >"${enroll_full}"
        chmod 0600 "${enroll_full}"
        timeout "${ENROLL_TIMEOUT}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" enroll --user "${lab_user}" --split-camera-choice "${diag_choice}" >"${enroll_full}" 2>&1
        local enroll_rc=$?
        # Console carries NO reply text: Engine text can name PCI addresses,
        # USB port chains, serials and vid:pid, which a hex/dev-path filter does
        # not cover. Only a line count and the 0600 file's path are printed.
        local reply_lines
        reply_lines="$(wc -l <"${enroll_full}" | tr -d ' ')"
        printf 'DIAGNOSTIC - not acceptance: root split enroll exit %s, reply lines %s, full reply in %s\n' \
            "${enroll_rc}" "${reply_lines}" "${enroll_full}"
        [[ "${enroll_rc}" == "0" ]] || return "${enroll_rc}"
        # No --list gate, no probe: a diagnostic run is never an acceptance run.
        return 0
    fi

    # Explicit split-enrollment entry point; needs the account's OS approval
    # at the attended terminal (stdin is preserved for it).
    timeout "${ENROLL_TIMEOUT}" sudo -u "${lab_user}" env "${lab_unset[@]}" "${lab_env[@]}" "${bin_dir}/irlume" enroll --user "${lab_user}" --split-camera-choice "${choice}" 2>&1 | tee "${evidence_dir}/enroll.txt"
    [[ "${PIPESTATUS[0]}" == "0" ]] || { t480_die "enroll failed"; return 1; }

    # --list gate: exactly one full test name, or nothing runs.
    local list_out matches
    list_out="$(sudo -u "${lab_user}" env "${lab_unset[@]}" "${lab_env[@]}" IRLUME_T480_TEST_USER="${lab_user}" "${test_bin}" --list 2>&1)"
    printf '%s\n' "${list_out}" >"${evidence_dir}/hw-test-list.txt"
    matches="$(t480_count_list_matches "${list_out}" "${hw_test}")"
    if [[ "${matches}" != "1" ]]; then
        t480_die "expected exactly one listed test, found ${matches} (zero/duplicate refused)"
        return 1
    fi
    sudo -u "${lab_user}" env "${lab_unset[@]}" "${lab_env[@]}" IRLUME_T480_TEST_USER="${lab_user}" timeout "${TEST_TIMEOUT}" "${test_bin}" --exact "${hw_test}" --ignored --nocapture 2>&1 | tee "${evidence_dir}/hw-test-run.txt"
    [[ "${PIPESTATUS[0]}" == "0" ]] || { t480_die "hardware test process failed"; return 1; }
    local result_line parsed
    result_line="$(grep -E '^test result:' "${evidence_dir}/hw-test-run.txt" | tail -n 1 || true)"
    parsed="$(t480_parse_test_result "${result_line}")"
    if ! t480_require_single_pass "${parsed}"; then
        t480_die "hardware test did not report exactly one pass (got: ${result_line:-<none>})"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    t480_main "$@"
fi
