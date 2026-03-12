#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYED_ADDRESSES_PATH="$ROOT_DIR/broadcast/deployed-addresses.json"
ENV_FILE_PATH="$ROOT_DIR/.env"
MULTISIGS_FILE_PATH="$ROOT_DIR/script/mintburn/prod-readiness-multisigs.json"

DEV_WALLET=""
FULL_REPORT=0
declare -a FINDINGS=()
declare -a DETAILS=()
declare -a REMEDIATIONS=()
FAIL_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0
OK_COUNT=0
FINDING_HEADER_PRINTED=0
STYLE_RESET=""
STYLE_BOLD=""
STYLE_CYAN=""
STYLE_YELLOW=""

usage() {
    cat <<EOF
Usage:
  source .env
  $0 --dev-wallet 0xYourDevWallet [--full] [--deployed-addresses path]
  $0 --dev-wallet 0xYourDevWallet --env-file .env [--multisigs-file path]

Checks the latest sponsored CCTP/OFT periphery contracts and reports only problematic spots by default:
  - src periphery owner/signer must not be the dev wallet
  - dst periphery privileged roles must not include the dev wallet
  - OFT dst authorized source periphery mappings must match canonical latest src peripheries from broadcast/deployed-addresses.json
  - permissioned multicall must not keep the dev wallet as admin and must whitelist the dst contract
  - donation box owner must equal the dst contract

Options:
  --dev-wallet, --deployer   Address to flag if it still has privileged access
  --full                     Print successful checks too
  --deployed-addresses       Override broadcast/deployed-addresses.json
  --env-file                 Source an env file and export its vars before running. Default: repo-root .env if present
  --multisigs-file           Read chainId -> multisig JSON. Default: script/mintburn/prod-readiness-multisigs.json
  -h, --help                 Show this help

Exit code:
  0 when no findings were detected
  1 when a fail, warning, or query error was detected
EOF
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing required command: $cmd" >&2
        exit 1
    }
}

normalize_addr() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

normalize_hex() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

normalize_uint() {
    local value="$1"
    value="${value%% *}"
    value="${value%%[*}"
    value="${value//[$'\t\r\n ']}"
    printf '%s\n' "$value"
}

