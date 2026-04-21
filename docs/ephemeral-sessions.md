# Ephemeral Per-Session Containers

This is the deep reference for the ephemeral-session mode. Everyday
setup lives in [`README.md`](../README.md); this doc covers the
design rationale, the per-tool cache concurrency analysis, and what's
implemented vs what's still open. Ephemeral mode is opt-in (`EPHEMERAL_SESSIONS=true`
in `.env`) as of the current branch; the maintainer is dogfooding it
before the default flip.

## TL;DR

- **Design**: each `be-claude` / `be-codex` / `be-shell` / `be-exec` invocation
  runs its own `docker run` against a pre-built image. The shared long-running
  container is still available at `EPHEMERAL_SESSIONS=false` (default).
- **Image rebuilds don't disturb active sessions**: running containers stay
  pinned to the image they started from; the next `be-*` invocation picks up
  whatever image tag `claude-docker:latest` points to.
- **Shared caches are still shared**: two named volumes
  (`claude-docker-build-cache` and `claude-docker-mise-installs`) are mounted
  into every session container at the same paths the shared container used.
  `EXTRA_VOLUMES` in `.env` lets users add project-specific ones
  (e.g. a persistent `rust/target` dir).
- **Cache concurrency verdict**: every tool we ship is safe to share.
  Cargo has a minor documented race on `config.lock` but the same risk
  exists today under the single container; npm's cache-corruption problem
  does not apply because Claude sessions write to project `node_modules`
  rather than a global cache.
- **ssh-agent forwarding** auto-detects across 1Password, Secretive,
  KeePassXC, gnome-keyring, `$SSH_AUTH_SOCK`, and the macOS synth path.
  Run `./run.sh ssh-agent-check` to see which agent will be selected.
- **Cleanup**: `./stop.sh` reaps orphan staging dirs; `./run.sh gc`
  removes idle named volumes (`--apply` to actually remove).
- **Second terminal**: `be-attach` replaces `ssh localhost -p 2222`
  with a `docker exec` wrapper that prompts for a session if multiple
  are running.

## Why the change is worth it

The shared-container model has two real problems:

1. **Rebuilds tear down all active sessions**. If the user rebuilds the image
   (e.g. to install a new apt package), every concurrent agent session is
   killed mid-work. There is no way to say "I want the new image for the
   next session but leave the current ones alone."
2. **All sessions share mutable container state**. Anything one session
   writes outside the bind mounts — installed user packages, running daemons,
   shell history, `/tmp` — leaks into every other session. There is no
   isolation between sessions.

The ephemeral-container design fixes both.

## Remaining trade-offs

1. **Per-session startup cost**. Every `be-claude` pays a `docker run`
   setup cost — image inspect, volume mount resolution, container create,
   OverlayFS setup, entrypoint chown pass. On a warm image this is typically
   in the 1–2 second range; the shared container incurs this once at
   `run.sh` time and then never again. Measure on your host before
   flipping the default.
2. **SSH / mosh escape hatch**. Shared-container mode's `ssh localhost -p 2222`
   from a second terminal is replaced by `be-attach` (which uses
   `docker exec`). Mosh is gone entirely — it needs a long-lived server
   which doesn't fit the ephemeral model. If the maintainer's workflow
   relies on mosh for resilient remote connections, that's a hard gap.
3. **compose.d overlays don't apply in ephemeral mode.** The replacement
   mechanisms cover every case we've hit so far:
   - `compose.d/bun.yml` → bun is now baked into the Dockerfile.
   - `compose.d/rust-cache.yml` → `EXTRA_VOLUMES` + `files/init.d/rust-cache.sh`.
   - `compose.d/todo-ui.yml` → out of scope; todo-ui is moving to its own
     standalone Docker container.
4. **Third-party ssh-agents on macOS may need a one-line .env override**.
   Auto-detection covers 1Password / Secretive / KeePassXC out of the
   box, but exotic setups (custom agent paths, agents running in a
   non-standard bundle ID) fall through to the launchd synth path. Run
   `./run.sh ssh-agent-check` to confirm; set `SSH_AGENT_HOST_SOCK` to
   override.

