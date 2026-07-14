IMAGE   ?= agentbox
VERSION ?= latest          # Claude Code version
CODEX_VERSION ?= latest    # Codex version
HOME_DIR ?= $(HOME)/.agentbox

# Shared docker args for the run/shell targets (parity with the agentbox launcher).
DOCKER_ENV = GH_TOKEN="$$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)"
DOCKER_ARGS = --rm -it \
  -v "$(HOME_DIR)":/home/node -v /Users:/Users -v /Volumes:/Volumes -v /tmp:/tmp -w "$(PWD)" \
  -e GH_TOKEN -e AGENTBOX_HOST=host.docker.internal -e AGENTBOX_HOST_USER="$$USER"

.PHONY: build rebuild install run run-codex shell host-bridge clean help

build: ## Build the image (pin: make build VERSION=1.2.3 CODEX_VERSION=0.144.3)
	docker build --build-arg CLAUDE_VERSION=$(VERSION) --build-arg CODEX_VERSION=$(CODEX_VERSION) -t $(IMAGE) .

rebuild: ## Rebuild without cache (picks up latest agent versions)
	docker build --no-cache --build-arg CLAUDE_VERSION=$(VERSION) --build-arg CODEX_VERSION=$(CODEX_VERSION) -t $(IMAGE) .

install: ## Add the shell functions to ~/.zshrc
	./install.sh

run: build ## Build then run Claude in the current dir (parity with agentbox claude)
	mkdir -p "$(HOME_DIR)"
	$(DOCKER_ENV) docker run $(DOCKER_ARGS) "$(IMAGE)" claude --dangerously-skip-permissions

run-codex: build ## Build then run Codex in the current dir (parity with agentbox codex)
	mkdir -p "$(HOME_DIR)"
	$(DOCKER_ENV) docker run $(DOCKER_ARGS) -p 127.0.0.1:1455:1455 -e OPENAI_API_KEY \
	  "$(IMAGE)" codex --dangerously-bypass-approvals-and-sandbox

shell: ## Open a bash shell inside the image (debug; same env as run)
	$(DOCKER_ENV) docker run $(DOCKER_ARGS) --entrypoint bash "$(IMAGE)"

host-bridge: build ## Set up the container->macOS-host command bridge (onhost)
	./setup-host-bridge.sh

clean: ## Remove the image (login/config in $(HOME_DIR) is kept)
	-docker rmi $(IMAGE)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
