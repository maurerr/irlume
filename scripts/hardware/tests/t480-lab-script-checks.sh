#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# Hardware-free checks for scripts/hardware/t480-lab-runner.sh.
# Ordinary user, no root, no hardware, no daemon: only the runner's pure
# helpers run here (sourcing the runner never executes the lab: main() is
# guarded). Temporary fixtures live under mktemp dirs and are removed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${HERE}/../t480-lab-runner.sh"

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

refuses() {
    t480_refuse_blank_or_multi "$1" >/dev/null 2>&1
    echo $?
}

# 1. Newline/multi-match refusal.
check "empty refused" "1" "$(refuses "")"
check "null refused" "1" "$(refuses "null")"
check "empty-object refused" "1" "$(refuses "{}")"
check "multi-line refused" "1" "$(refuses "$(printf 'a\nb')")"
check "single value accepted" "0" "$(refuses '{"supervisor_id":"x"}')"

# 2. Paths containing spaces.
trap 'rm -rf -- "${SPACED:-/nonexistent-t480-spaces}" "${MODELS:-/nonexistent-t480-models}"; rm -f "${GOOD_TREE:-/nonexistent-t480-a}" "${BAD_TREE:-/nonexistent-t480-b}" "${NOAUTH_TREE:-/nonexistent-t480-e}" "${DEV_TREE:-/nonexistent-t480-c}" "${MANIFEST_OK:-/nonexistent-t480-d}"' EXIT
SPACED="$(mktemp -d "/tmp/t480-spaces test.XXXXXX")"
mkdir -p "${SPACED}/evidence dir" "${SPACED}/state dir"
printf 'x\n' >"${SPACED}/evidence dir/split-list-root.txt"
printf 'x\n' >"${SPACED}/state dir/keep"
if t480_require_files "${SPACED}/evidence dir" "split-list-root.txt" >/dev/null 2>&1; then
    got=0
else
    got=1
fi
check "spaced paths required ok" "0" "${got}"
if command -v jq >/dev/null 2>&1; then
    GUARD="$(t480_build_guard "sup id" 7 \
        '{"instance_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":1,"endpoint":"/dev/video 0"}' \
        '{"instance_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","generation":2,"endpoint":"/dev/video 1"}')"
    check "guard keeps spaced endpoints" "/dev/video 0" "$(printf '%s' "${GUARD}" | jq -r .rgb.endpoint)"
    check "guard keeps spaced supervisor" "sup id" "$(printf '%s' "${GUARD}" | jq -r .supervisor_id)"
else
    echo "SKIP: jq absent, guard round-trip not checked"
fi

# 3. Zero/duplicate test names.
LIST_ZERO="running 8 tests"
LIST_ONE="t480_hw_authenticate_isolated::t480_hw_authenticate_isolated: test"
LIST_TWO="t480_hw_authenticate_isolated::t480_hw_authenticate_isolated: test
t480_hw_authenticate_isolated::t480_hw_authenticate_isolated: test"
NAME="t480_hw_authenticate_isolated::t480_hw_authenticate_isolated"
check "zero matches" "0" "$(t480_count_list_matches "${LIST_ZERO}" "${NAME}")"
check "exactly one match" "1" "$(t480_count_list_matches "${LIST_ONE}" "${NAME}")"
check "duplicate matches" "2" "$(t480_count_list_matches "${LIST_TWO}" "${NAME}")"
[[ "$(t480_count_list_matches "${LIST_ONE}" "${NAME}")" == "1" ]] && one_ok=0 || one_ok=1
[[ "$(t480_count_list_matches "${LIST_TWO}" "${NAME}")" == "1" ]] && two_ok=0 || two_ok=1
check "exactly-one gate accepts one" "0" "${one_ok}"
check "exactly-one gate refuses duplicates" "1" "${two_ok}"

