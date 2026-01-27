# New Experiment Guide

## Workflow

```bash
# 1. Create experiment (generates manifest.json from template)
make new-experiment DRAFT=draft-2020-12

# 2. Edit manifest.json - add your cases
$EDITOR experiments/draft-2020-12/manifest.json

# 3. Check status (validates manifest against schema, shows next steps)
make status-experiment DRAFT=draft-2020-12

# 4. Scaffold directories (validates manifest first, then creates dirs via dirschema)
make hydrate-experiment DRAFT=draft-2020-12

# 5. Fill in schema.json / instance.json in each case dir

# 6. Validate structure (checks all required files exist)
make validate-experiment DRAFT=draft-2020-12

# 7. Run benchmarks (outputs events.jsonl)
make run-draft-2020-12
```

## Schema Validation at Each Step

| Step | What's validated | Tool |
|------|------------------|------|
| new | draft is valid | jsonnet assertion |
| status | manifest.json against schema | check-jsonschema |
| hydrate | manifest.json against schema | check-jsonschema |
| validate | directory structure matches manifest | dirschema |
| run | manifest via Pydantic, events output typed | Python/Pydantic |

## Manifest Format

```json
{
  "draft": "draft-2020-12",
  "cases": {
    "my-case": {
      "schema_valid": true,
      "instance_valid": true
    }
  }
}
```

| Field | Values | Meaning |
|-------|--------|---------|
| `schema_valid` | `true` / `false` | Should schema pass metaschema validation? |
| `instance_valid` | `true` / `false` / `null` | Should instance validate? (`null` if schema is invalid) |

## Results

Output is in `results/<draft>/events.jsonl`:

```bash
# View all events
cat results/draft-2020-12/events.jsonl | jq .

# Filter correctness results
cat results/draft-2020-12/events.jsonl | jq 'select(.event == "correctness_result")'

# Filter benchmark results
cat results/draft-2020-12/events.jsonl | jq 'select(.event == "benchmark_result")'
```

## Codegen Pipeline

Schemas are the source of truth. Models are generated:

```
generators/*.jsonnet → schemas/*.schema.json → src/models/*.py
```

Regenerate with:
```bash
make schemas   # jsonnet → JSON Schema
make models    # JSON Schema → Pydantic
```

## Available Commands

Run `make help` for all commands. Help is self-documenting (reads `##` comments from Makefile).
