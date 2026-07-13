# A self-contained image running personal AI coding agents (Claude Code + Codex),
# isolated from the host's corporate auth/environment. Login + config persist in
# a mounted volume (~/.agentbox on the host), not inside the image.
FROM node:22-bookworm

# Pin versions with:  make build CLAUDE_VERSION=1.2.3 CODEX_VERSION=0.144.3
# Install each in its OWN layer: claude-code's postinstall (node install.cjs)
# downloads a native binary and doesn't complete reliably when co-installed with
# another package in a single `npm install`.
ARG CLAUDE_VERSION=latest
ARG CODEX_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}
RUN npm install -g @openai/codex@${CODEX_VERSION}

# A few niceties the agents commonly shell out to.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ripgrep less ca-certificates jq openssh-client \
  && rm -rf /var/lib/apt/lists/*

# Git inside the container: (1) trust bind-mounted repos even though the host
# uid != the container's node uid (avoids "dubious ownership"), and (2) auth to
# GitHub over HTTPS using the GH_TOKEN env var injected at runtime.
COPY git-credential-ghtoken /usr/local/bin/git-credential-ghtoken
RUN chmod +x /usr/local/bin/git-credential-ghtoken \
  && git config --system --add safe.directory '*' \
  && git config --system credential.helper ghtoken

# Bridge for running macOS-host-only steps (smoke tests, Darwin pty tests) from
# inside the container. See onhost + setup-host-bridge.sh + README.
COPY onhost /usr/local/bin/onhost
RUN chmod +x /usr/local/bin/onhost

# Claude Code (and Codex) refuse their --dangerously-* flags as root, so run as
# the non-root "node" user (uid 1000) that ships with the base image. Its home
# (/home/node) — holding ~/.claude and ~/.codex — is mounted from the host.
# No ENTRYPOINT: the launcher passes the agent command (claude/codex) explicitly,
# so this one image serves both.
USER node
WORKDIR /workspace
