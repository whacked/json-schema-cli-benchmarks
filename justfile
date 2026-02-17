# justfile — single entry point for json-schema-cli-benchmarks
# Run `just --list` to see all available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

experiments_dir := "experiments"
results_dir := "results"
bench_dir := "bench"
tools_dir := "tools"
schemas_dir := "schemas"
dirschema_dir := "dirschema"

[private]
default:
    @just --list

# ─── Codegen ─────────────────────────────────────────────────

# Regenerate all schemas and pydantic models from jsonnet
[group('codegen')]
codegen: codegen-schemas codegen-models

# Regenerate JSON Schemas from jsonnet
[group('codegen')]
codegen-schemas:
    jsonnet generators/events.schema.jsonnet | jq -S > schemas/events.schema.json
    jsonnet generators/manifest.schema.jsonnet | jq -S > schemas/manifest.schema.json
    jsonnet generators/system.schema.jsonnet | jq -S > schemas/system.schema.json
    jsonnet generators/hyperfine.schema.jsonnet | jq -S > schemas/hyperfine.schema.json
    jsonnet generators/jobs.schema.jsonnet | jq -S > schemas/jobs.schema.json
    jsonnet generators/output.schema.jsonnet | jq -S > schemas/output.schema.json

# Regenerate Pydantic models from schemas
[group('codegen')]
codegen-models:
    @mkdir -p src/models
    datamodel-codegen --input schemas/manifest.schema.json --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output src/models/manifest.py
    datamodel-codegen --input schemas/events.schema.json --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output src/models/events.py
    datamodel-codegen --input schemas/system.schema.json --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output src/models/system.py
    datamodel-codegen --input schemas/jobs.schema.json --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output src/models/jobs.py
    datamodel-codegen --input schemas/output.schema.json --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output src/models/output.py

# ─── Experiment lifecycle ────────────────────────────────────

# Create new experiment with manifest template
[group('experiment')]
new draft: (_check-no-manifest draft)
    @mkdir -p "{{ experiments_dir }}/{{ draft }}"
    jsonnet --ext-str "draft={{ draft }}" "{{ dirschema_dir }}/manifest.template.jsonnet" \
        | yq -P > "{{ experiments_dir }}/{{ draft }}/manifest.yaml"
    @echo "Created: {{ experiments_dir }}/{{ draft }}/manifest.yaml"
    @just status "{{ draft }}"

# Create case directories from manifest
[group('experiment')]
hydrate draft: (_check-manifest draft) (_check-schema draft)
    #!/usr/bin/env bash
    manifest_json=$(just _manifest-as-json "{{ draft }}")
    jsonnet --ext-code "manifest=${manifest_json}" "{{ dirschema_dir }}/experiment-cases.jsonnet" \
        | dirschema hydrate --root "{{ experiments_dir }}/{{ draft }}" -
    echo "Hydrated case directories."
    just status "{{ draft }}"

# Generate benchmark corpus via jsf
[group('experiment')]
gen-corpus draft *args: (_check-manifest draft)
    python3 "{{ tools_dir }}/generate_corpus.py" --draft "{{ draft }}" {{ args }}

