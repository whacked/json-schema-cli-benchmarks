# Development Overview

> **Status:** Active refactoring. This document captures current state and immediate priorities for handoff.

## Current Architecture

### Directory Structure

```
experiments/                    # Test fixtures (tool-agnostic)
└── draft-07/
    ├── manifest.json           # Case declarations + expected outcomes
    └── cases/
        └── <case-name>/
            ├── schema.json     # JSON Schema under test
            └── instance.json   # Instance to validate (optional)

tools/
├── adapters/
│   └── check-jsonschema.sh    # Tool adapter (normalized CLI interface)
└── experiment-manager.sh      # Scaffolding + status tracking

dirschema/
├── manifest.template.jsonnet  # Generates manifest.json for new experiments
└── experiment-cases.jsonnet   # Generates dirschema spec from manifest

bench/
├── run_correctness.sh         # Correctness phase runner
├── run_speed.sh               # Speed phase runner (hyperfine)
└── render_report.sh           # Generates REPORT.md

results/                       # Outputs (generated)
└── draft-07/
    ├── correctness.jsonl
    ├── speed.jsonl
    └── raw/<tool>/            # Raw hyperfine JSON

schemas/                       # (Planned) JSON Schemas for our data model
```

### Key Components

| Component | Role | Location |
|-----------|------|----------|
| Manifest | Declares cases + expected outcomes | `experiments/<draft>/manifest.json` |
| Case fixtures | Test inputs (schema.json, instance.json) | `experiments/<draft>/cases/*/` |
| Tool adapters | Normalize CLI interface per tool | `tools/adapters/<tool>.sh` |
| Experiment manager | Scaffolding workflow (new/hydrate/validate/status) | `tools/experiment-manager.sh` |
| Correctness runner | Executes validation, compares to expected | `bench/run_correctness.sh` |
| Speed runner | Runs hyperfine benchmarks | `bench/run_speed.sh` |

### Data Flow

```
manifest.json
    │
    ├──→ experiment-cases.jsonnet ──→ dirschema hydrate (creates case dirs)
    │
    └──→ run_correctness.sh ──→ correctness.jsonl
                │
                └──→ run_speed.sh ──→ speed.jsonl
```

---

## Recent Decisions

### 1. Merge correctness and speed outputs

**Decision:** Single `results.jsonl` instead of separate `correctness.jsonl` + `speed.jsonl`.

**Rationale:**
- Always analyzed together
- Avoids join
- Correctness gates speed; if `match: false`, timing fields are `null`

**New unified row structure:**
```json
{
  "draft": "draft-07",
  "tool": "check-jsonschema",
  "tool_version": "0.36.0",
  "case_id": "valid-object",
  "operation": "instance",
  "mode": "file",
  "outcome": "VALID",
  "expected": true,
  "match": true,
  "mean_s": 0.142,
  "stddev_s": 0.003,
  "min_s": 0.138,
  "max_s": 0.149,
  "runs": 10
}
```

**Status:** Not yet implemented. Requires merging `run_correctness.sh` and `run_speed.sh`.

### 2. Remove `meta_schema` from manifest

**Decision:** Keep only `draft` in manifest. Derive `meta_schema` URL when needed.

**Rationale:**
- Redundant: `draft-07` implies `http://json-schema.org/draft-07/schema#`
- Single source of truth for the mapping in `manifest.template.jsonnet`

**Status:** Not yet implemented.

### 3. Directory organization confirmed

**Decision:** Keep draft at directory level, tool at field level.

**Rationale:**
- Fixtures (schema.json, instance.json) are shared across tools
- Adding a tool doesn't duplicate fixtures
- Results are JSONL — filter by tool trivially

### 4. Move toward Python runner with codegen

**Decision:** Rewrite runner in Python. Use code generation for dataclasses (not hand-written).

**Rationale:**
- Type safety for manifest parsing and result writing
- Codegen from JSON Schema ensures single source of truth
- Python already indirectly in stack (check-jsonschema)

**Status:** Not yet started. Depends on schema definition.

NOTE: there's an example of the codegen pipeline from jsonnet schema -> json schema -> pydantic model
defined in the Makefile's `schemas` target, reading from ./generators and ./schemas and ./src/schemas

---

## Immediate Priorities

### Priority 1: Define manifest JSON Schema

**Why first:** Everything else depends on this. The schema is the single source of truth.

**Location:** `schemas/manifest.schema.json`

**Must define:**
- `draft` (string, enum of valid drafts)
- `cases` (object, keys are case names)
- Case structure: `schema_valid` (boolean), `instance_valid` (boolean | null)
- Optional: `description` per case

**Open question:** Should the schema allow per-experiment extension, or be strict?

### Priority 2: Define results JSON Schema