## Per-tool cache concurrency analysis

All of these tools share a single named volume
(`claude-docker-build-cache`) mounted at `~/.cache` inside each session.
`docker run --mount type=volume,...` places no concurrency-safety
constraints on the filesystem itself — the question is whether the tools
writing to that filesystem are safe when multiple containers do it at once.

### Go module cache (`GOMODCACHE=~/.cache/go-mod`) — SAFE

Go's official documentation for `cmd/go/internal/cache` states:

> "It is safe for multiple processes on a single machine to use the same
> cache directory in a local file system simultaneously. They will
> coordinate using operating system file locks and may duplicate effort
> but will not corrupt the cache."

Source: [pkg.go.dev/cmd/go/internal/cache](https://pkg.go.dev/cmd/go/internal/cache).

Docker named volumes on Linux sit on an ext4 or overlay2 filesystem that
supports `flock(2)`, so the locking contract holds. The explicit caveat is
network filesystems (NFS etc.), which do not apply here.

**Verdict**: safe. No change needed.

### Go build cache (`GOCACHE`, default `~/.cache/go-build`) — SAFE

Same documented guarantee as `GOMODCACHE`. Content-addressed storage plus
`flock`. Issue [golang/go#43645](https://github.com/golang/go/issues/43645)
reported apparent concurrency issues around Go 1.15 but is frozen with no
repro on recent Go; the documented invariant is authoritative.

**Verdict**: safe.

### Cargo (`CARGO_HOME=~/.cache/cargo`) — MOSTLY SAFE, WITH CAVEAT

Cargo locks the index directory (`registry/index/*/.cargo-lock`) with
read/write advisory locks and locks unpacking via `.cargo-ok` files. The
failure mode documented in
[rust-lang/cargo#11376](https://github.com/rust-lang/cargo/issues/11376) is
an exception on `config.lock` when two Cargo instances race on first-time
registry population. It does not corrupt the cache — subsequent `cargo`
runs succeed.

**Important**: this exact failure mode is *also* possible in the current
shared-container design if two agents run `cargo build` at the same time.
The ephemeral change does not introduce a new concurrency risk; it just
preserves the existing one.

**Verdict**: same concurrency profile as today. No mitigation needed for
parity. A future hardening could wrap concurrent `cargo build` with a
host-side semaphore, but that is out of scope.

### Rust target directory (`rust-cache.yml` volume) — SAFE UNDER SCCACHE

The `compose.d/rust-cache.yml` overlay mounts a persistent named volume at
`rust/target`. Rust's own `target/` directory is **not** safe for two
concurrent `cargo build` invocations compiling overlapping dep graphs — but
the maintainer uses [sccache](https://github.com/mozilla/sccache) on top,
which is content-addressed and explicitly designed for concurrent use by
multiple compilers. Under sccache, two sessions compiling the same crate
either hit the cache on the second compile or rebuild independently
without clobbering each other's artifacts.

**Verdict**: safe. No mitigation needed.

### svm (`SVM_HOME=~/.cache/svm`) — SAFE

`alloy-rs/svm-rs` installs each solc version under a per-version advisory
file lock (`try_lock_file(lock_path_for_version)`), see
[install.rs](https://github.com/alloy-rs/svm-rs/blob/master/crates/svm-rs/src/install.rs).
The lock is `flock(2)`-based and blocks a second installer until the first
finishes unpacking. If two sessions try to install the same version
simultaneously, one will wait; once unpacked, both use the same binary.

**Verdict**: safe.

### mise (`MISE_DATA_DIR=~/.local/share/mise`, separate volume) — SAFE UNDER OUR INVARIANTS

mise has [known problems](https://mise.jdx.dev/configuration.html#mise-data-dir)
with shared-across-users data directories because installs create symlinks
with the installing user's ownership. In our design **every session runs as
the same UID** (the container's `$APP_USER`), so that failure mode doesn't
apply. mise itself does not currently lock installs, so two concurrent
`mise install <same-version>` calls could race — the losing install throws
away its work, the winning install's tree becomes the canonical one. This
is rare (tools are installed once and reused) and recoverable (re-run
`mise install`).

**Verdict**: safe under the constraint that all sessions run as the same
host user. Document the constraint.

### npm global cache (`~/.npm`, inside `~/.cache`) — UNSAFE BUT NOT USED

npm's cache *is* known to corrupt under concurrent writes
([npm/npm#5948](https://github.com/npm/npm/issues/5948),
[npm/npm#2500](https://github.com/npm/npm/issues/2500)). Claude sessions,
however, overwhelmingly run `npm install` against a project's
`node_modules/` — that lives inside the bind-mounted `$CODE_PATH`, not
inside the shared `~/.cache` volume. The only global npm writes we do
happen in the Dockerfile at image build time (`npm install -g
diff-so-fancy @openai/codex`), which is single-threaded.

**Verdict**: unsafe in general; not exercised by our workload. If a user's
workflow includes concurrent `npm install -g`, the shared cache could
corrupt. Document.

### bun cache (`~/.bun/install/cache`, under `~/.cache` via XDG) — SAFE

bun's install cache is content-addressed and designed for concurrent use
across processes. bun itself is now installed at image build time (see
the Dockerfile `curl -fsSL https://bun.sh/install | bash` step) so there
is zero per-session install cost; the install cache under `~/.cache/bun`
is shared across sessions via the `claude-docker-build-cache` volume.

**Verdict**: safe.

### Foundry (`~/.foundry`, under `~/.cache` via XDG) — SAFE

Foundry's cache is mostly read-only references to svm-managed solc; mutable
state is limited to the compilation cache which is project-local (in
`out/`), not global. The solc binaries themselves come through svm, which
we've already established is safe.

**Verdict**: safe.

## ssh-agent forwarding

`ssh -A` goes away with ephemeral mode — there is no outer ssh connection
to forward. The agent socket has to reach the container by bind mount.
Inside the container the forwarded agent is used for:

- **Onward ssh** (e.g. `git push` over `ssh://` remotes, `ssh git@host`).
- **Git commit signing** — `files/setupGitSigning.sh` runs `ssh-add -L`
  at shell init and uses the first key as `user.signingkey` with
  `gpg.format=ssh`.

Both must work in ephemeral mode to preserve parity with the shared path.

### Auto-detection

`lib/ssh-agent-detect.sh` tries a prioritized list of host-side socket
paths and emits `-v <sock>:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent` for
the first one that's a real UNIX socket (or the macOS synth-path
fallback, which lives inside the Docker VM and can't be stat'd from the
host). The container-side path is always `/ssh-agent`.

Priority:

1. `SSH_AGENT_HOST_SOCK` in `.env` or the environment (explicit override,
   always wins if the path is a real socket).
2. `$SSH_AUTH_SOCK` if the docker runtime can bind-mount it. Native Linux
   and OrbStack can mount any path; Docker Desktop can only share paths
   inside directories it's been told to share (by default `$HOME`), so
   a socket in `/tmp` or `/var/folders` is skipped there.
3. Known agent socket paths on disk, checked in order:
   - **1Password (macOS)**: `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
   - **1Password (Linux)**: `~/.1password/agent.sock`
   - **1Password (Linux snap)**: `~/snap/1password/common/1Password/1password-ssh-agent.sock`
   - **Secretive**: `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`
   - **KeePassXC (macOS)**: `~/Library/Application Support/KeePassXC/sshagent.sock`
   - **KeePassXC (Linux)**: `~/.keepassxc/sshagent.sock`
   - **gnome-keyring**: `$XDG_RUNTIME_DIR/keyring/ssh` or `/run/user/$UID/keyring/ssh`
4. On macOS, the Docker Desktop / OrbStack synth path
   `/run/host-services/ssh-auth.sock` as a last resort — works for the
   default launchd agent only. See
   [docs.orbstack.dev/docker](https://docs.orbstack.dev/docker/) and
   [docker/for-mac#4242](https://github.com/docker/for-mac/issues/4242).

If detection fails, `run-ephemeral.sh` prints a warning listing every
candidate path so the fix is obvious.

### Diagnostic: `./run.sh ssh-agent-check`

Prints the selected agent and path without starting a container:

```
Selected: 1Password (macOS)
Path:     /Users/you/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
```

### Docker provider detection

`docker info --format '{{.OperatingSystem}}'` reports `OrbStack` on
OrbStack and `Docker Desktop` on Docker Desktop; anything else (native
Linux docker, Rancher, Colima) is treated as `native` and trusts
arbitrary host paths. Cached in `_CD_DOCKER_PROVIDER` for the lifetime
of the shell. This detection matters for step 2 only — every other step
is a fixed path that's equally valid on any provider.

### 1Password / Secretive setup

Auto-detection covers both. The user still has to enable the SSH agent
feature in their password manager:

- **1Password**: *Settings → Developer → Use the SSH agent*.
- **Secretive**: install, add keys, ensure the menubar agent is running.
- **KeePassXC**: *Tools → Settings → SSH Agent → Enable SSH Agent
  integration*; open your database so keys are decrypted.

Docker Desktop users may see a "Permission denied" the first time they
bind-mount a third-party agent socket. Worked-around in the 1Password
forum thread [#133105](https://1password.community/discussion/133105).
This is host environment configuration — the ephemeral launcher just
passes the path through unchanged.

### Legacy OrbStack fallback

OrbStack's pre-unified-proxy path
`/opt/orbstack-guest/run/host-ssh-agent.sock` still works if the
synthesized `/run/host-services/ssh-auth.sock` doesn't cooperate with
a third-party agent ([orbstack/orbstack#1062](https://github.com/orbstack/orbstack/issues/1062)).
Set `SSH_AGENT_HOST_SOCK` to it if you hit that case.

### Unit tests

`tests/test-ssh-agent-detect.sh` covers 15 scenarios against a fake
`$HOME` with real AF_UNIX sockets and a stubbed docker provider detector:
override precedence, each known-agent path, provider-specific `$SSH_AUTH_SOCK`
handling, the macOS fallback, and the "no agent found" error case. Run
from the repo root:

```sh
bash tests/test-ssh-agent-detect.sh
```

### Acceptance checks

Inside a fresh ephemeral session, all three should succeed:

- `ssh-add -L` returns the host's keys (not "The agent has no identities").
- `git commit --allow-empty -m probe` produces a signed commit
  (`git log --show-signature -1` shows `Good "git" signature`).
- `ssh -T git@github.com` returns `Hi <user>! You've successfully
  authenticated` without prompting.

## What was tested

- Shell syntax on all modified scripts (bash `-n`).
- Compose file validation is unchanged (shared-container path untouched).
- Unit tests for ssh-agent auto-detection: 20 assertions pass against
  a fake `$HOME` with real AF_UNIX sockets (`tests/test-ssh-agent-detect.sh`).
- Unit tests for `EXTRA_VOLUMES` parsing: 11 assertions across empty,
  single, multiple, whitespace, malformed, and mixed entries
  (`tests/test-extra-volumes.sh`).
- Smoke test of `lib/gc.sh` dry-run against fabricated orphan staging
  dirs: correctly identified both as removable.
- Live smoke test of `detect_ssh_agent` against the maintainer's host
  `$SSH_AUTH_SOCK`: returns "SSH_AUTH_SOCK" with the right path.

## What was NOT tested

Docker was not available in the environment where these phases were
implemented. The end-to-end checks from issue #11 Phase 0 are left for
the maintainer to run:

1. Build the image in ephemeral mode (`EPHEMERAL_SESSIONS=true ./run.sh`).
2. Start two concurrent `be-claude` sessions and confirm they are separate
   containers (`docker ps` shows two `claude-session-*` rows).
3. Confirm a cache write from one session is visible to the other (e.g.
   run `go get` of a new module in session A, then import it in session B
   without a re-download).
4. Rebuild the image; confirm the two running sessions are undisturbed.
5. Start a third session; confirm it uses the new image.
6. Confirm `~/.claude` credential refresh propagates back to the host
   Keychain on macOS after the session exits.
7. Measure startup latency (`time be-shell echo ok`) on a warm image.
8. **ssh-agent**: `ssh-add -L` inside a session returns host keys.
9. **git signing**: `git commit --allow-empty -m probe` signs and verifies.
10. **onward ssh**: `ssh -T git@github.com` succeeds without prompting.
11. `be-attach` drops into a running session's zsh from a second terminal.
12. `./run.sh gc` reports accurately; `--apply` reclaims idle volumes.
13. `EXTRA_VOLUMES="rust-target:/.../rust/target"` + `files/init.d/rust-cache.sh`
    produces a writable cross-session rust/target dir.
14. `bun --version` works in a fresh session with zero install cost.

All are mechanical; ~15 minutes of maintainer time with Docker running.

## Phase status vs. ajsutton/claude-docker#11

| Phase | Status | Notes |
|---|---|---|
| 0 — validate prototype | **pending** | requires Docker; left for maintainer |
| 1 — port compose.d overlays | **done** | `EXTRA_VOLUMES` + `files/init.d/` + rust-cache.sh.example |
| 2 — split todo-ui | **out of scope** | separate repo, separate PR |
| 3 — bake bun | **done** | Dockerfile + PATH in `.zshenv` |
| 4 — volume GC + stage-dir reaper | **done** | `./run.sh gc`, `stop.sh` autoreap |
| 5 — be-attach | **done** | pattern / selection / `-c` modes |
| 6 — docs | **done** | README + this file |
| 7 — cutover to default | **deferred** | maintainer wants dogfooding first |

## Remaining open questions

1. Is **startup latency** actually under 2s on the maintainer's host?
   Only way to know is measurement. Phase 0 has the command.
2. Is the **one-shared-user** assumption permanent? If a future use case
   wants per-session users (true sandboxing), the volume-sharing model
   has to be rethought entirely because mise-style UID-sensitive tools
   will break. Not a blocker; flag for the record.
3. **Mosh replacement.** Mosh is not available in ephemeral mode. If
   the maintainer uses mosh today (from their current `.env` it looks
   like `USE_MOSH=false` by default), this isn't a blocker. If they do
   use it on a flaky connection, we'd need a long-lived-debug-container
   design — out of scope here.

## Files touched on this branch

- `Dockerfile` — `ephemeral-init.sh` copy; bun install
- `run.sh` — branches on `EPHEMERAL_SESSIONS`; `ssh-agent-check` and `gc` subcommands
- `stop.sh` — branches on `EPHEMERAL_SESSIONS`; orphan stage-dir reaper
- `lib/connect.sh` — branches on `EPHEMERAL_SESSIONS` for `run_remote`
- `lib/run-ephemeral.sh` — docker-run based launcher; EXTRA_VOLUMES; ssh-agent via lib
- `lib/ssh-agent-detect.sh` — agent auto-detection
- `lib/gc.sh` — volume GC driver
- `files/ephemeral-init.sh` — in-container root-then-user init
- `files/init.d/README.md`, `.gitignore`, `rust-cache.sh.example` — overlay replacement
- `files/.zshenv` — bun bin on PATH
- `be-attach` — docker-exec second-terminal wrapper
- `tests/test-ssh-agent-detect.sh`, `tests/test-extra-volumes.sh`
- `.env.example`, `README.md`, `docs/ephemeral-sessions.md`
