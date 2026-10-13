#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright the irlume contributors.
#
# Enroll a face profile on the authorized T480 split pair (5986:2113 rgb +
# 5986:1141 ir) by building the --split-camera-choice payload from the LIVE
# listing.
#
# The payload has exactly two members, both required:
#
#   {
#     "expected":      { "supervisor_id": <string>,
#                        "revision":      <u64>,
#                        "rgb": {"instance_id": <string>, "generation": <u64>, "endpoint": <string>},
#                        "ir":  {"instance_id": <string>, "generation": <u64>, "endpoint": <string>} },
#     "authorization": { "generation": <u64>, "token": <string> }
#   }
#
# There is NO pair_key member: SplitEnrollmentChoiceWire is deny_unknown_fields,
# so an extra key is rejected outright. The daemon re-derives the pair from the
# guard against the current publication.
#
# This must run AS THE ENROLLING ACCOUNT, not as root. A root listing carries
# node paths (/dev/videoN); the account listing carries endpoint tokens, and
# the daemon verifies the choice against the CALLER's own view
# (resolve_split_enrollment_choice, main.rs:5077). Root endpoints in a
# non-root choice are refused, and the authorization proof must be the
# account's own.
#
# Extra arguments pass straight through, e.g.:
#   ./scripts/t480-enroll.sh --name mau-t480 --scans 5
#   ./scripts/t480-enroll.sh --reset

set -euo pipefail

RGB_MARKER="5986:2113"
IR_MARKER="5986:1141"
IRLRUME="irlume"
DRY_RUN=0

die() {
    echo "t480-enroll: $1" >&2
    exit 1
}

note() {
    echo "==> $1"
}

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
}

# Options this helper consumes itself. Everything else is forwarded to
# `irlume enroll` untouched, including --name, --scans, --reset, --user.
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
            break
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v "${IRLRUME}" >/dev/null 2>&1 || die "'${IRLRUME}' not found in PATH; pass --irlume PATH"

# A root listing would build node-path endpoints the daemon refuses for a
# non-root peer. Refuse loudly rather than fail later at the daemon.
if [[ "$(id -u)" -eq 0 ]]; then
    die "run this as the enrolling account, not root: a root split list returns node paths, but a non-root enroll must send the account's endpoint tokens"
fi

# Zero-match and ambiguity protection: exactly one candidate per role.
#
# The account listing publishes candidates under `facts.ShareSafe` and masks the
# USB identity entirely (ADR-0030 section 4), so `facts.Root.identity` is null
# here. Matching on it would be a jq error, not a miss. Select by `role`, which
# the account view does carry. When an identity IS exposed (a root-shaped view)
# it is still used as a second check, so a wrong camera cannot slip through
# silently; `// ""` keeps the probe null-safe either way.
pick_guard() {
    printf '%s' "$1" | jq -ce --arg role "$2" --arg marker "$3" '
        [.candidates[] | select(.role == $role)]
        | if length != 1 then empty
          else .[0]
          | select((.facts.Root.identity // "") == ""
                   or (.facts.Root.identity | contains($marker)))
          | .guard
          end'
}

refuse_blank() {
    local value="$1" what="$2"
    if [[ -z "${value}" || "${value}" == "null" || "${value}" == "{}" ]]; then
        die "${what}: no value (zero-match refused)"
    fi
    if [[ "${value}" == *$'\n'* ]]; then
        die "${what}: multiple matches (ambiguous, refused)"
    fi
}

note "reading the account's split listing"
listing="$("${IRLRUME}" split list)"
[ -n "${listing}" ] || die "split list returned nothing"

supervisor="$(printf '%s' "${listing}" | jq -r '.supervisor_id // empty')"
revision="$(printf '%s' "${listing}" | jq -r '.revision // empty')"
authorization="$(printf '%s' "${listing}" | jq -c '.authorization // empty')"
refuse_blank "${supervisor}" "supervisor_id"
refuse_blank "${revision}" "revision"
refuse_blank "${authorization}" "authorization"

rgb_guard="$(pick_guard "${listing}" rgb "${RGB_MARKER}")"
ir_guard="$(pick_guard "${listing}" ir "${IR_MARKER}")"
refuse_blank "${rgb_guard}" "rgb guard for role rgb (${RGB_MARKER})"
refuse_blank "${ir_guard}" "ir guard for role ir (${IR_MARKER})"

# The pair key is reported for the operator's records only; it is NOT part of
# the payload, whose wire type has no such member. The account view publishes
# records under `ShareSafe` with neither a `key` nor an identity, so this is
# best-effort: absent here is normal, not an error.
pair_key="$(printf '%s' "${listing}" | jq -r '[.records[] | .key? // empty] | if length == 1 then .[0] else empty end' 2>/dev/null || true)"

CHOICE="$(jq -cn \
    --arg sup "${supervisor}" --argjson rev "${revision}" \
    --argjson rgb "${rgb_guard}" --argjson ir "${ir_guard}" \
    --argjson auth "${authorization}" \
    '{expected:{supervisor_id:$sup,revision:$rev,rgb:$rgb,ir:$ir},authorization:$auth}')"

# Self-check the exact shape the wire type demands, before the daemon sees it.
printf '%s' "${CHOICE}" | jq -e '
    (keys | sort) == ["authorization","expected"]
    and (.expected | keys | sort) == ["ir","revision","rgb","supervisor_id"]
    and (.expected.rgb | keys | sort) == ["endpoint","generation","instance_id"]
    and (.expected.ir  | keys | sort) == ["endpoint","generation","instance_id"]
    and (.authorization | keys | sort) == ["generation","token"]
    and (.expected.revision | type == "number" and . > 0)
    and (.expected.rgb.generation | type == "number" and . > 0)
    and (.expected.ir.generation  | type == "number" and . > 0)
    and (.authorization.generation | type == "number")
    and (.expected.rgb.endpoint | startswith("/dev/") | not)
    and (.expected.ir.endpoint  | startswith("/dev/") | not)
' >/dev/null || die "composed choice does not match the split choice schema"

echo "    supervisor_id : ${supervisor}"
echo "    revision      : ${revision}"
echo "    rgb endpoint  : $(printf '%s' "${rgb_guard}" | jq -r .endpoint)"
echo "    ir  endpoint  : $(printf '%s' "${ir_guard}" | jq -r .endpoint)"
echo "    pair_key      : ${pair_key:-<not found; not part of the payload>}"
echo
echo "    choice        = ${CHOICE}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo
    note "dry run: stopping before enroll"
    exit 0
fi

note "enrolling on the selected split pair"
exec "${IRLRUME}" enroll --split-camera-choice "${CHOICE}" "$@"