**Location:** `schemas/results.schema.json`

**Must define:**
- All fields from the unified row structure above
- Types, nullability

### Priority 3: Codegen Python dataclasses from schemas

**Approach:** Use a tool like `datamodel-code-generator` or similar to generate Python dataclasses/Pydantic models from JSON Schema.

```bash
datamodel-codegen --input schemas/manifest.schema.json --output lib/models/manifest.py
datamodel-codegen --input schemas/results.schema.json --output lib/models/results.py
```

**Status:** User will provide guidance on codegen tooling.

### Priority 4: Rewrite runner in Python

**Replace:** `bench/run_correctness.sh` + `bench/run_speed.sh`

**With:** `bench/run.py` (or similar)

note that we have included python dependencies in the environment (see shell.nix buildInputs).
this is ALL the dependencies we will use. of these, pydantic is the most important;
it is the main reason we want to replace shell with python -- so we can read from the manifest and have structure and type checking

**Behavior:**
1. Load manifest, validate against schema
2. For each tool × case × operation × mode:
   - Run correctness check
   - If match, run hyperfine
   - Emit unified result row
3. Write `results/<draft>/results.jsonl`

### Priority 5: Update experiment-manager for new manifest structure

**Changes needed:**
- Remove `meta_schema` handling
- Validate manifest against JSON Schema
- Update jsonnet templates

---

## Open Questions

### Q1: Per-experiment schema variation?

**Context:** Current manifest structure assumes all experiments have the same case fields (`schema_valid`, `instance_valid`). Some experiments might need different fields.

**Options:**
- A: Strict schema, all experiments identical
- B: Base schema + per-experiment extensions
- C: Schema is minimal (just case names), experiment-specific runner interprets

**Current lean:** Start with A (strict), revisit if needed.

### Q2: Where does draft → meta_schema mapping live?

**Options:**
- In `manifest.template.jsonnet` (current)
- In JSON Schema as enum
- In Python codegen output
- In a shared config file

**Current lean:** Keep in jsonnet for generation, replicate in Python for runtime.

### Q3: Hyperfine integration in Python runner

**Options:**
- Shell out to hyperfine, parse JSON output
- Use Python benchmarking library directly
- Keep hyperfine, Python orchestrates

**Current lean:** Shell out to hyperfine. It's battle-tested.

---

## Technical Context

### Tool Adapter Interface

Adapters must implement:
```bash
./adapter.sh version                          # Print version
./adapter.sh validate-schema <schema>         # Exit 0=VALID, 1=INVALID
./adapter.sh validate-instance <schema> <inst> # Exit 0=VALID, 1=INVALID
./adapter.sh validate-instance-stdin <schema>  # Read instance from stdin
```

Exit codes: `0=VALID, 1=INVALID, 2=UNSUPPORTED, 3=ERROR`

### dirschema Usage

```bash
# Validate structure
jsonnet --ext-code "manifest=$(cat manifest.json)" experiment-cases.jsonnet \
  | dirschema validate --root experiments/draft-07 -

# Hydrate (create directories)
jsonnet --ext-code "manifest=$(cat manifest.json)" experiment-cases.jsonnet \
  | dirschema hydrate --root experiments/draft-07 -
```

Requires dirschema >= 20260125.3.

### Current Dependencies

- `jq` — JSON processing
- `jsonnet` — Template generation
- `hyperfine` — Benchmarking
- `dirschema` — Directory structure validation/hydration
- `check-jsonschema` — JSON Schema validation (also a benchmark target)

### Environment Variables

- `DIRSCHEMA_BIN` — Path to dirschema binary
- `CHECK_JSONSCHEMA_BIN` — Path to check-jsonschema binary

---

## Files to Modify/Create

| Action | File | Description |
|--------|------|-------------|
| Create | `schemas/manifest.schema.json` | Manifest JSON Schema |
| Create | `schemas/results.schema.json` | Results row JSON Schema |
| Create | `lib/models/manifest.py` | Codegen'd dataclasses |
| Create | `lib/models/results.py` | Codegen'd dataclasses |
| Create | `bench/run.py` | Unified Python runner |
| Modify | `dirschema/manifest.template.jsonnet` | Remove meta_schema |
| Modify | `experiments/draft-07/manifest.json` | Remove meta_schema |
| Modify | `Makefile` | Update targets for new runner |

---

## How to Continue

1. **Read this document** to understand current state
2. **Define schemas** in `schemas/` (Priority 1 & 2)
3. **Run codegen** to generate Python models (Priority 3)
4. **Implement Python runner** using generated models (Priority 4)
5. **Update experiment-manager** and Makefile (Priority 5)
6. **Test end-to-end** with draft-07 experiment
7. **Clean up** old bash scripts once Python runner is validated
