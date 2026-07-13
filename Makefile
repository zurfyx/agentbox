IMAGE   ?= claude-personal
VERSION ?= latest
HOME_DIR ?= $(HOME)/.claude-personal

.PHONY: build rebuild install run shell host-bridge clean help

build: ## Build the image (make build VERSION=1.2.3 to pin)
	docker build --build-arg CLAUDE_VERSION=$(VERSION) -t $(IMAGE) .

rebuild: ## Rebuild without cache (picks up latest Claude Code)
	docker build --no-cache --build-arg CLAUDE_VERSION=$(VERSION) -t $(IMAGE) .

install: ## Add the shell function to ~/.zshrc
	./install.sh

run: build ## Build then run Claude in the current directory (parity with my-clauded)
	mkdir -p "$(HOME_DIR)"
	GH_TOKEN="$$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)" docker run --rm -it \
	  -v "$(HOME_DIR)":/home/node -v /Users:/Users -v /Volumes:/Volumes -v /tmp:/tmp -w "$(PWD)" \
	  -e GH_TOKEN -e CLAUDED_HOST=host.docker.internal -e CLAUDED_HOST_USER="$$USER" \
	  "$(IMAGE)" --dangerously-skip-permissions

shell: ## Open a bash shell inside the image (debug; same env as run)
	GH_TOKEN="$$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)" docker run --rm -it --entrypoint bash \
	  -v "$(HOME_DIR)":/home/node -v /Users:/Users -v /Volumes:/Volumes -v /tmp:/tmp -w "$(PWD)" \
	  -e GH_TOKEN -e CLAUDED_HOST=host.docker.internal -e CLAUDED_HOST_USER="$$USER" \
	  "$(IMAGE)"

host-bridge: build ## Set up the container->macOS-host command bridge (onhost)
	./setup-host-bridge.sh

clean: ## Remove the image (login/config in $(HOME_DIR) is kept)
	-docker rmi $(IMAGE)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
