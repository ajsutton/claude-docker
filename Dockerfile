FROM ubuntu:latest

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl zsh fzf ripgrep make \
    iptables ipset iproute2 dnsutils \
    openssh-server jq vim gh golang gpg python3.12-venv \
    ca-certificates tmux mosh libclang-dev libssl-dev lld \
    tzdata

# Install additional apt packages specified by the user
ARG EXTRA_PACKAGES=""
RUN if [ -n "$EXTRA_PACKAGES" ]; then apt-get install -y $EXTRA_PACKAGES; fi

# Install custom CA certificates (drop .crt files into certs/ to include them)
COPY certs/ /usr/local/share/ca-certificates/custom/
RUN update-ca-certificates

# Install Node.js (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs

# Install diff-so-fancy and Codex CLI globally
RUN npm install -g diff-so-fancy @openai/codex

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

# Install tuicr
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then TARGET="x86_64-unknown-linux-gnu"; \
    else TARGET="aarch64-unknown-linux-gnu"; fi && \
    VERSION=$(curl -fsSL https://api.github.com/repos/agavra/tuicr/releases/latest | jq -r .tag_name) && \
    curl -fsSL "https://github.com/agavra/tuicr/releases/download/${VERSION}/tuicr-${VERSION#v}-${TARGET}.tar.gz" \
    | tar xz -C /usr/local/bin tuicr

# Entrypoint runs as root to set up SSH, then sshd handles user sessions
COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh

USER $USERNAME
WORKDIR $CODE_PATH

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

