# Multi-stage Containerfile for Perl application with Carton dependency management
#
# 9-stage build: perl-src → oracle-client → oracle-sdk → system-libs → perl-buildbase → carton-runner → perl-modules → perl-dev → runtime
# See README.md for detailed architecture documentation and Mermaid diagrams

# Build argument for Perl version
ARG PERL_VERSION=5.28.1

# ============================================================================
# Stage 1/9: perl-src - Compile Perl from source
# ============================================================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS perl-src

ARG PERL_VERSION

# Install build dependencies
# hadolint ignore=DL3041
RUN microdnf install -y \
    gcc \
    make \
    tar \
    gzip \
    wget \
    && microdnf clean all

# Download and compile Perl
WORKDIR /tmp/perl-build

# Copy and extract Perl source
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
# Stage 2/9: oracle-client - Unpack Oracle Instant Client (runtime only)
# ============================================================================
# Using BusyBox for minimal footprint (~1.5MB) - only extracted files are copied out
FROM docker.io/library/busybox:uclibc AS oracle-client

WORKDIR /opt/oracle

# Copy and unzip ONLY basiclite (runtime libraries)
# SDK is extracted in separate oracle-sdk stage
COPY artifacts/instantclient-basiclite*.zip /tmp/

RUN unzip -o -q /tmp/instantclient-basiclite*.zip \
 && mv instantclient_* instantclient \
 && rm -rf /tmp/*

# ============================================================================
# Stage 3/9: oracle-sdk - Unpack Oracle Instant Client SDK (build-time only)
# ============================================================================
# Using BusyBox for minimal footprint - extracts SDK without polluting build layers
FROM docker.io/library/busybox:uclibc AS oracle-sdk

WORKDIR /opt/oracle

# Extract SDK to get development headers for DBD::Oracle
COPY artifacts/instantclient-sdk*.zip /tmp/

RUN unzip -o -q /tmp/instantclient-sdk*.zip \
 && mv instantclient_*/sdk instantclient-sdk \
 && rm -rf /tmp/*

# ============================================================================
# Stage 4/9: system-libs - Common base with Perl and runtime libraries
# ============================================================================
# This stage is the shared foundation for both dev and runtime images.
# Contains ONLY runtime libraries (no build tools, no -devel packages).
# Ensures dev and runtime have identical runtime dependencies.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS system-libs

# Copy compiled Perl from previous stage
COPY --from=perl-src /opt/perl /opt/perl

# Install RUNTIME libraries only (no -devel packages, no build tools)
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

# Oracle instantclient
COPY --from=oracle-client /opt/oracle/instantclient /opt/oracle/instantclient

# Dont need Java/C++ libs
RUN rm -rf /opt/oracle/instantclient/*.jar \
           /opt/oracle/instantclient/libocci.so

# Set Perl environment
ENV PATH="/opt/perl/bin:${PATH}" \
    PERL5LIB="/opt/perl/lib/perl5" \
    PERL_LOCAL_LIB_ROOT="" \
    PERL_MB_OPT="" \
    PERL_MM_OPT=""


ENV LD_LIBRARY_PATH=/opt/oracle/instantclient \
    ORACLE_HOME=/opt/oracle/instantclient

# ============================================================================
# Stage 5/9: perl-buildbase - Build environment (system-libs + build tools)
# ============================================================================
# Inherits runtime libs from system-libs and adds build tools on top.
# Used for: compiling XS modules, running CPAN tests, building bundles.
FROM system-libs AS perl-buildbase

# Install BUILD tools and development headers
# hadolint ignore=DL3041
RUN microdnf -y install \
      # Core build tools
      gcc \
      make \
      perl-core \
      perl-devel \
      # Utilities
      which \
      util-linux \
      findutils \
      tar \
      gzip \
      unzip \
      patch \
      # Development headers (matching runtime libs from system-libs)
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

# Copy Oracle SDK from extraction stage (no zip files in this layer!)
COPY --from=oracle-sdk /opt/oracle/instantclient-sdk /opt/oracle/instantclient/sdk

# ============================================================================
# Stage 6/9: carton-runner - Generate CPAN bundle with Carton
# ============================================================================
FROM perl-buildbase AS carton-runner

# Copy cpanm fatpack from artifacts
COPY artifacts/cpanm /opt/perl/bin/cpanm

# Install Carton
RUN /opt/perl/bin/cpanm --notest Carton

# Set up working directory
WORKDIR /build

# Copy dependency files
COPY cpanfile cpanfile.snapshot ./

# Run Carton to install dependencies and create mirror
RUN /opt/perl/bin/carton install --deployment \
    && /opt/perl/bin/carton bundle \
    && tar czf cpan-bundle.tar.gz ./vendor cpanfile cpanfile.snapshot

# ============================================================================
# Stage 7/9: perl-modules - Install Perl modules (shared between dev & runtime)
# ============================================================================
# This stage installs all CPAN modules once, providing a clean source for both
# perl-dev and runtime to copy from. This ensures DRY and layer optimization.
FROM perl-buildbase AS perl-modules

WORKDIR /opt/perl-install

# Copy cpm fatpack from artifacts
COPY artifacts/cpm /opt/perl/bin/cpm

# Copy dependency files
COPY cpanfile cpanfile.snapshot ./

# Copy the bundle artifact
COPY bundles/bundle-latest.tar.gz ./cpan-bundle.tar.gz

# Extract bundle and install dependencies with cpm (offline)
# Install to dedicated location /opt/cpan-modules for explicit, predictable copying
# hadolint ignore=DL3003
RUN tar xzf cpan-bundle.tar.gz \
    && rm cpanfile.snapshot \
    && cpm install -L /opt/cpan-modules --resolver "02packages,file://$PWD/vendor/cache" \
    && rm -rf /opt/perl-install ~/.perl-cpm

# Result: Clean /opt/cpan-modules/lib/perl5 ready to be copied to dev and runtime

# ============================================================================
# Stage 8/9: perl-dev - Development image
# ============================================================================
# Development image with build tools + installed modules from perl-modules stage
FROM perl-buildbase AS perl-dev

# Copy CPAN modules to separate location (don't merge with core Perl)
COPY --from=perl-modules /opt/cpan-modules /opt/cpan-modules

# Add CPAN modules to PERL5LIB (prepend to search before system paths)
ENV PERL5LIB="/opt/cpan-modules/lib/perl5:${PERL5LIB}"

# Copy cpanm for running test suites
COPY artifacts/cpanm /opt/perl/bin/cpanm

WORKDIR /app

# Copy dependency files (for reference)
COPY cpanfile cpanfile.snapshot ./

# Copy application code
COPY app/ ./

# Default command
CMD ["/opt/perl/bin/perl", "app.pl"]

# ============================================================================
# Stage 9/9: runtime - Minimal runtime image
# ============================================================================
# Inherits from system-libs (clean runtime base), ensuring identical runtime libs.
# Copies installed modules from perl-modules (not perl-dev) for optimal layer efficiency.
FROM system-libs AS runtime

# Copy CPAN modules to separate location (don't merge with core Perl)
COPY --from=perl-modules /opt/cpan-modules /opt/cpan-modules

# Add CPAN modules to PERL5LIB (prepend to search before system paths)
ENV PERL5LIB="/opt/cpan-modules/lib/perl5:${PERL5LIB}"

# Set up application directory
WORKDIR /app

# Copy application code
COPY app/ ./

# Run as non-root user
# hadolint ignore=DL3041
RUN microdnf install -y shadow-utils \
    && useradd -m -u 1001 appuser \
    && chown -R appuser:appuser /app \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

USER appuser

# Default command
CMD ["/opt/perl/bin/perl", "app.pl"]
