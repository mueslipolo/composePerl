# Switching to GitLab: step-by-step

An ordered checklist for actually doing the cutover in your org's GitLab,
Nexus, and proxy environment. For the technical reference (CI/CD variables
table, GH→GitLab concept mapping, what's still unverified) see
[`docs/gitlab-ci.md`](gitlab-ci.md) — this doc is the "do this, then this"
sequence; that one is "here's what each piece means and why."

**Guiding principle**: `.github/workflows/test.yml` keeps running the whole
time. Nothing here requires touching it, and nothing about this migration
is reversible-costly if a step doesn't work — GitHub stays the safety net
until GitLab is proven for real, per your own call earlier.

## 0. Before you start — gather these

- GitLab project access with permission to set CI/CD variables and
  Pipeline Schedules (typically Maintainer role).
- Your org's Nexus: the raw-hosted repo URL (for `NEXUS_URL`), and separate
  credentials for (a) the artifact repo if it needs auth for reads, (b) the
  Docker/OCI registry (needed for pushes, and for pulls if `UBI_IMAGE` gets
  pointed through Nexus too).
- Corporate proxy host:port for `http_proxy`/`https_proxy`, and the
  `no_proxy` suffix list (internal hosts that should bypass it — Nexus
  itself almost certainly belongs here).
- Your corporate CA certificate, as a single PEM file.
- Confirmation from whoever runs your GitLab Runners: the **real tag** for
  the VM-based runner pool that builds container images (this file uses
  `vm-container-build` as a placeholder), and whether **podman** is
  actually installed there alongside buildah. This is the single biggest
  unknown — see step 4.

## 1. Create the GitLab project and push

```bash
# In GitLab: create an empty project (don't let it auto-generate a
# .gitlab-ci.yml or README — this repo already has both).
git remote add gitlab <your-gitlab-project-url>
git push gitlab main
```

`.gitlab-ci.yml` at the repo root is picked up automatically — GitLab will
try to run it on this first push. **Expect the first run to fail or stall**
until steps 2–5 below are done; that's expected, not a sign anything's
wrong with the file itself (it's already schema-validated — see
`docs/gitlab-ci.md`).

If you'd rather not have a half-configured pipeline firing on every push
while you set things up, disable CI runs on this project temporarily
(**Settings → General → Visibility, project features, permissions → CI/CD**
→ toggle off) and re-enable once step 5 is ready to go.

## 2. Set the CI/CD variables

**Settings → CI/CD → Variables → Add variable.** Mask every secret; protect
anything that should only be usable on `main` (recommended for all of
these, since they're all either credentials or environment config, not
per-branch app config):

| Variable                              | Type              | Value                                                                                                    |
| ------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------- |
| `NEXUS_URL`                           | Variable          | your Nexus raw-hosted repo base URL                                                                      |
| `NEXUS_USER` / `NEXUS_PASSWORD`       | Variable (masked) | only needed if you'll run `make mirror-artifacts` from CI later — not required for a normal pipeline run |
| `REGISTRY_HOST`                       | Variable          | your Nexus Docker/OCI registry hostname                                                                  |
| `REGISTRY_USER` / `REGISTRY_PASSWORD` | Variable (masked) | only needed if a job calls `make registry-login` — none do by default (see `docs/gitlab-ci.md`)          |
| `http_proxy` / `https_proxy`          | Variable          | `http://proxy.your-org:port`                                                                             |
| `no_proxy`                            | Variable          | include your Nexus hostname here                                                                         |
| `CORP_CA_CERT`                        | **File**          | paste your CA's PEM content — GitLab stores it and hands jobs a file path, not the raw text              |

Double-check `CORP_CA_CERT`'s type is actually **File**, not **Variable** —
picking the wrong type here is the most common mistake, and `.corp-ca-setup`
(baked into every job in `.gitlab-ci.yml`) expects a path, not PEM content
inline.

## 3. Set up the weekly security-audit schedule

**Build → Pipeline schedules → New schedule**:

- Description: `weekly security audit`
- Interval: custom cron `0 6 * * 1` (matches the GitHub workflow's cadence)
- Target branch: `main`
- Leave "Run for the next N days" etc. at defaults

`.gitlab-ci.yml`'s `security-audit` job only *reacts* to
`$CI_PIPELINE_SOURCE == "schedule"` — this step is what actually makes that
condition true on a schedule. Without it, `security-audit` only ever runs
via manual trigger (step 5.3 below).

## 4. Confirm the runner — do this before trusting any pipeline result

This file assumes **two separate runner pools**, not one uniform fleet
(see `docs/gitlab-ci.md`'s "Runner topology" section for the full
reasoning):

- **Kubernetes/OpenShift** (the default pool, privileged pods blocked
  cluster-wide) — `lint`, `bats`, `integration` run here. No podman
  involved, so nothing to confirm beyond "pods on this cluster can pull
  `quay.io/podman/stable` and run `dnf install`."
- **A separate VM-based pool** that already builds container images —
  every podman/buildah-needing job (`container-build`, `multi-component`,
  `enterprise-proxy`, `vm-deployment`, `sbom`, `security-audit`) routes here
  via `tags: [vm-container-build]`.

Ask whoever administrates your GitLab Runners for two things:

- **The real tag name** for that VM pool — `vm-container-build` in this
  file is a placeholder. Update `.vm-runner-job`'s `tags:` in
  `.gitlab-ci.yml` once you have it.
- **Whether podman (not just buildah) is installed there.** Buildah is
  confirmed present (it's what builds images there today); podman is not
  yet confirmed. This repo's scripts call `podman` directly for
  build/run/exec/cp/inspect, so podman's presence is a hard requirement,
  not a nice-to-have. Each of the 6 VM-runner jobs fails fast with a clear
  error (`command -v podman ...`) if it's missing, rather than failing
  confusingly deep inside a later step — but that's a fast, clear failure,
  not a fix; if podman genuinely isn't there, it needs to be added to that
  VM image before these jobs can pass.

If your org's runner setup doesn't match this two-pool shape at all (e.g.
no separate VM pool, or privileged pods are actually allowed on
Kubernetes), stop here and read `docs/gitlab-ci.md`'s runner-topology
section — `.gitlab-ci.yml` would need re-targeting, not just variable
tweaks.

## 5. First real run — in this order, not all at once

Trigger jobs individually rather than letting the whole pipeline rip on
the first real attempt, so a failure tells you something specific:

1. **`lint` and `bats`** first (**Build → Pipelines → Run pipeline**, or
   just push). These run on the Kubernetes/OpenShift pool, no podman, no
   proxy/Nexus dependency — if these fail, the problem is basic runner
   setup (can the pod pull `quay.io/podman/stable`, is `dnf` reachable
   through the proxy), not proxy/Nexus/certs.
1. **`integration`** next — still Kubernetes/OpenShift, exercises real CPAN
   network access (through your proxy/certs) but no podman at all. Confirms
   proxy + `certs/` + Nexus (if `NEXUS_URL` is set) work before touching the
   VM pool.
1. **`container-build`, `multi-component`, `sbom`** — first jobs on the VM
   pool. If these fail at the `command -v podman` check, that's step 4's
   VM-runner-tag/podman-presence question, not a proxy/certs problem. If
   they fail after that check passes, look at proxy/Nexus/certs same as
   `integration`.
1. **`enterprise-proxy`, `vm-deployment`** last — same VM pool as above,
   just the most involved jobs (each runs its own nested `podman run ... ubi-minimal` for a real end-to-end test, which is ordinary
   podman-in-a-VM, not a restricted-pod concern).
1. **`security-audit`** — trigger manually once (**Build → Pipelines → Run
   pipeline**, `$CI_PIPELINE_SOURCE` becomes `"web"` which the job's rule
   already matches) rather than waiting for Monday. **Expect it to fail** —
   this repo's real pinned dependencies have genuine, currently-unaddressed
   CVEs (confirmed earlier this session: 112 CPAN + 27 OS findings). A red
   `security-audit` is the audit working, not a migration bug.

## 6. Validate the registry path (optional, do when ready)

Not required for the pipeline above — `publish-platform`/`registry-login`
aren't called by any job. When you're ready to test pushing images to your
real Nexus:

```bash
make registry-login REGISTRY_HOST=<nexus-registry-host> \
  REGISTRY_USER=<svc-account> REGISTRY_PASSWORD=<...>
make common-dev common-runtime          # if not already built
make publish-platform REGISTRY=<nexus-registry-host>/<path>
```

Run this locally first (same as this session's local `registry:2`
validation) before wiring it into a CI job — publishing on every push is a
release-process decision to make deliberately, not a default to fall into.

## If something fails

- **`lint`/`bats` fail**: runner/image problem, not this repo's logic —
  check the runner can pull `quay.io/podman/stable` at all, and that `dnf`
  isn't blocked by the same proxy that needs configuring in step 2.
- **`integration` fails with network errors**: check `http_proxy`/
  `https_proxy`/`no_proxy` values, and that `CORP_CA_CERT` is genuinely
  **File** type (step 2's most common mistake).
- **Any VM-pool job fails at the `command -v podman` check**: podman isn't
  installed on that VM image — take it to whoever administrates the
  runners (step 4), it's a VM-image change, not a YAML fix.
- **A VM-pool job fails elsewhere with "job stuck / no runner matches
  tags"**: `vm-container-build` doesn't match your real runner tag — go
  back to step 4 and update `.vm-runner-job`'s `tags:` in
  `.gitlab-ci.yml`.
- **Anything else**: GitHub Actions is still green and still the source of
  truth — there's no pressure to make GitLab work before it's ready.

## When to retire GitHub Actions

Not yet, and not as part of this checklist. Once `.gitlab-ci.yml` has run
green end to end for real, on your actual runners, against your actual
Nexus — that's a separate, deliberate decision, not an automatic next step
here.
