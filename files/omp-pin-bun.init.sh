#!/bin/sh
# Replace the omp launcher with a wrapper that pins bun and the bundle path.
#
# `bun install -g` writes the omp launcher as a standalone copy of the bundle in
# ~/.local/bin with a `#!/usr/bin/env bun` shebang. That copy has two problems:
#
#  1. mise prepends a repository's pinned tool directories to PATH, so inside a
#     repository that pins an older bun, omp runs on that bun. omp needs a recent
#     bun and fails to parse its own bundle on an old one.
#  2. The copy sits outside node_modules, so the pi-natives loader treats it as a
#     workspace load, never resolves the platform addon package, and aborts with
#     "Failed to load pi_natives native addon".
#
# The wrapper calls the image's bun by absolute path and runs the bundle in
# node_modules, which avoids both. It also makes omp-shift-enter.init.sh
# effective, because that script patches the node_modules copy.
#
# This runs on every container start, so it reinstates the wrapper after an omp
# update restores the original launcher.

if [ -n "$APP_USER" ]; then
  _omp_home="$(eval echo ~"$APP_USER")"
  _omp_bun="$_omp_home/.local/bin/bun"
  _omp_bundle="$_omp_home/.local/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
  _omp_launcher="$_omp_home/.local/bin/omp"

  if [ -x "$_omp_bun" ] && [ -f "$_omp_bundle" ] && [ -e "$_omp_launcher" ]; then
    printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$_omp_bun" "$_omp_bundle" > "$_omp_launcher"
    chmod +x "$_omp_launcher"
    chown "$APP_USER:$APP_USER" "$_omp_launcher"
    echo "omp launcher: pinned to $_omp_bun"
  fi

  unset _omp_home _omp_bun _omp_bundle _omp_launcher
fi