is_address() {
    [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

bytes32_from_address() {
    local hex="${1#0x}"
    printf '0x%064s\n' "$hex" | tr ' ' '0'
}

bytes32_to_display() {
    local value
    value="$(normalize_hex "$1")"
    if [[ "$value" =~ ^0x0{24}([0-9a-f]{40})$ ]]; then
        echo "0x${BASH_REMATCH[1]}"
        return
    fi
    echo "$value"
}

rpc_url_for_chain() {
    local chain_id="$1"
    local var_name="NODE_URL_${chain_id}"
    local value="${!var_name:-}"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

rpc_url_ref_for_chain() {
    local chain_id="$1"
    printf '"$NODE_URL_%s"\n' "$chain_id"
}

multisig_for_chain() {
    local chain_id="$1"
    [[ -f "$MULTISIGS_FILE_PATH" ]] || return 0
    jq -r --arg chain_id "$chain_id" '.[$chain_id] // empty' "$MULTISIGS_FILE_PATH"
}

fallback_eoa() {
    [[ -f "$MULTISIGS_FILE_PATH" ]] || return 0
    jq -r '.fallbackEOA // empty' "$MULTISIGS_FILE_PATH"
}

normalized_target_address() {
    local value="$1"
    [[ -n "$value" ]] || return 0
    is_address "$value" || return 1
    normalize_addr "$value"
}

resolve_eventual_owner() {
    local __outvar="$1"
    local __notevar="$2"
    local chain_id="$3"

    local target raw_target fallback raw_fallback note=""
    raw_target="$(multisig_for_chain "$chain_id")"
    if target="$(normalized_target_address "$raw_target")" && [[ -n "$target" ]]; then
        printf -v "$__outvar" '%s' "$target"
        printf -v "$__notevar" '%s' "$note"
        return 0
    fi

    raw_fallback="$(fallback_eoa)"
    if fallback="$(normalized_target_address "$raw_fallback")" && [[ -n "$fallback" ]]; then
        note="NOTE: chain multisig missing in $MULTISIGS_FILE_PATH; using fallbackEOA $fallback as eventual owner/admin"
        printf -v "$__outvar" '%s' "$fallback"
        printf -v "$__notevar" '%s' "$note"
        return 0
    fi

    printf -v "$__outvar" '%s' ""
    printf -v "$__notevar" '%s' ""
    return 1
}

build_cast_send() {
    local address="$1"
    local signature="$2"
    local chain_id="$3"
    shift 3

    local cmd="cast send $address \"$signature\""
    local arg
    for arg in "$@"; do
        cmd+=" $arg"
    done
    cmd+=" --rpc-url $(rpc_url_ref_for_chain "$chain_id") --account dev"
    printf '%s\n' "$cmd"
}

load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

init_styles() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        STYLE_RESET=$'\033[0m'
        STYLE_BOLD=$'\033[1m'
        STYLE_CYAN=$'\033[36m'
        STYLE_YELLOW=$'\033[33m'
    fi
}

print_finding_header() {
    printf '%-7s %-18s %-28s %-42s %-30s %s\n' "LEVEL" "CHAIN" "CONTRACT" "ADDRESS" "FIELD" "DETAIL"
    printf '%-7s %-18s %-28s %-42s %-30s %s\n' "-----" "-----" "--------" "-------" "-----" "------"
}

add_finding() {
    local level="$1"
    local chain="$2"
    local contract_name="$3"
    local address="$4"
    local field="$5"
    local detail="$6"
    local entry

    case "$level" in
        FAIL) ((FAIL_COUNT += 1)) ;;
        WARN) ((WARN_COUNT += 1)) ;;
        ERROR) ((ERROR_COUNT += 1)) ;;
        *) ;;
    esac

    entry="$level"$'\t'"$chain"$'\t'"$contract_name"$'\t'"$address"$'\t'"$field"$'\t'"$detail"

    FINDINGS+=("$entry")
    if [[ "$FINDING_HEADER_PRINTED" -eq 0 ]]; then
        print_finding_header
        FINDING_HEADER_PRINTED=1
    fi
    printf '%-7s %-18s %-28s %-42s %-30s %s\n' "$level" "$chain" "$contract_name" "$address" "$field" "$detail"
}

add_detail() {
    local chain="$1"
    local contract_name="$2"
    local address="$3"
    local field="$4"
    local value="$5"
    ((OK_COUNT += 1))
    DETAILS+=("$chain"$'\t'"$contract_name"$'\t'"$address"$'\t'"$field"$'\t'"$value")
}

add_remediation() {
    local priority="$1"
    local chain_id="$2"
    local chain_name="$3"
    local contract_name="$4"
    local address="$5"
    local note="$6"
    local command="$7"
    REMEDIATIONS+=(
        "$priority"$'\t'"$chain_id"$'\t'"$chain_name"$'\t'"$contract_name"$'\t'"$address"$'\t'"$note"$'\t'"$command"
    )
}

print_remediations() {
    local prev_group=""
    local priority chain_id chain_name contract_name address note command group

    while IFS=$'\t' read -r priority chain_id chain_name contract_name address note command; do
        [[ -n "$priority" ]] || continue
        group="$chain_id"$'\t'"$chain_name"$'\t'"$contract_name"$'\t'"$address"
        if [[ "$group" != "$prev_group" ]]; then
            [[ -z "$prev_group" ]] || echo
            printf '%s%s# %s %s | %s | %s%s\n' \
                "$STYLE_BOLD" \
                "$STYLE_CYAN" \
                "$chain_id" \
                "$chain_name" \
                "$contract_name" \
                "$address" \
                "$STYLE_RESET"
            prev_group="$group"
        fi
        if [[ -n "$note" ]]; then
            printf '%s# %s%s\n' "$STYLE_YELLOW" "$note" "$STYLE_RESET"
        fi
        if [[ -n "$command" ]]; then
            printf '%s\n' "$command"
        fi
    done < <(printf '%s\n' "${REMEDIATIONS[@]}" | sort -t $'\t' -k2,2n -k4,4 -k5,5 -k1,1n)
}

