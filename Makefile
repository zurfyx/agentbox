IMAGE ?= agentbox-runtime:dev
SHELL := bash

.DEFAULT_GOAL := help

.PHONY: check test test-unit test-static lint format format-check install-hooks docker-build help

check: test lint format-check ## Run the complete local/CI quality gate

test: ## Run all deterministic tests (no Docker or network)
	npm test

test-unit: ## Run CLI, state, and runtime contract tests
	npm run test:unit

test-static: ## Run repository policy and syntax tests
	npm run test:static

lint: ## Run ShellCheck on shell entry points
	npm run lint

format-check: ## Check shell formatting without changing files
	npm run format:check

format: ## Format shell entry points
	npm run format

install-hooks: ## Install pinned development dependencies and the Husky hook
	npm install

docker-build: ## Build the payload-free development runtime image
	docker build -t "$(IMAGE)" .

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
