# Ephemeral Per-Session Containers (experiment)

This document captures the design, trade-offs, and — most importantly — the
per-tool concurrency analysis for the ephemeral-session mode introduced on
this branch. The purpose of the experiment is to surface the true cost of
this architectural change so the maintainer can decide whether to adopt it.

## TL;DR

- **Design**: each `be-claude` / `be-codex` / `be-shell` / `be-exec` invocation
  runs its own `docker run` against a pre-built image. The shared long-running
  container goes away.
- **Image rebuilds don't disturb active sessions**: running containers stay
  pinned to the image they started from; the next `be-*` invocation picks up
  whatever image tag `claude-docker:latest` points to.
- **Shared caches are still shared**: two named volumes
  (`claude-docker-build-cache` and `claude-docker-mise-installs`) are mounted
  into every session container at the same paths the shared container used.
- **Cache concurrency verdict**: every tool we ship is safe to share except
  `npm` (which the monorepo uses locally in `node_modules`, not out of a
  shared cache — no actual impact) and `cargo` (mostly safe, occasional race
  on `config.lock`; same risk exists today under the single container when
  two agents compile Rust simultaneously).
- **Net new operational cost**: a small startup latency per session (~1s on
  a warm image) and loss of the compose-overlay mechanism inside sessions.

## Why the change might be worth it

The current shared-container model has two real problems:

1. **Rebuilds tear down all active sessions**. If the user rebuilds the image
   (e.g. to install a new apt package), every concurrent agent session is
   killed mid-work. There is no way to say "I want the new image for the
   next session but leave the current ones alone."
2. **All sessions share mutable container state**. Anything one session
   writes outside the bind mounts — installed user packages, running daemons,
   shell history, `/tmp` — leaks into every other session. There is no
   isolation between sessions.

The ephemeral-container design fixes both.

## Why the change might not be worth it

1. **Loss of compose overlays**. `compose.d/*.yml` files are read by
   `run.sh` for the shared container but not by `lib/run-ephemeral.sh`.
   Users relying on `bun.yml`, `rust-cache.yml`, or `todo-ui.yml` would need
   those ported to plain `docker run` flags or some new extension mechanism.
   This is a meaningful cost — those overlays exist because the author uses
   them.
2. **Per-session startup cost**. Every `be-claude` pays a `docker run`
   setup cost — image inspect, volume mount resolution, container create,
   OverlayFS setup, entrypoint chown pass. On a warm image this is typically
   in the 1–2 second range; the shared container incurs this once at
   `run.sh` time and then never again.
3. **More to clean up**. Exited containers `--rm` themselves, but named
   volumes accrete. `stop.sh` stops active sessions but doesn't reclaim
   volumes — a dedicated `gc` path would need to exist.
4. **SSH / mosh goes away**. The nice "just `ssh localhost -p 2222`" escape
   hatch is gone in ephemeral mode. If the user's workflow relies on SSHing
   in from a second terminal to debug a stuck session, that breaks. A
   `docker exec -it claude-session-<x> zsh` replaces it, but it is less
   ergonomic.

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
the same UID** (host `$USER` via `APP_UID`), so that failure mode doesn't
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

### bun cache (`~/.bun/install/cache`, inside `~/.cache` if `HOME` is set correctly) — SAFE

bun's install cache is content-addressed and designed for concurrent use
across processes. The `bun.init.sh` overlay installs bun into `~/.bun`
which is **not currently in the shared volume** — each ephemeral session
would re-run the curl install. This is a genuine regression for bun users;
the fix is either to bake bun into the Dockerfile or add `~/.bun` to the
shared cache volume. **Punted on this branch; see "Known gaps".**

**Verdict**: bun cache itself is safe; packaging of bun is a gap.

### Foundry (`~/.foundry`, under `~/.cache` via XDG) — SAFE

Foundry's cache is mostly read-only references to svm-managed solc; mutable
state is limited to the compilation cache which is project-local (in
`out/`), not global. The solc binaries themselves come through svm, which
we've already established is safe.

**Verdict**: safe.

## What was tested

- Shell syntax on all modified scripts (bash `-n`).
- Compose file validation is unchanged (shared-container path untouched).
- Code review of the new `run-ephemeral.sh` and `ephemeral-init.sh` against
  the existing `connect.sh` and `entrypoint.sh` for parity.

