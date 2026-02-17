# Manifest-Driven JSON Schema Validator Benchmark

**Execution Design & Requirements**

> **Purpose**
> Provide a precise, unambiguous specification for implementing a manifest-driven benchmark harness for JSON Schema validators.
> This document defines *what exists*, *what it means*, *what runs*, and *what gets recorded*, including all invariants needed to avoid semantic confusion.

---

## 1. High-Level Model

The system benchmarks JSON Schema validator tools across drafts by executing **two kinds of correctness operations**:

1. **Schema validation**
   “Is this document a valid JSON Schema under the given draft?”

2. **Instance validation**
   “Does this JSON instance validate against this schema?”

---

## 2. Single Source of Truth: Manifest

### 2.1 Location

```
experiments/<draft>/manifest.json
```

Exactly one manifest exists per draft.

---

### 2.2 Manifest Shape (Conceptual)

```json
{
  "draft": "draft-07",
  "cases": {
    "<case_id>": {
      "schema_valid": true,
      "instance_valid": true | false | null,
      "instances": "instances/**/*.json",
      "meta": { "...": "..." }
    }
  }
}
```

---

### 2.3 Field Semantics

#### `draft` (required)

* JSON Schema draft identifier.
* Example values:

  * `draft-04`
  * `draft-07`
  * `draft-2019-09`
  * `draft-2020-12`
  * `draft-2024-09`

---

#### `cases` (required)

* Mapping from `case_id` → case specification.
* `case_id` is **local to the manifest** (no global uniqueness requirement).

---

#### Per-case fields

| Field            | Required | Meaning                                                             |
| ---------------- | -------- | ------------------------------------------------------------------- |
| `schema_valid`   | yes      | Expected result of schema validation                                |
| `instance_valid` | yes      | Expected result of instance validation, or `null` if not applicable |
| `instances`      | optional | **Single zsh-style glob selector** (relative to case directory)     |
| `meta`           | optional | Arbitrary metadata for reporting / filtering                        |

---

## 3. Fundamental Invariants (Critical)

These invariants are **mandatory** and must be enforced by validation code.

### 3.1 Applicability Invariants

1. **Schema validation always runs**

   * Every case produces a **schema-validation job**, regardless of validity.

2. **Instance validation only runs when schema is valid**

   * If `schema_valid == false`, **no instance-validation jobs are generated**.

---

### 3.2 Expectation Invariants

| Operation  | Required expectation       | Forbidden / irrelevant  |
| ---------- | -------------------------- | ----------------------- |
| `schema`   | `schema_valid`             | `instance_valid`        |
| `instance` | `instance_valid` (boolean) | `instance_valid = null` |

Formally:

* If `operation == "schema"`:

  * `schema_valid` **must exist**
  * `instance_valid` **must be `null`**
* If `operation == "instance"`:

  * `schema_valid` **must be `true`**
  * `instance_valid` **must be `true` or `false`**

---

## 4. Directory Structure & dirschema

### 4.1 Canonical Layout

```
experiments/<draft>/
├── manifest.json
└── cases/
    └── <case_id>/
        ├── schema.json
        └── instances/
            └── *.json
```

---

### 4.2 Role of dirschema

* **Validate** that the directory structure matches manifest intent.
* **Hydrate** missing directories or stub files.

### 4.3 Source of Truth

* The **manifest** defines *which cases exist* and *whether instances are expected*.
* The **project** defines invariant layout conventions.
* The **dirschema spec is generated** from the manifest; it is not hand-maintained.

---

## 5. Job Model

### 5.1 Job Definition

A **job** is one atomic execution of one tool against one case under one operation and one mode, and possibly one concrete instance file.

---

### 5.2 Job Dimensions

| Dimension   | Meaning                                             |
| ----------- | --------------------------------------------------- |
| `draft`     | JSON Schema draft                                   |
| `tool`      | Validator program                                   |
| `case_id`   | Case identifier                                     |
| `operation` | `schema` or `instance`                              |
| `mode`      | `file` or `stdin`                                   |
| `input_id`  | Relative path of instance file (instance jobs only) |

---

### 5.3 Instance Expansion

