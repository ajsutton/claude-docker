# Iron-proxy: when egress is routed through iron-proxy, the entrypoint (running
# as root at container start) captures placeholder tokens and CA paths into this
# file. Sourcing it here — via .zshenv, which runs for every zsh invocation —
# makes them available to every interactive session, every `be-exec` command,
# and every process they spawn, not just to whichever SSH session set them.
[ -f /etc/claude-docker/iron-proxy.env ] && source /etc/claude-docker/iron-proxy.env
