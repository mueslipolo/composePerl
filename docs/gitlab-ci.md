# GitLab CI (`.gitlab-ci.yml`)

A full translation of `.github/workflows/test.yml`'s 9 jobs, written without
access to a real GitLab instance — validated everywhere that's actually
possible (structural schema, shellcheck, side-by-side completeness against
the source), and clearly flagged everywhere it isn't. Both pipelines are
meant to coexist: `.github/workflows/test.yml` is untouched, and stays the
proven, currently-running pipeline until GitLab is validated for real.

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

**Custom CA cert into `certs/`**: this file doesn't populate `certs/` yet —
add a `before_script` (or a dedicated early job) that writes your corporate
CA into `certs/` from either a GitLab **File-type** CI/CD variable (cleanest,
if your GitLab tier supports it) or a base64'd variable decoded with
`base64 -d`. Deliberately left as a choice, not assumed, since it depends on
your GitLab tier/config.

## What's deliberately NOT in this file

- **No job publishes to Nexus.** `make publish-platform`/`make registry-login` stay manual/local operations — pushing platform images on
  every CI run is a release-process decision for later, not a CI-bring-up
  requirement.
- **No label-based Traefik auto-discovery** (unrelated to this file, but
  same principle) — `compose/` stays a local dev-only concern, not part of
  CI at all.

## First things to validate on real infrastructure

In priority order — start with #1, it's the one thing that could mean a
structural rework, not just filling in a placeholder:

1. **Nested podman.** `enterprise-proxy` and `vm-deployment` both run
   `podman run ... ubi9-minimal` *from inside* the already-podman-in-Docker-
   executor container. This is genuinely untested — the riskiest assumption
   in this file. If it doesn't work under your runner's privileged-mode
   config, these two jobs need the most rework of anything here.
1. **`registry-login` actually authenticating** against your real Nexus
   Docker registry (never tested against anything but a local anonymous
   `registry:2` this session).
1. **`dnf install` package names** on `quay.io/podman/stable` (Fedora) —
   confirmed real via `dnf list --available` this session (`ShellCheck`,
   `curl`, `git`, `jq`, `perl`, `python3`, `gcc`, `make`, `tar`, `unzip`,
   `findutils`, `patch`, `gzip` all present), but the *job semantics*
   (does the whole pipeline actually run end to end) still need a real
   runner.
1. **GitLab cache behavior across runners.** The `cache:` blocks here work
   on a single shared runner out of the box; a multi-runner fleet without a
   distributed cache backend may see more cache misses than the GitHub
   version did — not wrong, just slower until/unless that's configured.
1. **Custom CA cert delivery** into `certs/` — pick File-type vs base64'd
   variable based on what your GitLab tier actually offers, then wire it
   into a `before_script`.