* The `instances` field is a **single zsh-style glob selector** (note we're fine with the glob facilities that python supports. full zsh support not needed).
* The runner resolves the selector at runtime.
* Each matched file produces a **separate instance-validation job**.
* `input_id` is the **relative path** under `cases/<case_id>/instances/`.

No numeric IDs are introduced.

---

## 6. Job Identity (`job_id`)

### 6.1 Purpose

* Stable correlation key across events, artifacts, and derived rows.
* Deterministic and reproducible.

---

### 6.2 Construction

1. Build a canonical JSON object with stable key ordering:

   ```json
   {
     "draft": "...",
     "tool": "...",
     "case_id": "...",
     "operation": "...",
     "mode": "...",
     "input_id": "..."   // omitted or null if not applicable
   }
   ```
2. Canonically serialize.
3. Compute `sha256`.
4. Encode as hex or base32.

The runner computes `job_id` **before execution**.

---

## 7. Tool Adapter Contract

Adapters are pure executables. They do **not** emit events.

```bash
adapter.sh version
adapter.sh validate-schema <schema>
adapter.sh validate-instance <schema> <instance>
adapter.sh validate-instance-stdin <schema>
```

### Exit Codes

| Code | Meaning     |
| ---- | ----------- |
| 0    | VALID       |
| 1    | INVALID     |
| 2    | UNSUPPORTED |
| 3    | ERROR       |

---

## 8. Runner Responsibilities (`bench/run.py`)

The runner:

1. Loads and validates `manifest.json` (JSON Schema + semantic invariants).
2. Generates dirschema spec and validates directory layout.
3. Enumerates jobs based on invariants.
4. For each job:

   * Computes `job_id`
   * Runs correctness check
   * Emits correctness event
   * If `match == true`, runs hyperfine
   * Emits benchmark event
5. Writes artifacts and appends events.

---

## 9. Event Log (Canonical Output)

### 9.1 Location

```
results/<draft>/<run_id>/events.jsonl
```

Each benchmark run produces a timestamped output directory. Append-only within a run.

---

### 9.2 Event Envelope (All Events)

| Field            | Meaning                                                    |
| ---------------- | ---------------------------------------------------------- |
| `event`          | Event type discriminator                                   |
| `ts`             | ISO-8601 timestamp                                         |
| `draft`          | Draft identifier                                           |
| `tool`           | Tool name                                                  |
| `tool_version`   | Observed tool version                                      |
| `case_id`        | Case identifier                                            |
| `operation`      | `schema` / `instance`                                      |
| `mode`           | `file` / `stdin`                                           |
| `job_id`         | Stable job hash                                            |
| `status`         | `ok` / `unsupported` / `error`                             |
| `schema_bytes`   | Size of schema file in bytes                               |
| `input_id`       | Relative path of instance file (instance operations only)  |
| `instance_bytes` | Size of instance file in bytes (null for schema-only ops)  |

---

### 9.3 Event Types

#### `correctness_result`

Additional fields:

* `exit_code` — raw exit code from adapter
* `outcome` (`VALID`, `INVALID`, `UNSUPPORTED`, `ERROR`)
* `expected` — expected validity from manifest
* `match` — did outcome match expected?

Tool stdout/stderr is captured in per-worker `output-N.jsonl` files (see §10), not inline in events.

**Important semantic rule:**

* For `operation="schema"`:

  * `expected == schema_valid`
  * `match = (observed_schema_outcome == schema_valid)`
* For `operation="instance"`:

  * `expected == instance_valid`
  * `match = (observed_instance_outcome == instance_valid)`

`match` always refers **only to the expectation relevant to the operation**.

---

#### `benchmark_result`

Additional fields:

* `mean_s`
* `stddev_s`
* `min_s`
* `max_s`
* `runs`

Raw timing data (individual run times, exit codes, memory usage) is preserved in `jobs.jsonl` (see §10).

---

## 10. Run Output Directory

Each benchmark run produces a directory:

```
results/<draft>/<run_id>/
├── system.json       # Machine/environment info (hostname, CPU, OS, tool versions)
├── events.jsonl      # Event log (correctness_result + benchmark_result records)
├── jobs.jsonl        # Consolidated hyperfine timing data (one record per benchmarked job)
└── output-N.jsonl    # Per-worker tool stdout/stderr capture (one file per parallel worker)
```

### File descriptions

| File | Contents |
| ---- | -------- |
| `system.json` | Machine identity and environment snapshot for reproducibility |
| `events.jsonl` | Append-only event log as described in §9 |
| `jobs.jsonl` | Raw hyperfine data: individual `times[]`, `exit_codes[]`, `memory_usage_byte[]` per benchmarked job. One JSONL record per job. |
| `output-N.jsonl` | Tool stdout/stderr captured during correctness checks, partitioned by worker process |

Structure is validated by `dirschema/run-output.yaml`.

**Design note:** Per-job artifact directories (`runs/<job_id>/stdout.txt`, etc.) were replaced by flat JSONL files to reduce storage overhead (~10x reduction). The raw timing arrays in `jobs.jsonl` preserve all data that was previously in separate hyperfine JSON files.

---

## 11. Post-Processing & Analysis

### Primary analysis surface

`events.jsonl` is the primary analysis surface. It contains both correctness and benchmark results in a single file, joined by `job_id`.

### Analysis scripts

Scripts in `analysis/` consume `events.jsonl` directly for comparison, visualization, and reporting.

---

## 12. Code Generation

### Schemas

* `schemas/manifest.schema.json`
* `schemas/events.schema.json`

### Usage

* JSON Schema → Pydantic / dataclasses
* Schema remains the single source of truth
* Semantic invariants enforced in code

---

## 13. End-to-End Flow

1. Human edits `manifest.json`
2. Runner validates manifest + directory layout
3. Jobs are generated deterministically
4. Runner executes jobs (correctness → benchmark for passing jobs)
5. Events are recorded to `events.jsonl`, timing data to `jobs.jsonl`, tool output to `output-N.jsonl`
6. Analysis scripts in `analysis/` consume `events.jsonl` for comparison and reporting

---

## Final Note

Two expectations (`schema_valid`, `instance_valid`) are canonical **because there are exactly two primitive correctness questions the system asks**.
They are not symmetric, not always applicable, and not always populated.