print_details() {
    printf '%s\n' "${DETAILS[@]}" | awk -F '\t' '
        {
            rows[NR] = $0
            for (i = 1; i <= NF; i++) {
                if (length($i) > w[i]) w[i] = length($i)
            }
        }
        END {
            h[1] = "CHAIN"
            h[2] = "CONTRACT"
            h[3] = "ADDRESS"
            h[4] = "FIELD"
            h[5] = "VALUE"
            for (i = 1; i <= 5; i++) {
                if (length(h[i]) > w[i]) w[i] = length(h[i])
            }
            fmt = ""
            for (i = 1; i <= 4; i++) fmt = fmt "%-" (w[i] + 2) "s"
            fmt = fmt "%s\n"
            printf fmt, h[1], h[2], h[3], h[4], h[5]
            for (r = 1; r <= NR; r++) {
                split(rows[r], f, FS)
                printf fmt, f[1], f[2], f[3], f[4], f[5]
            }
        }
    '
}

chain_name_from_json() {
    local chain_id="$1"
    jq -r --arg chain_id "$chain_id" '.chains[$chain_id].chain_name // $chain_id' "$DEPLOYED_ADDRESSES_PATH"
}

try_cast_view() {
    local __outvar="$1"
    local rpc_url="$2"
    local address="$3"
    local signature="$4"
    shift 4

    local output
    local attempt
    for attempt in 1 2 3; do
        if output="$(cast call "$address" "$signature" "$@" --rpc-url "$rpc_url" 2>&1 | tr -d '\r' | tail -n 1)"; then
            printf -v "$__outvar" '%s' "$output"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

json_contract_rows() {
    local contract_name="$1"
    jq -r --arg contract_name "$contract_name" '
        .chains
        | to_entries[]
        | select(.value.contracts[$contract_name])
        | [
            .key,
            .value.chain_name,
            .value.contracts[$contract_name].address
          ]
        | @tsv
    ' "$DEPLOYED_ADDRESSES_PATH"
}

propose_signer_update() {
    local chain_id="$1"
    local chain_name="$2"
    local contract_name="$3"
    local address="$4"
    local sender_note="$5"

    add_remediation \
        10 \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "$sender_note; replace \$CORRECT_SIGNER with the intended signer" \
        "$(build_cast_send "$address" "setSigner(address)" "$chain_id" '$CORRECT_SIGNER')"
}

propose_transfer_ownership() {
    local priority="$1"
    local chain_id="$2"
    local chain_name="$3"
    local contract_name="$4"
    local address="$5"
    local sender_note="$6"
    local new_owner="$7"

    add_remediation \
        "$priority" \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "$sender_note" \
        "$(build_cast_send "$address" "transferOwnership(address)" "$chain_id" "$new_owner")"
}

propose_revoke_role() {
    local priority="$1"
    local chain_id="$2"
    local chain_name="$3"
    local contract_name="$4"
    local address="$5"
    local role_label="$6"
    local role_value="$7"
    local target_account="$8"
    local sender_note="$9"

    add_remediation \
        "$priority" \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "$sender_note" \
        "$(build_cast_send "$address" "revokeRole(bytes32,address)" "$chain_id" "$role_value" "$target_account")"
}

propose_grant_role() {
    local priority="$1"
    local chain_id="$2"
    local chain_name="$3"
    local contract_name="$4"
    local address="$5"
    local role_value="$6"
    local target_account="$7"
    local sender_note="$8"

    add_remediation \
        "$priority" \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "$sender_note" \
        "$(build_cast_send "$address" "grantRole(bytes32,address)" "$chain_id" "$role_value" "$target_account")"
}

propose_default_admin_handoff() {
    local chain_id="$1"
    local chain_name="$2"
    local contract_name="$3"
    local address="$4"
    local role_value="$5"

    local eventual_owner owner_note
    if ! resolve_eventual_owner eventual_owner owner_note "$chain_id"; then
        add_remediation \
            90 \
            "$chain_id" \
            "$chain_name" \
            "$contract_name" \
            "$address" \
            "missing chain multisig and fallbackEOA in $MULTISIGS_FILE_PATH" \
            ""
        return
    fi
    if [[ -z "$eventual_owner" ]]; then
        add_remediation \
            90 \
            "$chain_id" \
            "$chain_name" \
            "$contract_name" \
            "$address" \
            "missing chain multisig and fallbackEOA in $MULTISIGS_FILE_PATH" \
            ""
        return
    fi

    propose_grant_role \
        90 \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "$role_value" \
        "$eventual_owner" \
        "${owner_note:+$owner_note; }grant DEFAULT_ADMIN_ROLE to the eventual owner before removing the dev wallet"
    propose_revoke_role \
        100 \
        "$chain_id" \
        "$chain_name" \
        "$contract_name" \
        "$address" \
        "DEFAULT_ADMIN_ROLE" \
        "$role_value" \
        "$DEV_WALLET" \
        "send after the multisig grant confirms"
}

check_owner_not_dev() {
    local chain_id="$1"
    local chain_name="$2"
    local contract_name="$3"
    local address="$4"
    local rpc_url="$5"

    local owner
    if ! try_cast_view owner "$rpc_url" "$address" "owner()(address)"; then
        add_finding "ERROR" "$chain_id $chain_name" "$contract_name" "$address" "owner()" "query failed"
        return
    fi
    owner="$(normalize_addr "$owner")"

    if [[ "$owner" == "$DEV_WALLET" ]]; then
        add_finding \
            "FAIL" \
            "$chain_id $chain_name" "$contract_name" "$address" "owner" "dev wallet $owner"
        local eventual_owner owner_note
        if ! resolve_eventual_owner eventual_owner owner_note "$chain_id"; then
            add_remediation \
                20 \
                "$chain_id" \
                "$chain_name" \
                "$contract_name" \
                "$address" \
                "missing chain multisig and fallbackEOA in $MULTISIGS_FILE_PATH" \
                ""
            return
        fi
        if [[ -z "$eventual_owner" ]]; then
            add_remediation \
                20 \
                "$chain_id" \
                "$chain_name" \
                "$contract_name" \
                "$address" \
                "missing chain multisig and fallbackEOA in $MULTISIGS_FILE_PATH" \
                ""
            return
        fi
        propose_transfer_ownership \
            20 \
            "$chain_id" \
            "$chain_name" \
            "$contract_name" \
            "$address" \
            "${owner_note:+$owner_note; }run after any signer update for this contract" \
            "$eventual_owner"
        return
    fi

    if [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "$contract_name" "$address" "owner" "$owner"
    fi
    return 0
}

check_signer_not_dev() {
    local chain_id="$1"
    local chain_name="$2"
    local contract_name="$3"
    local address="$4"
    local rpc_url="$5"

    local signer
    if ! try_cast_view signer "$rpc_url" "$address" "signer()(address)"; then
        add_finding "ERROR" "$chain_id $chain_name" "$contract_name" "$address" "signer()" "query failed"
        return
    fi
    signer="$(normalize_addr "$signer")"

    if [[ "$signer" == "$DEV_WALLET" ]]; then
        add_finding \
            "FAIL" \
            "$chain_id $chain_name" "$contract_name" "$address" "signer" "dev wallet $signer"
        case "$contract_name" in
            SponsoredCCTPSrcPeriphery|SponsoredOFTSrcPeriphery)
                propose_signer_update \
                    "$chain_id" \
                    "$chain_name" \
                    "$contract_name" \
                    "$address" \
                    "requires the current owner"
                ;;
            SponsoredCCTPDstPeriphery)
                propose_signer_update \
                    "$chain_id" \
                    "$chain_name" \
                    "$contract_name" \
                    "$address" \
                    "requires a current DEFAULT_ADMIN_ROLE holder"
                ;;
        esac
        return
    fi

    if [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "$contract_name" "$address" "signer" "$signer"
    fi
    return 0
}

check_role_not_dev() {
    local chain_id="$1"
    local chain_name="$2"
    local contract_name="$3"
    local address="$4"
    local rpc_url="$5"
    local role_getter="$6"
    local role_label="$7"

    local role_value
    local has_dev_role

    if ! try_cast_view role_value "$rpc_url" "$address" "$role_getter()(bytes32)"; then
        add_finding "ERROR" "$chain_id $chain_name" "$contract_name" "$address" "$role_label" "getter failed"
        return
    fi
    role_value="$(normalize_hex "$role_value")"

    if ! try_cast_view has_dev_role "$rpc_url" "$address" "hasRole(bytes32,address)(bool)" "$role_value" "$DEV_WALLET"; then
        add_finding "ERROR" "$chain_id $chain_name" "$contract_name" "$address" "hasRole($role_label,dev)" "query failed"
        return
    fi

    if [[ "$has_dev_role" == "true" ]]; then
        add_finding \
            "FAIL" \
            "$chain_id $chain_name" "$contract_name" "$address" "$role_label" "dev wallet present"
        case "$role_label" in
            FUNDS_SWEEPER_ROLE|PERMISSIONED_BOT_ROLE)
                propose_revoke_role \
                    40 \
                    "$chain_id" \
                    "$chain_name" \
                    "$contract_name" \
                    "$address" \
                    "$role_label" \
                    "$role_value" \
                    "$DEV_WALLET" \
                    "requires an address that holds the admin role for $role_label"
                ;;
            DEFAULT_ADMIN_ROLE)
                propose_default_admin_handoff "$chain_id" "$chain_name" "$contract_name" "$address" "$role_value"
                ;;
        esac
        return
    fi

    if [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "$contract_name" "$address" "$role_label" "dev wallet absent"
    fi
    return 0
}

