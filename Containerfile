# Multi-stage Containerfile for Perl application with Carton dependency management
# Stage workflow: perl-src → system-libs → perl-buildbase → carton-runner → perl-dev → runtime
#
# Key design:
# - system-libs: Shared base layer with Perl + runtime libraries (used by both dev & runtime)
# - perl-buildbase: Adds build tools on top of system-libs (for building modules)
# - runtime: Uses system-libs directly (guaranteed identical runtime libs as dev)

# Build argument for Perl version
ARG PERL_VERSION=5.28.1

# ============================================================================
# Stage 1: perl-src - Compile Perl from source
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
# Stage 2: system-libs - Common base with Perl and runtime libraries
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

# Set Perl environment
ENV PATH="/opt/perl/bin:${PATH}" \
    PERL5LIB="/opt/perl/lib/perl5" \
    PERL_LOCAL_LIB_ROOT="" \
    PERL_MB_OPT="" \
    PERL_MM_OPT=""

# Install Oracle Instant Client (basic runtime libraries only)
COPY artifacts/instantclient-basic*.zip /tmp/
WORKDIR /opt/oracle
# hadolint ignore=DL3041
RUN microdnf install -y unzip \
    && unzip -o /tmp/instantclient-basic*.zip \
    && mv instantclient_* instantclient \
    && rm -rf /tmp/* \
    && microdnf remove -y unzip \
    && microdnf clean all

ENV LD_LIBRARY_PATH=/opt/oracle/instantclient \
    ORACLE_HOME=/opt/oracle/instantclient

# ============================================================================
# Stage 3: perl-buildbase - Build environment (system-libs + build tools)
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

# Install Oracle SDK (development headers for DBD::Oracle)
COPY artifacts/instantclient-sdk*.zip /tmp/
WORKDIR /opt/oracle
RUN unzip -o /tmp/instantclient-sdk*.zip \
    && cp -r instantclient_*/sdk instantclient/ \
    && rm -rf instantclient_* /tmp/*

# ============================================================================
# Stage 4: carton-runner - Generate CPAN bundle with Carton
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
# Stage 5: perl-dev - Development image with offline dependency installation
# ============================================================================
FROM perl-buildbase AS perl-dev

WORKDIR /app

# Copy cpm & cpanm fatpacked from artifacts
COPY artifacts/cpm /opt/perl/bin/cpm

# Copy dependency files
COPY cpanfile cpanfile.snapshot ./

# Copy the bundle artifact (this will be built context in actual builds)
COPY bundles/bundle-latest.tar.gz /build/cpan-bundle.tar.gz

# Extract bundle and install dependencies with cpm (offline)
# hadolint ignore=DL3003
RUN cd /build \
    && tar xzf cpan-bundle.tar.gz \
    && rm cpanfile.snapshot \
    && cpm install -g --resolver "02packages,file://$PWD/vendor/cache" \
    && rm -rf /build ~/.perl-cpm

# Copy application code
COPY app/ ./

# Default command
CMD ["/opt/perl/bin/perl", "app.pl"]

# ============================================================================
# Stage 6: runtime - Minimal runtime image
# ============================================================================
# Inherits from system-libs (same base as dev), ensuring identical runtime libs.
# Only adds: installed Perl modules from dev + application code + non-root user.
FROM system-libs AS runtime

# Copy installed Perl modules from perl-dev
# Note: We copy from perl-dev (which has all CPAN modules installed)
# but the base layer (system-libs) already has Perl and Oracle
COPY --from=perl-dev /opt/perl/lib /opt/perl/lib

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
