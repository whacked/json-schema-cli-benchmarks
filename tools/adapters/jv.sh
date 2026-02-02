#!/usr/bin/env bash
# Adapter for jv (JSON Schema validator)
# https://github.com/santhosh-tekuri/jsonschema
#
# Exit codes:
#   0 = VALID (input accepted by validator)
#   1 = INVALID (input rejected by validator)
#   2 = UNSUPPORTED (operation not supported)
#   3 = ERROR (tool error)

set -euo pipefail

TOOL_BIN="${JV_BIN:-jv}"

cmd_version() {
    # jv --version outputs multiple lines; extract version from jsonschema module line
    # e.g., "github.com/santhosh-tekuri/jsonschema/v6 v6.0.1" -> "v6.0.1"
    "$TOOL_BIN" --version 2>/dev/null | grep 'jsonschema/v[0-9]' | awk '{print $2}'
}

cmd_validate_schema() {
    local schema="$1"
    # Validates schema against its declared $schema (metaschema)
    # When called without an instance, jv validates the schema only
    if "$TOOL_BIN" "$schema" >/dev/null 2>&1; then
        return 0  # VALID
    else
        return 1  # INVALID
    fi
}

cmd_validate_instance() {
    local schema="$1"
    local instance="$2"
    if "$TOOL_BIN" "$schema" "$instance" >/dev/null 2>&1; then
        return 0  # VALID
    else
        return 1  # INVALID
    fi
}

cmd_validate_instance_stdin() {
    local schema="$1"
    if "$TOOL_BIN" "$schema" /dev/stdin >/dev/null 2>&1; then
        return 0  # VALID
    else
        return 1  # INVALID
    fi
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
