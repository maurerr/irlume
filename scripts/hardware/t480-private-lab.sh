#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# T480 YUYV experimental private lab (PREPARE ONLY - do not execute without a
# separately approved attended session; this task performs no hardware, root
# lab, install, commit, push or PR action).
#
# Usage (as root, from the t480-private-experimental worktree root):
#   ./scripts/hardware/t480-private-lab.sh <models-dir>
#
# <models-dir> must already contain the six ONNX weights below, verified
# against the pinned models/SHA256SUMS before launch. Nothing is downloaded:
# a missing or mismatched file refuses the run. ORT_DYLIB_PATH must name an
# existing libonnxruntime in the operator environment.
#
# Client access model: root runs the candidate daemon and the `split`
# management commands; the target account (IRLUME_T480_TEST_USER) runs
# `split list` (for its endpoint-token choice), `enroll` (needs its own OS
# approval at the attended terminal) and the hardware test binary. The daemon
# chmods its socket to 0666, so the lab directory carries o+x and the test
# account can reach the socket without any installed-system change.
#
# Attended stages live in the literal scripts/hardware/t480-lab-runner.sh
# (never an interpolated `bash -c` string); standard input is never
# redirected, so enroll/OS-approval prompts keep the terminal.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "t480-private-lab: must run as root" >&2
    exit 1
fi
if [[ $# -ne 1 ]]; then
    echo "t480-private-lab: usage: $0 <models-dir>" >&2
    exit 1
fi
MODELS_DIR="$1"
: "${IRLUME_T480_TEST_USER:?t480-private-lab: IRLUME_T480_TEST_USER must be set}"
: "${ORT_DYLIB_PATH:?t480-private-lab: ORT_DYLIB_PATH must name an existing libonnxruntime}"
if [[ ! -f "${ORT_DYLIB_PATH}" ]]; then
    echo "t480-private-lab: ORT_DYLIB_PATH does not exist: ${ORT_DYLIB_PATH}" >&2
    exit 1
fi
# Complete ONNX set from the daemon loader (main.rs model resolution),
# including the two default-on PAD cues. PAD must never be disabled to
# proceed; a missing PAD weight refuses here instead.
REQUIRED_MODELS="face_detection_yunet_2023mar.onnx glintr100.onnx face_landmark.onnx blaze_face_short_range.onnx liveness_vit.onnx flir.onnx"
# shellcheck disable=SC2086
for model in ${REQUIRED_MODELS}; do
    if [[ ! -f "${MODELS_DIR}/${model}" || ! -s "${MODELS_DIR}/${model}" ]]; then
        echo "t480-private-lab: missing model (no downloads are attempted): ${MODELS_DIR}/${model}" >&2
        exit 1
    fi
done

WORKTREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "${WORKTREE_ROOT}/Cargo.toml" || ! -f "${WORKTREE_ROOT}/Cargo.lock" || ! -d "${WORKTREE_ROOT}/crates/irlume-daemon" ]]; then
    echo "t480-private-lab: run from the t480-private-experimental worktree root" >&2
    exit 1
fi
# Verify every selected weight against the pinned upstream manifest before
# launch. The manifest ships in this worktree; authenticity beyond it (e.g. a
# release signature) is unavailable and stays an operator disclosure.
if [[ ! -f "${WORKTREE_ROOT}/models/SHA256SUMS" ]]; then
    echo "t480-private-lab: pinned manifest absent: ${WORKTREE_ROOT}/models/SHA256SUMS" >&2
    exit 1
fi
(cd "${MODELS_DIR}" && sha256sum -c "${WORKTREE_ROOT}/models/SHA256SUMS") || {
    echo "t480-private-lab: model manifest verification failed" >&2
    exit 1
}

# Pure lab helpers (artifact resolution, tree gates, manifest checks) live in
# the literal runner file; sourcing it never executes the lab (guarded).
# Sourced up-front so helper definitions are available throughout the launcher.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/t480-lab-runner.sh"