check_multicall_permissions() {
    local chain_id="$1"
    local chain_name="$2"
    local parent_contract_name="$3"
    local parent_address="$4"
    local rpc_url="$5"

    local multicall_handler
    if ! try_cast_view multicall_handler "$rpc_url" "$parent_address" "multicallHandler()(address)"; then
        add_finding "ERROR" "$chain_id $chain_name" "$parent_contract_name" "$parent_address" "multicallHandler()" "query failed"
        return
    fi
    multicall_handler="$(normalize_addr "$multicall_handler")"

    local default_admin_role
    local whitelisted_caller_role
    local dev_is_admin
    local dst_is_whitelisted
    local dev_is_whitelisted

    if ! try_cast_view default_admin_role "$rpc_url" "$multicall_handler" "DEFAULT_ADMIN_ROLE()(bytes32)"; then
        add_finding "ERROR" "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "DEFAULT_ADMIN_ROLE()" "query failed"
        return
    fi
    if ! try_cast_view whitelisted_caller_role "$rpc_url" "$multicall_handler" "WHITELISTED_CALLER_ROLE()(bytes32)"; then
        add_finding "ERROR" "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE()" "query failed"
        return
    fi

    default_admin_role="$(normalize_hex "$default_admin_role")"
    whitelisted_caller_role="$(normalize_hex "$whitelisted_caller_role")"

    if ! try_cast_view dev_is_admin "$rpc_url" "$multicall_handler" "hasRole(bytes32,address)(bool)" "$default_admin_role" "$DEV_WALLET"; then
        add_finding "ERROR" "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "DEFAULT_ADMIN_ROLE" "dev role check failed"
        return
    fi
    if ! try_cast_view dst_is_whitelisted "$rpc_url" "$multicall_handler" "hasRole(bytes32,address)(bool)" "$whitelisted_caller_role" "$parent_address"; then
        add_finding "ERROR" "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dst)" "check failed"
        return
    fi
    if ! try_cast_view dev_is_whitelisted "$rpc_url" "$multicall_handler" "hasRole(bytes32,address)(bool)" "$whitelisted_caller_role" "$DEV_WALLET"; then
        add_finding "ERROR" "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dev)" "check failed"
        return
    fi

    if [[ "$dev_is_whitelisted" == "true" ]]; then
        add_finding \
            "FAIL" \
            "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dev)" "dev wallet present"
        propose_revoke_role \
            40 \
            "$chain_id" \
            "$chain_name" \
            "PermissionedMulticallHandler" \
            "$multicall_handler" \
            "WHITELISTED_CALLER_ROLE" \
            "$whitelisted_caller_role" \
            "$DEV_WALLET" \
            "requires a current DEFAULT_ADMIN_ROLE holder"
    elif [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dev)" "absent"
    fi

    if [[ "$dst_is_whitelisted" != "true" ]]; then
        add_finding \
            "WARN" \
            "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dst)" "missing $parent_address"
        propose_grant_role \
            50 \
            "$chain_id" \
            "$chain_name" \
            "PermissionedMulticallHandler" \
            "$multicall_handler" \
            "$whitelisted_caller_role" \
            "$parent_address" \
            "requires a current DEFAULT_ADMIN_ROLE holder"
    elif [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "WHITELISTED_CALLER_ROLE(dst)" "$parent_address"
    fi

    if [[ "$dev_is_admin" == "true" ]]; then
        add_finding \
            "FAIL" \
            "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "DEFAULT_ADMIN_ROLE" "dev wallet present"
        propose_default_admin_handoff \
            "$chain_id" \
            "$chain_name" \
            "PermissionedMulticallHandler" \
            "$multicall_handler" \
            "$default_admin_role"
    elif [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "PermissionedMulticallHandler" "$multicall_handler" "DEFAULT_ADMIN_ROLE" "dev wallet absent"
    fi
    return 0
}

check_donation_box_owner() {
    local chain_id="$1"
    local chain_name="$2"
    local parent_contract_name="$3"
    local parent_address="$4"
    local rpc_url="$5"

    local donation_box
    local donation_owner

    if ! try_cast_view donation_box "$rpc_url" "$parent_address" "donationBox()(address)"; then
        add_finding "ERROR" "$chain_id $chain_name" "$parent_contract_name" "$parent_address" "donationBox()" "query failed"
        return
    fi
    donation_box="$(normalize_addr "$donation_box")"

    if ! try_cast_view donation_owner "$rpc_url" "$donation_box" "owner()(address)"; then
        add_finding "ERROR" "$chain_id $chain_name" "DonationBox" "$donation_box" "owner()" "query failed"
        return
    fi
    donation_owner="$(normalize_addr "$donation_owner")"

    if [[ "$donation_owner" != "$parent_address" ]]; then
        add_finding \
            "WARN" \
            "$chain_id $chain_name" "DonationBox" "$donation_box" "owner" "got $donation_owner expected $parent_address"
        propose_transfer_ownership \
            60 \
            "$chain_id" \
            "$chain_name" \
            "DonationBox" \
            "$donation_box" \
            "requires the current owner $donation_owner" \
            "$parent_address"
        return
    fi

    if [[ "$FULL_REPORT" -eq 1 ]]; then
        add_detail "$chain_id $chain_name" "DonationBox" "$donation_box" "owner" "$donation_owner"
    fi
    return 0
}

check_cctp_src_contract() {
    local chain_id="$1"
    local chain_name="$2"
    local address="$3"
    local rpc_url="$4"

    check_owner_not_dev "$chain_id" "$chain_name" "SponsoredCCTPSrcPeriphery" "$address" "$rpc_url"
    check_signer_not_dev "$chain_id" "$chain_name" "SponsoredCCTPSrcPeriphery" "$address" "$rpc_url"
}

check_oft_src_contract() {
    local chain_id="$1"
    local chain_name="$2"
    local address="$3"
    local rpc_url="$4"

    check_owner_not_dev "$chain_id" "$chain_name" "SponsoredOFTSrcPeriphery" "$address" "$rpc_url"
    check_signer_not_dev "$chain_id" "$chain_name" "SponsoredOFTSrcPeriphery" "$address" "$rpc_url"
}

check_cctp_dst_contract() {
    local chain_id="$1"
    local chain_name="$2"
    local address="$3"
    local rpc_url="$4"

    check_role_not_dev "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url" "FUNDS_SWEEPER_ROLE" "FUNDS_SWEEPER_ROLE"
    check_role_not_dev "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url" "PERMISSIONED_BOT_ROLE" "PERMISSIONED_BOT_ROLE"
    check_signer_not_dev "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url"
    check_multicall_permissions "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url"
    check_donation_box_owner "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url"
    check_role_not_dev "$chain_id" "$chain_name" "SponsoredCCTPDstPeriphery" "$address" "$rpc_url" "DEFAULT_ADMIN_ROLE" "DEFAULT_ADMIN_ROLE"
}

check_oft_dst_roles() {
    local chain_id="$1"
    local chain_name="$2"
    local address="$3"
    local rpc_url="$4"

    check_role_not_dev "$chain_id" "$chain_name" "DstOFTHandler" "$address" "$rpc_url" "FUNDS_SWEEPER_ROLE" "FUNDS_SWEEPER_ROLE"
    check_role_not_dev "$chain_id" "$chain_name" "DstOFTHandler" "$address" "$rpc_url" "PERMISSIONED_BOT_ROLE" "PERMISSIONED_BOT_ROLE"
    check_multicall_permissions "$chain_id" "$chain_name" "DstOFTHandler" "$address" "$rpc_url"
    check_donation_box_owner "$chain_id" "$chain_name" "DstOFTHandler" "$address" "$rpc_url"
    check_role_not_dev "$chain_id" "$chain_name" "DstOFTHandler" "$address" "$rpc_url" "DEFAULT_ADMIN_ROLE" "DEFAULT_ADMIN_ROLE"
}

check_oft_authorized_peripheries_from_broadcast() {
    local dst_chain_id="$1"
    local dst_chain_name="$2"
    local dst_handler="$3"
    local dst_rpc_url="$4"

    while IFS=$'\t' read -r src_chain_id src_chain_name src_periphery; do
        [[ -n "$src_chain_id" ]] || continue
        [[ "$src_chain_id" != "$dst_chain_id" ]] || continue

        local src_rpc_url
        if ! src_rpc_url="$(rpc_url_for_chain "$src_chain_id")"; then
            add_finding "ERROR" "$src_chain_id $src_chain_name" "SponsoredOFTSrcPeriphery" "$src_periphery" "rpc" "requires NODE_URL_${src_chain_id}"
            continue
        fi

        local src_eid
        if ! try_cast_view src_eid "$src_rpc_url" "$src_periphery" "SRC_EID()(uint32)"; then
            add_finding "ERROR" "$src_chain_id $src_chain_name" "SponsoredOFTSrcPeriphery" "$src_periphery" "SRC_EID()" "query failed"
            continue
        fi
        src_eid="$(normalize_uint "$src_eid")"

        local actual_authorized
        if ! try_cast_view actual_authorized "$dst_rpc_url" "$dst_handler" "authorizedSrcPeripheryContracts(uint64)(bytes32)" "$src_eid"; then
            add_finding "ERROR" "$dst_chain_id $dst_chain_name" "DstOFTHandler" "$dst_handler" "authorizedSrc[$src_eid]" "query failed"
            continue
        fi

        local expected_authorized
        expected_authorized="$(normalize_hex "$(bytes32_from_address "$(normalize_addr "$src_periphery")")")"
        actual_authorized="$(normalize_hex "$actual_authorized")"

        if [[ "$actual_authorized" != "$expected_authorized" ]]; then
            add_finding \
                "WARN" \
                "$dst_chain_id $dst_chain_name" "DstOFTHandler" "$dst_handler" "authorizedSrc[$src_eid]" "got $(bytes32_to_display "$actual_authorized") expected $(normalize_addr "$src_periphery")"
            add_remediation \
                55 \
                "$dst_chain_id" \
                "$dst_chain_name" \
                "DstOFTHandler" \
                "$dst_handler" \
                "requires a current DEFAULT_ADMIN_ROLE holder" \
                "$(build_cast_send "$dst_handler" "setAuthorizedPeriphery(uint32,bytes32)" "$dst_chain_id" "$src_eid" "$expected_authorized")"
            continue
        fi

        if [[ "$FULL_REPORT" -eq 1 ]]; then
            add_detail "$dst_chain_id $dst_chain_name" "DstOFTHandler" "$dst_handler" "authorizedSrc[$src_eid]" "$(normalize_addr "$src_periphery")"
        fi
    done < <(json_contract_rows "SponsoredOFTSrcPeriphery")
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev-wallet|--deployer)
            DEV_WALLET="${2:-}"
            shift 2
            ;;
        --full)
            FULL_REPORT=1
            shift
            ;;
        --deployed-addresses)
            DEPLOYED_ADDRESSES_PATH="${2:-}"
            shift 2
            ;;
        --env-file)
            ENV_FILE_PATH="${2:-}"
            shift 2
            ;;
        --multisigs-file)
            MULTISIGS_FILE_PATH="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd jq
