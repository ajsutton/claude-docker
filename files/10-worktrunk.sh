# Enable Worktrunk directory switching and zsh completions.
if command -v wt >/dev/null 2>&1; then
    eval "$(command wt config shell init zsh)"
fi
