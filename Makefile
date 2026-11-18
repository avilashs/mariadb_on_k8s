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
RULE_FILES = $(wildcard $(ROOT)/charts/db-alerts/rules/*.yaml)
RULE_TESTS = $(wildcard $(ROOT)/charts/db-alerts/promtool/*.yaml)
CHART_TESTS = $(patsubst %/tests,%,$(wildcard $(ROOT)/charts/*/tests))
GO_FILES = $(shell find $(ROOT)/tools -name '*.go' 2>/dev/null | head -n1)
# Suites of about an hour each run nightly (ci.yaml, e2e-nightly), not in every pull request.
E2E_LONG = drain rotation
E2E_SUITES = $(filter-out $(E2E_LONG),$(patsubst $(ROOT)/tests/e2e/%.sh,%,$(filter-out %/lib.sh,$(wildcard $(ROOT)/tests/e2e/*.sh))))

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
lint: lint-yaml lint-shell lint-charts lint-platform lint-instances lint-budgets lint-rules lint-go ## All static checks

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

.PHONY: lint-platform
lint-platform: schemas ## Render the platform for ENV and validate every object (needs network for charts)
	@echo "==> render and validate the platform for ENV=$(ENV)"
	@cd $(ROOT) && ENV=$(ENV) helmfile -f helmfile.d/00-platform.yaml.gotmpl template --skip-deps >$(CACHE)/platform-rendered.yaml
	@$(ROOT)/hack/kubeconform.sh -summary $(CACHE)/platform-rendered.yaml

.PHONY: lint-instances
lint-instances: schemas ## Validate every instance file of every environment
	@echo "==> validate instance files"
	@$(ROOT)/hack/lint-instances.sh

.PHONY: lint-budgets
lint-budgets: ## No chart renders a second PodDisruptionBudget over database pods (PLAN.md D6)
	@$(ROOT)/hack/lint-budgets.sh

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
unit: unit-tooling unit-platform unit-charts unit-rules unit-go ## All unit tests

.PHONY: unit-tooling
unit-tooling: schemas
	@$(ROOT)/hack/selftest.sh

.PHONY: unit-platform
unit-platform: ## Shell and chart checks for platform scripts (no cluster)
	@cd $(ROOT) && shellcheck --external-sources hack/*.sh tests/e2e/*.sh

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

##@ Cluster and platform

.PHONY: kind-up
kind-up: ## Create the kind test cluster with its node classes (idempotent)
	@$(ROOT)/hack/kind-up.sh

.PHONY: kind-down
kind-down: ## Delete the kind test cluster
	@$(ROOT)/hack/kind-down.sh

.PHONY: platform-up
platform-up: schemas ## Install or update the platform components for ENV (idempotent)
	@ENV=$(ENV) $(ROOT)/hack/platform-up.sh

# A target that is not built yet fails loudly instead of pretending to work.
define not_yet
@echo "ERROR: 'make $@' arrives with phase $(1) of PLAN.md and is not implemented yet." >&2; exit 1
endef

# The images are compiled on the host and copied into a scratch image, so the build
# pulls nothing from a registry. kind loads them from the local Docker daemon.
IMAGE_TAG ?= dev
KIND_CLUSTER ?= dbaas
IMAGES = db-canary drain-guard

.PHONY: images
images: ## Build the db-canary and drain-guard images and load them into the kind cluster
	@for img in $(IMAGES); do \
	  echo "==> image dbaas/$$img:$(IMAGE_TAG)"; \
	  mkdir -p $(CACHE)/images/$$img && \
	  (cd $(ROOT)/tools && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o $(CACHE)/images/$$img/$$img ./$$img) && \
	  cp $(ROOT)/tools/$$img/Dockerfile $(CACHE)/images/$$img/Dockerfile && \
	  docker build --quiet -t dbaas/$$img:$(IMAGE_TAG) $(CACHE)/images/$$img >/dev/null && \
	  if kind get clusters 2>/dev/null | grep -qx $(KIND_CLUSTER); then kind load docker-image dbaas/$$img:$(IMAGE_TAG) --name $(KIND_CLUSTER); fi; \
	done

.PHONY: instances-up
instances-up: schemas ## Sync every instance file of ENV (idempotent; deleting a file does not delete the instance)
	@ENV=$(ENV) $(ROOT)/hack/instances-up.sh

.PHONY: instance-new
instance-new: ## Scaffold and validate an instance: NAME=<name> ENGINE=mariadb SIZE=<small|medium|large> NODE_CLASS=<class>
	@ENV=$(ENV) $(ROOT)/scripts/instance-new.sh "$(NAME)" "$(ENGINE)" "$(SIZE)" "$(NODE_CLASS)"

.PHONY: instance-remove
instance-remove: ## Remove an instance whose file is already deleted: NAME=<name>
	@ENV=$(ENV) $(ROOT)/scripts/instance-remove.sh "$(NAME)"

.PHONY: restore-drill
restore-drill: ## Restore an instance to TIME (default: newest recoverable) into a throwaway, check it, delete it: NAME=<name> [TIME=<RFC 3339 UTC>]
	@KUBE_CONTEXT=$$(yq -r '.kubeContext' $(ROOT)/environments/$(ENV)/platform.yaml) $(ROOT)/scripts/restore-drill.sh "$(NAME)" "$(TIME)"

##@ End-to-end suites

.PHONY: e2e
e2e: $(addprefix e2e-,$(E2E_SUITES)) ## Run every quick e2e suite for ENV and ENGINE (the long ones: make e2e-drain, e2e-rotation)

e2e-%: ## Run one suite, e.g. make e2e-platform (suites live in tests/e2e/)
	@test -f $(ROOT)/tests/e2e/$*.sh || { echo "ERROR: no e2e suite '$*' (tests/e2e/$*.sh)" >&2; exit 1; }
	@ENV=$(ENV) ENGINE=$(ENGINE) $(ROOT)/tests/e2e/$*.sh

##@ Housekeeping

.PHONY: clean
clean: ## Remove generated schemas and caches (keeps installed tools)
	rm -rf $(CACHE)/schemas $(CACHE)/kubeconform $(CACHE)/helm

.PHONY: clean-tools
clean-tools: ## Remove installed tools
	rm -rf $(BIN) $(CACHE)/venv
