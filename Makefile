IMAGE   ?= claude-personal
VERSION ?= latest
HOME_DIR ?= $(HOME)/.claude-personal

.PHONY: build rebuild install run shell clean help

build: ## Build the image (make build VERSION=1.2.3 to pin)
	docker build --build-arg CLAUDE_VERSION=$(VERSION) -t $(IMAGE) .

rebuild: ## Rebuild without cache (picks up latest Claude Code)
	docker build --no-cache --build-arg CLAUDE_VERSION=$(VERSION) -t $(IMAGE) .

install: ## Add the shell function to ~/.zshrc
	./install.sh

run: build ## Build then run Claude in the current directory
	mkdir -p $(HOME_DIR)
	docker run --rm -it -v $(HOME_DIR):/home/node -v $(PWD):/workspace -w /workspace $(IMAGE) --dangerously-skip-permissions

shell: ## Open a bash shell inside the image (debug)
	docker run --rm -it --entrypoint bash -v $(HOME_DIR):/home/node -v $(PWD):/workspace -w /workspace $(IMAGE)

clean: ## Remove the image (login/config in $(HOME_DIR) is kept)
	-docker rmi $(IMAGE)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
