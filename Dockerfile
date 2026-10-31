# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Booted as a smolvm microVM by ./claude-sandbox, with Docker Engine running
# inside the VM, or run directly as a Docker container (without Docker inside)
# by `claude-sandbox run-container`.
# Base: Ubuntu 26.04 LTS (broad package availability, well-trodden by CLI tools/agents)
FROM ubuntu:26.04

ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base OS packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    sudo \
    git \
    git-lfs \
    vim \
    nano \
    less \
    jq \
    unzip \
    zip \
    tar \
    build-essential \
    pkg-config \
    software-properties-common \
    openssh-client \
    ripgrep \
    fd-find \
    tmux \
    htop \
    zsh \
    locales \
    && rm -rf /var/lib/apt/lists/*

# Python (via apt, well-stocked with common tooling)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Make `python` / `pip` available, and allow pip to install system-wide
# without fighting PEP 668 (this is a disposable sandbox, not a host system).
RUN ln -sf /usr/bin/python3 /usr/local/bin/python && \
    ln -sf /usr/bin/pip3 /usr/local/bin/pip && \
    rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED

# Node.js (NodeSource, for a recent LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Docker Engine (Docker's own apt repo), so the agent can build and run
# containers inside the VM (container mode leaves it unused)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create the "agent" user, matching host uid/gid
# (removes/renames any existing uid/gid 1000 entries first so it doesn't clash
#  with a default ubuntu user on some base images)
RUN (getent group ${AGENT_GID} && groupdel "$(getent group ${AGENT_GID} | cut -d: -f1)" || true) && \
    (getent passwd ${AGENT_UID} && userdel -r "$(getent passwd ${AGENT_UID} | cut -d: -f1)" || true) && \
    groupadd --gid ${AGENT_GID} agent && \
    useradd --uid ${AGENT_UID} --gid ${AGENT_GID} --groups docker --create-home --shell /usr/bin/zsh agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent

COPY sandbox-entrypoint /usr/local/bin/sandbox-entrypoint

# Project mount point + npm/pip user-level dirs, owned by agent
RUN mkdir -p /home/agent/project && chown -R agent:agent /home/agent

# Let npm global installs work for the agent user without sudo
ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global
ENV PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH

USER agent
WORKDIR /home/agent/project

RUN mkdir -p /home/agent/.npm-global

# rustup base installation (done late, as the agent user)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH=/home/agent/.cargo/bin:$PATH

# Basic shell niceties so an interactive session isn't miserable
RUN echo 'export PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH' >> /home/agent/.bashrc && \
    echo 'export PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH' >> /home/agent/.zshrc

# Snapshot the image's ENV for sandbox-entrypoint: smolvm packs don't carry
# image config, so the entrypoint restores it from here
RUN export -p | grep -E '^export (DEBIAN_FRONTEND|LANG|LC_ALL|NPM_CONFIG_PREFIX|PATH)=' | \
    sudo tee /etc/sandbox-env >/dev/null

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["claude", "--dangerously-skip-permissions", "--ax-screen-reader", "--remote-control"]