require_cmd cast
require_cmd awk

load_env_file "$ENV_FILE_PATH"
init_styles

[[ -f "$DEPLOYED_ADDRESSES_PATH" ]] || {
    echo "Missing deployed addresses file: $DEPLOYED_ADDRESSES_PATH" >&2
    exit 1
}

if [[ -f "$MULTISIGS_FILE_PATH" ]]; then
    jq empty "$MULTISIGS_FILE_PATH" >/dev/null
fi

[[ -n "$DEV_WALLET" ]] || {
    echo "--dev-wallet is required" >&2
    usage >&2
    exit 1
}
is_address "$DEV_WALLET" || {
    echo "Invalid dev wallet: $DEV_WALLET" >&2
    exit 1
}
DEV_WALLET="$(normalize_addr "$DEV_WALLET")"

echo "Sponsored periphery prod-readiness check"
echo "dev wallet: $DEV_WALLET"
echo "deployed-addresses: $DEPLOYED_ADDRESSES_PATH"
if [[ -f "$ENV_FILE_PATH" ]]; then
    echo "env-file: $ENV_FILE_PATH"
fi
if [[ -f "$MULTISIGS_FILE_PATH" ]]; then
    echo "multisigs-file: $MULTISIGS_FILE_PATH"
fi
echo

