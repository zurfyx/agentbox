# A self-contained image running Claude Code, isolated from the host's
# corporate auth/environment. Login + config persist in a mounted volume
# (~/.claude-personal on the host), not inside the image.
FROM node:22-bookworm

# Pin a specific Claude Code version with:  make build VERSION=1.2.3
ARG CLAUDE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# A few niceties Claude Code commonly shells out to.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ripgrep less ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
ENTRYPOINT ["claude"]
