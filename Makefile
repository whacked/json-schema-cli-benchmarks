# Makefile for json-schema-cli-benchmark

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

REPO_ROOT := $(shell pwd)
EXPERIMENTS_DIR := $(REPO_ROOT)/experiments
RESULTS_DIR := $(REPO_ROOT)/results
BENCH_DIR := $(REPO_ROOT)/bench
TOOLS_DIR := $(REPO_ROOT)/tools

# Discover drafts with manifest.json or manifest.yaml
DRAFTS := $(shell find $(EXPERIMENTS_DIR) -mindepth 2 -maxdepth 2 \( -name 'manifest.json' -o -name 'manifest.yaml' \) -exec dirname {} \; 2>/dev/null | xargs -I{} basename {} | sort -u)

CORRECTNESS_FILES := $(foreach d,$(DRAFTS),$(RESULTS_DIR)/$(d)/correctness.jsonl)
SPEED_FILES := $(foreach d,$(DRAFTS),$(RESULTS_DIR)/$(d)/speed.jsonl)

.PHONY: all correctness speed report clean list-drafts help
.PHONY: $(foreach d,$(DRAFTS),correctness-$(d) speed-$(d))
.PHONY: new-experiment hydrate-experiment validate-experiment status-experiment

# -----------------------------------------------------------------------------
# Help (self-documenting: reads ## comments above targets)
# -----------------------------------------------------------------------------

help:
	@echo "Benchmarking (Python runner):"
	@grep -B1 -E '^run' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'
	@echo ""
	@echo "Code generation:"
	@grep -B1 -E '^(models|schemas):' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'
	@echo ""
	@echo "Experiment scaffolding:"
	@grep -B1 -E '^(new-|validate-|hydrate-|status-)' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'
	@echo ""
	@echo "Status:"
	@grep -B1 -E '^(info|list-)' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'
	@echo ""
	@echo "Corpora:"
	@grep -B1 -E '^gen-cor' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'
	@echo ""
	@echo "Cleanup:"
	@grep -B1 -E '^clean' $(MAKEFILE_LIST) | grep '^##' | sed 's/^## /  make /'

## info                        Show repo status (experiments, results, tools)
info:
	@echo "=== Experiments ==="
	@for d in $(DRAFTS); do \
		cases=$$(jq '.cases | keys | length' $(EXPERIMENTS_DIR)/$$d/manifest.json 2>/dev/null || echo 0); \
		if [ -f "$(RESULTS_DIR)/$$d/events.jsonl" ]; then \
			events=$$(wc -l < $(RESULTS_DIR)/$$d/events.jsonl | tr -d ' '); \
			echo "  $$d: $$cases cases, $$events events"; \
		else \
			echo "  $$d: $$cases cases, no results"; \
		fi; \
	done
	@echo ""
	@echo "=== Tools ==="
	@for adapter in $(TOOLS_DIR)/adapters/*.sh; do \
		name=$$(basename $$adapter .sh); \
		version=$$($$adapter version 2>/dev/null | head -1 || echo "unknown"); \
		echo "  $$name: $$version"; \
	done
	@echo ""
	@echo "=== Schemas ==="
	@ls -1 schemas/*.schema.json 2>/dev/null | xargs -I{} basename {} | sed 's/^/  /' || echo "  (none)"
	@echo ""
	@echo "=== Models ==="
	@ls -1 src/models/*.py 2>/dev/null | xargs -I{} basename {} | grep -v __init__ | sed 's/^/  /' || echo "  (none)"

## list-drafts                 List discovered drafts
list-drafts:
	@echo "$(DRAFTS)"

## list-tools                  List available tool adapters
list-tools:
	@for adapter in $(TOOLS_DIR)/adapters/*.sh; do basename $$adapter .sh; done

## list-cases DRAFT=...        List cases in an experiment
list-cases: _check-draft
	@jq -r '.cases | keys[]' $(EXPERIMENTS_DIR)/$(DRAFT)/manifest.json

# -----------------------------------------------------------------------------
# Benchmarking (Python runner - unified correctness + speed)
# -----------------------------------------------------------------------------

EVENTS_FILES := $(foreach d,$(DRAFTS),$(RESULTS_DIR)/$(d)/events.jsonl)

.PHONY: run run-correctness

## run                        Run all drafts (correctness + speed)
run: $(EVENTS_FILES)

# Note: No explicit manifest dependency - runner validates manifest exists (json or yaml)
$(RESULTS_DIR)/%/events.jsonl:
	python3 $(BENCH_DIR)/run.py $*

## run-<draft>                Run one draft (correctness + speed)
.PHONY: run-%
run-%:
	python3 $(BENCH_DIR)/run.py $*

## run-correctness            Run correctness only for all drafts
run-correctness:
	@for d in $(DRAFTS); do python3 $(BENCH_DIR)/run.py $$d --skip-speed; done

## run-correctness-<draft>    Run correctness only for one draft
run-correctness-%:
	python3 $(BENCH_DIR)/run.py $* --skip-speed

# -----------------------------------------------------------------------------
# Legacy shell-based runners (deprecated, kept for reference)
# -----------------------------------------------------------------------------

all: correctness speed report

correctness: $(CORRECTNESS_FILES)
speed: $(SPEED_FILES)

$(RESULTS_DIR)/%/correctness.jsonl: $(EXPERIMENTS_DIR)/%/manifest.json
	@mkdir -p $(RESULTS_DIR)/$*
	$(BENCH_DIR)/run_correctness.sh $*

$(RESULTS_DIR)/%/speed.jsonl: $(RESULTS_DIR)/%/correctness.jsonl
	@mkdir -p $(RESULTS_DIR)/$*/raw
	$(BENCH_DIR)/run_speed.sh $*

