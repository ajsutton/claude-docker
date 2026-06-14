#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/compose-files.sh"

# Load .env so we can inspect SSH_AUTHORIZED_KEYS
if [ -f "$SCRIPT_DIR/.env" ]; then
  source "$SCRIPT_DIR/.env"
fi

# Validate CODE_PATH
if [ -z "${CODE_PATH:-}" ]; then
  echo "Error: CODE_PATH is not set. Set it in .env to the directory you want mounted in the container." >&2
  exit 1
fi
if [ ! -d "$CODE_PATH" ]; then
  echo "Error: CODE_PATH=$CODE_PATH does not exist. Update it in .env to point to an existing directory." >&2
  exit 1
fi

# Default SSH_AUTHORIZED_KEYS to the host ssh-agent's loaded keys
if [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
  if ! ssh-add -l >/dev/null 2>&1; then
    echo "Error: SSH_AUTHORIZED_KEYS is not set in .env and no keys are loaded in ssh-agent." >&2
    echo "Either add SSH_AUTHORIZED_KEYS=\"...\" to .env or load a key with: ssh-add <your-key>" >&2
    exit 1
  fi
  SSH_AUTHORIZED_KEYS=$(ssh-add -L)
fi

export SSH_AUTHORIZED_KEYS

# Detect host timezone so the container matches
if [ -z "${TZ:-}" ]; then
  if [ -L /etc/localtime ]; then
    # macOS: /var/db/timezone/zoneinfo/<tz>, Linux: /usr/share/zoneinfo/<tz>
    TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
  elif [ -f /etc/timezone ]; then
    TZ=$(cat /etc/timezone)
  fi
fi
export TZ="${TZ:-UTC}"

# iron-proxy setup (opt-in via IRON_PROXY in .env): generate a CA, materialise
# the proxy config, and export the real secrets so docker compose hands them to
# the proxy container only.
case "$(printf '%s' "${IRON_PROXY:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    cert_dir="$SCRIPT_DIR/iron-proxy/certs"
    mkdir -p "$cert_dir"
    if [ ! -f "$cert_dir/ca.crt" ] || [ ! -f "$cert_dir/ca.key" ]; then
      echo "Generating iron-proxy CA in iron-proxy/certs/ ..."
      ca_cnf="$(mktemp)"
      cat > "$ca_cnf" <<'EOF'
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no
[req_dn]
CN = claude-docker iron-proxy CA
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign
EOF
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
        -days 3650 -nodes -config "$ca_cnf"
      rm -f "$ca_cnf"
    fi

    # First-run: copy the tracked example to the (gitignored) live config.
    if [ ! -f "$SCRIPT_DIR/iron-proxy/proxy.yaml" ]; then
      cp "$SCRIPT_DIR/iron-proxy/proxy.example.yaml" "$SCRIPT_DIR/iron-proxy/proxy.yaml"
      echo "Created iron-proxy/proxy.yaml from the example — edit it to customise egress rules."
    fi

    # Export the real secrets (already evaluated by sourcing .env above) so
    # docker compose interpolates them into the iron-proxy service. Shell env
    # takes precedence over .env-file values, so command substitutions like
    # GH_TOKEN=$(gh auth token) resolve correctly here.
    for _secret in ${IRON_PROXY_SECRETS:-GH_TOKEN}; do
      [ -n "${!_secret:-}" ] && export "$_secret"
    done
    unset _secret
    ;;
esac

build_compose_file_args

# Stage .claude.json into a directory mount to avoid Docker single-file bind
# mount corruption.  When Claude Code does an atomic write (write-tmp + rename)
# on the host, a file-level bind mount loses track of the new inode and the
# container sees stale / truncated data.  A directory mount handles this correctly.
mkdir -p "$SCRIPT_DIR/.mount-stage"
cp "$HOME/.claude.json" "$SCRIPT_DIR/.mount-stage/.claude.json" 2>/dev/null || true

#docker compose "${COMPOSE_FILE_ARGS[@]}" build --no-cache
docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --build