## What was NOT tested

Docker was not available in the environment where this prototype was
assembled. The following end-to-end checks from the original acceptance
criteria could not be run and are left for the reviewer:

1. Build the image in ephemeral mode (`EPHEMERAL_SESSIONS=true ./run.sh`).
2. Start two concurrent `be-claude` sessions and confirm they are separate
   containers (`docker ps` shows two `claude-session-*` rows).
3. Confirm a cache write from one session is visible to the other (e.g.
   run `go get` of a new module in session A, then import it in session B
   without a re-download).
4. Rebuild the image; confirm the two running sessions are undisturbed.
5. Start a third session; confirm it uses the new image (e.g. put a marker
   file in the Dockerfile build and check for its presence only in the
   third container).
6. Confirm `~/.claude` credential refresh propagates back to the host
   Keychain on macOS after the session exits.
7. Measure startup latency (`time be-shell echo ok`) on a warm image.

All seven are mechanical and fast; any reviewer with Docker can run them
in about 10 minutes.

## Known gaps

- **compose.d/ overlays are not ported.** `bun.yml`, `rust-cache.yml`, and
  `todo-ui.yml` are ignored in ephemeral mode. For the maintainer's current
  workflow this is a real regression (bun install every session; no
  persistent rust target; no todo-ui server). A production version of this
  mode would need an equivalent extension mechanism — probably a
  `files/init.d/*.sh` directory that the ephemeral init script sources,
  with a migration path from compose.d scripts (most of which are
  `/etc/claude-docker/init.d/*.sh` already).
- **Stage-dir cleanup in the rare case `be-*` is killed with SIGKILL**
  leaves `.mount-stage/session-<name>/` behind. A pass in `stop.sh` would
  handle it.
- **No GC for the shared volumes.** `docker volume rm` still works; we
  just don't wrap it.
- **No `docker exec` convenience wrapper** for attaching a second terminal
  to an already-running session. `docker exec -it claude-session-<tab>
  zsh` works but is less ergonomic than `ssh -p 2222 localhost` was.
- **mosh is not supported** in ephemeral mode. Mosh needs a long-running
  server; by design these containers are short-lived.

## Estimated effort to productionize

Rough estimates, assuming "productionize" means this is the default mode
and the shared-container path goes away:

| Work item | Effort |
|-----------|--------|
| Run the 7 acceptance tests and fix any runtime bugs | 0.5–1 day |
| Port `compose.d/*.yml` to `files/init.d/*.sh` equivalents | 0.5 day |
| Add bun to the Dockerfile (or the shared volume) | 0.25 day |
| Add stage-dir GC and a `volume gc` subcommand | 0.5 day |
| Add a `be-attach` / `be-debug` wrapper around `docker exec` | 0.25 day |
| Update README + docs + .env.example consolidation | 0.5 day |
| Decide on rollback plan / remove shared path | 0.5 day |
| **Total** | **~3 days engineering** |

If the maintainer wants to keep both paths indefinitely, drop the last two
items (~1 day savings) but accept a permanent branching in `connect.sh`.

## Open questions

1. Is the **startup latency** actually under the "couple seconds" target?
   Untested here; depends on host. macOS Docker Desktop is slower than
   native Linux.
2. Is losing compose overlays a **dealbreaker** for the maintainer's own
   workflow? If yes, the whole design is blocked on the overlay
   replacement story.
3. Is the **one-shared-user** assumption permanent? If a future use case
   wants per-session users (true sandboxing), the volume-sharing model
   has to be rethought entirely because mise-style UID-sensitive tools
   will break.

## Files touched on this branch

- `Dockerfile` — added `ephemeral-init.sh` copy
- `run.sh` — branches on `EPHEMERAL_SESSIONS`, builds image only
- `stop.sh` — branches on `EPHEMERAL_SESSIONS`, stops active sessions
- `lib/connect.sh` — branches on `EPHEMERAL_SESSIONS` for `run_remote`
- `lib/run-ephemeral.sh` — new, the docker-run based launcher
- `files/ephemeral-init.sh` — new, the in-container init script
- `.env.example` — documented the new flag
- `README.md` — documented the new mode
- `docs/ephemeral-sessions.md` — this file
