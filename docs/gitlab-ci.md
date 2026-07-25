# GitLab CI (`.gitlab-ci.yml`)

A full translation of `.github/workflows/test.yml`'s 9 jobs, written without
access to a real GitLab instance — validated everywhere that's actually
possible (structural schema, shellcheck, side-by-side completeness against
the source), and clearly flagged everywhere it isn't. Both pipelines are
meant to coexist: `.github/workflows/test.yml` is untouched, and stays the
proven, currently-running pipeline until GitLab is validated for real.

**Doing the actual cutover?** [`docs/gitlab-migration.md`](gitlab-migration.md)
is the ordered step-by-step checklist. This doc is the technical reference
it links back to — what each piece means and why, not what order to do
things in.

## What's already CI-platform-agnostic (zero code changes needed)

These were specifically designed this session to not care which CI system
calls them — GitLab just needs the right CI/CD variables set:

- **Proxy**: every script reads plain `http_proxy`/`https_proxy`/`no_proxy`
  (`docs/proxy.md`).
- **Custom CA trust**: the `certs/` directory (container builds) and
  `CURL_CA_BUNDLE`/`VM_CA_CERT` (host/VM paths) — verified against a real
  MITM proxy this session.
- **Nexus artifact fetch/mirror**: `scripts/fetch-artifacts.sh`'s `NEXUS_URL`/
  `NEXUS_USER`/`NEXUS_PASSWORD`/`--mirror`.
- **Base image registry**: `UBI_IMAGE` build-arg already points anywhere.

## What's new: authenticated Docker/OCI registry

