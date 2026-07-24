# Multi-stage Containerfile for Perl application with Carton dependency management
#
# 5-stage build: perl-src → base → dev-tools → dev → runtime
# Bundle regeneration (Containerfile.deps) also FROMs dev-tools, so the build
# toolchain and Oracle SDK live in exactly one place.
# See README.md for architecture details.

# Build arguments
ARG PERL_VERSION=5.28.1
# Override UBI_IMAGE to target a different RHEL/UBI major version at build time.
# Example: --build-arg UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:9.6

# Optional corporate proxy for microdnf/cpanm/carton network access during the
# build. No-op if unset, same pattern as certs/ below (which handles TLS trust
# for a TLS-inspecting proxy — a different, complementary concern: these vars
# make traffic *reach* the proxy, certs/ makes TLS validation *succeed* once
# it's there). See docs/proxy.md for which tool reads which var and why.
ARG http_proxy
ARG https_proxy
ARG no_proxy

# ============================================================================
# Stage 1/5: perl-src - Compile Perl from source
# ============================================================================
# Isolated as its own stage because Perl compile is expensive (10+ min) and
# rarely changes — this is the cache boundary that pays for itself.
# hadolint ignore=DL3006
FROM ${UBI_IMAGE} AS perl-src

ARG PERL_VERSION
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    no_proxy=${no_proxy}

# Optional corporate CA trust: users behind a TLS-inspecting proxy drop
# their CA cert(s) into certs/ (gitignored). No-op otherwise.
COPY certs/ /etc/pki/ca-trust/source/anchors/
RUN rm -f /etc/pki/ca-trust/source/anchors/.gitkeep && update-ca-trust

# hadolint ignore=DL3041,SC2015
RUN microdnf install -y \
      gcc \
      make \
      tar \
      gzip \
      wget \
  && microdnf clean all \
  || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }

WORKDIR /tmp/perl-build

COPY artifacts/perl-${PERL_VERSION}.tar.gz ./
# --no-same-owner: perl 5.42.2 upstream tarball is packaged with Windows-style
# ownership (Administrators/steve) that rootless podman cannot chown to.
# hadolint ignore=DL3003
RUN tar --no-same-owner -xzf "perl-${PERL_VERSION}.tar.gz" \
    && cd "perl-${PERL_VERSION}" \
    && ./Configure -des \
        -Dprefix=/opt/perl \
        -Dusethreads \
        -Duseshrplib \
    && make -j"$(nproc)" \
    && make install \
    && cd / \
    && rm -rf /tmp/perl-build


# ============================================================================
# Stage 2/5: base - Shared runtime foundation for dev and runtime
# ============================================================================
# Sole ancestor of both dev and runtime → guarantees identical runtime libraries
# in production and development. Contains ONLY runtime libraries (no build tools,
# no -devel packages).
# hadolint ignore=DL3006
FROM ${UBI_IMAGE} AS base

ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    no_proxy=${no_proxy}

COPY --from=perl-src /opt/perl /opt/perl

# Optional corporate CA trust: users behind a TLS-inspecting proxy drop
# their CA cert(s) into certs/ (gitignored). No-op otherwise.
COPY certs/ /etc/pki/ca-trust/source/anchors/
RUN rm -f /etc/pki/ca-trust/source/anchors/.gitkeep && update-ca-trust

