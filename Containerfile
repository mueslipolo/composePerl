# Multi-stage Containerfile for Perl application with Carton dependency management
#
# 4-stage build: perl-src → base → dev → runtime
# Bundle regeneration lives in Containerfile.deps.
# See README.md for architecture details.

# Build arguments
ARG PERL_VERSION=5.42.2
# Override UBI_IMAGE to target a different RHEL/UBI major version at build time.
# Example: --build-arg UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:9.6

# ============================================================================
# Stage 1/4: perl-src - Compile Perl from source
# ============================================================================
# Isolated as its own stage because Perl compile is expensive (10+ min) and
# rarely changes — this is the cache boundary that pays for itself.
FROM ${UBI_IMAGE} AS perl-src

ARG PERL_VERSION

# hadolint ignore=DL3041
RUN microdnf install -y \
      gcc \
      make \
      tar \
      gzip \
      wget \
  && microdnf clean all

WORKDIR /tmp/perl-build

COPY artifacts/perl-${PERL_VERSION}.tar.gz ./
# hadolint ignore=DL3003
RUN tar -xzf "perl-${PERL_VERSION}.tar.gz" \
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
# Stage 2/4: base - Shared runtime foundation for dev and runtime
# ============================================================================
# Sole ancestor of both dev and runtime → guarantees identical runtime libraries
# in production and development. Contains ONLY runtime libraries (no build tools,
# no -devel packages).
FROM ${UBI_IMAGE} AS base

COPY --from=perl-src /opt/perl /opt/perl

# hadolint ignore=DL3041
RUN microdnf -y install \
      libaio \
      expat \
      libdb \
      libpq \
      mariadb-connector-c \
      gd \
      libpng \
      libjpeg-turbo \
      freetype \
      libxml2 \
      libxslt \
      openssl-libs \
      zlib \
      bzip2-libs \
      xz-libs \
  && microdnf clean all

# Oracle Instant Client (runtime libraries only, no SDK).
# unzip is installed transiently and removed in the same layer, so it never
# ships in the final image.
# hadolint ignore=DL3041
COPY artifacts/instantclient-basiclite*.zip /tmp/
RUN microdnf install -y unzip \
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
# Stage 3/4: dev - Development image (build tools + CPAN modules + app)
# ============================================================================
# Merges what used to be perl-buildbase + perl-modules + perl-dev.
# Installs modules once into /opt/cpan-modules; the runtime stage copies from
# this location so both images use bit-identical module builds.
FROM base AS dev

# hadolint ignore=DL3041
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
      libxml2-devel \
      libxslt-devel \
      expat-devel \
      freetype-devel \
      libpng-devel \
      libjpeg-turbo-devel \
      gd-devel \
      postgresql-devel \
      mariadb-connector-c-devel \
      openssl-devel \
      zlib-devel \
      bzip2-devel \
      xz-devel \
      subversion-devel \
  && microdnf clean all

# Oracle SDK headers (build-time only, required by DBD::Oracle).
COPY artifacts/instantclient-sdk*.zip /tmp/
RUN unzip -o -q /tmp/instantclient-sdk*.zip -d /opt/oracle-sdk-extract \
    && mv /opt/oracle-sdk-extract/instantclient_*/sdk /opt/oracle/instantclient/sdk \
    && rm -rf /opt/oracle-sdk-extract /tmp/instantclient-sdk*.zip

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
# Stage 4/4: runtime - Minimal production image
# ============================================================================
# Inherits from base (clean runtime lineage — no build tools).
# Copies installed modules from dev; no CPAN install runs here.
FROM base AS runtime

COPY --from=dev /opt/cpan-modules /opt/cpan-modules

ENV PERL5LIB="/opt/cpan-modules/lib/perl5:${PERL5LIB}"

WORKDIR /app
COPY app/ ./

# hadolint ignore=DL3041
RUN microdnf install -y shadow-utils \
    && useradd -m -u 1001 appuser \
    && chown -R appuser:appuser /app \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

USER appuser

CMD ["/opt/perl/bin/perl", "app.pl"]
