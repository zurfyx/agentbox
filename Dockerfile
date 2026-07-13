# A self-contained image running Claude Code, isolated from the host's
# corporate auth/environment. Login + config persist in a mounted volume
# (~/.claude-personal on the host), not inside the image.
FROM node:22-bookworm

# Pin a specific Claude Code version with:  make build VERSION=1.2.3
ARG CLAUDE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# A few niceties Claude Code commonly shells out to.
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

# Bridge for running macOS-host-only steps (real-Claude smoke test, Darwin pty
# tests) from inside the container. See onhost + setup-host-bridge.sh + README.
COPY onhost /usr/local/bin/onhost
RUN chmod +x /usr/local/bin/onhost

# Claude Code refuses --dangerously-skip-permissions as root, so run as the
# non-root "node" user (uid 1000) that ships with the base image. Its config
# lives at /home/node/.claude, which we mount from the host.
USER node
WORKDIR /workspace
ENTRYPOINT ["claude"]
