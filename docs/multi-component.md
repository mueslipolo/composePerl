# Multi-component architecture (design)

> **Status: design / roadmap, not yet implemented.** This document records the
> target architecture and the incremental path to it, agreed in design review.
> Today the repo builds a *single* component (one `cpanfile` → one bundle → one
> image pair). Nothing here changes current behaviour until the phases below
> are actually built; each is marked so you can see what exists vs. what's
> planned.

## Where we're starting from

The real-world starting point this design serves:

- **Multiple app repositories** plus a **common Perl library** repository (itself
  a component), all deployed onto the **same VM**.
- One **monolithic `cpanfile`** covers the whole server's CPAN dependencies —
  every app shares it.
- **Common config files** configure the common Perl library.
- Apps are **deployed together**, coordinated by a matching-branch-name
  convention across repos.

The direction: **containerize (container-first)**, keep using the **bundle
system to manage the global CPAN modules on the servers**, and **incrementally**
split the monolithic `cpanfile` into per-component dependency sets — no big-bang.

## Core model: shared platform → common BOM → per-component delta

Three layers, from most-shared to least:

| Layer               | What it is                                                                           | Built                     | Shared by      |
| ------------------- | ------------------------------------------------------------------------------------ | ------------------------- | -------------- |
| **Platform**        | `perl-src → base → dev-tools` — one compiled Perl, system libs, XS toolchain, Oracle | once                      | everything     |
| **Common**          | the shared CPAN set + the common Perl library's code + (env-injected) config         | once per platform version | all components |
| **Component delta** | one component's *additional* CPAN modules + its app code                             | per component             | nobody         |

Decisions that fix this shape (from the review):

- **One Perl for all components.** They share `perl-src`/`base`, so one compiled
  Perl, one ABI, one CVE surface. A component that ever needs a *different* Perl
  is the thing that graduates out to a non-shared build — see "Graduation".
- **Build-time layer sharing** for the common libs (not a runtime volume): the
  common set is an image layer each component `FROM`s, deduplicated on disk by
  the container storage driver. Images stay self-contained (signable, SBOM-able,
  rollback-able). The VM equivalent is a single `@common` perlbrew lib.

### Target image DAG (planned)

```
perl-src → base → dev-tools ─┬─→ common-dev        (installs common/ cpanfile → /opt/cpan-common)
                             │        │
   (shared platform,         │        └─→ <comp>-dev   (FROM common-dev; installs the component's
    built once)              │                          DELTA only → /opt/cpan-<comp>; + app)
                             │
              base ──────────────────→ <comp>-runtime  (FROM base; COPY /opt/cpan-common from
                                                        common-dev + /opt/cpan-<comp> from <comp>-dev
                                                        + app; non-root)
```

`perl-src`/`base`/`dev-tools` are unchanged from today. `common-dev` is new and
shared. Each component adds exactly one `dev` and one `runtime`. `runtime` still
`FROM base` (preserving today's ABI-parity + no-build-tools-in-runtime
invariants), now COPYing **two** module trees.

Runtime `PERL5LIB` for a component:
`/opt/cpan-<comp>/lib/perl5 : /opt/cpan-common/lib/perl5 : /opt/perl/lib/perl5`.

### Directory layout (planned)

```
common/
  cpanfile              # the shared CPAN set (starts = today's monolith)
  cpanfile.snapshot     # the BOM (bill of materials)
  lib/                  # the common Perl library's own code
components/
  <app>/  cpanfile  cpanfile.snapshot  app/    # delta deps + app code
bundles/
  common/   bundle-<hash>.tar.gz + .build-info
  <app>/    bundle-<hash>.tar.gz + .build-info  # vendors the FULL closure; only the installed runtime layer ends up delta-only
```

## Dependency model: common is a BOM; components add, never override

`@INC` is **process-global** — there is no way to give common's modules one
version of a library and a component's code a different version in the same
process. Whatever is first on `PERL5LIB` wins for everything. So the only safe
policy is:

> **`common` is authoritative for every distribution it pins. A component may
> *add* new distributions; it may not *override* a common one.**

This is the Maven/Gradle "managed dependencies" model. Resolving a component:

| Component needs a dist that…                | Outcome                                               |
| ------------------------------------------- | ----------------------------------------------------- |
| common pins, at a satisfying version        | ✅ satisfied by common, **not** re-vendored           |
| common pins, at an **incompatible** version | ❌ **hard error** — the conflict gate fails the build |
| common doesn't pin                          | ✅ goes in the component's **delta** bundle           |

A conflict is never auto-resolved. It surfaces with two remediations:
**bump it in `common/`** (accept it affects everyone) or **de-share it** (remove
from `common/` so each component pins its own).

### How resolution actually works — Carton resolves, a gate enforces

