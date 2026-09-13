#!/bin/sh
# Replace Bun's omp symlink with a wrapper that pins bun and the bundle path.
#
# `bun install -g` links ~/.local/bin/omp to the bundle in node_modules. Running
# that link has two problems:
#
#  1. mise prepends a repository's pinned tool directories to PATH, so inside a
#     repository that pins an older bun, omp runs on that bun. omp needs a recent
#     bun and fails to parse its own bundle on an old one.
#  2. The pi-natives loader treats the linked entry point as a workspace load,
#     never resolves the platform addon package, and aborts with
#     "Failed to load pi_natives native addon".
#
# The wrapper calls the image's bun by absolute path and runs the bundle in
# node_modules, which avoids both. This runs on every container start, so it
# reinstates the wrapper after an omp update restores the symlink.

if [ -n "$APP_USER" ]; then
  _omp_home="$USER_HOME"
  _omp_bun="$_omp_home/.local/bin/bun"
  _omp_bundle="$_omp_home/.local/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
  _omp_launcher="$_omp_home/.local/bin/omp"

  if [ -x "$_omp_bun" ] && [ -f "$_omp_bundle" ] && [ -e "$_omp_launcher" ]; then
    _omp_tmp="$(mktemp "${_omp_launcher}.XXXXXX")"
    if printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$_omp_bun" "$_omp_bundle" > "$_omp_tmp" &&
      chmod +x "$_omp_tmp" &&
      chown "$APP_USER:$APP_USER" "$_omp_tmp" &&
      mv -f "$_omp_tmp" "$_omp_launcher"; then
      echo "omp launcher: pinned to $_omp_bun"
    else
      rm -f "$_omp_tmp"
    fi
  fi

  unset _omp_home _omp_bun _omp_bundle _omp_launcher _omp_tmp
fi
