#!/usr/bin/env bash
# Generate a Govex smart-account action wrapper from a callable Move function.
#
# This script is the public entry point for adding a typed action to Govex smart
# accounts. It scans a `public fun` or `entry fun`, writes an action schema, and
# then generates:
#   - Move action-spec staging code,
#   - Move execution wrapper code,
#   - TypeScript SDK definition/composer/executor snippets.
#
# Review the generated files before publishing. The scanner can infer many
# details from the Move signature, but humans still need to verify object and
# capability sources, validation rules, package addresses, and output handling.
#
# Prerequisites:
#   npm --prefix tools/action-codegen install
#
# Usage from the smart-account-v3 repo root:
#   ./scripts/generate-action-wrapper.sh --list <path/to/module.move>
#   ./scripts/generate-action-wrapper.sh <path/to/module.move> <function_name> --id <action_id> [--dry-run]
#   ./scripts/generate-action-wrapper.sh --from-schema <action_id> [--dry-run]
#
# Examples:
#   ./scripts/generate-action-wrapper.sh --list ./examples/router.move
#   ./scripts/generate-action-wrapper.sh ./examples/router.move swap --id cetus_swap --dry-run
#   ./scripts/generate-action-wrapper.sh --from-schema cetus_swap
set -euo pipefail

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
codegen_dir="$repo_root/tools/action-codegen"

if [[ ! -f "$codegen_dir/src/scan.ts" || ! -f "$codegen_dir/src/generate.ts" ]]; then
    echo "Action codegen sources not found at: $codegen_dir" >&2
    exit 1
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

if [[ ! -d "$codegen_dir/node_modules" ]]; then
    echo "Missing action-codegen dependencies." >&2
    echo "Run: npm --prefix tools/action-codegen install" >&2
    exit 1
fi

resolve_file() {
    local input="$1"
    if [[ ! -f "$input" ]]; then
        echo "Move file not found: $input" >&2
        exit 1
    fi
    local dir
    dir="$(cd "$(dirname "$input")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$input")"
}

run_codegen() {
    cd "$codegen_dir"
    npx tsx "$@"
}

if [[ "${1:-}" == "--list" ]]; then
    if [[ $# -ne 2 ]]; then
        usage >&2
        exit 1
    fi
    move_file="$(resolve_file "$2")"
    run_codegen src/scan.ts "$move_file" --list
    exit 0
fi

if [[ "${1:-}" == "--from-schema" ]]; then
    if [[ $# -lt 2 ]]; then
        usage >&2
        exit 1
    fi
    action_id="$2"
    shift 2
    run_codegen src/generate.ts --action "$action_id" "$@"
    exit 0
fi

if [[ $# -lt 4 ]]; then
    usage >&2
    exit 1
fi

move_file="$(resolve_file "$1")"
function_name="$2"
shift 2

action_id=""
dry_run_args=()
scan_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "--id requires an action id" >&2
                exit 1
            fi
            action_id="$2"
            scan_args+=("--id" "$2")
            shift 2
            ;;
        --dry-run)
            dry_run_args+=("--dry-run")
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$action_id" ]]; then
    echo "Pass --id <action_id> so the generated schema and output are stable." >&2
    exit 1
fi

run_codegen src/scan.ts "$move_file" "$function_name" "${scan_args[@]}"
run_codegen src/generate.ts --action "$action_id" "${dry_run_args[@]}"