define correctness_target
correctness-$(1): $(RESULTS_DIR)/$(1)/correctness.jsonl
endef
$(foreach d,$(DRAFTS),$(eval $(call correctness_target,$(d))))

define speed_target
speed-$(1): $(RESULTS_DIR)/$(1)/speed.jsonl
endef
$(foreach d,$(DRAFTS),$(eval $(call speed_target,$(d))))

report: $(CORRECTNESS_FILES) $(SPEED_FILES)
	$(BENCH_DIR)/render_report.sh

## clean                      Remove all results
clean:
	rm -rf $(RESULTS_DIR)

## clean-<draft>              Remove results for one draft
clean-%:
	rm -rf $(RESULTS_DIR)/$*

# -----------------------------------------------------------------------------
# Corpus generation (multi-draft support)
# -----------------------------------------------------------------------------

# Note: jsf requires venv with PYTHONPATH unset (conflicts with nix python)
VENV_PYTHON := unset PYTHONPATH && source .venv/bin/activate && python

## gen-corpus DRAFT=...        Generate benchmark corpus for a draft via jsf
gen-corpus: _check-draft
	@$(VENV_PYTHON) $(TOOLS_DIR)/generate_corpus.py --draft $(DRAFT) --seed 0

## gen-corpus-small DRAFT=...  Generate small corpus (S tier only, fewer instances)
gen-corpus-small: _check-draft
	@$(VENV_PYTHON) $(TOOLS_DIR)/generate_corpus.py --draft $(DRAFT) --seed 0 --tiers S --n-valid 5 --m-invalid 3

## clean-corpus DRAFT=...      Remove generated corpus for a draft
clean-corpus: _check-draft
	rm -rf $(EXPERIMENTS_DIR)/$(DRAFT)/cases $(EXPERIMENTS_DIR)/$(DRAFT)/manifest.json $(EXPERIMENTS_DIR)/$(DRAFT)/manifest.yaml

# Convenience targets for common drafts
## gen-corpus-draft-04         Generate draft-04 benchmark corpus via jsf
gen-corpus-draft-04:
	@$(VENV_PYTHON) $(TOOLS_DIR)/generate_corpus.py --draft draft-04 --seed 0

