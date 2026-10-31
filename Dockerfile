# The semperwake agent with Docker in place of systemd. Everything agent-specific
# is generated at start by install.sh, so this image holds only the runtime.
FROM node:22-bookworm-slim

# Pinned because a detached agent cannot be walked through a surprise upgrade.
ARG CLAUDE_CODE_VERSION=2.1.314
# Must match the owner of ./agents on Linux hosts, or the agent cannot write it.
ARG AGENT_UID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq openssh-client procps python3 tmux \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

RUN usermod -u "$AGENT_UID" node \
 && mkdir -p /workspace \
 && chown -R node:node /home/node /workspace

COPY install.sh /opt/semperwake/install.sh
COPY prompts/ /opt/semperwake/prompts/
COPY docker/entrypoint.sh /opt/semperwake/docker/entrypoint.sh

# The image, not claude, decides the version: see the pin above.
ENV DISABLE_AUTOUPDATER=1 \
    SUPERVISOR=container \
    LANG=C.UTF-8 \
    PATH=/home/node/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# claude refuses --dangerously-skip-permissions as root, and so does the installer.
USER node
WORKDIR /workspace
ENTRYPOINT ["/opt/semperwake/docker/entrypoint.sh"]
