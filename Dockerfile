# Payload-free, digest-selected runtime for Agentbox. Claude and Codex are
# downloaded by the host from release-manifest URLs and mounted read-only at
# /opt/agentbox/vendor; no vendor executable is copied into an image layer.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

ARG AGENTBOX_VERSION=0.0.0
ARG SOURCE_COMMIT=unknown
ARG RUNTIME_PROTOCOL=1
ARG INSTRUCTIONS_SHA256=2ccf449972183f4b48a3917aa3f2605dbb46d93fea97dc32400c23e88807e2e0
ARG STATUSLINE_SHA256=ebcf9964b8f3741d56034ab95afaca4b1eb9abe78fbd2f59e9b1994cf9468501

LABEL org.opencontainers.image.title="Agentbox runtime" \
      org.opencontainers.image.description="Payload-free runtime for release-managed coding agents" \
      org.opencontainers.image.source="https://github.com/zurfyx/agentbox" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${AGENTBOX_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      io.agentbox.runtime-protocol="${RUNTIME_PROTOCOL}" \
      io.agentbox.instructions-sha256="${INSTRUCTIONS_SHA256}" \
      io.agentbox.statusline-sha256="${STATUSLINE_SHA256}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       bash ca-certificates git jq less openssh-client python3 ripgrep \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid 1000 node \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash node \
  && install -d -o node -g node -m 0755 /workspace

COPY --chmod=0555 runtime/runtime /usr/local/libexec/agentbox/runtime
COPY --chmod=0555 git-credential-ghtoken onhost /usr/local/bin/
COPY --chmod=0444 runtime/instructions.md /usr/local/share/agentbox/instructions.md
COPY --chmod=0555 runtime/statusline.sh /usr/local/share/agentbox/statusline.sh
COPY --chmod=0444 runtime/claude-settings.json /usr/local/share/agentbox/claude-settings.json
COPY --chmod=0444 runtime/codex-requirements.toml /etc/codex/requirements.toml

RUN chmod 0555 /usr/local/share/agentbox /etc/codex \
  && git config --system --add safe.directory '*' \
  && git config --system credential.helper ghtoken

ENV HOME=/home/node \
    PATH=/usr/local/bin:/usr/bin:/bin \
    DISABLE_UPDATES=1 \
    DISABLE_AUTOUPDATER=1

USER node
WORKDIR /workspace
ENTRYPOINT ["/usr/local/libexec/agentbox/runtime"]