# Show experiment readiness checklist
[group('experiment')]
status draft="":
    #!/usr/bin/env bash
    if [[ -z "{{ draft }}" ]]; then
        found=0
        for d in "{{ experiments_dir }}"/*/; do
            [[ -d "$d" ]] || continue
            name=$(basename "$d")
            just status "$name"
            found=1
        done
        [[ $found -eq 1 ]] || echo "No experiments found. Run: just new <draft>"
        exit 0
    fi

    draft="{{ draft }}"
    exp_dir="{{ experiments_dir }}/$draft"
    manifest=""
    manifest_name=""

    # [1] new — manifest exists?
    if [[ -f "$exp_dir/manifest.yaml" ]]; then
        manifest="$exp_dir/manifest.yaml"
        manifest_name="manifest.yaml"
    elif [[ -f "$exp_dir/manifest.json" ]]; then
        manifest="$exp_dir/manifest.json"
        manifest_name="manifest.json"
    fi

    echo ""
    echo "=== $draft ==="

    if [[ -n "$manifest" ]]; then
        echo "  [x] new       - $manifest_name"
    else
        echo "  [ ] new       - create experiment"
        echo ""
        echo "Next: just new $draft"
        exit 0
    fi

    # [2] schema — manifest validates against schema?
    manifest_json=$(cat "$manifest" | yq -o j)
    if printf '%s' "$manifest_json" | jsonschema-cli schemas/manifest.schema.json -i /dev/stdin >/dev/null 2>&1; then
        echo "  [x] schema    - $manifest_name valid"
    else
        echo "  [!] schema    - $manifest_name INVALID"
        echo ""
        echo "Next: fix $manifest_name errors"
        exit 0
    fi

    # [3] edit — cases defined?
    case_count=$(printf '%s' "$manifest_json" | jq '.cases | keys | length')
    if [[ "$case_count" -gt 0 ]]; then
        echo "  [x] edit      - $case_count cases defined"
    else
        echo "  [ ] edit      - add cases to manifest"
        echo ""
        echo "Next: edit $manifest"
        exit 0
    fi

    # [4] hydrate — cases/ directory exists?
    if [[ -d "$exp_dir/cases" ]]; then
        echo "  [x] hydrate   - cases/ exists"
    else
        echo "  [ ] hydrate   - run hydrate command"
        echo ""
        echo "Next: just hydrate $draft"
        exit 0
    fi

    # [5] content — dirschema validates all files present?
    dirschema_output=$(jsonnet --ext-code "manifest=$manifest_json" \
        "{{ dirschema_dir }}/experiment-cases.jsonnet" \
        | dirschema validate -format json --root "$exp_dir" - 2>&1) && dirschema_ok=true || dirschema_ok=false
    if $dirschema_ok; then
        echo "  [x] content   - all files present"
    else
        n_errors=$(printf '%s' "$dirschema_output" | jq '.errors | length' 2>/dev/null || echo "?")
        echo "  [ ] content   - $n_errors missing files"
        echo ""
        echo "Next: fill in missing files"
        exit 0
    fi

    # [6] ready
    echo "  [x] validate  - structure valid"
    echo ""
    echo "Ready: just run $draft"

# ─── Benchmarking ────────────────────────────────────────────

# Run benchmarks (correctness + speed)
[group('bench')]
run draft *args: (_check-manifest draft) (_check-schema draft) (_check-hydrated draft)
    python3 "{{ bench_dir }}/run.py" "{{ draft }}" {{ args }}

# Run correctness only (skip speed)
[group('bench')]
run-correctness draft *args: (_check-manifest draft) (_check-schema draft) (_check-hydrated draft)
    python3 "{{ bench_dir }}/run.py" "{{ draft }}" --skip-speed {{ args }}

# ─── Validation (atomic) ─────────────────────────────────────

# Validate manifest against JSON Schema
[group('validate')]
validate-manifest draft: (_check-manifest draft)
    #!/usr/bin/env bash
    t0=$EPOCHREALTIME
    manifest_json=$(just _manifest-as-json "{{ draft }}")
    if printf '%s' "$manifest_json" | jsonschema-cli schemas/manifest.schema.json -i /dev/stdin >/dev/null 2>&1; then
        printf 'PASS {{ draft }} manifest (%ss)\n' "$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")"
    else
        printf 'FAIL {{ draft }} manifest (%ss)\n' "$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")"
        printf '%s' "$manifest_json" | jsonschema-cli schemas/manifest.schema.json -i /dev/stdin 2>&1 || true
        exit 1
    fi

# Validate experiment directory structure (dirschema/experiment-cases.jsonnet)
[group('validate')]
validate-experiment-structure draft: (_check-manifest draft)
    #!/usr/bin/env bash
    t0=$EPOCHREALTIME
    manifest_json=$(just _manifest-as-json "{{ draft }}")
    spec=$(jsonnet --ext-code "manifest=${manifest_json}" "{{ dirschema_dir }}/experiment-cases.jsonnet")
    result=$(printf '%s' "$spec" | dirschema validate --format json --root "{{ experiments_dir }}/{{ draft }}" - 2>&1) \
        && ds_ok=true || ds_ok=false
    dt=$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")
    if $ds_ok; then
        echo "PASS {{ draft }} experiment structure (dirschema/experiment-cases.jsonnet) (${dt}s)"
    else
        echo "FAIL {{ draft }} experiment structure (dirschema/experiment-cases.jsonnet) (${dt}s)"
        if printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1; then
            printf '%s' "$result" | jq -r '.errors[] | "  missing: \(.path // .message)"'
        else
            printf '%s\n' "$result"
        fi
        exit 1
    fi

# Validate run output directory structure (dirschema/run-output.yaml)
[group('validate')]
validate-run-structure dir:
    #!/usr/bin/env bash
    t0=$EPOCHREALTIME
    result=$(dirschema validate --format json --root "{{ dir }}" "{{ dirschema_dir }}/run-output.yaml" 2>&1) \
        && ds_ok=true || ds_ok=false
    dt=$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")
    if $ds_ok; then
        echo "PASS {{ dir }} run structure (dirschema/run-output.yaml) (${dt}s)"
    else
        echo "FAIL {{ dir }} run structure (dirschema/run-output.yaml) (${dt}s)"
        if printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1; then
            printf '%s' "$result" | jq -r '.errors[] | "  missing: \(.path // .message)"'
        else
            printf '%s\n' "$result"
        fi
        exit 1
    fi

# Validate run output file contents against JSON Schemas
[group('validate')]
validate-run-content dir:
    #!/usr/bin/env bash
    just _validate-json schemas/system.schema.json "{{ dir }}/system.json"

    [[ -f "{{ dir }}/events.jsonl" ]] && \
        just _validate-jsonl schemas/events.schema.json "{{ dir }}/events.jsonl"

    [[ -f "{{ dir }}/jobs.jsonl" ]] && \
        just _validate-jsonl schemas/jobs.schema.json "{{ dir }}/jobs.jsonl"

    for f in "{{ dir }}"/output-*.jsonl; do
        [[ -f "$f" ]] || continue
        just _validate-jsonl schemas/output.schema.json "$f"
    done

# ─── Validation (composite) ─────────────────────────────────

# Validate experiment manifest + directory structure
[group('validate')]
validate-experiment draft: (validate-manifest draft) (validate-experiment-structure draft)

# Validate run output directory structure + all data files
[group('validate')]
validate-run dir: (validate-run-structure dir) (validate-run-content dir)

# Validate all run output directories
[group('validate')]
validate-runs:
    #!/usr/bin/env bash
    for r in "{{ results_dir }}"/*/*/; do
        [[ -d "$r" ]] || continue
        echo "=== $r ==="
        just validate-run "$r" || true
    done

