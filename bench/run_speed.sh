#!/usr/bin/env bash
# Run speed benchmarks for tool × case combos that passed correctness
#
# Usage: ./bench/run_speed.sh <draft>
# Example: ./bench/run_speed.sh draft-2020-12
#
# Requires: hyperfine
# Outputs JSONL to results/<draft>/speed.jsonl
# Raw hyperfine JSON goes to results/<draft>/raw/<tool>/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "Usage: $0 <draft>"
DRAFT="$1"

EXPERIMENT_DIR="$REPO_ROOT/experiments/$DRAFT"
RESULTS_DIR="$REPO_ROOT/results/$DRAFT"
ADAPTERS_DIR="$REPO_ROOT/tools/adapters"
CORRECTNESS_FILE="$RESULTS_DIR/correctness.jsonl"

[[ -d "$EXPERIMENT_DIR" ]] || die "Experiment not found: $EXPERIMENT_DIR"
[[ -f "$CORRECTNESS_FILE" ]] || die "Correctness results not found: $CORRECTNESS_FILE (run correctness first)"

# Check for hyperfine
command -v hyperfine >/dev/null 2>&1 || die "hyperfine not found in PATH"

# Output files
OUTPUT="$RESULTS_DIR/speed.jsonl"
: > "$OUTPUT"  # truncate

# Warmup and run counts
WARMUP="${BENCH_WARMUP:-3}"
RUNS="${BENCH_RUNS:-10}"

echo "Speed benchmark: warmup=$WARMUP, runs=$RUNS" >&2

# Get passing tool×case×operation×mode combos from correctness
# Filter: match=true (expected outcome matched)
passing_combos=$(jq -c 'select(.match == true)' "$CORRECTNESS_FILE")

# Group by tool
tools=$(echo "$passing_combos" | jq -r '.tool' | sort -u)

for tool in $tools; do
    adapter="$ADAPTERS_DIR/${tool}.sh"
    [[ -x "$adapter" ]] || { echo "SKIP: adapter not found: $adapter" >&2; continue; }

    tool_version=$(echo "$passing_combos" | jq -r "select(.tool == \"$tool\") | .tool_version" | head -1)

    RAW_DIR="$RESULTS_DIR/raw/$tool"
    mkdir -p "$RAW_DIR"

    echo "=== Tool: $tool ===" >&2

    # Get cases for this tool
    tool_combos=$(echo "$passing_combos" | jq -c "select(.tool == \"$tool\")")

    # Process each combo
    echo "$tool_combos" | while read -r combo; do
        case_id=$(echo "$combo" | jq -r '.case_id')
        operation=$(echo "$combo" | jq -r '.operation')
        mode=$(echo "$combo" | jq -r '.mode')

        case_dir="$EXPERIMENT_DIR/cases/$case_id"
        schema="$case_dir/schema.json"
        instance="$case_dir/instance.json"

        bench_name="${case_id}_${operation}_${mode}"
        raw_file="$RAW_DIR/${bench_name}.json"

        echo "  Benchmarking: $bench_name" >&2

        # Build the command based on operation and mode
        if [[ "$operation" == "schema" ]]; then
            cmd="$adapter validate-schema $schema"
        elif [[ "$operation" == "instance" && "$mode" == "file" ]]; then
            cmd="$adapter validate-instance $schema $instance"
        elif [[ "$operation" == "instance" && "$mode" == "stdin" ]]; then
            cmd="$adapter validate-instance-stdin $schema < $instance"
        else
            echo "    SKIP: unknown operation/mode: $operation/$mode" >&2
            continue
        fi

        # Run hyperfine
        # --ignore-failure: benchmark commands that return non-zero (e.g., invalid input rejection)
        if hyperfine \
            --ignore-failure \
            --warmup "$WARMUP" \
            --runs "$RUNS" \
            --export-json "$raw_file" \
            --shell bash \
            "$cmd" 2>/dev/null; then

            # Extract timing from hyperfine JSON
            mean=$(jq '.results[0].mean' "$raw_file")
            stddev=$(jq '.results[0].stddev' "$raw_file")
            min=$(jq '.results[0].min' "$raw_file")
            max=$(jq '.results[0].max' "$raw_file")
            median=$(jq '.results[0].median' "$raw_file")

            # Emit JSONL row
            printf '{"draft":"%s","tool":"%s","tool_version":"%s","case_id":"%s","operation":"%s","mode":"%s","mean":%s,"stddev":%s,"min":%s,"max":%s,"median":%s,"runs":%d}\n' \
                "$DRAFT" "$tool" "$tool_version" "$case_id" "$operation" "$mode" \
                "$mean" "$stddev" "$min" "$max" "$median" "$RUNS" >> "$OUTPUT"
        else
            echo "    WARN: hyperfine failed for $bench_name" >&2
        fi
    done
done

echo "" >&2
echo "Results written to: $OUTPUT" >&2
total=$(wc -l < "$OUTPUT" | tr -d ' ')
echo "Total benchmarks: $total" >&2
