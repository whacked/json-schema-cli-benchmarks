# PLAN.md — json-schema-cli-benchmark

## Premise

We benchmark multiple JSON Schema validator CLIs to answer:

1) **Schema validation against metaschema**:
   - Can the tool validate a local JSON Schema against the appropriate metaschema?
   - What is the exact CLI command to do it?

2) **Instance validation against schema**:
   - Can the tool validate JSON instance data against a local JSON Schema?
   - stdin → stdout is the primary workflow; file → stdout is secondary.

Repo constraints:
- Dev environment is always `shell.nix` + `nix-shell`.
- Repo commits everything needed: fixtures, scripts, raw/normalized results, and reports.
- Correctness parity is strict: pass/fail must match expected outcomes across tools.
- Prefer `rg` over `grep`; do not assume `tree`.

Input size:
- Most fixtures will likely be O(1MB) for practicality, but **there is no hard size cap**.
- If an experiment needs a 10MB schema/instance, commit it and benchmark it.

---

## Core design

### A. Experiments are version-locked and horizontally expandable

Benchmarks are organized by explicit JSON Schema draft version:

- `experiments/<draft>/`

Examples:
- `experiments/draft-2020-12/` — JSON Schema Draft 2020-12
- `experiments/draft-07/` — JSON Schema Draft-07
- `experiments/draft-04/` — JSON Schema Draft-04

This is the "horizontal expansion surface":
- today: `draft-2020-12` (small, controlled)
- later: additional drafts, or specialized experiments like `openapi-3.1/`, `geojson/`

Each experiment contains:
- `manifest.json`: case list with expected outcomes
- `cases/`: one subdirectory per test case
- `notes.md`: optional explanation / provenance

Case directory structure:
```
experiments/draft-2020-12/
├── manifest.json
├── cases/
│   ├── valid-object/
│   │   ├── schema.json      # schema under test
│   │   └── instance.json    # instance to validate (optional)
│   ├── invalid-type-mismatch/
│   │   ├── schema.json
│   │   └── instance.json
│   └── schema-invalid-keyword/
│       └── schema.json      # no instance = schema-only case
└── notes.md
```

Case type is inferred from file presence:
- `schema.json` only → schema-vs-metaschema case
- `schema.json` + `instance.json` → instance-vs-schema case (also tests schema validity)

Initial experiment:
- `experiments/draft-2020-12/`

### B. Directory structure overview

```
experiments/                    # WHAT we test (shared fixtures)
└── draft-2020-12/
    ├── manifest.json
    ├── cases/
    │   ├── valid-object/
    │   │   ├── schema.json
    │   │   └── instance.json
    │   └── ...
    └── notes.md

tools/                          # HOW each tool is invoked
├── adapters/
│   ├── check-jsonschema.sh
│   ├── ajv.sh
│   └── ...
└── probe.sh

bench/                          # Harness scripts
├── run_correctness.sh
├── run_speed.sh
└── render_report.sh

results/                        # WHAT happened (outputs)
└── draft-2020-12/
    ├── correctness.jsonl
    ├── speed.jsonl
    └── raw/
        ├── check-jsonschema/
        └── ajv/
```

Separation of concerns:
- `experiments/<draft>/` — shared test fixtures and expected outcomes
- `tools/adapters/` — tool-specific CLI wrappers (normalization layer)
- `results/<draft>/` — per-tool outputs from benchmark runs

The harness iterates: `for tool in tools/adapters/*.sh; for case in experiments/<draft>/cases/*/`

### C. Tool adapters normalize CLI behavior

Each validator gets an adapter script in:

- `tools/adapters/<tool>.sh`

Adapter responsibilities:
- output tool identity + version
- provide normalized operations:
  - validate schema vs metaschema
  - validate instance vs schema (stdin primary; file secondary)
- normalize exit semantics:
  - PASS=0
  - FAIL=1
  - UNSUPPORTED=2
  - ERROR=3

A probing script (`tools/probe.sh`) interrogates adapters and emits capability info
(stdin support, file support, how draft/version is configured, etc.).

### D. Two-phase execution: correctness gate → speed

We only time things that pass correctness.

1) Correctness phase (`bench/run_correctness.sh`)
- For each tool × case:
  - run schema-vs-metaschema
  - run instance-vs-schema (stdin first; file second)
- Compare to expected outcomes.
- Record JSONL rows to:
  - `results/<draft>/correctness.jsonl`

Row fields (minimum):
- draft (e.g., "draft-2020-12")
- tool
- tool_version
- case_id
- operation: schema|instance
- mode: stdin|file
- outcome: PASS|FAIL|UNSUPPORTED|ERROR
- exit_code

2) Speed phase (`bench/run_speed.sh`)
- Only run for tool×case×mode combos that:
  - are supported
  - matched expected correctness
- Use `hyperfine` to time:
  - schema-vs-metaschema command
  - instance-vs-schema command (stdin and/or file)
- Store:
  - raw hyperfine JSON: `results/<draft>/raw/<tool>/`
  - normalized timing rows: `results/<draft>/speed.jsonl`

### E. Reporting

A renderer (`bench/render_report.sh`) generates:
- `REPORT.md` at repo root (publishable)

Report should include, per experiment:
- tools + versions
- support matrix (supported/unsupported per operation/mode)
- correctness parity summary
- speed tables for passing, supported cases

No “error reporting quality” comparisons are required; we only care about pass/fail ability + timing.

---

## Data model governance (repo-level schemas)

Beyond benchmark fixtures, the repo maintains **project-level schemas** for the artifacts we store:
- correctness JSONL row schema
- speed JSONL row schema
- (optional) adapter probe output schema
- (optional) raw hyperfine JSON schema (only if we rely on specific fields)

### A. `generators/` → `schemas/` pipeline

- `generators/` contains Jsonnet sources that define JSON Schemas.
- Root `Makefile` generates JSON Schemas into:
  - `schemas/` (checked into git)

Design goals:
- stable, conservative schemas
- human-readable where feasible
- schemas describe *our artifacts* (not the benchmarked tools)

### B. Optional meta-validation (artifact content)

Makefile includes optional targets to validate stored artifacts against these schemas.
Validation is optional, but supported and encouraged when:
- changing transformers
- changing output fields
- adding new experiments/tools that affect outputs

Transformers that rewrite stored artifacts should update schemas in `generators/`,
regenerate `schemas/`, and optionally validate.

---

## Experiment structure validation (filesystem → JSON → schema)

We validate the **experiment directory structure** itself (completeness of required files/dirs),
separately from validating file contents.

### A. Inventory: filesystem → JSON

Provide a script:
- `tools/exp_inventory.{sh|py}`
that converts `experiments/<name>/` into a deterministic JSON inventory.

Recommended minimal inventory shape:

```json
{
  "experiment": "draft-2020-12",
  "root": "experiments/draft-2020-12",
  "entries": [
    {"path": "manifest.json", "type": "file"},
    {"path": "cases", "type": "dir"},
    {"path": "cases/valid-object/schema.json", "type": "file"},
    {"path": "cases/valid-object/instance.json", "type": "file"}
  ]
}