# Runtime lib package list is generated from lib-packages.conf (column 1) —
# single source of truth shared with the dev-tools -devel list below, so the
# two can't drift apart from being hand-maintained separately. Extracted
# with grep|cut|sed rather than awk/perl/jq: all three are already present
# in the bare base image (no toolchain, no new dependency), and each does
# one obvious job — grep drops comments/blanks, cut extracts the column,
# sed trims whitespace and drops now-empty lines.
# The pipe here isn't pipefail-protected (this minimal `base` stage predates
# the toolchain, and podman's OCI build format ignores SHELL's own pipefail
# option anyway — discovered the hard way in an earlier RUN in this file).
# That's fine in this specific case: lib-packages.conf's presence is
# guaranteed by the COPY immediately above (a missing file fails the COPY,
# not this pipe), and `microdnf install` with an empty package list fails
# loudly on its own (`error: Packages are not specified`, exit 1 — verified)
# rather than silently no-op'ing, so there's no scenario where an internal
# pipe failure here produces a silent bad build.
COPY lib-packages.conf /tmp/lib-packages.conf
# hadolint ignore=DL3041,SC2046,SC2015,DL4006
RUN microdnf -y install $(grep -v -E '^[[:space:]]*(#|$)' /tmp/lib-packages.conf | cut -d'|' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d') \
  && rm -f /tmp/lib-packages.conf \
  && microdnf clean all \
  || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }

# Oracle Instant Client (runtime libraries only, no SDK).
# unzip is installed transiently and removed in the same layer, so it never
# ships in the final image.
COPY artifacts/instantclient-basiclite*.zip /tmp/
# hadolint ignore=DL3041
RUN { microdnf install -y unzip \
        || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }; } \
    && unzip -o -q /tmp/instantclient-basiclite*.zip -d /opt/oracle \
    && mv /opt/oracle/instantclient_* /opt/oracle/instantclient \
    && rm -f /opt/oracle/instantclient/*.jar /opt/oracle/instantclient/libocci.so \
    && rm -f /tmp/instantclient-basiclite*.zip \
    && microdnf remove -y unzip \
    && microdnf clean all

ENV PATH="/opt/perl/bin:${PATH}" \
    PERL5LIB="/opt/perl/lib/perl5" \
    PERL_LOCAL_LIB_ROOT="" \
    PERL_MB_OPT="" \
    PERL_MM_OPT="" \
    LD_LIBRARY_PATH=/opt/oracle/instantclient \
    ORACLE_HOME=/opt/oracle/instantclient


# ============================================================================
# Stage 3/5: dev-tools - Build toolchain shared with Containerfile.deps
# ============================================================================
# Adds the full XS compile toolchain and Oracle SDK on top of base. Contains
# NO CPAN modules and NO application code — exists purely to be the shared
# ancestor of `dev` (which adds modules + app) and Containerfile.deps (which
# adds Carton). Editing the toolchain package list here updates both.
#
# No proxy ARG/ENV redeclared here: http_proxy/https_proxy/no_proxy set in
# `base` are already baked into its image config and inherited automatically
# by every `FROM base` (this stage) or `FROM <image>:dev-tools`
# (Containerfile.deps) — redeclaring here with no default would overwrite the
# inherited value with an empty string on any build that doesn't repeat the
# same --build-arg.
FROM base AS dev-tools

# Generic build toolchain — not per-library, so not part of lib-packages.conf.
# hadolint ignore=DL3041,SC2015
RUN microdnf -y install \
      gcc \
      make \
      perl-core \
      perl-devel \
      which \
      util-linux \
      findutils \
      tar \
      gzip \
      unzip \
      patch \
  && microdnf clean all \
  || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }

# -devel headers matching base's runtime libs, generated from the same
# lib-packages.conf (column 2) base's RUN used — see the comment there
# (same grep|cut|sed reasoning, and the same pipefail non-concern applies).
COPY lib-packages.conf /tmp/lib-packages.conf
# hadolint ignore=DL3041,SC2046,SC2015,DL4006
RUN microdnf -y install $(grep -v -E '^[[:space:]]*(#|$)' /tmp/lib-packages.conf | cut -d'|' -f2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d') \
  && rm -f /tmp/lib-packages.conf \
  && microdnf clean all \
  || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }

# Oracle SDK headers (build-time only, required by DBD::Oracle).
COPY artifacts/instantclient-sdk*.zip /tmp/
RUN unzip -o -q /tmp/instantclient-sdk*.zip -d /opt/oracle-sdk-extract \
    && mv /opt/oracle-sdk-extract/instantclient_*/sdk /opt/oracle/instantclient/sdk \
    && rm -rf /opt/oracle-sdk-extract /tmp/instantclient-sdk*.zip


# ============================================================================
# Stage 4/5: dev - Development image (dev-tools + CPAN modules + app)
# ============================================================================
# Installs modules once into /opt/cpan-modules; the runtime stage copies from
# this location so both images use bit-identical module builds.
FROM dev-tools AS dev

# Install all CPAN modules offline from the pre-built bundle.
# cpanfile.snapshot is intentionally removed before cpm runs: cpm resolves
# against the local vendor/cache mirror (built by `carton bundle`), which
# contains ONLY the exact distributions pinned in the snapshot at bundle-
# creation time — so cpm has no other version to resolve to and effectively
# reproduces the snapshot's pins. If vendor/cache is ever regenerated to
# include multiple versions of a distribution, this determinism guarantee
# breaks. Do not remove this without an explicit lock mechanism in its place.
WORKDIR /opt/perl-install
COPY artifacts/cpm /opt/perl/bin/cpm
COPY cpanfile cpanfile.snapshot ./
COPY bundles/bundle-latest.tar.gz ./cpan-bundle.tar.gz
# hadolint ignore=DL3003
RUN tar xzf cpan-bundle.tar.gz \
    && rm cpanfile.snapshot \
    && cpm install -L /opt/cpan-modules --resolver "02packages,file://$PWD/vendor/cache" \
    && rm -rf /opt/perl-install ~/.perl-cpm

ENV PERL5LIB="/opt/cpan-modules/lib/perl5:${PERL5LIB}"

# cpanm kept in the dev image for running test suites (see scripts/test-run-suites.sh).
COPY artifacts/cpanm /opt/perl/bin/cpanm

WORKDIR /app
COPY cpanfile cpanfile.snapshot ./
COPY app/ ./

CMD ["/opt/perl/bin/perl", "app.pl"]


# ============================================================================
# Stage 5/5: runtime - Minimal production image
# ============================================================================
# Inherits from base (clean runtime lineage — no build tools).
# Copies installed modules from dev; no CPAN install runs here.
FROM base AS runtime

COPY --from=dev /opt/cpan-modules /opt/cpan-modules

ENV PERL5LIB="/opt/cpan-modules/lib/perl5:${PERL5LIB}"

WORKDIR /app
COPY app/ ./

# hadolint ignore=DL3041
RUN { microdnf install -y shadow-utils \
        || { echo "==> microdnf failed - check http_proxy/https_proxy build-args and certs/ CA trust; see docs/proxy.md" >&2; exit 1; }; } \
    && useradd -m -u 1001 appuser \
    && chown -R appuser:appuser /app \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

USER appuser

# No HEALTHCHECK: app.pl is a placeholder that prints and exits rather than
# serving requests, so there's nothing for a check to poll yet. When a real
# long-running component lands here, add one against its actual liveness
# signal, e.g.:
#   HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
#       CMD curl -f http://localhost:PORT/health || exit 1
# A check that always passes (e.g. "perl -e 1") would be worse than no check
# at all — it reports healthy regardless of whether the app is actually up.

CMD ["/opt/perl/bin/perl", "app.pl"]
