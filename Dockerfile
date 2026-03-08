FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    git curl sudo zsh fzf ripgrep make \
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
    useradd -ms /bin/zsh -d "$USER_HOME" $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Copy dotfiles with correct ownership
COPY --chown=${USERNAME}:${USERNAME} files/.profile ${USER_HOME}/.profile
COPY --chown=${USERNAME}:${USERNAME} files/.zshenv ${USER_HOME}/.zshenv
COPY --chown=${USERNAME}:${USERNAME} files/.zshrc ${USER_HOME}/.zshrc
# Create .zshrc.d directory and install snippets
RUN mkdir -p ${USER_HOME}/.zshrc.d && \
    chown ${USERNAME}:${USERNAME} ${USER_HOME}/.zshrc.d
COPY --chown=${USERNAME}:${USERNAME} files/setupGitSigning.sh ${USER_HOME}/.zshrc.d/setupGitSigning.sh

# Setup SSH authorized_keys from build arg
ARG SSH_AUTHORIZED_KEYS
RUN mkdir -p ${USER_HOME}/.ssh && \
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > ${USER_HOME}/.ssh/authorized_keys && \
    chmod 700 ${USER_HOME}/.ssh && \
    chmod 600 ${USER_HOME}/.ssh/authorized_keys && \
    chown -R ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh

# Copy known_hosts from host as a starting point (container maintains its own copy).
# RUN --mount is used instead of COPY so we can handle the file being absent gracefully,
# since COPY fails if the source file doesn't exist.
RUN --mount=type=bind,from=ssh_config,target=/tmp/ssh_config \
    if [ -f /tmp/ssh_config/known_hosts ]; then \
        cp /tmp/ssh_config/known_hosts ${USER_HOME}/.ssh/known_hosts && \
        chmod 600 ${USER_HOME}/.ssh/known_hosts && \
        chown ${USERNAME}:${USERNAME} ${USER_HOME}/.ssh/known_hosts; \
    fi

# Install iTerm2 utilities
RUN for util in imgcat imgls it2api it2attention it2cat it2check it2copy it2dl it2getvar it2git it2profile it2setcolor it2setkeylabel it2ssh it2tip it2ul it2universion; do \
        curl -fsSL "https://raw.githubusercontent.com/gnachman/iTerm2-shell-integration/main/utilities/$util" \
            -o "/usr/local/bin/$util" && \
        chmod +x "/usr/local/bin/$util"; \
    done

USER $USERNAME
WORKDIR $CODE_PATH

RUN go install golang.org/x/tools/gopls@latest

# Install mise
RUN curl https://mise.run | sh

# Wrapper that unprefixes FORWARD_* env vars and execs claude
COPY --chown=${USERNAME}:${USERNAME} files/claude-wrapper ${USER_HOME}/.local/bin/claude-wrapper

# Install Claude Code (native install, auto-updates in background)
RUN curl -fsSL https://claude.ai/install.sh | bash