# Validate everything (all experiments + all results)
[group('validate')]
validate-all:
    #!/usr/bin/env bash
    passes=0; failures=0

    for d in "{{ experiments_dir }}"/*/; do
        [[ -d "$d" ]] || continue
        draft=$(basename "$d")
        # skip dirs without a manifest
        [[ -f "$d/manifest.json" || -f "$d/manifest.yaml" ]] || continue
        if just validate-experiment "$draft" 2>&1; then
            passes=$((passes + 1))
        else
            failures=$((failures + 1))
        fi
    done

    for r in "{{ results_dir }}"/*/*/; do
        [[ -d "$r" ]] || continue
        if just validate-run "$r" 2>&1; then
            passes=$((passes + 1))
        else
            failures=$((failures + 1))
        fi
    done

    printf '\n\033[1m=== Summary: %d passed, %d failed ===\033[0m\n' "$passes" "$failures"
    [[ $failures -eq 0 ]]

# ─── Info & discovery ────────────────────────────────────────

# Show repo status (experiments, results, tools)
[group('info')]
info:
    #!/usr/bin/env bash
    echo "=== Experiments ==="
    for d in "{{ experiments_dir }}"/*/; do
        [[ -d "$d" ]] || continue
        draft=$(basename "$d")
        manifest=""
        [[ -f "$d/manifest.json" ]] && manifest="$d/manifest.json"
        [[ -f "$d/manifest.yaml" ]] && manifest="$d/manifest.yaml"
        if [[ -n "$manifest" ]]; then
            cases=$(cat "$manifest" | yq -o j | jq '.cases | keys | length')
        else
            cases=0
        fi
        latest_run=""
        for r in "{{ results_dir }}/$draft"/*/; do
            [[ -d "$r" ]] && latest_run="$r"
        done
        if [[ -n "$latest_run" && -f "${latest_run}events.jsonl" ]]; then
            events=$(wc -l < "${latest_run}events.jsonl" | tr -d ' ')
            echo "  $draft: $cases cases, $events events (latest run)"
        else
            echo "  $draft: $cases cases, no results"
        fi
    done

    echo ""
    echo "=== Tools ==="
    for adapter in "{{ tools_dir }}"/adapters/*.sh; do
        name=$(basename "$adapter" .sh)
        version=$("$adapter" version 2>/dev/null | head -1 || echo "unknown")
        echo "  $name: $version"
    done

    echo ""
    echo "=== Schemas ==="
    ls -1 schemas/*.schema.json 2>/dev/null | xargs -I{} basename {} | sed 's/^/  /' || echo "  (none)"

    echo ""
    echo "=== Models ==="
    ls -1 src/models/*.py 2>/dev/null | xargs -I{} basename {} | grep -v __init__ | sed 's/^/  /' || echo "  (none)"

# List discovered drafts
[group('info')]
list-drafts:
    @for d in "{{ experiments_dir }}"/*/; do [ -d "$d" ] && basename "$d"; done | sort

