# json-schema-cli-benchmark

Benchmarks JSON Schema CLI validators for correctness and performance.

> **Status:** Early development. Data model and automation are provisional and subject to change.

## Goals

1. **Correctness parity** — Do all tools agree on what's valid/invalid for the same inputs?
2. **Performance comparison** — How fast is each tool for schema and instance validation?
3. **Shell ergonomics** — stdin/stdout-first workflows

## Quick start

```bash
# Enter dev environment
nix-shell

# Run correctness checks
make correctness

# Run speed benchmarks (requires correctness to pass first)
make speed

# Generate report
make report

# Or run everything
make
```

## Directory structure

```
experiments/                    # Test fixtures (one dir per draft)
└── draft-07/
    ├── manifest.json           # Case definitions + expected outcomes
    └── cases/
        ├── valid-object/
        │   ├── schema.json     # Schema under test
        │   └── instance.json   # Instance to validate
        └── invalid-type/
            ├── schema.json
            └── instance.json

tools/                          # Tool adapters
└── adapters/
    └── check-jsonschema.sh     # Adapter script

bench/                          # Harness scripts
├── run_correctness.sh
├── run_speed.sh
└── render_report.sh

results/                        # Outputs (gitignored or committed)
└── draft-07/
    ├── correctness.jsonl
    ├── speed.jsonl
    └── raw/                    # Raw hyperfine JSON
        └── check-jsonschema/

schemas/                        # (Future) JSON Schemas for our data model
```

## Creating a new experiment

An experiment is a collection of test cases for a specific JSON Schema draft.

### 1. Create the directory structure

```bash
mkdir -p experiments/draft-04/cases
```

### 2. Create the manifest

`experiments/draft-04/manifest.json`:

```json
{
  "draft": "draft-04",
  "meta_schema": "http://json-schema.org/draft-04/schema#",
  "cases": {
    "valid-object": {
      "description": "Valid object with required property",
      "schema_valid": true,
      "instance_valid": true
    },
    "invalid-type": {
      "description": "Instance has wrong type",
      "schema_valid": true,
      "instance_valid": false
    },
    "invalid-schema": {
      "description": "Schema uses invalid keyword",
      "schema_valid": false,
      "instance_valid": null
    }
  }
}
```

### 3. Create test cases

Each case is a directory under `cases/` containing:

- `schema.json` (required) — the schema under test
- `instance.json` (optional) — instance to validate against the schema

If `instance.json` is absent, only schema-vs-metaschema validation runs.

```bash
# Example: valid case
echo '{"$schema": "http://json-schema.org/draft-04/schema#", "type": "object"}' \
  > experiments/draft-04/cases/valid-object/schema.json
echo '{"name": "test"}' \
  > experiments/draft-04/cases/valid-object/instance.json
```

### 4. Run

```bash
make correctness-draft-04
make speed-draft-04
```

## Creating a new tool adapter

An adapter wraps a CLI tool with a normalized interface.

### 1. Create the adapter script

`tools/adapters/my-tool.sh`:

```bash
#!/usr/bin/env bash
# Adapter for my-tool
#
# Exit codes:
#   0 = VALID (input accepted)
#   1 = INVALID (input rejected)
#   2 = UNSUPPORTED (operation not supported)
#   3 = ERROR (tool error)

set -euo pipefail

TOOL_BIN="${MY_TOOL_BIN:-my-tool}"

case "$1" in
    version)
        "$TOOL_BIN" --version
        ;;
    validate-schema)
        # Validate schema against metaschema
        "$TOOL_BIN" check-schema "$2" && exit 0 || exit 1
        ;;
    validate-instance)
        # Validate instance against schema (file mode)
        "$TOOL_BIN" validate --schema "$2" "$3" && exit 0 || exit 1
        ;;
    validate-instance-stdin)
        # Validate instance against schema (stdin mode)
        "$TOOL_BIN" validate --schema "$2" /dev/stdin && exit 0 || exit 1
        ;;
    *)
        echo "Unknown command: $1" >&2
        exit 3
        ;;
esac
```

### 2. Make it executable

```bash
chmod +x tools/adapters/my-tool.sh
```

### 3. Set the binary path (if not in PATH)

```bash
export MY_TOOL_BIN=/path/to/my-tool
```

### 4. Run

The adapter is auto-discovered. Just run `make correctness`.

## Data model

### correctness.jsonl

Each row is one validation check (tool × case × operation × mode):

```json
{
  "draft": "draft-07",
  "tool": "check-jsonschema",
  "tool_version": "check-jsonschema, version 0.36.0",
  "case_id": "valid-object",
  "operation": "schema",
  "mode": "file",
  "exit_code": 0,
  "outcome": "VALID",
  "expected": true,
  "match": true
}
```

| Field | Description |
|-------|-------------|
| `draft` | JSON Schema draft being tested |
| `tool` | Adapter name (filename without .sh) |
| `tool_version` | Output of `adapter version` |
| `case_id` | Case directory name |
| `operation` | `schema` (vs metaschema) or `instance` (vs schema) |
| `mode` | `file` or `stdin` |
| `exit_code` | Raw exit code from adapter |
| `outcome` | `VALID`, `INVALID`, `UNSUPPORTED`, or `ERROR` |
| `expected` | Expected validity from manifest (`true`, `false`, `null`) |
| `match` | Did outcome match expected? (`true`, `false`, `null`) |

### speed.jsonl

Each row is timing data for one benchmark:

```json
{
  "draft": "draft-07",
  "tool": "check-jsonschema",
  "tool_version": "check-jsonschema, version 0.36.0",
  "case_id": "valid-object",
  "operation": "instance",
  "mode": "file",
  "mean": 0.1418,
  "stddev": 0.0011,
  "min": 0.1411,
  "max": 0.1426,
  "median": 0.1415,
  "runs": 10
}
```

Times are in seconds.

## Preconditions

System requirements (provided by `shell.nix`):

- `jq` — JSON processing
- `hyperfine` — Benchmarking
- `rg` (ripgrep) — Text search
- Tool binaries (e.g., `check-jsonschema`)

## Design decisions (ADR)

### Why separate correctness and speed phases?

- **Correctness is fast** (single run per case)
- **Speed is slow** (warmup + N runs via hyperfine)
- During development, iterate quickly on correctness before committing to full benchmarks
- In steady state, expect 100% correctness — failures indicate bugs in test fixtures, not validators

### Why VALID/INVALID instead of PASS/FAIL?

- `PASS`/`FAIL` is ambiguous — does "FAIL" mean the test failed or the validator rejected?
- `VALID`/`INVALID` describes what the validator did (accepted/rejected input)
- `match: true/false` describes whether the test passed

### Why one directory per case?

- Shell-friendly iteration: `for case in experiments/draft-07/cases/*/`
- Self-contained and movable
- Easy to add per-case metadata later
- Supports multiple instances per case (future)

### Why explicit draft versions instead of "common-latest"?

- **Reproducibility** — "latest" changes over time
- **No drift** — Adding tools doesn't change experiment meaning
- **Traceability** — Experiment name is self-documenting

## Future work

- [ ] JSON Schemas for manifest, correctness, speed data models
- [ ] Adapter template script
- [ ] More tool adapters (ajv-cli, jsonschema-rs, etc.)
- [ ] More drafts (draft-04, draft-06, draft-2020-12)
- [ ] Larger/realistic test cases
- [ ] CI integration

## License

TBD