command -v jq >/dev/null || { echo "t480-private-lab: jq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "t480-private-lab: python3 is required" >&2; exit 1; }
command -v swtpm >/dev/null || { echo "t480-private-lab: swtpm is required" >&2; exit 1; }
command -v timeout >/dev/null || { echo "t480-private-lab: timeout is required" >&2; exit 1; }
if ! id "${IRLUME_T480_TEST_USER}" >/dev/null 2>&1; then
    echo "t480-private-lab: unknown user ${IRLUME_T480_TEST_USER}" >&2
    exit 1
fi

# Compilation (and toolchain evidence) run as the ordinary development
# account, never as root: refuse a root shell without an invoking user.
if [[ "${SUDO_USER:-}" == "" || "${SUDO_USER}" == "root" ]]; then
    echo "t480-private-lab: run via sudo from the ordinary development account (SUDO_USER is '${SUDO_USER:-<unset>}')" >&2
    exit 1
fi
BUILD_USER="${SUDO_USER}"
BUILD_HOME="$(getent passwd "${BUILD_USER}" | cut -d: -f6)"
if [[ -z "${BUILD_HOME}" || ! -d "${BUILD_HOME}" ]]; then
    echo "t480-private-lab: no home directory for ${BUILD_USER}" >&2
    exit 1
fi
if ! sudo -u "${BUILD_USER}" test -w ./Cargo.toml -a -w ./Cargo.lock; then
    echo "t480-private-lab: ${BUILD_USER} cannot write the worktree; refusing to build" >&2
    exit 1
fi
# sudo resets PATH; point it at the build account's cargo explicitly.
BUILD_ENV="env HOME=${BUILD_HOME} PATH=${BUILD_HOME}/.cargo/bin:/usr/bin:/bin"
# Cargo availability is checked inside the build account's environment, not
# root's: root's PATH need not (and must not be assumed to) contain cargo.
# Executed through the build user's bash so shell builtins like command -v run
# properly under sudo.
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} bash -c 'command -v cargo' >/dev/null || { echo "t480-private-lab: cargo is required for ${BUILD_USER}" >&2; exit 1; }
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} bash -c 'command -v rustc' >/dev/null || { echo "t480-private-lab: rustc is required for ${BUILD_USER}" >&2; exit 1; }

# The installed daemon keeps its devices: refuse, never stop or kill it.
if fuser /dev/video* >/dev/null 2>&1; then
    echo "t480-private-lab: a process holds /dev/video*; not stopping anything - free the pair and retry" >&2
    fuser -v /dev/video* 2>&1 || true
    exit 1
fi

HW_TEST="t480_hw_authenticate_isolated::t480_hw_authenticate_isolated"

LAB_DIR="$(mktemp -d /tmp/irlume-t480-lab.XXXXXX)"
chmod 0711 "${LAB_DIR}"
BIN_DIR="${LAB_DIR}/bin"
EVIDENCE_DIR="${LAB_DIR}/evidence"
STATE_DIR="${LAB_DIR}/state"
CONFIG_DIR="${LAB_DIR}/config"
EMITTER_LOCK_DIR="${LAB_DIR}/emitter-lock"
KEYRING_DIR="${LAB_DIR}/keyring"
RECOVERY_DIR="${LAB_DIR}/recovery"
SOCK_PATH="${LAB_DIR}/irlume.sock"
mkdir -p "${BIN_DIR}" "${EVIDENCE_DIR}" "${STATE_DIR}" "${CONFIG_DIR}" "${EMITTER_LOCK_DIR}" "${KEYRING_DIR}" "${RECOVERY_DIR}"
chmod 0755 "${BIN_DIR}" "${EVIDENCE_DIR}" "${CONFIG_DIR}"
chmod 0700 "${STATE_DIR}" "${EMITTER_LOCK_DIR}" "${KEYRING_DIR}" "${RECOVERY_DIR}"
echo "t480-private-lab: lab dir ${LAB_DIR}"

git rev-parse HEAD >"${EVIDENCE_DIR}/base-rev.txt"
git status --porcelain >"${EVIDENCE_DIR}/worktree-status.txt" || true
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} cargo --version >"${EVIDENCE_DIR}/toolchain.txt"
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} rustc --version >>"${EVIDENCE_DIR}/toolchain.txt"

