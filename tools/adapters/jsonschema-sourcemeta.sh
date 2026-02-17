#!/usr/bin/env bash
# Adapter for sourcemeta/jsonschema
# https://github.com/sourcemeta/jsonschema
#
# Exit codes:
#   0 = VALID (input accepted by validator)
#   1 = INVALID (input rejected by validator)
#   2 = UNSUPPORTED (operation not supported)
#   3 = ERROR (tool error)
#
# Note: This tool uses exit code 2 for validation failures, which we map to 1.
#       It uses exit code 1 for errors (e.g., file not found).

set -euo pipefail

TOOL_BIN="${JSONSCHEMA_SOURCEMETA_BIN:-jsonschema-sourcemeta}"

cmd_version() {
    # Version may go to stdout or stderr depending on build
    "$TOOL_BIN" version 2>&1
}

cmd_validate_schema() {
    local schema="$1"
    local exit_code
    # metaschema validates schema against its declared $schema
    "$TOOL_BIN" metaschema "$schema" && exit_code=0 || exit_code=$?
    case $exit_code in
        0) return 0 ;;  # VALID
        2) return 1 ;;  # INVALID (tool uses 2 for validation failure)
        *) return 3 ;;  # ERROR
    esac
}

cmd_validate_instance() {
    local schema="$1"
    local instance="$2"
    local exit_code
    "$TOOL_BIN" validate "$schema" "$instance" && exit_code=0 || exit_code=$?
    case $exit_code in
        0) return 0 ;;  # VALID
        2) return 1 ;;  # INVALID (tool uses 2 for validation failure)
        *) return 3 ;;  # ERROR
    esac
}

cmd_validate_instance_stdin() {
    # sourcemeta/jsonschema does not support reading instance from stdin
    return 2  # UNSUPPORTED
}

usage() {
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  version                           Print tool version
  validate-schema <schema>          Validate schema against metaschema
  validate-instance <schema> <inst> Validate instance against schema (file)
  validate-instance-stdin <schema>  Validate instance against schema (stdin)

Exit codes:
  0 = VALID, 1 = INVALID, 2 = UNSUPPORTED, 3 = ERROR
EOF
}

main() {
    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 3
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        version)
            cmd_version
            ;;
        validate-schema)
            [[ $# -ge 1 ]] || { echo "Missing schema argument" >&2; exit 3; }
            cmd_validate_schema "$1"
            ;;
        validate-instance)
            [[ $# -ge 2 ]] || { echo "Missing schema or instance argument" >&2; exit 3; }
            cmd_validate_instance "$1" "$2"
            ;;
        validate-instance-stdin)
            [[ $# -ge 1 ]] || { echo "Missing schema argument" >&2; exit 3; }
            cmd_validate_instance_stdin "$1"
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage >&2
            exit 3
            ;;
    esac
}

main "$@"
