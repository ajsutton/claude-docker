ARG UBUNTU_VERSION=latest
FROM ubuntu:${UBUNTU_VERSION}

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl zsh fzf ripgrep make zip unzip \
    iptables ipset iproute2 dnsutils \
    openssh-server jq vim golang gpg python3-venv \
    ca-certificates tmux libclang-dev libssl-dev lld \
    software-properties-common \
    tzdata xz-utils

# Install gh from GitHub's official apt repo (Ubuntu's package is frozen at 2.45.0)
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh

# Install Eternal Terminal from the upstream PPA. et keeps the terminal session
# alive across TCP resets, so a laptop sleep does not kill the connection.
RUN add-apt-repository -y ppa:jgmath2000/et && \
    apt-get update && apt-get install -y et

# Install runit to supervise sshd and etserver. --no-install-recommends keeps
# out runit-run, which wires runsvdir into an init system this container has not
# got. runit needs a sysusers implementation; name the standalone one, because
# apt otherwise picks the first alternative and pulls in all of systemd.
# Services live in our own directory, not the package's /etc/service, so the
# Debian runlevel machinery stays out of the way.
RUN apt-get install -y --no-install-recommends systemd-standalone-sysusers runit
ENV SVDIR=/etc/claude-docker/sv
COPY files/sv/ /etc/claude-docker/sv/
RUN chmod +x /etc/claude-docker/sv/*/run

# Install CircleCI CLI
RUN curl -fLSs https://raw.githubusercontent.com/CircleCI-Public/circleci-cli/main/install.sh | bash

# Install additional apt packages specified by the user
ARG EXTRA_PACKAGES=""
RUN if [ -n "$EXTRA_PACKAGES" ]; then apt-get install -y $EXTRA_PACKAGES; fi

# Install custom CA certificates (drop .crt files into certs/ to include them)
COPY certs/ /usr/local/share/ca-certificates/custom/
RUN update-ca-certificates

# Install Node.js (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs

# Install root-owned npm tools that do not need to self-update.
RUN npm install -g diff-so-fancy

# Install additional npm packages specified by the user
ARG EXTRA_NPM_PACKAGES=""
RUN if [ -n "$EXTRA_NPM_PACKAGES" ]; then npm install -g $EXTRA_NPM_PACKAGES; fi

# SSH setup
RUN mkdir /var/run/sshd && \
    cp -r /etc/ssh /etc/ssh.original && \
    echo 'AcceptEnv ITERM_SESSION_ID FORWARD_*' >> /etc/ssh/sshd_config && \
    echo 'AcceptEnv ITERM_SESSION_ID FORWARD_*' >> /etc/ssh.original/sshd_config

# Non-root user for better isolation
ARG USERNAME
ARG USER_HOME
ARG CODE_PATH
RUN mkdir -p "$(dirname "$USER_HOME")" && \
    useradd -ms /bin/zsh -d "$USER_HOME" $USERNAME

# Copy dotfiles with correct ownership
COPY --chown=${USERNAME}:${USERNAME} files/.profile ${USER_HOME}/.profile
COPY --chown=${USERNAME}:${USERNAME} files/.zshenv ${USER_HOME}/.zshenv
COPY --chown=${USERNAME}:${USERNAME} files/.zshrc ${USER_HOME}/.zshrc
# Create .zshrc.d directory and install snippets
RUN mkdir -p ${USER_HOME}/.zshrc.d && \
    chown ${USERNAME}:${USERNAME} ${USER_HOME}/.zshrc.d
COPY --chown=${USERNAME}:${USERNAME} files/00-forward-env.sh ${USER_HOME}/.zshrc.d/00-forward-env.sh
COPY --chown=${USERNAME}:${USERNAME} files/10-worktrunk.sh ${USER_HOME}/.zshrc.d/10-worktrunk.sh
COPY --chown=${USERNAME}:${USERNAME} files/setupGitSigning.sh ${USER_HOME}/.zshrc.d/setupGitSigning.sh

# Setup SSH authorized_keys from build arg
ARG SSH_AUTHORIZED_KEYS
RUN mkdir -p ${USER_HOME}/.ssh && \
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > ${USER_HOME}/.ssh/authorized_keys && \
    chmod 700 ${USER_HOME}/.ssh && \
    chmod 600 ${USER_HOME}/.ssh/authorized_keys && \
    chown -R ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh

# known_hosts is bind-mounted read-only from the host (see docker-compose.yml)
# so it stays in sync without rebuilding.

# Install iTerm2 utilities
RUN for util in imgcat imgls it2api it2attention it2cat it2check it2copy it2dl it2getvar it2git it2profile it2setcolor it2setkeylabel it2ssh it2tip it2ul it2universion; do \
        curl -fsSL "https://raw.githubusercontent.com/gnachman/iTerm2-shell-integration/main/utilities/$util" \
            -o "/usr/local/bin/$util" && \
        chmod +x "/usr/local/bin/$util"; \
    done

# Install sccache (compiler cache with LRU size cap, wraps rustc via RUSTC_WRAPPER)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then TARGET="x86_64-unknown-linux-musl"; \
    else TARGET="aarch64-unknown-linux-musl"; fi && \
    VERSION=$(curl -fsSL https://api.github.com/repos/mozilla/sccache/releases/latest | jq -r .tag_name) && \
    curl -fsSL "https://github.com/mozilla/sccache/releases/download/${VERSION}/sccache-${VERSION}-${TARGET}.tar.gz" \
    | tar xz --strip-components=1 -C /usr/local/bin "sccache-${VERSION}-${TARGET}/sccache"

# Install tuicr
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then TARGET="x86_64-unknown-linux-gnu"; \
    else TARGET="aarch64-unknown-linux-gnu"; fi && \
    VERSION=$(curl -fsSL https://api.github.com/repos/agavra/tuicr/releases/latest | jq -r .tag_name) && \
    curl -fsSL "https://github.com/agavra/tuicr/releases/download/${VERSION}/tuicr-${VERSION#v}-${TARGET}.tar.gz" \
    | tar xz -C /usr/local/bin tuicr

# Install Worktrunk
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) TARGET="x86_64-unknown-linux-musl" ;; \
        aarch64|arm64) TARGET="aarch64-unknown-linux-musl" ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    VERSION=$(curl -fsSL https://api.github.com/repos/max-sixty/worktrunk/releases/latest | jq -r .tag_name) && \
    curl -fsSL "https://github.com/max-sixty/worktrunk/releases/download/${VERSION}/worktrunk-${TARGET}.tar.xz" \
    | tar xJ --strip-components=1 -C /usr/local/bin "worktrunk-${TARGET}/wt" "worktrunk-${TARGET}/git-wt" && \
    chmod +x /usr/local/bin/wt /usr/local/bin/git-wt

# Entrypoint runs as root to set up SSH, then hands off to runsvdir
COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh

USER $USERNAME
WORKDIR $CODE_PATH

# Install Codex in a user-owned npm prefix so CLI self-updates can write to it.
RUN mkdir -p ${USER_HOME}/.local && \
    npm config set prefix ${USER_HOME}/.local && \
    npm install -g @openai/codex

# Install Bun and omp in the same user-owned prefix so agent CLI updates can write to it.
# Bun is pinned because omp runs on it and fails to parse its own bundle on an
# older bun. files/omp-pin-bun.init.sh makes omp use this bun by absolute path.
ARG BUN_VERSION=1.4.0
ENV BUN_INSTALL=${USER_HOME}/.local
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" && \
    ${BUN_INSTALL}/bin/bun install -g @oh-my-pi/pi-coding-agent

RUN go install golang.org/x/tools/gopls@latest

# Configure cargo to use lld linker on Linux. GNU ld processes static libraries
# in a single pass and can fail on aarch64 when crate link order causes symbols
# to be discarded before they're referenced (e.g. blst/c-kzg in the OP Stack).
# Write to both ~/.cargo/ (default) and ~/.cache/cargo/ (CARGO_HOME at runtime).
RUN mkdir -p ${USER_HOME}/.cargo ${USER_HOME}/.cache/cargo && \
    printf '[target.aarch64-unknown-linux-gnu]\nrustflags = ["-C", "link-arg=-fuse-ld=lld"]\n\n[target.x86_64-unknown-linux-gnu]\nrustflags = ["-C", "link-arg=-fuse-ld=lld"]\n' \
    | tee ${USER_HOME}/.cargo/config.toml > ${USER_HOME}/.cache/cargo/config.toml

# Install mise and ensure state directory exists (prevents Docker creating it as root on mount)
RUN curl https://mise.run | sh && \
    mkdir -p ${USER_HOME}/.local/state/mise

# Install Claude Code (native install, auto-updates in background)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Install herdr into the same user-owned prefix so `herdr update` can write to it.
# Create the config directory too, so Docker does not create it as root when it
# mounts config.toml into it.
RUN curl -fsSL https://herdr.dev/install.sh | sh && \
    mkdir -p ${USER_HOME}/.config/herdr
