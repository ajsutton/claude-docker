# files/init.d/

Drop `*.sh` files into this directory to run per-session container init
logic in ephemeral mode. Scripts here are bind-mounted into the container
at `/etc/claude-docker/init.d/` and sourced by `files/ephemeral-init.sh`
at container start, running **as root** before the user command is
exec'd via `su - $APP_USER`.

Use this to chown named-volume mount points, start side processes the
session needs, write config files, or any other root-required setup.

## Conventions

- Scripts are sourced (not exec'd) so they share the init shell's
  environment. They have access to `$APP_USER`, `$APP_HOME`, etc.
- Keep scripts **idempotent** — they run every session.
- Make them **fast** — they sit on the critical path before Claude starts.
- Use `[ -d ... ]` / `[ -x ... ]` guards so the absence of a dependency
  isn't fatal.

## Pairing with `EXTRA_VOLUMES`

Named volumes declared in `.env` via `EXTRA_VOLUMES="name:/path/in/container"`
are created as root by Docker on first attach. If the tool that uses the
volume needs to write it as `$APP_USER`, pair the volume declaration with
a `chown` init script here. See `rust-cache.sh.example` for the pattern.

## Local vs tracked

Real init scripts tend to be host-specific (they reference absolute paths
on your machine). The `.gitignore` keeps `*.sh` here out of version
control so your `rust-cache.sh` doesn't accidentally leak everyone
else's absolute paths. `*.sh.example` files ARE tracked, so examples can
ship with the repo. Copy `foo.sh.example` → `foo.sh` and edit.
