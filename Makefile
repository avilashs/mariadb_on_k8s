# One command per job. Run `make help` for the list.
#
# Every target reads:
#   ENV     environment directory under environments/   (default: kind)
#   ENGINE  database engine: mariadb or postgres         (default: mariadb)

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules --no-print-directory

ENV ?= kind
ENGINE ?= mariadb

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BIN := $(ROOT)/.bin
CACHE := $(ROOT)/.cache

export PATH := $(BIN):$(PATH)
export ENV ENGINE

ifeq ($(filter $(ENGINE),mariadb postgres),)
$(error ENGINE must be 'mariadb' or 'postgres', got '$(ENGINE)')
endif
ifeq ($(wildcard $(ROOT)/environments/$(ENV)),)
$(error ENV '$(ENV)' has no directory under environments/)
endif

# Files that exist only from later phases on. Targets work on whatever is there.
SHELL_FILES = $(shell git -C $(ROOT) ls-files --cached --others --exclude-standard -- '*.sh')
RULE_FILES = $(wildcard $(ROOT)/alerts/rules/*.yaml)
RULE_TESTS = $(wildcard $(ROOT)/alerts/tests/*.yaml)
CHART_TESTS = $(patsubst %/tests,%,$(wildcard $(ROOT)/charts/*/tests))
GO_FILES = $(shell find $(ROOT)/tools -name '*.go' 2>/dev/null | head -n1)

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*##" } \
	  /^##@/ { printf "\n%s\n", substr($$0, 5) } \
	  /^[a-zA-Z0-9_%-]+:.*##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Tools

.PHONY: tools
tools: ## Install every pinned tool into .bin/
	@$(ROOT)/hack/install-tools.sh

.PHONY: tools-check
tools-check: ## Verify that every tool matches its pin in versions.yaml
	@$(ROOT)/hack/tools-check.sh

.PHONY: schemas
schemas: ## Generate strict JSON Schemas from the pinned operator CRDs
	@$(ROOT)/hack/gen-crd-schemas.sh

##@ Verification

.PHONY: verify
verify: lint unit ## Everything that needs no cluster: lint + unit

.PHONY: lint
lint: lint-yaml lint-shell lint-charts lint-rules lint-go ## All static checks

.PHONY: lint-yaml
lint-yaml:
	@echo "==> yamllint"
	@cd $(ROOT) && yamllint --strict .

.PHONY: lint-shell
lint-shell:
	@echo "==> shellcheck"
	@cd $(ROOT) && shellcheck --external-sources $(SHELL_FILES)

.PHONY: lint-charts
lint-charts: schemas
	@$(ROOT)/hack/lint-charts.sh

.PHONY: lint-rules
lint-rules:
ifeq ($(RULE_FILES),)
	@echo "==> no alert rules yet: nothing to check"
else
	@echo "==> promtool check rules"
	@promtool check rules $(RULE_FILES)
endif

.PHONY: lint-go
lint-go:
ifeq ($(GO_FILES),)
	@echo "==> no Go code yet: nothing to vet"
else
	@echo "==> go vet"
	@cd $(ROOT)/tools && go vet ./...
endif

.PHONY: unit
unit: unit-tooling unit-charts unit-rules unit-go ## All unit tests

.PHONY: unit-tooling
unit-tooling: schemas
	@$(ROOT)/hack/selftest.sh

.PHONY: unit-charts
unit-charts:
ifeq ($(CHART_TESTS),)
	@echo "==> no chart tests yet: nothing to run"
else
	@echo "==> helm-unittest"
	@helm-unittest --strict $(CHART_TESTS)
endif

.PHONY: unit-rules
unit-rules:
ifeq ($(RULE_TESTS),)
	@echo "==> no alert rule tests yet: nothing to run"
else
	@echo "==> promtool test rules"
	@promtool test rules $(RULE_TESTS)
endif

.PHONY: unit-go
unit-go:
ifeq ($(GO_FILES),)
	@echo "==> no Go code yet: nothing to test"
else
	@echo "==> go test"
	@cd $(ROOT)/tools && go test ./...
endif

##@ Cluster and instances (arrive with later phases of PLAN.md)

# A target that is not built yet fails loudly instead of pretending to work.
define not_yet
@echo "ERROR: 'make $@' arrives with phase $(1) of PLAN.md and is not implemented yet." >&2; exit 1
endef

.PHONY: images
images: ## Build the db-canary and drain-guard images (phase 6)
	$(call not_yet,6)

.PHONY: kind-up
kind-up: ## Create the kind test cluster (phase 1)
	$(call not_yet,1)

.PHONY: kind-down
kind-down: ## Delete the kind test cluster (phase 1)
	$(call not_yet,1)

.PHONY: platform-up
platform-up: ## Install the platform components for ENV (phase 1)
	$(call not_yet,1)

.PHONY: instances-up
instances-up: ## Sync every instance of ENV (phase 4)
	$(call not_yet,4)

.PHONY: instance-new
instance-new: ## Scaffold an instance: NAME=<name> SIZE=<size> NODE_CLASS=<class> (phase 4)
	$(call not_yet,4)

.PHONY: e2e
e2e: ## Run every e2e suite for ENGINE (phase 3 onwards)
	$(call not_yet,3)

e2e-%: ## Run one e2e suite, e.g. make e2e-drain (phase 3 onwards)
	$(call not_yet,3)

##@ Housekeeping

.PHONY: clean
clean: ## Remove generated schemas and caches (keeps installed tools)
	rm -rf $(CACHE)/schemas $(CACHE)/kubeconform $(CACHE)/helm

.PHONY: clean-tools
clean-tools: ## Remove installed tools
	rm -rf $(BIN) $(CACHE)/venv