# List available tool adapters
[group('info')]
list-tools:
    @for adapter in "{{ tools_dir }}"/adapters/*.sh; do basename "$adapter" .sh; done

# List cases in an experiment
[group('info')]
list-cases draft: (_check-manifest draft)
    #!/usr/bin/env bash
    just _manifest-as-json "{{ draft }}" | jq -r '.cases | keys[]'

# ─── Analysis ────────────────────────────────────────────────

# Start local webserver for analysis dashboard
[group('analysis')]
serve *args:
    cd analysis && python3 -m http.server {{ args }}

# ─── Releases ────────────────────────────────────────────────

# Bundle results/ into results-YYYY-MM-DD.N.tar.zst
[group('releases')]
bundle:
    #!/usr/bin/env bash
    [[ -d "{{ results_dir }}" ]] || { echo "No results/ directory"; exit 1; }
    date=$(date +%Y-%m-%d)
    n=1
    while [[ -f "results-${date}.${n}.tar.zst" ]]; do
        n=$((n + 1))
    done
    name="results-${date}.${n}.tar.zst"
    tar cf - results/ | zstd -q -o "$name"
    size=$(du -h "$name" | cut -f1)
    echo "Created: $name ($size)"

# List available result bundles on GitHub
[group('releases')]
list-releases:
    #!/usr/bin/env bash
    repo=$(git remote get-url origin | sed 's|.*github.com[:/]||; s|\.git$||')
    releases=$(curl -sf "https://api.github.com/repos/${repo}/releases" \
        | jq -r '.[] | select(.assets | length > 0) | {tag: .tag_name, date: .published_at, assets: [.assets[] | {name, size}]}')
    if [[ -z "$releases" || "$releases" == "null" ]]; then
        echo "No releases with assets found."
        echo "  https://github.com/${repo}/releases"
        exit 0
    fi
    printf '%-28s  %-10s  %s\n' "TAG" "DATE" "ASSET"
    printf '%-28s  %-10s  %s\n' "---" "----" "-----"
    echo "$releases" | jq -r '
        .date[:10] as $date |
        .assets[] |
        [.name, (.size / 1048576 * 10 | floor / 10 | tostring + " MB")] as [$name, $size] |
        "\(.tag)  \($date)  \($name) (\($size))"
    ' | while IFS= read -r line; do
        tag=$(echo "$line" | cut -d' ' -f1)
        rest=$(echo "$line" | cut -d' ' -f3-)
        date=$(echo "$line" | cut -d' ' -f2)
        printf '%-28s  %-10s  %s\n' "$tag" "$date" "$rest"
    done

# Download a result bundle from GitHub
[group('releases')]
download-release tag:
    #!/usr/bin/env bash
    repo=$(git remote get-url origin | sed 's|.*github.com[:/]||; s|\.git$||')
    release=$(curl -sf "https://api.github.com/repos/${repo}/releases/tags/{{ tag }}")
    if [[ -z "$release" || "$release" == "null" ]]; then
        echo "Release '{{ tag }}' not found."
        echo "Run 'just list-releases' to see available releases."
        exit 1
    fi
    # Find the .tar.zst asset
    asset_url=$(printf '%s' "$release" | jq -r '.assets[] | select(.name | endswith(".tar.zst")) | .browser_download_url' | head -1)
    asset_name=$(printf '%s' "$release" | jq -r '.assets[] | select(.name | endswith(".tar.zst")) | .name' | head -1)
    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "No .tar.zst asset in release '{{ tag }}'."
        # Show what assets are available
        printf '%s' "$release" | jq -r '.assets[] | "  \(.name) (\(.size / 1048576 * 10 | floor / 10) MB)"'
        exit 1
    fi
    if [[ -f "$asset_name" ]]; then
        echo "Already downloaded: $asset_name"
    else
        echo "Downloading: $asset_name"
        curl -L --progress-bar -o "$asset_name" "$asset_url"
    fi
    size=$(du -h "$asset_name" | cut -f1)
    echo "Ready: $asset_name ($size)"
    echo ""
    echo "Extract with:"
    echo "  zstd -dc $asset_name | tar xf -"

# ─── Cleanup ─────────────────────────────────────────────────

# Remove all results for a draft
[group('cleanup')]
clean draft:
    rm -rf "{{ results_dir }}/{{ draft }}"

# Remove all results
[group('cleanup')]
clean-all:
    rm -rf "{{ results_dir }}"

# ─── Private helpers ─────────────────────────────────────────

[private]
_check-manifest draft:
    @test -f "{{ experiments_dir }}/{{ draft }}/manifest.json" \
        -o -f "{{ experiments_dir }}/{{ draft }}/manifest.yaml" \
        || (echo "No manifest for {{ draft }}. Run: just new {{ draft }}"; exit 1)

[private]
_check-no-manifest draft:
    @test ! -f "{{ experiments_dir }}/{{ draft }}/manifest.json" \
        -a ! -f "{{ experiments_dir }}/{{ draft }}/manifest.yaml" \
        || (echo "Manifest already exists for {{ draft }}"; exit 1)

[private]
_check-schema draft:
    #!/usr/bin/env bash
    manifest_json=$(just _manifest-as-json "{{ draft }}")
    printf '%s' "$manifest_json" | jsonschema-cli schemas/manifest.schema.json -i /dev/stdin >/dev/null 2>&1 \
        || (echo "Manifest for {{ draft }} is invalid. Run: just validate-experiment {{ draft }}"; exit 1)

[private]
_check-hydrated draft:
    @test -d "{{ experiments_dir }}/{{ draft }}/cases" \
        || (echo "Cases missing for {{ draft }}. Run: just hydrate {{ draft }}"; exit 1)

[private]
_manifest-as-json draft:
    #!/usr/bin/env bash
    if [[ -f "{{ experiments_dir }}/{{ draft }}/manifest.json" ]]; then
        cat "{{ experiments_dir }}/{{ draft }}/manifest.json"
    elif [[ -f "{{ experiments_dir }}/{{ draft }}/manifest.yaml" ]]; then
        cat "{{ experiments_dir }}/{{ draft }}/manifest.yaml" | yq -o j
    else
        echo "No manifest for {{ draft }}" >&2; exit 1
    fi

[private]
_validate-json schema file:
    #!/usr/bin/env bash
    t0=$EPOCHREALTIME
    base=$(basename "{{ file }}")
    if jsonschema-cli "{{ schema }}" -i <(cat "{{ file }}" | yq -o j) >/dev/null 2>&1; then
        printf 'PASS %s (%ss)\n' "$base" "$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")"
    else
        printf 'FAIL %s (%ss)\n' "$base" "$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")"
        exit 1
    fi

[private]
_validate-jsonl schema file:
    #!/usr/bin/env bash
    t0=$EPOCHREALTIME
    total=$(wc -l < "{{ file }}" | tr -d ' ')
    base=$(basename "{{ file }}")
    printf '  .. %s (%d records)\r' "$base" "$total" >&2
    jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
    errs=$(< "{{ file }}" tr '\n' '\0' \
        | xargs -0 -n1 -P "$jobs" sh -c \
            'printf "%s" "$2" | jsonschema-cli "$1" -i /dev/stdin >/dev/null 2>&1 || echo x' \
            _ "{{ schema }}" \
        | wc -l | tr -d ' ')
    printf '\033[2K\r' >&2
    dt=$(awk "BEGIN{printf \"%.1f\", $EPOCHREALTIME - $t0}")
    if [[ "$errs" -eq 0 ]]; then
        echo "PASS $base ($total records, ${dt}s)"
    else
        echo "FAIL $base ($errs/$total failed, ${dt}s)"
        exit 1
    fi