Carton does resolution and bundling, but it will **not** enforce the no-override
rule: if a component demands a higher version than common pins, Carton silently
*moves the pin*. So enforcement is a thin gate we add on top.

Per component (`make bundle COMPONENT=<app>`), planned flow:

1. **Merge requirements.** Workdir `cpanfile` = `common/cpanfile` + the
   component's `cpanfile`, **seeded** with `common/cpanfile.snapshot`.
1. **`carton install`.** Keeps common's pins for everything they satisfy;
   resolves the component's genuinely-new distributions on top.
1. **Conflict gate** *(the piece we build — a small snapshot-diff script).*
   Compare the resulting snapshot against `common/cpanfile.snapshot` on the
   **shared distribution names**. If any shared dist's version differs → Carton
   moved a common pin → **fail** with the exact list. Because the gate re-checks
   the output, it's correct regardless of whether Carton would upgrade or error.
   (The `cpanfile.snapshot` `DISTRIBUTIONS`/`pathname` format is already parsed
   by `scripts/generate-cpan-sbom.pl` and `tests/TestConfig.pm`.)
1. **Bundle.** `component_snapshot − common_snapshot` = `delta.txt`, the dists
   only this component adds. The vendor mirror itself carries the **full**
   resolved closure (common's shared dists too), not just the delta — see
   "Layered install" below for why.
1. **Install (seed, then delta — see "Layered install" below for the full
   mechanism and why the naive approach doesn't work).** `<comp>-dev` is
   `FROM common-dev`; the component's install target is seeded from
   `/opt/cpan-common` so cpm skips (re-)installing anything already there,
   then the files that seed provided are pruned back out, leaving
   `/opt/cpan-<comp>` with just the delta.

### Worked example

`common` pins three distributions; component `x` declares its own direct deps
(one of which, `JSON::XS`, common already provides):

```
common/cpanfile              common/cpanfile.snapshot (the BOM)
  requires 'Try::Tiny';        Try-Tiny-0.30
  requires 'JSON::XS';         JSON-XS-3.04
  requires 'Moo';              Moo-2.005005

components/x/cpanfile
  requires 'JSON::XS';   # already in common
  requires 'DBI';        # new
  requires 'DBD::SQLite';# new
```

Step 1 — the scratch workdir gets the **union** cpanfile and a **copy of
common's snapshot** as the seed:

```
workdir/cpanfile          = common/cpanfile + components/x/cpanfile
workdir/cpanfile.snapshot = cp common/cpanfile.snapshot
```

Step 2 — `carton install` keeps common's three pins and adds only the new
distributions, producing:

```
workdir/cpanfile.snapshot:  Try-Tiny-0.30  JSON-XS-3.04  Moo-2.005005  DBI-1.643  DBD-SQLite-1.74
```

Step 3–4 — the gate diffs that against `common/cpanfile.snapshot`:

```
$ scripts/bom-gate.pl common/cpanfile.snapshot workdir/cpanfile.snapshot
DBD-SQLite 1.74
DBI 1.643
```

Exit 0, and those two lines are exactly `x`'s **delta** — `delta.txt` records
them, and they're the only distributions that end up in `x`'s *installed*
runtime layer once seed-then-delta prunes the rest back out. The bundle's
vendor mirror itself still carries all five (`Try-Tiny`, `JSON-XS`, `Moo` too)
— see "Layered install" for why.

**The conflict case:** had `components/x/cpanfile` said
`requires 'JSON::XS', '>= 4.0'`, Carton couldn't satisfy that from the seeded
`JSON-XS-3.04` pin, so it would re-resolve JSON-XS to 4.x — the resolved
snapshot then diverges from common on JSON-XS, and the gate exits 1:

```
BOM CONFLICT: component overrides distribution(s) that 'common' pins.
  JSON-XS   common=3.04   component=4.03
Fix: bump it in common/cpanfile (affects all), or remove it from common/.
```

Because the gate re-checks Carton's *output*, it's correct regardless of
whether a given Carton version re-resolves or errors on that unsatisfiable
seed — which is precisely why enforcement lives in the gate, not in Carton.
(Verified empirically: given contradictory constraints, Carton **silently
installs the higher version and exits 0** — it does not error — so the gate is
the only enforcement.)

### Layered install (seed, then delta)

The obvious install — "the component only installs its delta, because
`common` is already on `PERL5LIB`" — **does not work with cpm**. The facts
below were verified against the real pinned `cpm` binary (0.997024, the one
actually baked into images — not a newer `cpm` on PATH, which masks this):

- **cpm ignores the ambient `PERL5LIB`.** `cpm -L` is a *contained* local::lib;
  a module loadable via `PERL5LIB` is still re-resolved/reinstalled.
- **cpm still resolves and *fetches* every requirement in the cpanfile
  regardless of what's pre-seeded into `-L`.** Seeding does **not** skip
  fetch — a delta-only vendor mirror makes cpm fail with `FAIL fetch` for
  every shared dependency, because it tries to fetch them anyway and their
  tarballs aren't there.
- **cpm honours the `-L` target lib at the *install* step.** A module already
  present *in the target lib* is skipped at install/build time — this is
  where "already satisfied" actually matters, not at fetch/resolve time.

The install is still **seed-then-delta** (`scripts/install-component-layered.sh`):

1. **seed** `/opt/cpan-<comp>` with a copy of `/opt/cpan-common`, so cpm skips
   *installing* the shared modules (no recompiling common's XS);
1. `cpm install -L /opt/cpan-<comp>` the component from its vendor mirror —
   which must carry the **full resolved closure** (common's shared
   distributions + the component's own delta), not just the delta, since
   fetch happens for everything regardless of the seed;
1. **prune** every file `/opt/cpan-common` provides (the seed + anything shared),
   leaving `/opt/cpan-<comp>` with just the delta;
1. drop the emptied directories.

The prune is **safe precisely because of the gate**: a distribution shared with
`common` is pinned to the *same version*, so the seeded files are byte-identical
to common's — deleting them loses nothing, and the runtime resolves them from
the shared layer via
`PERL5LIB=/opt/cpan-<comp>/... : /opt/cpan-common/... : /opt/perl/...`. This
keeps the shared `common` layer physically single (COPYed once, deduped by the
storage driver) while each component's **runtime layer** carries only its own
delta — the bundle itself (the vendor mirror) is the full closure; only the
*installed, pruned* result is delta-only.

The lever is still seeding: it's what lets install skip recompiling common's
XS per component. What it does **not** do is let the bundle skip vendoring
common's distributions — that earlier assumption shipped delta-only bundles
that broke `cpm install` outright. `scripts/bundle-component.sh` produces the
full-closure bundle; `install-component-layered.sh` consumes it (baked into
the `common-dev` image so component builds can call it directly) and does the
delta-only pruning after install, not before.

## The split is a dial, not a switch

The migration does not require splitting anything up front:

- **Start:** `common/cpanfile` = today's **entire monolithic** cpanfile;
  every component's delta is **empty** (just app code). This is a faithful
  lift-and-shift of the current VM — everything shares the same big lib set.
- **Then:** move app-specific modules out of `common/` into a component's
  `cpanfile`, one at a time, at your own pace. The conflict gate is the safety
  rail — a move either resolves cleanly or tells you the dep is still shared and
  can't move yet.
- **End:** `common/` holds only the genuinely-shared set (including the common
  library's own deps); each component carries its true delta.

## One bundle, two delivery targets (VM + container)

The bundle is delivery-neutral — `vendor/cache` (source distributions),
`cpanfile`, `cpanfile.snapshot` — and installs the same way in both places
(`cpm` against the local mirror, snapshot removed first). This is what lets you
containerize **app-by-app** while the rest of the fleet stays on the VM, all
consuming the **same `common` bundle**:

|            | Container                      | VM / perlbrew                                              |
| ---------- | ------------------------------ | ---------------------------------------------------------- |
| common     | image layer `/opt/cpan-common` | perlbrew lib `perl-<ver>@common` (installed once per host) |
| component  | image layer `/opt/cpan-<comp>` | stacked lib `@common,@<comp>`                              |
| resolution | `PERL5LIB` order               | perlbrew lib **stacking** (native)                         |

So "manage the global CPAN modules on the servers with the bundle system" and
"go container-first" are the **same** source of truth used two ways — not two
dependency-management systems to keep in sync.

## Config: environment-scoped, injected at runtime

The common config files vary **by environment only** (not by app, not fixed).
Therefore they are **not baked into any image**. The common image is built once
and promoted unchanged across environments; the per-environment config is
provided at run time (a mounted config volume / secret / env vars, selected by
environment) to every component in that environment. This keeps images
env-agnostic and preserves reproducibility (the same digest runs in dev and
prod).

## Perl / common upgrades

A Perl bump (or a common-lib change) is a **platform event**, not a per-component
one, because XS is ABI-bound to Perl and everything shares it. Planned as one
command, resolved common-first and fanned out, gate-protected:

1. Stage the new `perl-<ver>.tar.gz`; set the version.
1. **Re-resolve `common` first** → new BOM (its shared versions may move).
1. **For each component: re-resolve against the new common, run the conflict
   gate.** A component that no longer fits the new baseline **fails here**, not
   in production.
1. Rebuild images + run full XS test suites; every bundle hash changes → new
   tags / perlbrew libs; old ones retained for rollback.

The same gate that guards a normal component change guards the platform bump.

## Repo topology & orchestration

Apps are **already separate repos**. This repo becomes the **platform** that
produces the shared artifacts; each app repo is a thin **component** that
consumes them and carries **its own git tags = its own versions**.

- **Cross-repo contract = a registry.** The platform publishes, versioned and
  (see prerequisites) signed: `common-dev` / `common-runtime` images, the
  `common` bundle as an OCI artifact (for VM consumers), and the common BOM
  (`cpanfile.snapshot`). Components pin the platform **by digest** for
  reproducibility. Full provenance of any image = (component delta snapshot) ×
  (platform digest).
- **Shared build machinery** (scripts + the conflict gate) ships as a published
  **builder image** / reusable CI workflow — consumed by component repos, not
  copy-pasted or submoduled.
- **Deploy-together, today, is a branch-name convention.** The near-term
  container equivalent is a **release-set manifest** (pin each app's image tag +
  the common version; deploy the set), loosened later as apps stop sharing a
  cadence.
- **Fan-out of platform upgrades** (later): a components manifest drives
  automated bump PRs into each component repo; each runs the conflict gate;
  green auto-merges, red parks for the owner. Not needed until deps are actually
  split and apps want independent cadence.

### Component versioning

Two orthogonal axes, both recorded on every built image:

- **Component version** — the app repo's own git tag → image tag
  (`registry/<app>:<git-tag>`).
- **Platform version** — recorded as an image **label** (`platform.version`,
  `perl.version`, `common.bom.hash`), so any image traces back to the exact
  shared foundation it was built on.

## Graduation seam (when a component leaves the shared platform)

A component only needs to leave the mono-platform if it needs a **different
Perl** or must diverge from the common baseline. The seam that allows it: the
platform's `base+common` is a published, signed, digest-pinned artifact, so a
component can move to a fully independent build `FROM registry/platform:...`
without this repo's machinery. Until then, keeping Perl-sensitive components on
the shared platform keeps upgrades **atomic** rather than a cross-repo rollout.

## Prerequisites this design assumes (not yet in place)

These are the up-front investments the multi-repo, container-first target
requires — tracked from the design review's supply-chain findings:

- **A registry** as the cross-repo contract (GHCR / Nexus / Harbor). The
  *mechanism* is validated: `make publish-platform REGISTRY=host/path`
  tags+pushes `common-dev`/`common-runtime`, and a component builds
  unmodified against it (`--build-arg COMMON_IMAGE=host/path`) — verified
  locally with a throwaway `registry:2` (`podman run -d -p 5000:5000 registry:2`; plain-HTTP localhost needs `PODMAN_PUSH_FLAGS=--tls-verify=false`
  on push and `--tls-verify=false` on the component's `podman build`). What's
  still open: which real registry, and — the bigger gap — **digest-pinning**.
  Today `COMMON_DEV_TAG`/`COMMON_RUNTIME_TAG` are plain tags; pinning by
  digest needs the Containerfile's `FROM ${COMMON_IMAGE}:${COMMON_DEV_TAG}`
  restructured into full-reference ARGs (e.g. `COMMON_DEV_REF`), since a tag
  reference (`name:tag`) and a digest reference (`name@sha256:...`) use
  different `FROM` syntax — not done yet, deliberately deferred past this
  validation pass.
- **Bundle-as-OCI-artifact + image signing** (cosign) so trust crosses the repo
- **Bundle-as-OCI-artifact + image signing** (cosign) so trust crosses the repo
  boundary — this is review finding **D4**, promoted from "future" to
  "prerequisite" by the multi-repo choice.
- **`.build-info` derived from the actual resolution environment** (review
  finding **D3**), not re-read from the Containerfile at stamp time.
- **A shared builder image / reusable CI workflow** carrying the conflict gate.

## Incremental roadmap

1. **Model split (no behaviour change):** introduce `common/` = current monolith,
   `components/<app>/` with empty deltas; thread a `COMPONENT` parameter through
   `deps.sh` / `build-image.sh` / the Containerfile (`ARG COMPONENT_DIR` +
   delta bundle), defaulting to preserve single-component builds.
1. **Conflict gate:** build and unit-test the snapshot-diff gate against
   hand-crafted common/component snapshot pairs.
1. **VM globals via the bundle:** install `common` as a `@common` perlbrew lib on
   the servers; formalize the current monolith in place.
1. **Container pilot:** containerize one app `FROM common-runtime`, env-injected
   config, off the same `common` bundle.
1. **Publish + sign** (D4/D3 prerequisites): platform artifacts to the registry.
1. **Start splitting:** move deps from `common/` into component deltas, gated.
1. **Cross-repo orchestration:** components manifest + gated fan-out, once
   independent cadence is actually wanted.
