# AGENTS.md

This repository (`json-schema-cli-benchmark`) is maintained by a **multi-agent** team (humans + coding agents).
It benchmarks JSON Schema **CLI validators** for correctness, ergonomics, and performance in a shell-centric workflow.

Agents must follow the policies below. If a task provides stricter instructions, follow those unless they
conflict with the commit policy.

---

## 1) Prime directive

Optimize for:
- **Correctness parity** across tools (pass/fail must match)
- **Reproducibility** (benchmarks must be rerunnable and deterministic)
- **Traceability** (clear methodology; clear provenance of results)
- **Shell ergonomics** (stdin/stdout-first workflows)

Avoid drive-by refactors. Keep changesets minimal and reviewable.

---

## 2) Development environment (MANDATORY)

We develop **inside Nix**:

- The dev environment is defined by `shell.nix`.
- All work is performed inside `nix-shell` (or an equivalent workflow using `shell.nix`).
- **All dependency changes** must be made by editing `shell.nix`.

The **single entry point** is the `justfile`:
- Run `just --list` to discover all available recipes.
- All workflows (codegen, experiment lifecycle, benchmarking, validation, analysis) are exposed as `just` recipes.
- Do **not** add Makefiles, shell wrappers, or other entry points. Extend the `justfile` instead.

Dependency policy:
- New dependencies are allowed only if:
  - they exist in **nixpkgs**, OR
  - they can be encapsulated into a **single Nix expression** and included in `buildInputs`.

Tooling preferences:
- Prefer `rg` over `grep`.
- Do not assume `tree` is available; use `rg`, `find`, or targeted file listings.

---

## 3) Benchmark goals and invariants (CORE)

We benchmark JSON Schema validator CLIs to answer:

### 3.1 Schema validation vs metaschema
- How to validate a local JSON Schema against the appropriate metaschema.
- Record the **exact command** used per tool.

### 3.2 Instance validation vs local schema
- How to validate JSON instance data against a local JSON Schema.
- stdin → stdout is **primary**
- file → stdout is **secondary**

### 3.3 Draft / version targeting
- Target the **latest JSON Schema draft/version supported in common** by all benchmarked tools.
- The framework must allow benchmarking additional drafts later.
- Raw benchmark output **must include** a `schema_version` (or equivalent) field even if all rows share the same value.
  - Rendered reports may hide the column when constant.

### 3.4 Correctness parity (STRICT)
- Pass/fail results **must be identical** across tools for a given benchmark case.
- If a tool cannot perform a case (unsupported draft/feature/CLI limitation):
  - mark it as **FAIL/UNSUPPORTED**
  - **do not collect speed data** for that tool/case.

### 3.5 Error reporting
- Correctness comes first.
- Error reporting quality (clarity, path reporting) is important but secondary.
- When feasible, capture representative error output in a stable, diff-friendly form.

### 3.6 Data size
- Benchmark inputs should remain **< 1MB**.

---

## 4) Repository contents policy (MANDATORY)

This repository commits **everything** needed to reproduce results:
- schemas
- instance data
- benchmark scripts
- benchmark outputs (raw and processed)
- rendered reports

Benchmark output structure (`results/<draft>/<run_id>/`):
- `events.jsonl` — correctness and benchmark result events
- `jobs.jsonl` — raw timing data from hyperfine (individual `times[]`, `exit_codes[]`, `memory_usage_byte[]` per job)
- `output-N.jsonl` — tool stdout/stderr captured per worker
- `system.json` — machine/environment snapshot

Per-job artifact directories were eliminated in favor of flat JSONL to reduce storage (~10x). Raw timing arrays in `jobs.jsonl` preserve all data that was previously in separate hyperfine JSON files.

Formatting rules for stability:
- JSON files must be **prettified** and deterministic.
- JSONL files must be stable:
  - deterministic field order
  - deterministic numeric formatting where feasible
  - avoid embedding large, highly variable blobs
- Prefer stable ordering of rows/records in outputs.

---

## 5) Benchmark execution

- The benchmark runner is `bench/run.py` (Python), which orchestrates `hyperfine` for timing.
  Python was chosen over pure shell for type safety (Pydantic models), manifest validation, and structured event output.
  Hyperfine remains the timing backend.
- Bench harnesses must:
  - emit machine-readable output (e.g. JSON),
  - record tool identity and version,
  - record the exact command invoked,
  - record benchmark case identifiers and schema version.

Avoid benchmark noise:
- use warmups when appropriate,
- document run counts and parameters,
- avoid hidden environment dependencies.

---

## 6) Planning before changes

For any non-trivial change, include a short plan in the commit body:
- **Goal**
- **Non-goals**
- **Approach**
- **Verification plan**

When uncertain, state assumptions explicitly. Do not silently guess.

---

## 7) Commit policy (MANDATORY)

### 7.1 Subject line format
The commit subject **must** be prefixed with "[ai]"

Examples:
- `[ai] Add schema-vs-metaschema benchmark cases`
- `[ai] Add adapter for sourcemeta/jsonschema CLI`
- `[ai] Normalize benchmark output with schema_version field`

### 7.2 Co-authorship trailer (MANDATORY)

Claude Code auto-appends a co-author trailer.

- **If you are Claude Code:** do nothing extra.
- **If you are NOT Claude Code:** you **must** add a co-author trailer at the end of the commit body.

Use one of:

Preferred:

Co-authored-by <Agent Name> agent@example.invalid

If identity/email is not applicable:

Co-authored-by AI Agent

Use `.invalid` to avoid leaking personal addresses.

---

## 8) Commit body templates

### Bugfix
**Problem**  
**Symptoms**  
**Reproduction**  
**Root cause**  
**Fix strategy**  
**Solution**  
**Resolution / Verification** (commands run)  
**Impact**

### Feature
**Need / Motivation**  
**Design / Reasoning**  
**Implementation**  
**Verification** (commands run)  
**Impact**

### Benchmark / methodology change
**Question**  
**Method**  
**Datasets**  
**Correctness parity checks**  
**Confounders / Caveats**  
**Verification**  
**Impact**

---

## 9) Workflow and history model

- Work is **single-threaded**: one agent or human at a time.
- Commit **directly to `main`**.
- No merge commits; history is linear by construction.

---

## 10) Releases and changelog

- Releases are created via **tags on `main`**.
- At tag time:
  - an agent drafts release notes from the git log since the previous tag,
  - grouped by **scope**,
  - you may edit before finalizing the tag.
- Release notes are recorded in `CHANGELOG.md`.

---

## 11) When uncertain

- Prefer a small validating experiment.
- If verification is not possible, mark uncertainty explicitly and propose a follow-up.

