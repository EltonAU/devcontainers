FROM node:20.20.2

ARG TZ
ENV TZ="$TZ"

# Pinned to specific versions for reproducible builds. Bump intentionally.
ARG CLAUDE_CODE_VERSION=2.1.121
ARG CODEX_VERSION=0.125.0

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  curl \
  wget \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions.
# /home/node/.claude and /home/node/.codex are pre-created so the named
# Docker volumes pick up correct ownership on first mount.
RUN mkdir -p /workspace \
      /home/node/.claude \
      /home/node/.codex \
      /home/node/.aws \
      /home/node/.config/gh && \
  chown -R node:node /workspace /home/node/.claude /home/node/.codex /home/node/.aws /home/node/.config

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

ARG AWS_CLI_VERSION=2.34.43
RUN ARCH_RAW=$(dpkg --print-architecture) && \
  case "$ARCH_RAW" in \
    amd64) AWS_ARCH=x86_64 ;; \
    arm64) AWS_ARCH=aarch64 ;; \
    *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
  esac && \
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
  unzip -q /tmp/awscliv2.zip -d /tmp && \
  /tmp/aws/install && \
  rm -rf /tmp/aws /tmp/awscliv2.zip

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

RUN npm install -g \
  @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
  @openai/codex@${CODEX_VERSION}

COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node