FEATURE="t480-experimental"
# Exact reproducible build of the candidate artifacts with the experimental
# feature, as the ordinary development account (never root). Default
# (non-feature) artifacts are never built here. A stale default daemon may
# already sit in target/release from earlier comparison builds: nothing below
# trusts pre-existing files - every copied artifact is resolved from the JSON
# of the build this run just performed, then hashed after copying.
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} cargo build --release --locked -p irlume-daemon -p irlume-cli --features "irlume-daemon/${FEATURE}" --message-format=json >"${EVIDENCE_DIR}/release-build.json" 2>"${EVIDENCE_DIR}/release-build-stderr.log"
# The resolver's exit status is checked explicitly: mapfile alone cannot
# propagate a python failure, and indexing an empty/malformed result must be
# refused before it happens.
RESOLVER_OUT="$(t480_resolve_bins "${EVIDENCE_DIR}/release-build.json")" || {
    echo "t480-private-lab: artifact resolver failed" >&2
    exit 1
}
[[ -n "${RESOLVER_OUT}" ]] || {
    echo "t480-private-lab: artifact resolver reported nothing" >&2
    exit 1
}
mapfile -t RESOLVED <<<"${RESOLVER_OUT}"
[[ "${#RESOLVED[@]}" -eq 2 ]] || {
    echo "t480-private-lab: malformed artifact resolver output" >&2
    exit 1
}
DAEMON_LINE="${RESOLVED[0]#irlumed }"
DAEMON_FEATURES="${DAEMON_LINE##* }"
DAEMON_EXE="${DAEMON_LINE% *}"
CLI_LINE="${RESOLVED[1]#irlume }"
CLI_FEATURES="${CLI_LINE##* }"
CLI_EXE="${CLI_LINE% *}"
if [[ -z "${DAEMON_EXE}" || -z "${CLI_EXE}" || "${DAEMON_EXE}" == "DUPLICATE" || "${CLI_EXE}" == "DUPLICATE" ]]; then
    echo "t480-private-lab: release artifacts did not resolve to exactly one irlumed and one irlume" >&2
    exit 1
fi
# Primary feature record: the build's own artifact metadata, not the tree. A
# missing features array refuses (fail closed). The daemon unit must carry
# t480-experimental; the CLI package defines no such feature, so its record
# is verified present and recorded without requiring it. Release
# test-support is forbidden on both artifacts.
t480_require_feature "${DAEMON_FEATURES}" "t480-experimental" || {
    echo "t480-private-lab: irlumed artifact lacks the t480-experimental feature record" >&2
    exit 1
}
t480_forbid_feature "${DAEMON_FEATURES}" "test-support" || {
    echo "t480-private-lab: irlumed artifact carries test-support" >&2
    exit 1
}
[[ "${CLI_FEATURES}" != "UNVERIFIED" ]] || {
    echo "t480-private-lab: irlume artifact lacks a verifiable feature record" >&2
    exit 1
}
t480_forbid_feature "${CLI_FEATURES}" "test-support" || {
    echo "t480-private-lab: irlume artifact carries test-support" >&2
    exit 1
}
printf 'irlumed features: %s\nirlume features: %s\n' "${DAEMON_FEATURES}" "${CLI_FEATURES}" | tee "${EVIDENCE_DIR}/artifact-features.txt"
for exe in "${DAEMON_EXE}" "${CLI_EXE}"; do
    if [[ ! -x "${exe}" ]]; then
        echo "t480-private-lab: resolved artifact is not executable: ${exe}" >&2
        exit 1
    fi
done
TEST_EXE="$(sudo -u "${BUILD_USER}" ${BUILD_ENV} cargo test --release --locked -p irlume-daemon --features "irlume-daemon/${FEATURE}" --test t480_hardware --no-run --message-format=json 2>"${EVIDENCE_DIR}/test-build-stderr.log" | python3 -c 'import json,sys; exes=[json.loads(l).get("executable") for l in sys.stdin if l.strip().startswith("{")]; exes=[e for e in exes if e and e.split("/")[-1].startswith("t480_hardware-")]; print(exes[0] if len(exes)==1 else "")')"
if [[ -z "${TEST_EXE}" || ! -x "${TEST_EXE}" ]]; then
    echo "t480-private-lab: test artifact did not resolve to exactly one executable" >&2
    exit 1
fi
cp "${DAEMON_EXE}" "${CLI_EXE}" "${TEST_EXE}" "${BIN_DIR}/"
chmod 0755 "${BIN_DIR}/irlumed" "${BIN_DIR}/irlume" "${BIN_DIR}/$(basename "${TEST_EXE}")"
TEST_BIN="${BIN_DIR}/$(basename "${TEST_EXE}")"
sha256sum "${BIN_DIR}/irlumed" "${BIN_DIR}/irlume" "${TEST_BIN}" | tee "${EVIDENCE_DIR}/sha256sums.txt"
# Release provenance: the COMPLETE feature tree of the exact selected build,
# recorded whole. Gates below read feature records, not path substrings (the
# worktree path itself contains "t480-experimental", so a bare grep proves
# nothing). Test-support must be absent: release builds carry no dev-deps.
# The compiler-artifact JSON above is the primary record (exact executables
# of this build); the tree is supplementary evidence for the feature chain.
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} cargo tree -p irlume-daemon --features "irlume-daemon/${FEATURE}" -e no-dev,features -i irlume-camera >"${EVIDENCE_DIR}/release-features.txt" 2>/dev/null
if ! grep -qF 'irlume-daemon feature "t480-experimental"' "${EVIDENCE_DIR}/release-features.txt"; then
    echo "t480-private-lab: release tree lacks the daemon t480-experimental edge" >&2
    exit 1