while IFS=$'\t' read -r chain_id chain_name address; do
    [[ -n "$chain_id" ]] || continue
    if ! rpc_url="$(rpc_url_for_chain "$chain_id")"; then
        add_finding "ERROR" "$chain_id $chain_name" "SponsoredCCTPSrcPeriphery" "$address" "rpc" "requires NODE_URL_${chain_id}"
        continue
    fi
    check_cctp_src_contract "$chain_id" "$chain_name" "$(normalize_addr "$address")" "$rpc_url"
done < <(json_contract_rows "SponsoredCCTPSrcPeriphery")

while IFS=$'\t' read -r chain_id chain_name address; do
    [[ -n "$chain_id" ]] || continue
    if ! rpc_url="$(rpc_url_for_chain "$chain_id")"; then
        add_finding "ERROR" "$chain_id $chain_name" "SponsoredOFTSrcPeriphery" "$address" "rpc" "requires NODE_URL_${chain_id}"
        continue
    fi
    check_oft_src_contract "$chain_id" "$chain_name" "$(normalize_addr "$address")" "$rpc_url"
done < <(json_contract_rows "SponsoredOFTSrcPeriphery")

while IFS=$'\t' read -r chain_id chain_name address; do
    [[ -n "$chain_id" ]] || continue
    if ! rpc_url="$(rpc_url_for_chain "$chain_id")"; then
        add_finding "ERROR" "$chain_id $chain_name" "SponsoredCCTPDstPeriphery" "$address" "rpc" "requires NODE_URL_${chain_id}"
        continue
    fi
    check_cctp_dst_contract "$chain_id" "$chain_name" "$(normalize_addr "$address")" "$rpc_url"