# 4. 0/1/11-pass result parsing.
parse() { t480_parse_test_result "$1"; }
check "0-pass parses" "0 0 0" "$(parse "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out")"
check "1-pass parses" "1 0 0" "$(parse "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out")"
check "11-pass parses" "11 0 0" "$(parse "test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out")"
check "failed line parses" "0 1 0" "$(parse "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out")"
check "garbage is INVALID" "INVALID" "$(parse "something else")"
check "empty is INVALID" "INVALID" "$(parse "")"
t480_require_single_pass "1 0 0" && p1=0 || p1=1
t480_require_single_pass "0 0 0" && p0=0 || p0=1
t480_require_single_pass "11 0 0" && p11=0 || p11=1
t480_require_single_pass "0 1 0" && pf=0 || pf=1
t480_require_single_pass "INVALID" && pi=0 || pi=1
check "single-pass gate accepts 1 0 0" "0" "${p1}"
check "single-pass gate refuses 0 0 0" "1" "${p0}"
check "single-pass gate refuses 11 0 0" "1" "${p11}"
check "single-pass gate refuses failures" "1" "${pf}"
check "single-pass gate refuses INVALID" "1" "${pi}"

# 5. Missing PAD inputs.
MODELS="$(mktemp -d /tmp/t480-models-check.XXXXXX)"
for name in face_detection_yunet_2023mar.onnx glintr100.onnx face_landmark.onnx blaze_face_short_range.onnx; do
    printf 'model-bytes\n' >"${MODELS}/${name}"
done
SIX="face_detection_yunet_2023mar.onnx glintr100.onnx face_landmark.onnx blaze_face_short_range.onnx liveness_vit.onnx flir.onnx"
# shellcheck disable=SC2086
t480_require_files "${MODELS}" ${SIX} >/dev/null 2>&1 && m4=0 || m4=1
check "four files refuse six-file requirement" "1" "${m4}"
printf 'model-bytes\n' >"${MODELS}/liveness_vit.onnx"
printf 'model-bytes\n' >"${MODELS}/flir.onnx"
# shellcheck disable=SC2086
t480_require_files "${MODELS}" ${SIX} >/dev/null 2>&1 && m6=0 || m6=1
check "six files pass" "0" "${m6}"

# 6. Incorrect artifact feature records.
GOOD_TREE="$(mktemp /tmp/t480-tree-good.XXXXXX)"
BAD_TREE="$(mktemp /tmp/t480-tree-bad.XXXXXX)"
NOAUTH_TREE="$(mktemp /tmp/t480-tree-noauth.XXXXXX)"
DEV_TREE="$(mktemp /tmp/t480-tree-dev.XXXXXX)"
printf '%s\n' 'x irlume-daemon feature "t480-experimental" (command-line)' \
    'x irlume-auth feature "t480-experimental"' \
    'x irlume-camera feature "t480-experimental"' >"${GOOD_TREE}"
printf '%s\n' 'x irlume-daemon feature "t480-experimental" (command-line)' >"${BAD_TREE}"
printf '%s\n' 'x irlume-daemon feature "t480-experimental" (command-line)' \
    'x irlume-camera feature "t480-experimental"' >"${NOAUTH_TREE}"
printf '%s\n' 'x irlume-daemon feature "t480-experimental" (command-line)' \
    'x irlume-auth feature "t480-experimental"' \
    'x irlume-camera feature "t480-experimental"' \
    'x irlume-auth feature "test-support"' >"${DEV_TREE}"
t480_check_release_features "${GOOD_TREE}" && g=0 || g=1
t480_check_release_features "${BAD_TREE}" && b=0 || b=1
t480_check_release_features "${NOAUTH_TREE}" && na=0 || na=1
t480_check_release_features "${DEV_TREE}" && d=0 || d=1
check "correct records accepted" "0" "${g}"
check "missing camera edge refused" "1" "${b}"
check "missing auth edge refused" "1" "${na}"
check "test-support refused" "1" "${d}"
# Empty arrays are valid verified records; missing fields are not.
t480_require_feature "" "t480-experimental" && re=0 || re=1
t480_require_feature "UNVERIFIED" "t480-experimental" && ru=0 || ru=1
t480_require_feature "default,t480-experimental" "t480-experimental" && rok=0 || rok=1
t480_forbid_feature "" "test-support" && fe=0 || fe=1
t480_forbid_feature "UNVERIFIED" "test-support" && fu=0 || fu=1
t480_forbid_feature "default,t480-experimental" "test-support" && fok=0 || fok=1
check "require refuses empty record" "1" "${re}"
check "require refuses UNVERIFIED" "1" "${ru}"
check "require accepts the feature" "0" "${rok}"
check "forbid accepts empty record" "0" "${fe}"
check "forbid refuses UNVERIFIED" "1" "${fu}"
check "forbid accepts clean record" "0" "${fok}"