fi
if ! grep -qF 'irlume-auth feature "t480-experimental"' "${EVIDENCE_DIR}/release-features.txt"; then
    echo "t480-private-lab: release tree lacks the auth t480-experimental edge" >&2
    exit 1
fi
if ! grep -qF 'irlume-camera feature "t480-experimental"' "${EVIDENCE_DIR}/release-features.txt"; then
    echo "t480-private-lab: release tree lacks the camera t480-experimental edge" >&2
    exit 1
fi
if grep -qF 'test-support' "${EVIDENCE_DIR}/release-features.txt"; then
    echo "t480-private-lab: release tree must not contain test-support" >&2
    exit 1
fi
# Hardware-test provenance is separate: its binary links dev-dependencies by
# design, so its tree is recorded on its own and never mixed into the release
# evidence above.
# shellcheck disable=SC2086
sudo -u "${BUILD_USER}" ${BUILD_ENV} cargo tree -p irlume-daemon --features "irlume-daemon/${FEATURE}" -e features -i irlume-camera >"${EVIDENCE_DIR}/test-features.txt" 2>/dev/null || true

# Lab environment, one explicit export per variable (auditable, no
# word-split strings). The runner applies exactly this set to the daemon and
# every client from an array, with inherited camera-selection/force overrides
# explicitly unset there.
export IRLUME_STATE_DIR="${STATE_DIR}"
export IRLUME_CONFIG_DIR="${CONFIG_DIR}"
export IRLUME_EMITTER_LOCK_DIR="${EMITTER_LOCK_DIR}"
export IRLUME_IR_EMITTER_CONF="${CONFIG_DIR}/ir_emitter.conf"
export IRLUME_KEYRING_DIR="${KEYRING_DIR}"
export IRLUME_RECOVERY_DIR="${RECOVERY_DIR}"
export IRLUME_DET_MODEL="${MODELS_DIR}/face_detection_yunet_2023mar.onnx"
export IRLUME_MODEL="${MODELS_DIR}/glintr100.onnx"
export IRLUME_MESH_MODEL="${MODELS_DIR}/face_landmark.onnx"
export IRLUME_BLAZE_MODEL="${MODELS_DIR}/blaze_face_short_range.onnx"
export IRLUME_VIT_PAD_MODEL="${MODELS_DIR}/liveness_vit.onnx"
export IRLUME_PAD_IR_MODEL="${MODELS_DIR}/flir.onnx"
export ORT_DYLIB_PATH="${ORT_DYLIB_PATH}"
export IRLUME_NPU=0
export IRLUME_MODELS_STRICT=1
# IRLUME_NPU=0 is the documented ADR-0022 section 12 CPU reference switch;
# IRLUME_MODELS_STRICT=1 is the documented daemon startup refusal for
# unverified weights. IRLUME_IR_ADAPTER stays unset (optional adapter model).
# No other environment safety switches are set.
for name in IRLUME_SOCKET IRLUME_STATE_DIR IRLUME_CONFIG_DIR IRLUME_EMITTER_LOCK_DIR IRLUME_IR_EMITTER_CONF IRLUME_KEYRING_DIR IRLUME_RECOVERY_DIR IRLUME_DET_MODEL IRLUME_MODEL IRLUME_MESH_MODEL IRLUME_BLAZE_MODEL IRLUME_VIT_PAD_MODEL IRLUME_PAD_IR_MODEL ORT_DYLIB_PATH IRLUME_NPU IRLUME_MODELS_STRICT; do
    printf '%s=%s\n' "${name}" "${!name:-<unset>}"
done | tee "${EVIDENCE_DIR}/lab-env.txt"
# IRLUME_SOCKET names this run's socket; recorded here once the runner path
# is fixed below (the daemon reads it from the environment, no --socket flag).

# Disposable loopback swtpm owns TPM selection for the whole run below.
# IRLUME_SOCKET is exported for the runner and daemon (same value the test
# binary asserts it dials); standard input is preserved for attended prompts.
export IRLUME_SOCKET="${SOCK_PATH}"
./scripts/with-swtpm.sh bash scripts/hardware/t480-lab-runner.sh \
    "${LAB_DIR}" "${BIN_DIR}" "${EVIDENCE_DIR}" "${SOCK_PATH}" \
    "${TEST_BIN}" "${IRLUME_T480_TEST_USER}" "${HW_TEST}"

echo "t480-private-lab: finished; evidence preserved in ${LAB_DIR} (nothing was removed)"
