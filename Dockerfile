FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    git curl zsh fzf ripgrep make \
    iptables ipset iproute2 dnsutils \
    openssh-server jq vim gh golang gpg python3.12-venv \
    ca-certificates tmux

# Install additional apt packages specified by the user
ARG EXTRA_PACKAGES=""
RUN if [ -n "$EXTRA_PACKAGES" ]; then apt-get install -y $EXTRA_PACKAGES; fi

# Install custom CA certificates (drop .crt files into certs/ to include them)
COPY certs/ /usr/local/share/ca-certificates/custom/
RUN update-ca-certificates

# Install Node.js (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs

# Install diff-so-fancy globally
RUN npm install -g diff-so-fancy

# Create init.d directory for user-provided startup scripts
RUN mkdir -p /etc/claude-docker/init.d

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
COPY --chown=${USERNAME}:${USERNAME} files/setupGitSigning.sh ${USER_HOME}/.zshrc.d/setupGitSigning.sh

# Stage SSH files in a location that won't be overlaid by the named volume.
# The entrypoint copies these into ~/.ssh (the volume mount) on every start,
# so authorized_keys stays current even after rebuilds.
ARG SSH_AUTHORIZED_KEYS
RUN mkdir -p ${USER_HOME}/.ssh.build && \
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > ${USER_HOME}/.ssh.build/authorized_keys && \
    chmod 600 ${USER_HOME}/.ssh.build/authorized_keys && \
    chown -R ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh.build

RUN --mount=type=bind,from=ssh_config,target=/tmp/ssh_config \
    if [ -f /tmp/ssh_config/known_hosts ]; then \
        cp /tmp/ssh_config/known_hosts ${USER_HOME}/.ssh.build/known_hosts && \
        chmod 600 ${USER_HOME}/.ssh.build/known_hosts && \
        chown ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh.build/known_hosts; \
    fi

# Create .ssh directory so it exists even without the volume (for local testing)
RUN mkdir -p ${USER_HOME}/.ssh && \
    chmod 700 ${USER_HOME}/.ssh && \
    chown ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh

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

# Entrypoint runs as the non-root user (sshd on port 2222, no privilege separation)
COPY --chmod=755 files/entrypoint.sh /usr/local/bin/entrypoint.sh

USER $USERNAME
WORKDIR $CODE_PATH

RUN go install golang.org/x/tools/gopls@latest

# Install mise and ensure state directory exists (prevents Docker creating it as root on mount)
RUN curl https://mise.run | sh && \
    mkdir -p ${USER_HOME}/.local/state/mise

# Wrapper that unprefixes FORWARD_* env vars and execs claude
COPY --chown=${USERNAME}:${USERNAME} files/claude-wrapper ${USER_HOME}/.local/bin/claude-wrapper

# Install Claude Code (native install, auto-updates in background)
RUN curl -fsSL https://claude.ai/install.sh | bash