done < <(json_contract_rows "SponsoredCCTPDstPeriphery")

while IFS=$'\t' read -r chain_id chain_name address; do
    [[ -n "$chain_id" ]] || continue
    if ! rpc_url="$(rpc_url_for_chain "$chain_id")"; then
        add_finding "ERROR" "$chain_id $chain_name" "DstOFTHandler" "$address" "rpc" "requires NODE_URL_${chain_id}"
        continue
    fi
    check_oft_dst_roles "$chain_id" "$chain_name" "$(normalize_addr "$address")" "$rpc_url"
    check_oft_authorized_peripheries_from_broadcast "$chain_id" "$chain_name" "$(normalize_addr "$address")" "$rpc_url"
done < <(json_contract_rows "DstOFTHandler")

if [[ "${#FINDINGS[@]}" -eq 0 ]]; then
    echo "No problematic spots detected."
fi

if [[ "$FULL_REPORT" -eq 1 && "${#DETAILS[@]}" -gt 0 ]]; then
    echo
    echo "Verified:"
    print_details
fi

if [[ "${#REMEDIATIONS[@]}" -gt 0 ]]; then
    echo
    echo "Proposed cast fixes:"
    print_remediations
fi

echo
echo "Summary: FAIL=$FAIL_COUNT WARN=$WARN_COUNT ERROR=$ERROR_COUNT OK=$OK_COUNT"
echo "Note: this proves the dev wallet is absent only for the inspected slots; it cannot prove the correct prod address is configured unless an expected value is derivable."

if ((FAIL_COUNT + WARN_COUNT + ERROR_COUNT > 0)); then
    exit 1
fi