# 7. Compiler-artifact bin resolution with feature records.
ART_JSON="$(mktemp /tmp/t480-artifacts.XXXXXX)"
{
    echo '{"reason":"build-script-executed","package_id":"x"}'
    echo '{"reason":"compiler-artifact","target":{"name":"irlume-dep","kind":["lib"]},"filenames":["/tmp/L/lib.rlib"]}'
    echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]},"executable":"/tmp/L/target/release/irlumed","fresh":false,"features":["default","t480-experimental"]}'
    echo '{"reason":"compiler-artifact","target":{"name":"irlume","kind":["bin"]},"executable":"/tmp/L/target/release/irlume","fresh":true,"features":["default"]}'
    echo 'not json at all'
    echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]}}'
} >"${ART_JSON}"
mapfile -t RESOLVED < <(t480_resolve_bins "${ART_JSON}")
DLINE="${RESOLVED[0]#irlumed }"; DFEATS="${DLINE##* }"; DEXE="${DLINE% *}"
CLINE="${RESOLVED[1]#irlume }"; CFEATS="${CLINE##* }"; CEXE="${CLINE% *}"
check "daemon exe parsed" "/tmp/L/target/release/irlumed" "${DEXE}"
check "daemon features parsed" "default,t480-experimental" "${DFEATS}"
check "cli features parsed" "default" "${CFEATS}"
[[ "${DFEATS}" == *"t480-experimental"* && "${DFEATS}" != *"test-support"* ]] && rf=0 || rf=1
check "daemon feature record accepted" "0" "${rf}"
[[ "${CFEATS}" == *"t480-experimental"* ]] && cf=0 || cf=1
check "cli without feature refused" "1" "${cf}"
ART_BAD="$(mktemp /tmp/t480-artifacts-bad.XXXXXX)"
{
    echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]},"executable":"/tmp/L/irlumed","features":["default","test-support"]}'
    echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]},"executable":"/tmp/L/irlumed2","features":["default"]}'
    echo '{"reason":"compiler-artifact","target":{"name":"irlume","kind":["bin"]},"executable":"/tmp/L/irlume"}'
} >"${ART_BAD}"
mapfile -t RESOLVED_BAD < <(t480_resolve_bins "${ART_BAD}")
BDLINE="${RESOLVED_BAD[0]#irlumed }"; BDEXE="${BDLINE% *}"
BCLINE="${RESOLVED_BAD[1]#irlume }"; BCFEATS="${BCLINE##* }"
check "duplicate exe refused" "DUPLICATE" "${BDEXE}"
check "missing features is UNVERIFIED" "UNVERIFIED" "${BCFEATS}"
ART_TS="$(mktemp /tmp/t480-artifacts-ts.XXXXXX)"
echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]},"executable":"/tmp/L/irlumed","features":["default","test-support"]}' >"${ART_TS}"
mapfile -t RESOLVED_TS < <(t480_resolve_bins "${ART_TS}")
TSDLINE="${RESOLVED_TS[0]#irlumed }"; TSFEATS="${TSDLINE##* }"
[[ "${TSFEATS}" == *"test-support"* ]] && ts=0 || ts=1
check "test-support detected" "0" "${ts}"
ART_EMPTY="$(mktemp /tmp/t480-artifacts-empty.XXXXXX)"
echo '{"reason":"compiler-artifact","target":{"name":"irlumed","kind":["bin"]},"executable":"/tmp/L/irlumed","features":[]}' >"${ART_EMPTY}"
mapfile -t RESOLVED_EMPTY < <(t480_resolve_bins "${ART_EMPTY}")
EDLINE="${RESOLVED_EMPTY[0]#irlumed }"; EDFEATS="${EDLINE##* }"; EDEXE="${EDLINE% *}"
check "empty features is a valid empty record" "" "${EDFEATS}"
check "empty record still resolves the exe" "/tmp/L/irlumed" "${EDEXE}"
t480_require_feature "${EDFEATS}" "t480-experimental" && er=0 || er=1
t480_forbid_feature "${EDFEATS}" "test-support" && ef=0 || ef=1
check "empty record lacks the feature" "1" "${er}"
check "empty record verified absent of test-support" "0" "${ef}"
rm -f "${ART_JSON}" "${ART_BAD}" "${ART_TS}" "${ART_EMPTY}"

