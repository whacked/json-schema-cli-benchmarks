#!/usr/bin/env bash
# Experiment manager - handles scaffolding, validation, and status
# Usage: ./tools/experiment-manager.sh <command> <draft>
#
# Commands:
#   new       Create new experiment with manifest.yaml
#   hydrate   Create case directories from manifest
#   validate  Validate structure matches manifest
#   status    Show setup progress and next steps

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIRSCHEMA_DIR="$REPO_ROOT/dirschema"
EXPERIMENTS_DIR="$REPO_ROOT/experiments"
SCHEMAS_DIR="$REPO_ROOT/schemas"
DIRSCHEMA_BIN="${DIRSCHEMA_BIN:-dirschema}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 <command> <draft>

Commands:
  new       Create new experiment with manifest.yaml
  hydrate   Create case directories from manifest
  validate  Validate structure matches manifest
  status    Show setup progress and next steps

Example:
  $0 new draft-04
  $0 status draft-04
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Manifest helpers (YAML preferred, JSON fallback)
# -----------------------------------------------------------------------------

# Returns path to manifest file (yaml preferred)
manifest_path() {
    local yaml_path="$EXPERIMENTS_DIR/$DRAFT/manifest.yaml"
    local json_path="$EXPERIMENTS_DIR/$DRAFT/manifest.json"
    if [[ -f "$yaml_path" ]]; then
        echo "$yaml_path"
    elif [[ -f "$json_path" ]]; then
        echo "$json_path"
    else
        echo ""
    fi
}

# Load manifest as JSON (converts yaml if needed)
load_manifest() {
    local path
    path=$(manifest_path)
    [[ -n "$path" ]] || return 1
    if [[ "$path" == *.yaml ]]; then
        yq -o j "$path"
    else
        cat "$path"
    fi
}

# -----------------------------------------------------------------------------
# State checks
# -----------------------------------------------------------------------------

has_dir() { [[ -d "$EXPERIMENTS_DIR/$DRAFT" ]]; }
has_manifest() { [[ -n "$(manifest_path)" ]]; }
has_cases_defined() { has_manifest && [[ $(load_manifest | jq '.cases | keys | length') -gt 0 ]]; }
has_cases_dir() { [[ -d "$EXPERIMENTS_DIR/$DRAFT/cases" ]]; }

# Schema validation (returns 0 if valid, 1 if invalid)
manifest_schema_valid() {
    has_manifest || return 1
    check-jsonschema --schemafile "$SCHEMAS_DIR/manifest.schema.json" \
        "$(manifest_path)" >/dev/null 2>&1
}

# Capture schema validation errors
manifest_schema_errors() {
    has_manifest || return
    check-jsonschema --schemafile "$SCHEMAS_DIR/manifest.schema.json" \
        "$(manifest_path)" 2>&1 || true
}

missing_case_dirs() {
    has_manifest || return
    for case_name in $(load_manifest | jq -r '.cases | keys[]'); do
        [[ -d "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name" ]] || echo "$case_name"
    done
}

missing_schemas() {
    has_manifest || return
    for case_name in $(load_manifest | jq -r '.cases | keys[]'); do
        [[ -f "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name/schema.json" ]] || echo "$case_name"
    done
}

missing_instances() {
    has_manifest || return
    for case_name in $(load_manifest | jq -r '.cases | to_entries[] | select(.value.instance_valid != null) | .key'); do
        [[ -f "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name/instance.json" ]] || echo "$case_name"
    done
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_new() {
    has_manifest && die "manifest already exists: $(manifest_path)"

    mkdir -p "$EXPERIMENTS_DIR/$DRAFT"
    # Generate YAML manifest (more human-friendly)
    jsonnet --ext-str "draft=$DRAFT" "$DIRSCHEMA_DIR/manifest.template.jsonnet" \
        | yq -o y -P \
        > "$EXPERIMENTS_DIR/$DRAFT/manifest.yaml"

    echo "Created: $EXPERIMENTS_DIR/$DRAFT/manifest.yaml"
    cmd_status
}

cmd_hydrate() {
    has_manifest || die "manifest not found. Run: $0 new $DRAFT"
    has_cases_defined || die "No cases defined in manifest. Edit it first."

    jsonnet --ext-code "manifest=$(load_manifest)" \
        "$DIRSCHEMA_DIR/experiment-cases.jsonnet" \
        | "$DIRSCHEMA_BIN" hydrate --root "$EXPERIMENTS_DIR/$DRAFT" -

    echo "Hydrated case directories."
    cmd_status
}

cmd_validate() {
    has_manifest || die "manifest not found."

    jsonnet --ext-code "manifest=$(load_manifest)" \
        "$DIRSCHEMA_DIR/experiment-cases.jsonnet" \
        | "$DIRSCHEMA_BIN" validate --root "$EXPERIMENTS_DIR/$DRAFT" -

    echo "Validation passed."
}

cmd_status() {
    echo ""
    echo "=== $DRAFT ==="

    # Determine current step
    if ! has_dir; then
        echo "  [ ] new       - create experiment"
        echo "  [ ] edit      - add cases to manifest"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make new-experiment DRAFT=$DRAFT"
        return
    fi

    if ! has_manifest; then
        echo "  [~] new       - directory exists, manifest missing"
        echo "  [ ] edit      - add cases to manifest"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make new-experiment DRAFT=$DRAFT"
        return
    fi

    local mpath
    mpath=$(manifest_path)
    local mname
    mname=$(basename "$mpath")

    echo "  [x] new       - $mname exists"

    # Check manifest schema validity
    if ! manifest_schema_valid; then
        echo "  [!] schema    - $mname is INVALID"
        echo ""
        echo "Schema errors:"
        manifest_schema_errors | sed 's/^/    /'
        echo ""
        echo "Next: fix $mname errors"
        return
    fi

    echo "  [x] schema    - $mname is valid"

    if ! has_cases_defined; then
        echo "  [ ] edit      - add cases to $mname (currently empty)"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: edit $mpath"
        return
    fi

    local case_count
    case_count=$(load_manifest | jq '.cases | keys | length')
    echo "  [x] edit      - $case_count cases defined"

    local missing_dirs
    missing_dirs=$(missing_case_dirs)
    if [[ -n "$missing_dirs" ]]; then
        echo "  [ ] hydrate   - missing dirs: $missing_dirs"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make hydrate-experiment DRAFT=$DRAFT"
        return
    fi

    echo "  [x] hydrate   - case directories exist"

    local missing_s
    local missing_i
    missing_s=$(missing_schemas)
    missing_i=$(missing_instances)
    if [[ -n "$missing_s" || -n "$missing_i" ]]; then
        [[ -n "$missing_s" ]] && echo "  [ ] content   - missing schema.json: $missing_s"
        [[ -n "$missing_i" ]] && echo "  [ ] content   - missing instance.json: $missing_i"
        [[ -z "$missing_s" && -z "$missing_i" ]] || echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: fill in missing files"
        return
    fi

    echo "  [x] content   - all files present"
    echo "  [?] validate  - run: make validate-experiment DRAFT=$DRAFT"
    echo ""
    echo "Ready: make run-$DRAFT"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

[[ $# -ge 2 ]] || usage

CMD="$1"
DRAFT="$2"

case "$CMD" in
    new)      cmd_new ;;
    hydrate)  cmd_hydrate ;;
    validate) cmd_validate ;;
    status)   cmd_status ;;
    *)        usage ;;
esac
