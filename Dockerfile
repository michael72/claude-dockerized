# Claude Code sandbox image.
#
# Structurally the same idea as opencode-dockerized: Debian slim, one non-root
# user whose UID/GID is remapped to the host user at runtime, the project bind
# mounted read-write, everything else either read-only or not mounted at all.
#
# What is different from the OpenCode image is marked with "CLAUDE:" below.

FROM debian:bookworm-slim

ARG NVM_VERSION=v0.40.1
ARG JAVA_VERSION=21.0.11-tem
ARG SCALA_VERSION=2.13.18

# CLAUDE: pin the CLI for reproducible builds. Use "latest" if you would rather
# rebuild than pin. The auto-updater is switched off further down, so a pinned
# version really stays pinned.
ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    bash \
    ca-certificates \
    gnupg \
    zip \
    unzip \
    xz-utils \
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    procps \
    tmux \
    lsof \
    tzdata \
    locales \
    tini \
    # CLAUDE: needed only by init-firewall.sh (egress allowlist). Drop these
    # three plus the NET_ADMIN/NET_RAW capabilities if you do not want a
    # firewall inside the container.
    iptables \
    ipset \
    dnsutils \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI only — talks to the host daemon through the mounted socket.
# SECURITY: see README, mounting the socket is a host-root-equivalent hole.
# Comment this block out unless you actually need Testcontainers.
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# CLAUDE: deliberately NO passwordless sudo for the agent user.
# opencode-dockerized grants "coder ALL=(ALL) NOPASSWD:ALL". With an agent that
# may run unattended that is an escape hatch out of every other control in this
# file: `sudo iptables -F` clears the firewall, `sudo tee` rewrites the managed
# settings. The entrypoint below does the few privileged things that are needed
# and then drops privileges for good.
RUN useradd -m -s /bin/bash -u 1000 coder

# --- toolchain (same as the OpenCode image; trim to what you need) -----------

USER coder
WORKDIR /home/coder

ENV SDKMAN_DIR=/home/coder/.sdkman
RUN curl -s "https://get.sdkman.io?rcupdate=false" | bash && \
    bash -c "source \$SDKMAN_DIR/bin/sdkman-init.sh && \
      sdk install java ${JAVA_VERSION} && \
      sdk default java ${JAVA_VERSION} && \
      sdk install sbt && \
      sdk install scala ${SCALA_VERSION}"

# CLAUDE: Node >= 22.15 matters here. Below that, an npm-installed Claude Code
# cannot read the OS trust store and only honours its bundled Mozilla CA set
# plus NODE_EXTRA_CA_CERTS — which bites behind a corporate TLS-inspecting
# proxy. The current LTS is well past that, so `nvm install --lts` is fine.
ENV NVM_DIR=/home/coder/.nvm
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    bash -c "source \$NVM_DIR/nvm.sh && \
      nvm install --lts && \
      nvm alias default node && \
      nvm use default && \
      ln -sfn \$(dirname \$(which node)) \$NVM_DIR/default"

ENV UV_PROJECT_ENVIRONMENT=/home/coder/.venv
ENV PATH="/home/coder/.venv/bin:/home/coder/.local/bin:$NVM_DIR/default:/home/coder/.sdkman/candidates/java/current/bin:$PATH"
ENV JAVA_HOME=/home/coder/.sdkman/candidates/java/current
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    uv python install && \
    uv venv "$UV_PROJECT_ENVIRONMENT"

# --- Claude Code ------------------------------------------------------------

# CLAUDE: npm install rather than the native installer from downloads.claude.ai.
# The npm route means the image needs registry.npmjs.org at build time but never
# needs downloads.claude.ai at run time, which keeps the egress allowlist one
# entry shorter.
RUN bash -c "source \$NVM_DIR/nvm.sh && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

USER root

# CLAUDE: managed settings sit at the top of the settings hierarchy on Linux and
# override anything in ~/.claude or the project's .claude/. Note the caveat from
# the docs: since this file comes out of your repository, anyone with write
# access can edit it — it is a guardrail, not an access control.
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod 0644 /etc/claude-code/managed-settings.json

# CLAUDE: ~/.claude holds credentials, settings, history and sessions, and
# ~/.claude.json (OAuth account, per-project trust, personal MCP servers) lives
# OUTSIDE that directory by default. Pointing CLAUDE_CONFIG_DIR at ~/.claude
# pulls .claude.json inside it, so a single mount covers all state. Without
# this you get signed out on every `docker run --rm`.
ENV CLAUDE_CONFIG_DIR=/home/coder/.claude

# CLAUDE: the feature always installs the latest release; turn the updater off
# so a pinned CLAUDE_CODE_VERSION is not silently replaced at runtime.
ENV DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1

RUN mkdir -p /home/coder/.claude /home/coder/.cache /home/coder/.npm \
             /home/coder/.m2 /home/coder/.gradle && \
    chown -R coder:coder /home/coder

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowed-domains.txt /etc/claude-dockerized/allowed-domains.txt
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

WORKDIR /
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