`make publish-platform` had zero authentication before this — it only ever
worked against a local anonymous test registry. `make registry-login REGISTRY_HOST=... REGISTRY_USER=... REGISTRY_PASSWORD=...` now does
`podman login` (password via stdin, never on the command line — same lesson
already applied to `fetch-artifacts.sh --mirror`'s Nexus credentials).
Login is separate from publish because authenticated **pulls** (the UBI
base image through Nexus) benefit from it too, not just pushes — once
logged in, podman's credential cache covers every subsequent
`build`/`pull`/`push` in the job.

## GitHub Actions → GitLab CI concept mapping

| GitHub Actions                                             | GitLab CI                                                     | Notes                                                                                                                                                                                   |
| ---------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `actions/checkout`                                         | (automatic)                                                   | GitLab clones before every job                                                                                                                                                          |
| `actions/cache`                                            | `cache: key: files: [...]`                                    | direct equivalent, up to 2 files                                                                                                                                                        |
| `actions/upload-artifact`                                  | `artifacts: paths: [...]`                                     | **must be inside `$CI_PROJECT_DIR`** — GitLab can't upload arbitrary host paths like GH's `/tmp/...` could; this file writes `sbom.json`/`security-audit.json` to the repo root instead |
| `id: x` + `$GITHUB_OUTPUT` + `working-directory:` per step | plain shell variables                                         | a GitLab job's whole `script:` array is **one continuous shell session** — `WORKDIR=$(...)` in one line is just usable in the next, no special mechanism                                |
| `$GITHUB_ENV`/`$GITHUB_PATH`                               | `export VAR=...`                                              | same reason as above                                                                                                                                                                    |
| `on.schedule.cron` (in-repo)                               | **Pipeline Schedules** (Project → Build → Pipeline schedules) | the cron itself is *not* in this YAML file — see below                                                                                                                                  |
| `github.event_name`                                        | `$CI_PIPELINE_SOURCE`                                         | `"schedule"`, `"web"` (manual UI trigger), `"push"`, `"merge_request_event"`                                                                                                            |
| `$GITHUB_STEP_SUMMARY`                                     | *(no direct equivalent used here)*                            | `scripts/security-audit.sh` already no-ops gracefully when it's unset — the report still prints to the job log                                                                          |
| secrets                                                    | CI/CD Variables (masked + protected)                          | see the table below                                                                                                                                                                     |

## Setting up the weekly `security-audit` schedule

The `- if: '$CI_PIPELINE_SOURCE == "schedule"'` rule in this file only
*reacts* to a schedule — it doesn't create one. In GitLab: **Project → Build
→ Pipeline schedules → New schedule**, cron `0 6 * * 1` (matches the
GitHub workflow's cadence), target branch `main`.

## CI/CD variables this file expects

Set these in **Project → Settings → CI/CD → Variables** (mask anything
secret; protect anything that should only run on protected branches):

| Variable                                                | Used by                                                                          | Purpose                                                                                           |
| ------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `NEXUS_URL`                                             | `fetch-artifacts.sh` (all build jobs)                                            | redirects artifact fetch to Nexus instead of the public internet                                  |
| `NEXUS_USER` / `NEXUS_PASSWORD`                         | `fetch-artifacts.sh --mirror` only                                               | not needed for a normal fetch — only for the (not wired into this file) mirror-populate operation |
| `REGISTRY_HOST` / `REGISTRY_USER` / `REGISTRY_PASSWORD` | `make registry-login` (not currently called by any job in this file — see below) | authenticate against the Docker/OCI registry                                                      |
| `http_proxy` / `https_proxy` / `no_proxy`               | every network-touching script                                                    | already-built proxy support, zero code changes                                                    |
| `CURL_CA_BUNDLE`                                        | host-side `curl` (`fetch-artifacts.sh`)                                          | trust a corporate TLS-inspecting proxy's CA                                                       |
| `CORP_CA_CERT` (**File** type)                          | `.corp-ca-setup` (every job, via `before_script`)                                | corporate CA written into `certs/corp-ca.pem` before any build — see below                        |

**Custom CA cert into `certs/`**: the `.corp-ca-setup` template's
`before_script` handles this — every job runs `cp "$CORP_CA_CERT" certs/corp-ca.pem` (no-op if the variable isn't set). Set `CORP_CA_CERT` as
a **File** type CI/CD variable — GitLab writes its *value* to a temp file
on disk and the variable itself holds that *path*, so no base64 decoding
is needed. File-type variables are available on every GitLab tier
(including free/self-managed CE), so this isn't a tier-dependent choice.

## What's deliberately NOT in this file

- **No job publishes to Nexus.** `make publish-platform`/`make registry-login` stay manual/local operations — pushing platform images on
  every CI run is a release-process decision for later, not a CI-bring-up
  requirement.
- **No label-based Traefik auto-discovery** (unrelated to this file, but
  same principle) — `compose/` stays a local dev-only concern, not part of
  CI at all.

## Runner topology: two separate pools, not one

This isn't a single homogeneous fleet, and getting the job → runner mapping
right matters more than any individual `dnf install` line:

- **Default pool: Kubernetes, deployed in OpenShift.** Privileged pods are
  **blocked cluster-wide** — no podman/buildah, no DinD sidecar, no
  kubectl-based "spin up a test pod" approach either. `lint`, `bats`, and
  `integration` run here (`.k8s-job`) because none of them touch a
  container engine at all.
- **Separate VM-based runner pool, already used to build container
  images.** Real VMs, not Kubernetes-executor pods, so the privileged-pod
  restriction doesn't apply there at all. Every job that calls
  `podman`/`buildah` — `container-build`, `multi-component`,
  `enterprise-proxy`, `vm-deployment`, `sbom`, `security-audit` — is routed
  here via `tags: [vm-container-build]` (`.vm-runner-job`).

This is *why* `enterprise-proxy` and `vm-deployment` (which both run
`podman run ... ubi9-minimal` from inside a job that's already running
under podman/buildah) work at all: they're on real VMs, so it's ordinary
podman-in-a-VM, not nested-container-in-a-restricted-pod. That was the
hard problem in an earlier draft of this file that assumed a single
Docker-executor pool; it went away once the VM pool was confirmed to
exist.

## First things to validate on real infrastructure

In priority order — start with #1, it's the one thing that could mean a
structural rework, not just filling in a placeholder:

1. **The VM runner tag.** `vm-container-build` (used by `.vm-runner-job`)
   is a **placeholder** — get the real tag from whoever administers your
   GitLab Runners and swap it in. Every podman/buildah-needing job routes
   through this one tag, so this is the single highest-leverage thing to
   confirm.
1. **Podman's actual presence on the VM runners.** Buildah is confirmed
   there (used for the existing image-build pattern); podman is only
   "I think" — unconfirmed. This repo's scripts (`Makefile`, `scripts/*.sh`)
   call `podman` directly (build, run, exec, cp, inspect), not `buildah`,
   so podman's presence is the real requirement — buildah alone isn't
   sufficient for the "run and test containers" half these jobs need. Each
   of the 6 VM-runner jobs opens with
   `command -v podman >/dev/null || { echo "ERROR: podman not found..."; exit 1; }`
   so a missing podman fails fast with a clear message instead of deep
   inside some later command.
1. **`registry-login` actually authenticating** against your real Nexus
   Docker registry (never tested against anything but a local anonymous
   `registry:2` this session).
1. **`dnf install` package names** — confirmed real via
   `dnf list --available` this session on `quay.io/podman/stable` (Fedora):
   `ShellCheck`, `curl`, `git`, `jq`, `perl`, `python3`, `gcc`, `make`,
   `tar`, `unzip`, `findutils`, `patch`, `gzip` all present. The VM
   runners' actual OS/package manager is unconfirmed — buildah's presence
   suggests a RHEL/Fedora-family VM (`dnf` likely works there too), but
   this is an assumption, not a verified fact. If the VM image already has
   these tools preinstalled, the `dnf install` lines are harmless no-ops;
   if the VM runs a different package manager entirely, swap them for the
   equivalent.
1. **GitLab cache behavior across runners.** The `cache:` blocks here work
   on a single shared runner out of the box; a multi-runner fleet without a
   distributed cache backend may see more cache misses than the GitHub
   version did — not wrong, just slower until/unless that's configured.
1. **`CORP_CA_CERT` (File-type variable) actually reaching `certs/`** —
   `.corp-ca-setup`'s `before_script` is wired in and shellcheck-clean, but
   unverified against a real GitLab instance's File-variable mechanism.
