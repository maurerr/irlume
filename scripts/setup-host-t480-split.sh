#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# Register and select the T480 split camera pair (5986:2113 rgb + 5986:1141 ir)
# on the INSTALLED host daemon.
#
# `split add` and `split select` are RootOnly requests with no OS-authorization
# prompt, so this script must run as root. It never calls sudo itself: it
# refuses a non-root caller and leaves the privilege decision to you.
#
# `split list` is AnyPeer and is readable without root, but every value this
# script derives from it is host-specific. Nothing is hardcoded: supervisor id,
# revision, instance ids, generations, endpoints, controller, domain and ports
# are read from the live listing each time.
#
# Usage:
#   sudo ./scripts/setup-host-t480-split.sh [--irlume PATH]
#
# Options:
#   --irlume PATH   CLI to use (default: irlume from PATH)
#   --dry-run       parse and print the payloads, issue no mutating request
#
# Exit status: 0 all stages done, non-zero at the first refusal.

set -euo pipefail

RGB_MARKER="5986:2113"
IR_MARKER="5986:1141"
IRLRUME="irlume"
DRY_RUN=0

die() {
    echo "setup-host-t480-split: $1" >&2
    exit 1
}

note() {
    echo "==> $1"
}

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --irlume)
            [[ $# -ge 2 ]] || die "--irlume needs a path"
            IRLRUME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v "${IRLRUME}" >/dev/null 2>&1 || die "'${IRLRUME}' not found in PATH; pass --irlume PATH"

# add/select/status are RootOnly. Refuse rather than pretend.
if [[ "${DRY_RUN}" -eq 0 && "$(id -u)" -ne 0 ]]; then
    die "split add/select/status are RootOnly. Re-run as root (e.g. sudo $0). This script never invokes sudo itself."
fi

# Refuse a blank, null, empty-object or multi-line jq extraction: zero-match and
# ambiguous-match protection, the same rule the lab runner applies.
refuse_blank_or_multi() {
    local value="$1" what="$2"
    if [[ -z "${value}" || "${value}" == "null" || "${value}" == "{}" ]]; then
        die "${what}: no value (zero-match refused)"
    fi
    if [[ "${value}" == *$'\n'* ]]; then
        die "${what}: multiple matches (ambiguous, refused)"
    fi
}

# One candidate per role, matched on the USB identity the daemon published.
pick_guard() {
    printf '%s' "$1" | jq -c --arg role "$2" --arg marker "$3" \
        '[.candidates[] | select(.role == $role and (.facts.Root.identity | contains($marker)))] | if length == 1 then .[0].guard else empty end'
}

pick_facts() {
    printf '%s' "$1" | jq -c --arg role "$2" --arg marker "$3" \
        '[.candidates[] | select(.role == $role and (.facts.Root.identity | contains($marker)))] | if length == 1 then .[0].facts.Root else empty end'
}

count_matches() {
    printf '%s' "$1" | jq --arg role "$2" --arg marker "$3" \
        '[.candidates[] | select(.role == $role and (.facts.Root.identity | contains($marker)))] | length'
}

build_guard() {
    jq -cn --arg sup "$1" --argjson rev "$2" --argjson rgb "$3" --argjson ir "$4" \
        '{supervisor_id:$sup,revision:$rev,rgb:$rgb,ir:$ir}'
}

# ---------------------------------------------------------------- stage 1
note "reading the current split listing"
list_json="$("${IRLRUME}" split list)"
[ -n "${list_json}" ] || die "split list returned nothing"

supervisor="$(printf '%s' "${list_json}" | jq -r '.supervisor_id // empty')"
revision="$(printf '%s' "${list_json}" | jq -r '.revision // empty')"
refuse_blank_or_multi "${supervisor}" "supervisor_id"
refuse_blank_or_multi "${revision}" "revision"

rgb_n="$(count_matches "${list_json}" rgb "${RGB_MARKER}")"
ir_n="$(count_matches "${list_json}" ir "${IR_MARKER}")"
echo "    supervisor_id : ${supervisor}"
echo "    revision      : ${revision}"
echo "    ${RGB_MARKER} candidates: ${rgb_n}"
echo "    ${IR_MARKER} candidates: ${ir_n}"
[[ "${rgb_n}" == "1" ]] || die "expected exactly one ${RGB_MARKER} rgb candidate, found ${rgb_n}"
[[ "${ir_n}" == "1" ]] || die "expected exactly one ${IR_MARKER} ir candidate, found ${ir_n}"

rgb_guard="$(pick_guard "${list_json}" rgb "${RGB_MARKER}")"
ir_guard="$(pick_guard "${list_json}" ir "${IR_MARKER}")"
rgb_facts="$(pick_facts "${list_json}" rgb "${RGB_MARKER}")"
ir_facts="$(pick_facts "${list_json}" ir "${IR_MARKER}")"
for pair in "rgb_guard:${rgb_guard}" "ir_guard:${ir_guard}" "rgb_facts:${rgb_facts}" "ir_facts:${ir_facts}"; do
    refuse_blank_or_multi "${pair#*:}" "${pair%%:*}"
done

guard="$(build_guard "${supervisor}" "${revision}" "${rgb_guard}" "${ir_guard}")"

echo
echo "    guard  = ${guard}"
echo "    rgb    = ${rgb_facts}"
echo "    ir     = ${ir_facts}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo
    note "dry run: stopping before split add"
    exit 0
fi

# ---------------------------------------------------------------- stage 2
note "registering the split pair (split add)"
"${IRLRUME}" split add --guard "${guard}" --rgb "${rgb_facts}" --ir "${ir_facts}" \
    || die "split add failed"

# ---------------------------------------------------------------- stage 3
note "re-reading the listing for the post-add revision and pair key"
list2_json="$("${IRLRUME}" split list)"
[ -n "${list2_json}" ] || die "split list returned nothing after add"

supervisor2="$(printf '%s' "${list2_json}" | jq -r '.supervisor_id // empty')"
revision2="$(printf '%s' "${list2_json}" | jq -r '.revision // empty')"
refuse_blank_or_multi "${supervisor2}" "supervisor_id after add"
refuse_blank_or_multi "${revision2}" "revision after add"

guard2="$(build_guard "${supervisor2}" "${revision2}" \
    "$(pick_guard "${list2_json}" rgb "${RGB_MARKER}")" \
    "$(pick_guard "${list2_json}" ir "${IR_MARKER}")")"

pair_key="$(printf '%s' "${list2_json}" | jq -r \
    --arg rgb "${RGB_MARKER}" --arg ir "${IR_MARKER}" \
    '[.records[] | select((.rgb.Root.identity // "" | contains($rgb))
                        and (.ir.Root.identity // "" | contains($ir)))] | if length == 1 then .[0].key else empty end')"
refuse_blank_or_multi "${guard2}" "fresh guard after add"
refuse_blank_or_multi "${pair_key}" "pair key after add"

echo "    revision after add: ${revision2}"
echo "    pair_key           : ${pair_key}"

# ---------------------------------------------------------------- stage 4
note "selecting the pair (split select)"
"${IRLRUME}" split select "${pair_key}" --guard "${guard2}" \
    || die "split select failed"

# ---------------------------------------------------------------- stage 5
note "final active configuration"
"${IRLRUME}" split status

echo
note "done: the 5986:2113 / 5986:1141 pair is registered and selected"