#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.

set -euo pipefail

# HARDWARE ISOLATION SCRIPT FOR T480 YUYV EXPERIMENT
# Does not run by default. Intended for attended physical testing only.

echo "T480 YUYV Experimental Private Lab"
echo "Requires root privileges and IRLUME_T480_TEST_USER to be set."

if [[ "${EUID}" -ne 0 ]]; then
    echo "Must be run as root."
    exit 1
fi

if [[ -z "${IRLUME_T480_TEST_USER:-}" ]]; then
    echo "IRLUME_T480_TEST_USER is not set."
    exit 1
fi

USER_UID=$(id -u "${IRLUME_T480_TEST_USER}")

LAB_DIR=$(mktemp -d /tmp/irlume-t480-lab.XXXXXX)
chmod 0700 "${LAB_DIR}"
echo "Lab dir: ${LAB_DIR}"

SOCK_PATH="${LAB_DIR}/irlume.sock"
CONFIG_DIR="${LAB_DIR}/etc"
STATE_DIR="${LAB_DIR}/var"
RUN_DIR="${LAB_DIR}/run"
SWTPM_DIR="${LAB_DIR}/swtpm"

mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${RUN_DIR}" "${SWTPM_DIR}"
chmod 0755 "${CONFIG_DIR}" "${RUN_DIR}"
chmod 0700 "${STATE_DIR}" "${SWTPM_DIR}"

# Check for existing daemon holding cameras
if fuser /dev/video* 2>/dev/null | grep -q .; then
    echo "Cameras are currently held by another process. Please stop the installed daemon."
    exit 1
fi

export IRLUME_SOCKET="${SOCK_PATH}"
export IRLUME_CONFIG_DIR="${CONFIG_DIR}"
export IRLUME_STATE_DIR="${STATE_DIR}"
export IRLUME_NPU=0

# Compile physical test
# Assumes binaries are already compiled and in target/debug/
DAEMON_BIN="./target/release/irlumed"
CLI_BIN="./target/release/irlume"
TEST_BIN=$(find ./target/release/deps -maxdepth 1 -type f -executable -name "t480_hardware-*" | head -n 1)

if [[ ! -x "${DAEMON_BIN}" || ! -x "${CLI_BIN}" || -z "${TEST_BIN}" ]]; then
    echo "Release binaries not found. Please compile them first."
    exit 1
fi

DAEMON_HASH=$(sha256sum "${DAEMON_BIN}" | cut -d ' ' -f 1)
CLI_HASH=$(sha256sum "${CLI_BIN}" | cut -d ' ' -f 1)
echo "Daemon Hash: ${DAEMON_HASH}"
echo "CLI Hash: ${CLI_HASH}"

# Use existing with-swtpm.sh
export IRLUME_TCTI="" # will be set by the script
export IRLUME_SKIP_TCTI_FALLBACK=1

# Wrap the execution in the swtpm environment
./scripts/with-swtpm.sh bash -c '
    set -euo pipefail
    
    # Start isolated daemon
    "'"${DAEMON_BIN}"'" --socket "'"${SOCK_PATH}"'" &
    DAEMON_PID=$!
    
    # Early cleanup traps
    trap "kill ${DAEMON_PID} || true" EXIT
    
    # Bounded readiness
    for i in {1..20}; do
        if [[ -S "'"${SOCK_PATH}"'" ]]; then
            break
        fi
        sleep 0.2
    done
    if [[ ! -S "'"${SOCK_PATH}"'" ]]; then
        echo "Daemon socket failed to appear."
        exit 1
    fi
    
    # 1. Discover
    JSON_OUT=$("'"${CLI_BIN}"'" camera-tune --discover --json)
    
    # 2. Extract split choice JSON for 2113 + 1141 pair
    SPLIT_CHOICE=$(echo "${JSON_OUT}" | jq -c ".devices[] | select(.candidate_roles == \"rgb_and_ir_split_pair\" and .split_identity.rgb.identity == \"5986:2113\" and .split_identity.ir.identity == \"5986:1141\") | .split_identity")
    
    if [[ -z "${SPLIT_CHOICE}" ]]; then
        echo "Could not find the T480 split pair in camera-tune output."
        exit 1
    fi
    
    # 3. Add group
    echo "${SPLIT_CHOICE}" | "'"${CLI_BIN}"'" add-camera-group --split-pair
    
    # 4. Enroll
    "'"${CLI_BIN}"'" -u "'"${IRLUME_T480_TEST_USER}"'" enroll --split-camera-choice "${SPLIT_CHOICE}"
    
    # 5. Run test as normal user
    sudo -u "'"${IRLUME_T480_TEST_USER}"'" IRLUME_SOCKET="'"${SOCK_PATH}"'" "'"${TEST_BIN}"'" --exact t480_hw_authenticate_isolated_test --ignored --nocapture
'

echo "Lab run finished. Evidence preserved in ${LAB_DIR}"
