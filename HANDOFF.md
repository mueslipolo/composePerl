# Handoff — remaining work (multi-component + review follow-ups)

This is a working handoff for continuing the composePerl work in an environment
with **podman that can build images** and **more open network access** than the
sandbox where the merged work was done. Read the "Environment setup" and
"Hard-won facts" sections first — they will save you the dead-ends already hit.

## Current state (all on `main`)

The **security review** is fully remediated (PRs #17, #18, #20, #21, #22): High
+ Medium + CI hardening + Low/nits + usability quick wins.

The **multi-component architecture** is designed and its dependency-resolution
half is built and tested against real CPAN (PRs #23, #25, #26, #27, #28, #29,
#30, #31). What exists and is proven:

- **`scripts/bom-gate.pl`** — the "common is a BOM" conflict gate: a component
  may add distributions, never re-pin a shared one. Unit-tested
  (`tests/bats/bom-gate.bats`).
- **`scripts/resolve-component.sh`** — resolve a component against common
  (union cpanfile + seeded common snapshot → `carton install` → gate → delta).
- **`scripts/install-component-layered.sh`** — **seed-then-delta** install: seed
  the target lib from common, `cpm install` the delta-only mirror, prune common
  back out → delta-only layer.
- **`scripts/bundle-common.sh`** / **`scripts/bundle-component.sh`** — host-path
  bundle producers (delta-only component bundles).
- **`scripts/deps.sh bundle-common`** — the container-path common bundle (via
  the carton-runner), parameterized by `Containerfile.deps`'s `CPANFILE_DIR`.
- **Containerfile `common-dev` / `common-runtime`** platform stages;
  **`components/example/`** worked component; **`make`** targets `bundle-common`,
  `bundle-component`, `common-dev`, `common-runtime`.
- **`.github/workflows/test.yml`** `multi-component` job — end-to-end build in CI.
- **`docs/multi-component.md`** — the full design (model, BOM/gate, seed-then-delta,
  measured cpm behaviour, roadmap).

Real-CPAN integration tests (skip without carton): `multi-component-resolve.bats`,
`multi-component-layered.bats`, `bundle-common.bats`, `bundle-component.bats`.
Full suite: 153 pass / 11 skip / 0 fail in the sandbox.

## Hard-won facts (do not re-derive)

1. **Carton silently upgrades on conflict.** Given contradictory constraints,
   `carton install` installs the higher version and exits 0 — it does NOT error
   and does NOT honour a seeded pin. Enforcement therefore lives in
   `bom-gate.pl`, which re-checks Carton's *output* snapshot. Never rely on
   Carton to reject an override.
2. **cpm ignores the ambient `PERL5LIB` but honours the `-L` target lib.** A
   module loadable via `PERL5LIB` is still reinstalled by `cpm -L`; a module
   already present *in the target lib* is skipped. This is why the install is
   **seed-then-delta** (seed the target with common, then install the delta).
3. **The repo working-tree mount rejects symlink creation** in some sandboxes
   (`ln -sf` → "Permission denied"). Bundle dirs use `bundle-latest` symlinks;
   tests that create them run in `BATS_TEST_TMPDIR` (tmpfs). On a normal
   filesystem / CI this is a non-issue.
4. **Oracle Instant Client versions get delisted.** The pinned
   `ORACLE_IC_VERSION` in `scripts/fetch-artifacts.sh` may 404; bump it (and
   `ORACLE_IC_SUBDIR`) to a current version — see `docs/troubleshooting.md`.
5. **`git update-index --chmod=+x` updates the index, not the working file.**
   New scripts need both `chmod +x` (working tree) and the mode committed, or
   they fail with "Permission denied" when invoked directly.
6. `deps.sh` uses podman-specific subcommands (e.g. `podman image exists`) that
   Docker lacks — a bare `CONTAINER_ENGINE` swap would silently misbehave.

## Environment setup (the part the sandbox couldn't do)

**podman**: installs fine (`sudo apt-get install -y podman`) but its default
rootless stack fails where `/dev/fuse` and `/dev/net/tun` are absent. It runs
with `--storage-driver=vfs --network=host`. To make the repo's bare `podman`
calls work, set these globally before building:

```bash
mkdir -p ~/.config/containers
printf '[storage]\ndriver = "vfs"\n' > ~/.config/containers/storage.conf
printf '[containers]\nnetns = "host"\n[engine]\n' > ~/.config/containers/containers.conf
# and build/run with --network=host if netns default isn't honoured
```
If your environment has a working daemoned podman/overlayfs, skip this.

**Network allow-list** (sandbox default-denies; open what your env needs):
- `registry.access.redhat.com` — the UBI base image (was blocked).
- `download.oracle.com` — Oracle Instant Client (was blocked).
- `www.cpan.org, cpan.org, cpan.metacpan.org, fastapi.metacpan.org, backpan.perl.org`
  — Perl source + CPAN (carton/cpanm).

**Host carton/cpm** (for the host-path bundle scripts and integration tests):
```bash
curl -fsSL https://raw.githubusercontent.com/miyagawa/cpanminus/1.7048/cpanm -o /tmp/cpanm
perl /tmp/cpanm --notest -n -l ~/perl5 Carton App::cpm
export PERL5LIB="$HOME/perl5/lib/perl5" PATH="$HOME/perl5/bin:$PATH"
```

## TASKS (roughly in priority order)

### 1. Build-validate the platform stages for real  ← do this first
The `common-dev` / `common-runtime` / `components/example/Containerfile` stages
were only hadolint-validated in the sandbox (no podman build). Build them:
```bash
make fetch-artifacts        # needs redhat+oracle+cpan open; bump Oracle if 404
make bundle-common          # carton-runner container → bundles/common/
make common-dev common-runtime
make bundle-component COMPONENT=components/example
cp "$(readlink -f bundles/example/bundle-latest.tar.gz)" components/example/bundle-latest.tar.gz
podman build -t example-component:test -f components/example/Containerfile components/example
podman run --rm example-component:test    # expect the "both loaded" line
```
**Acceptance:** the run prints "Capture::Tiny (common) + Test::Fatal (delta)
both loaded"; the invariants in the `multi-component` CI job hold (delta-only
`/opt/cpan-component`, no gcc/make in the runtime, uid 1001). Fix any Containerfile
issues found — this is their first real build. Confirm the `multi-component`
GitHub CI job (added in #30) is green.

### 2. Per-component container path in `deps.sh`
Mirror `bundle-common` for components (currently only the host `bundle-component.sh`
exists). Add `deps.sh bundle-component <component-dir>`:
- assemble a temp build-context dir with the **union** cpanfile (`common/cpanfile`
  + component cpanfile) and a **seed** copy of `common/cpanfile.snapshot`;
- `build_carton_runner <that-dir>` (already parameterized via `CPANFILE_DIR`);
- extract the resolved `cpanfile.snapshot` + vendor from the container;
- run `bom-gate.pl common/cpanfile.snapshot <extracted-snapshot>` → conflict
  (exit 1) or delta; prune vendor to the delta; write `bundles/<name>/` +
  `delta.txt` + build-info + latest symlink (see `bundle-component.sh` for the
  exact packaging).
- Repoint `make bundle-component` at it (keep the host script as the no-podman
  reference), and add mock tests mirroring `deps-bundle-common.bats`.
**Acceptance:** `make bundle-component COMPONENT=components/example` builds the
delta bundle via the container; a conflicting component fails with exit 1;
mock-based bats + a real podman build both pass.

### 3. `WITH_ORACLE` opt-out (usability U2 — also unblocks Oracle-free builds)
Oracle Instant Client is currently mandatory (`Containerfile` base/dev-tools/dev
COPY+extract it; `check-artifacts` requires both zips). Make it opt-in
(`WITH_ORACLE`, default off): guard the Oracle COPY/RUN blocks and the
`check-artifacts`/`fetch-artifacts` Oracle steps. This lets anyone build without
Oracle and removes a hard dependency from the multi-component build.
**Acceptance:** `make bundle` / `make all` succeed with no Oracle zips when
`WITH_ORACLE` is unset; Oracle still works when set.

### 4. Real Docker support or keep podman-only (usability U1)
Either thread a `CONTAINER_ENGINE` variable through the scripts AND handle the
podman-vs-docker subcommand differences (`podman image exists` →
`docker image inspect`, etc.), or leave the README's "Podman only" statement as
the honest answer. Decide, don't fake it.

### 5. Supply-chain finish (D4) — needs a registry decision
- **Sign images** (cosign) and record the produced **bundle's own digest**
  (there's `artifacts.sha256` for inputs, nothing for outputs).
- **Store the common bundle as an OCI artifact** (ORAS) in the chosen registry
  so component repos consume `base+common` by digest — this is the seam that
  lets a component graduate to its own repo (docs/multi-component.md
  "Graduation seam").

### 6. `.build-info` from the real resolution env (D3)
`stamp_build_env` in `deps.sh` writes `PERL_VERSION`/`UBI_IMAGE` by re-reading
the Containerfile, and re-stamps on the cache-hit path. Derive it from what was
actually resolved inside the carton-runner, and don't overwrite an existing
stamp on cache hit — so the VM compat gate can't be fed a stale/mismatched stamp.

### 7. Cross-repo fan-out — needs decisions
When components move to their own repos: a components manifest + automated
"bump to platform vNext" PRs that run the conflict gate (green auto-merges, red
parks). Only worth building once components are actually split and independently
released. See docs/multi-component.md "Repo topology & orchestration".

### 8. Product-owner calls (decisions, not code)
- **Perl 5.28.1 is EOL (2019).** Plan a migration; a bump re-resolves common
  then every component (common-first), gate-protected — see the Perl-upgrade
  section in docs/multi-component.md.
- **Pin the UBI base image by digest** (currently by tag `ubi9/ubi-minimal:9.6`).

## Working conventions used so far
- One branch + PR per change; squash-merge; delete the branch after.
- Every shell script `shellcheck`-clean; both Containerfiles `hadolint`-clean.
- Tests are bats; real-CPAN/real-podman ones skip gracefully when the tool is
  absent, so the fast `bats` CI job stays hermetic.
- Do not commit `bundles/`, `vendor/`, `local/`, `artifacts/` (gitignored).
