# json-schema-cli-benchmarks

Benchmarks JSON Schema CLI validators for correctness and performance in a shell-centric workflow.

## Quick start

**Requires [Nix](https://nixos.org/download/).** All dependencies are provided by `shell.nix`.

```bash
nix-shell          # enter dev environment — everything is available
just               # show all available recipes
just info          # show experiments, tools, schemas, models
just status        # show readiness checklist for all experiments
```

## Creating and running an experiment

An experiment tests multiple CLI validators against a set of schema/instance cases for a specific JSON Schema draft.

### 1. Scaffold

```bash
just new draft-07              # creates experiments/draft-07/manifest.yaml
```

### 2. Define cases

Edit `experiments/draft-07/manifest.yaml` and add cases:

```yaml
draft: draft-07
cases:
  valid-object:
    schema_valid: true
    instance_valid: true
  invalid-type:
    schema_valid: true
    instance_valid: false
  invalid-schema:
    schema_valid: false
    instance_valid: null          # null = no instance validation
```

### 3. Hydrate

```bash
just hydrate draft-07          # creates cases/<name>/schema.json (+ instance.json) stubs
```

Fill in the schema and instance files under `experiments/draft-07/cases/`.

### 4. Check readiness

```bash
just status draft-07           # shows which steps are complete
just validate-experiment draft-07  # validates manifest + directory structure
```

### 5. Run

```bash
just run draft-07              # correctness + speed benchmarks
just run-correctness draft-07  # correctness only (faster iteration)
```

Results land in `results/draft-07/<timestamp>/`.

### 6. Validate results

```bash
just validate-run results/draft-07/2026-02-15T09-45-21
just validate-runs             # validate all run directories
```

## Directory structure

```
experiments/<draft>/            # one dir per JSON Schema draft
  manifest.yaml                 # case definitions + expected outcomes
  cases/<case>/
    schema.json                 # schema under test
    instance.json               # instance to validate (optional)

tools/adapters/<tool>.sh        # normalized adapter per CLI tool
bench/run.py                    # unified benchmark runner

results/<draft>/<timestamp>/    # one dir per benchmark run
  system.json                   # machine/environment info
  events.jsonl                  # per-check correctness results
  jobs.jsonl                    # per-job timing data

generators/*.jsonnet            # JSON Schema generators (jsonnet → schemas/)
schemas/*.schema.json           # generated JSON Schemas for our data model
dirschema/                      # directory structure specs for validation
src/models/                     # generated Pydantic models
```

## Tool adapters

Each adapter in `tools/adapters/` wraps a CLI validator with a normalized interface:

```bash
just list-tools                # show available adapters
```

Exit code convention: `0` = VALID, `1` = INVALID, `2` = UNSUPPORTED, `3` = ERROR.

To add a new tool: copy an existing adapter, implement the `version`, `validate-schema`, `validate-instance`, and `validate-instance-stdin` commands, and add the tool binary to `shell.nix`.

## Result bundles

```bash
just bundle                    # create results-YYYY-MM-DD.N.tar.zst
just list-releases             # list available bundles on GitHub
just download-release <tag>    # download a bundle
```

Bundles are uploaded manually to GitHub Releases.

## Design decisions

### Why separate correctness and speed?

Correctness is fast (single run per case). Speed is slow (warmup + N runs via hyperfine). Iterate on correctness first; only benchmark speed when correctness passes across all tools.

### Why VALID/INVALID instead of PASS/FAIL?

`PASS`/`FAIL` is ambiguous — does "FAIL" mean the test failed or the validator rejected the input? `VALID`/`INVALID` describes what the validator did. `match: true/false` in events.jsonl describes whether the test passed.

### Why one directory per case?

Shell-friendly iteration (`for case in experiments/draft-07/cases/*/`), self-contained, supports multiple instances per case.

### Why explicit draft versions?

Reproducibility — "latest" changes over time. Adding tools doesn't change experiment meaning. The experiment name is self-documenting.

## License

TBD
