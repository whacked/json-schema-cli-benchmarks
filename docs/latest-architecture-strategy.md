# Manifest-Driven JSON Schema Validator Benchmark

**Execution Design & Requirements (Clarified Version)**

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

These are **distinct operations**, with different applicability rules and different expected outcomes.

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
results/<draft>/events.jsonl
```

Append-only.

---

### 9.2 Event Envelope (All Events)

| Field          | Meaning                        |
| -------------- | ------------------------------ |
| `event`        | Event type discriminator       |
| `ts`           | ISO-8601 timestamp             |
| `draft`        | Draft identifier               |
| `tool`         | Tool name                      |
| `tool_version` | Observed tool version          |
| `case_id`      | Case identifier                |
| `operation`    | `schema` / `instance`          |
| `mode`         | `file` / `stdin`               |
| `job_id`       | Stable job hash                |
| `status`       | `ok` / `unsupported` / `error` |

---

### 9.3 Event Types

#### `correctness_result`

Additional fields:

* `exit_code`
* `outcome` (`VALID`, `INVALID`, `UNSUPPORTED`, `ERROR`)
* `expected`
* `match`
* `stdout_path`
* `stderr_path`

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
* `hyperfine_json_path`

---

## 10. Artifacts

Per job:

```
results/<draft>/runs/<job_id>/
├── stdout.txt
├── stderr.txt
└── hyperfine.json
```

Artifacts are referenced by events and exist for debugging and reproducibility.

---

## 11. Post-Processing: Events → Rows

### Purpose

Produce a 2-D, analysis-ready dataset.

### Input

* `events.jsonl`
* `manifest.json` (for metadata joins)

### Logic

* Group by `job_id`
* Require one correctness event
* Attach benchmark data only if `match == true`
* Join `meta` by `(draft, case_id)`

### Output

```
results/<draft>/rows.jsonl
```

The row schema may evolve independently of the runner.

---

## 12. Code Generation

### Schemas

* `schemas/manifest.schema.json`
* `schemas/events.schema.json`
* (optional) `schemas/rows.schema.json`

### Usage

* JSON Schema → Pydantic / dataclasses
* Schema remains the single source of truth
* Semantic invariants enforced in code

---

## 13. End-to-End Flow

1. Human edits `manifest.json`
2. Runner validates manifest + directory layout
3. Jobs are generated deterministically
4. Runner executes jobs
5. Events + artifacts are recorded
6. Post-processor derives rows
7. Reporting consumes rows

---

## Final Note

Two expectations (`schema_valid`, `instance_valid`) are canonical **because there are exactly two primitive correctness questions the system asks**.
They are not symmetric, not always applicable, and not always populated — and that asymmetry is **intentional and enforced**.

