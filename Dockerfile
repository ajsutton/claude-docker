FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    git curl sudo zsh fzf ripgrep make \
    iptables ipset iproute2 dnsutils \
    openssh-server jq vim gh golang gpg python3.12-venv \
    ca-certificates tmux

# Install internal domain root certificates
RUN printf '%s\n' \
    '-----BEGIN CERTIFICATE-----' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    '-----END CERTIFICATE-----' \
    > /usr/local/share/ca-certificates/custom-ca.crt && \
    printf '%s\n' \
    '-----BEGIN CERTIFICATE-----' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    'REDACTED' \
    '-----END CERTIFICATE-----' \
    > /usr/local/share/ca-certificates/custom-ca-2.crt && \
    update-ca-certificates

# Install Node.js (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs

# Install diff-so-fancy globally
RUN npm install -g diff-so-fancy

# SSH setup
RUN mkdir /var/run/sshd && \
    cp -r /etc/ssh /etc/ssh.original

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

USER $USERNAME
WORKDIR $CODE_PATH

RUN go install golang.org/x/tools/gopls@latest

# Install mise
RUN curl https://mise.run | sh

# Install Claude Code into user's local bin (already on PATH via .zshenv)
RUN npm install -g --prefix ~/.local @anthropic-ai/claude-code
