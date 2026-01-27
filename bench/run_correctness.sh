#!/usr/bin/env bash
# Run correctness checks for all tools × cases in an experiment
#
# Usage: ./bench/run_correctness.sh <draft>
# Example: ./bench/run_correctness.sh draft-2020-12
#
# Outputs JSONL to results/<draft>/correctness.jsonl

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "Usage: $0 <draft>"
DRAFT="$1"

EXPERIMENT_DIR="$REPO_ROOT/experiments/$DRAFT"
RESULTS_DIR="$REPO_ROOT/results/$DRAFT"
ADAPTERS_DIR="$REPO_ROOT/tools/adapters"

[[ -d "$EXPERIMENT_DIR" ]] || die "Experiment not found: $EXPERIMENT_DIR"
[[ -f "$EXPERIMENT_DIR/manifest.json" ]] || die "Manifest not found: $EXPERIMENT_DIR/manifest.json"

mkdir -p "$RESULTS_DIR"

# Load manifest (requires jq)
MANIFEST="$EXPERIMENT_DIR/manifest.json"

# Output file
OUTPUT="$RESULTS_DIR/correctness.jsonl"
: > "$OUTPUT"  # truncate

# Collect adapters
mapfile -t ADAPTERS < <(find "$ADAPTERS_DIR" -name '*.sh' -type f | sort)

[[ ${#ADAPTERS[@]} -gt 0 ]] || die "No adapters found in $ADAPTERS_DIR"

# Helper: map exit code to outcome string
# VALID = validator accepted the input
# INVALID = validator rejected the input
# UNSUPPORTED = operation not supported by tool
# ERROR = tool error (crash, bad args, etc.)
exit_to_outcome() {
    case "$1" in
        0) echo "VALID" ;;
        1) echo "INVALID" ;;
        2) echo "UNSUPPORTED" ;;
        *) echo "ERROR" ;;
    esac
}

# Helper: emit a JSONL row
emit_row() {
    local draft="$1"
    local tool="$2"
    local tool_version="$3"
    local case_id="$4"
    local operation="$5"
    local mode="$6"
    local exit_code="$7"
    local outcome="$8"
    local expected="$9"
    local match="${10}"

    printf '{"draft":"%s","tool":"%s","tool_version":"%s","case_id":"%s","operation":"%s","mode":"%s","exit_code":%d,"outcome":"%s","expected":%s,"match":%s}\n' \
        "$draft" "$tool" "$tool_version" "$case_id" "$operation" "$mode" "$exit_code" "$outcome" "$expected" "$match"
}

# Main loop
for adapter in "${ADAPTERS[@]}"; do
    tool_name="$(basename "$adapter" .sh)"
    chmod +x "$adapter"

    # Get tool version
    tool_version="$("$adapter" version 2>/dev/null || echo "unknown")"
    tool_version="${tool_version//\"/\\\"}"  # escape quotes for JSON

    echo "=== Tool: $tool_name ($tool_version) ===" >&2

    # Iterate cases
    for case_dir in "$EXPERIMENT_DIR/cases"/*/; do
        [[ -d "$case_dir" ]] || continue
        case_id="$(basename "$case_dir")"
        schema="$case_dir/schema.json"
        instance="$case_dir/instance.json"

        [[ -f "$schema" ]] || { echo "  SKIP $case_id: no schema.json" >&2; continue; }

        # Get expected outcomes from manifest (jq outputs true/false/null as literals)
        expected_schema=$(jq ".cases[\"$case_id\"].schema_valid" "$MANIFEST")
        expected_instance=$(jq ".cases[\"$case_id\"].instance_valid" "$MANIFEST")

        # --- Schema validation ---
        set +e
        "$adapter" validate-schema "$schema" >/dev/null 2>&1
        schema_exit=$?
        set -e
        schema_outcome=$(exit_to_outcome $schema_exit)

        # Determine match for schema validation
        # expected=true means schema should be valid, so outcome should be VALID
        # expected=false means schema should be invalid, so outcome should be INVALID
        if [[ "$expected_schema" == "true" && "$schema_outcome" == "VALID" ]]; then
            schema_match="true"
        elif [[ "$expected_schema" == "false" && "$schema_outcome" == "INVALID" ]]; then
            schema_match="true"
        elif [[ "$expected_schema" == "null" ]]; then
            schema_match="null"
        else
            schema_match="false"
        fi

        emit_row "$DRAFT" "$tool_name" "$tool_version" "$case_id" "schema" "file" "$schema_exit" "$schema_outcome" "$expected_schema" "$schema_match" >> "$OUTPUT"
        echo "  $case_id/schema: $schema_outcome (expected=$expected_schema, match=$schema_match)" >&2

        # --- Instance validation (only if instance exists) ---
        if [[ -f "$instance" ]]; then
            # File mode
            set +e
            "$adapter" validate-instance "$schema" "$instance" >/dev/null 2>&1
            instance_exit=$?
            set -e
            instance_outcome=$(exit_to_outcome $instance_exit)

            if [[ "$expected_instance" == "true" && "$instance_outcome" == "VALID" ]]; then
                instance_match="true"
            elif [[ "$expected_instance" == "false" && "$instance_outcome" == "INVALID" ]]; then
                instance_match="true"
            elif [[ "$expected_instance" == "null" ]]; then
                instance_match="null"
            else
                instance_match="false"
            fi

            emit_row "$DRAFT" "$tool_name" "$tool_version" "$case_id" "instance" "file" "$instance_exit" "$instance_outcome" "$expected_instance" "$instance_match" >> "$OUTPUT"
            echo "  $case_id/instance(file): $instance_outcome (expected=$expected_instance, match=$instance_match)" >&2

            # Stdin mode
            set +e
            "$adapter" validate-instance-stdin "$schema" < "$instance" >/dev/null 2>&1
            stdin_exit=$?
            set -e
            stdin_outcome=$(exit_to_outcome $stdin_exit)

            if [[ "$expected_instance" == "true" && "$stdin_outcome" == "VALID" ]]; then
                stdin_match="true"
            elif [[ "$expected_instance" == "false" && "$stdin_outcome" == "INVALID" ]]; then
                stdin_match="true"
            elif [[ "$expected_instance" == "null" ]]; then
                stdin_match="null"
            else
                stdin_match="false"
            fi

            emit_row "$DRAFT" "$tool_name" "$tool_version" "$case_id" "instance" "stdin" "$stdin_exit" "$stdin_outcome" "$expected_instance" "$stdin_match" >> "$OUTPUT"
            echo "  $case_id/instance(stdin): $stdin_outcome (expected=$expected_instance, match=$stdin_match)" >&2
        fi
    done
done

echo "" >&2
echo "Results written to: $OUTPUT" >&2

# Summary
total=$(wc -l < "$OUTPUT" | tr -d ' ')
matched=$(rg -c '"match":true' "$OUTPUT" 2>/dev/null || echo 0)
failed=$(rg -c '"match":false' "$OUTPUT" 2>/dev/null || echo 0)

echo "Summary: $total rows, $matched matched, $failed mismatched" >&2
