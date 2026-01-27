#!/usr/bin/env bash
# Experiment manager - handles scaffolding, validation, and status
# Usage: ./tools/experiment-manager.sh <command> <draft>
#
# Commands:
#   new       Create new experiment with manifest.json
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
  new       Create new experiment with manifest.json
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
# State checks
# -----------------------------------------------------------------------------

has_dir() { [[ -d "$EXPERIMENTS_DIR/$DRAFT" ]]; }
has_manifest() { [[ -f "$EXPERIMENTS_DIR/$DRAFT/manifest.json" ]]; }
has_cases_defined() { has_manifest && [[ $(jq '.cases | keys | length' "$EXPERIMENTS_DIR/$DRAFT/manifest.json") -gt 0 ]]; }
has_cases_dir() { [[ -d "$EXPERIMENTS_DIR/$DRAFT/cases" ]]; }

# Schema validation (returns 0 if valid, 1 if invalid)
manifest_schema_valid() {
    has_manifest || return 1
    check-jsonschema --schemafile "$SCHEMAS_DIR/manifest.schema.json" \
        "$EXPERIMENTS_DIR/$DRAFT/manifest.json" >/dev/null 2>&1
}

# Capture schema validation errors
manifest_schema_errors() {
    has_manifest || return
    check-jsonschema --schemafile "$SCHEMAS_DIR/manifest.schema.json" \
        "$EXPERIMENTS_DIR/$DRAFT/manifest.json" 2>&1 || true
}

missing_case_dirs() {
    has_manifest || return
    for case_name in $(jq -r '.cases | keys[]' "$EXPERIMENTS_DIR/$DRAFT/manifest.json"); do
        [[ -d "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name" ]] || echo "$case_name"
    done
}

missing_schemas() {
    has_manifest || return
    for case_name in $(jq -r '.cases | keys[]' "$EXPERIMENTS_DIR/$DRAFT/manifest.json"); do
        [[ -f "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name/schema.json" ]] || echo "$case_name"
    done
}

missing_instances() {
    has_manifest || return
    for case_name in $(jq -r '.cases | to_entries[] | select(.value.instance_valid != null) | .key' "$EXPERIMENTS_DIR/$DRAFT/manifest.json"); do
        [[ -f "$EXPERIMENTS_DIR/$DRAFT/cases/$case_name/instance.json" ]] || echo "$case_name"
    done
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_new() {
    has_manifest && die "manifest.json already exists: $EXPERIMENTS_DIR/$DRAFT/manifest.json"

    mkdir -p "$EXPERIMENTS_DIR/$DRAFT"
    jsonnet --ext-str "draft=$DRAFT" "$DIRSCHEMA_DIR/manifest.template.jsonnet" \
        > "$EXPERIMENTS_DIR/$DRAFT/manifest.json"

    echo "Created: $EXPERIMENTS_DIR/$DRAFT/manifest.json"
    cmd_status
}

cmd_hydrate() {
    has_manifest || die "manifest.json not found. Run: $0 new $DRAFT"
    has_cases_defined || die "No cases defined in manifest.json. Edit it first."

    jsonnet --ext-code "manifest=$(cat "$EXPERIMENTS_DIR/$DRAFT/manifest.json")" \
        "$DIRSCHEMA_DIR/experiment-cases.jsonnet" \
        | "$DIRSCHEMA_BIN" hydrate --root "$EXPERIMENTS_DIR/$DRAFT" -

    echo "Hydrated case directories."
    cmd_status
}

cmd_validate() {
    has_manifest || die "manifest.json not found."

    jsonnet --ext-code "manifest=$(cat "$EXPERIMENTS_DIR/$DRAFT/manifest.json")" \
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
        echo "  [ ] edit      - add cases to manifest.json"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make new-experiment DRAFT=$DRAFT"
        return
    fi

    if ! has_manifest; then
        echo "  [~] new       - directory exists, manifest missing"
        echo "  [ ] edit      - add cases to manifest.json"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make new-experiment DRAFT=$DRAFT"
        return
    fi

    echo "  [x] new       - manifest.json exists"

    # Check manifest schema validity
    if ! manifest_schema_valid; then
        echo "  [!] schema    - manifest.json is INVALID"
        echo ""
        echo "Schema errors:"
        manifest_schema_errors | sed 's/^/    /'
        echo ""
        echo "Next: fix manifest.json errors"
        return
    fi

    echo "  [x] schema    - manifest.json is valid"

    if ! has_cases_defined; then
        echo "  [ ] edit      - add cases to manifest.json (currently empty)"
        echo "  [ ] hydrate   - create case directories"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: edit $EXPERIMENTS_DIR/$DRAFT/manifest.json"
        return
    fi

    local case_count=$(jq '.cases | keys | length' "$EXPERIMENTS_DIR/$DRAFT/manifest.json")
    echo "  [x] edit      - $case_count cases defined"

    local missing_dirs=$(missing_case_dirs)
    if [[ -n "$missing_dirs" ]]; then
        echo "  [ ] hydrate   - missing dirs: $missing_dirs"
        echo "  [ ] content   - add schema.json / instance.json"
        echo "  [ ] validate  - check structure"
        echo ""
        echo "Next: make hydrate-experiment DRAFT=$DRAFT"
        return
    fi

    echo "  [x] hydrate   - case directories exist"

    local missing_s=$(missing_schemas)
    local missing_i=$(missing_instances)
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