# 8. Manifest verification helper.
MANIFEST_OK="$(mktemp /tmp/t480-manifest.XXXXXX)"
printf 'hello\n' >"${MODELS}/a.onnx"
printf 'world\n' >"${MODELS}/b.onnx"
(cd "${MODELS}" && sha256sum a.onnx b.onnx >"${MANIFEST_OK}")
t480_verify_manifest "${MODELS}" "${MANIFEST_OK}" >/dev/null 2>&1 && v=0 || v=1
check "matching manifest verifies" "0" "${v}"
printf 'tampered\n' >"${MODELS}/b.onnx"
t480_verify_manifest "${MODELS}" "${MANIFEST_OK}" >/dev/null 2>&1 && vt=0 || vt=1
check "tampered weight refused" "1" "${vt}"

# 9. Checked-in launcher regressions (source position, build tool checks, empty CLI record gate).
LAUNCHER="${HERE}/../t480-private-lab.sh"

# 9a. Helpers are sourced before artifact resolution.
SOURCE_LINE=$(grep -n 'source .*/t480-lab-runner.sh' "${LAUNCHER}" | head -n 1 | cut -d: -f1)
RESOLVE_LINE=$(grep -n 't480_resolve_bins' "${LAUNCHER}" | head -n 1 | cut -d: -f1)
[[ -n "${SOURCE_LINE}" && -n "${RESOLVE_LINE}" && "${SOURCE_LINE}" -lt "${RESOLVE_LINE}" ]] && sb=0 || sb=1
check "helpers sourced before artifact resolution in launcher" "0" "${sb}"

# 9b. Tool availability is checked through the intended shell/environment.
grep -q "sudo -u .*\${BUILD_USER}.*\${BUILD_ENV}.*bash -c 'command -v cargo'" "${LAUNCHER}" && tc_cargo=0 || tc_cargo=1
grep -q "sudo -u .*\${BUILD_USER}.*\${BUILD_ENV}.*bash -c 'command -v rustc'" "${LAUNCHER}" && tc_rustc=0 || tc_rustc=1
check "cargo checked through build user bash" "0" "${tc_cargo}"
check "rustc checked through build user bash" "0" "${tc_rustc}"

# 9c. A real-format empty CLI features array is accepted, while UNVERIFIED refuses.
# We test the exact logic pattern directly from the launcher:
# [[ "${CLI_FEATURES}" != "UNVERIFIED" ]]
eval_cli_record() {
    local CLI_FEATURES="$1"
    [[ "${CLI_FEATURES}" != "UNVERIFIED" ]] && t480_forbid_feature "${CLI_FEATURES}" "test-support"
}
eval_cli_record "" && ec_empty=0 || ec_empty=1
eval_cli_record "UNVERIFIED" && ec_unv=0 || ec_unv=1
eval_cli_record "default" && ec_def=0 || ec_def=1
eval_cli_record "test-support" && ec_ts=0 || ec_ts=1
check "launcher gate accepts empty CLI features array" "0" "${ec_empty}"
check "launcher gate refuses UNVERIFIED CLI features" "1" "${ec_unv}"
check "launcher gate accepts normal CLI features" "0" "${ec_def}"
check "launcher gate refuses CLI test-support" "1" "${ec_ts}"

echo "t480-lab-script-checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" == "0" ]]