## gen-corpus-draft-07         Generate draft-07 benchmark corpus via jsf
gen-corpus-draft-07:
	@$(VENV_PYTHON) $(TOOLS_DIR)/generate_corpus.py --draft draft-07 --seed 0

## gen-corpus-2020-12          Generate 2020-12 benchmark corpus via jsf
gen-corpus-2020-12:
	@$(VENV_PYTHON) $(TOOLS_DIR)/generate_corpus.py --draft 2020-12 --seed 0

# -----------------------------------------------------------------------------
# Experiment scaffolding (delegates to experiment-manager.bb.clj)
# -----------------------------------------------------------------------------

_check-draft:
ifndef DRAFT
	$(error DRAFT required. Example: make $(MAKECMDGOALS) DRAFT=draft-07)
endif

## new-experiment DRAFT=...   Create manifest.yaml from template
new-experiment: _check-draft
	@$(TOOLS_DIR)/experiment-manager.bb.clj new $(DRAFT)

## validate-manifest DRAFT=...  Validate manifest against schema
validate-manifest: _check-draft
	@if [ -f "$(EXPERIMENTS_DIR)/$(DRAFT)/manifest.yaml" ]; then \
		check-jsonschema --schemafile schemas/manifest.schema.json \
			$(EXPERIMENTS_DIR)/$(DRAFT)/manifest.yaml; \
	elif [ -f "$(EXPERIMENTS_DIR)/$(DRAFT)/manifest.json" ]; then \
		check-jsonschema --schemafile schemas/manifest.schema.json \
			$(EXPERIMENTS_DIR)/$(DRAFT)/manifest.json; \
	else \
		echo "ERROR: No manifest found for $(DRAFT)"; exit 1; \
	fi

## hydrate-experiment DRAFT=...  Create case directories from manifest
hydrate-experiment: _check-draft validate-manifest
	@$(TOOLS_DIR)/experiment-manager.bb.clj hydrate $(DRAFT)

## validate-experiment DRAFT=...  Validate directory structure
validate-experiment: _check-draft validate-manifest
	@$(TOOLS_DIR)/experiment-manager.bb.clj validate $(DRAFT)

## status-experiment DRAFT=...  Show progress + validation status
status-experiment: _check-draft
	@$(TOOLS_DIR)/experiment-manager.bb.clj status $(DRAFT)

## debug-experiment DRAFT=...  Dump experiment state as JSON
debug-experiment: _check-draft
	@$(TOOLS_DIR)/experiment-manager.bb.clj debug $(DRAFT)

# -----------------------------------------------------------------------------
# Code generation (jsonnet -> JSON Schema -> Pydantic)
# -----------------------------------------------------------------------------

./schemas/example.schema.json: ./generators/example.schema.jsonnet
	jsonnet $< | jq -S | tee $@

./src/schemas/example_schema_autogen.py: ./schemas/example.schema.json
	datamodel-codegen --input $< --input-file-type jsonschema --output $@

./schemas/manifest.schema.json: ./generators/manifest.schema.jsonnet
	jsonnet $< | jq -S > $@

./schemas/events.schema.json: ./generators/events.schema.jsonnet
	jsonnet $< | jq -S > $@

./schemas/system.schema.json: ./generators/system.schema.jsonnet
	jsonnet $< | jq -S > $@

./src/models/manifest.py: ./schemas/manifest.schema.json
	@mkdir -p src/models
	datamodel-codegen --input $< --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output $@

./src/models/events.py: ./schemas/events.schema.json
	@mkdir -p src/models
	datamodel-codegen --input $< --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output $@

./src/models/system.py: ./schemas/system.schema.json
	@mkdir -p src/models
	datamodel-codegen --input $< --input-file-type jsonschema --output-model-type pydantic_v2.BaseModel --output $@

## schemas                    Generate JSON Schemas from jsonnet
schemas: ./schemas/manifest.schema.json ./schemas/events.schema.json ./schemas/system.schema.json

## models                     Generate Pydantic models from schemas
models: ./src/models/manifest.py ./src/models/events.py ./src/models/system.py
