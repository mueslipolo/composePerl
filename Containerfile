# Multi-stage Containerfile for Perl application with Carton dependency management
# Stage workflow: perl-src → perl-buildbase → carton-runner → perl-dev → runtime

# Build argument for Perl version
ARG PERL_VERSION=5.28.1

# ============================================================================
# Stage 1: perl-src - Compile Perl from source
# ============================================================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS perl-src

ARG PERL_VERSION

# Install build dependencies
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
RUN tar -xzf perl-${PERL_VERSION}.tar.gz \
    && cd "perl-${PERL_VERSION}" \
    && ./Configure -des \
        -Dprefix=/opt/perl \
        -Dusethreads \
        -Duseshrplib \
    && make -j$(nproc) \
    && make install \
    && cd / \
    && rm -rf /tmp/perl-build

# ============================================================================
# Stage 2: perl-buildbase - Base image with Perl and build dependencies
# ============================================================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS perl-buildbase

# Copy compiled Perl from previous stage
COPY --from=perl-src /opt/perl /opt/perl

# Install all build dependencies for XS/CPAN modules
RUN microdnf -y install \
      gcc make perl-core perl-devel \
      which util-linux findutils \
      tar gzip unzip patch \
      libxml2-devel libxslt-devel expat-devel libaio \
      freetype-devel libpng-devel libjpeg-turbo-devel gd-devel \
      postgresql-devel mariadb-connector-c-devel \
      openssl-devel zlib-devel bzip2-devel xz-devel \
      subversion-devel \
  && microdnf clean all

# Set Perl environment
ENV PATH="/opt/perl/bin:${PATH}" \
    PERL5LIB="/opt/perl/lib/perl5" \
    PERL_LOCAL_LIB_ROOT="" \
    PERL_MB_OPT="" \
    PERL_MM_OPT=""

# Copy Oracle Instant Client artifacts
COPY artifacts/instantclient-basic*.zip /tmp
COPY artifacts/instantclient-sdk*.zip /tmp

WORKDIR /opt/oracle
RUN unzip -o /tmp/instantclient-basic*.zip && \
    unzip -o /tmp/instantclient-sdk*.zip && \
    mv instantclient_* instantclient && \
    rm -rf /tmp/*
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
ENV ORACLE_HOME=/opt/oracle/instantclient

# ============================================================================
# Stage 3: carton-runner - Generate CPAN bundle with Carton
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
# Stage 4: perl-dev - Development image with offline dependency installation
# ============================================================================
FROM perl-buildbase AS perl-dev

WORKDIR /app

# Copy cpm & cpanm fatpacked from artifacts
COPY artifacts/cpm /opt/perl/bin/cpm
#COPY artifacts/cpanm /opt/perl/bin/cpanm

# Copy dependency files
COPY cpanfile cpanfile.snapshot ./

# Copy the bundle artifact (this will be built context in actual builds)
COPY bundles/bundle-latest.tar.gz /build/cpan-bundle.tar.gz

# Extract bundle and install dependencies with cpm (offline)
RUN cd /build \
    && tar xzf cpan-bundle.tar.gz \
    && rm cpanfile.snapshot \
    && cpm install -g --resolver "02packages,file://$PWD/vendor/cache" \
    #&& cpanm --from "$PWD/vendor/cache" --installdeps --notest --quiet . \
    && rm -rf /build ~/.perl-cpm

# Copy application code
COPY app/ ./

# Default command
CMD ["/opt/perl/bin/perl", "app.pl"]

# ============================================================================
# Stage 5: runtime - Minimal runtime image
# ============================================================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS runtime

# Copy Perl+libs and Oracle libraries
COPY --from=perl-dev /opt/perl /opt/perl
COPY --from=perl-buildbase /opt/oracle /opt/oracle

# Install system dependencies
RUN microdnf -y install \
    libaio \
    expat \
    libpq \
    libdb \
    mariadb-connector-c \
    gd libpng libjpeg-turbo freetype \
    && microdnf clean all

# Set Perl environment
ENV PATH="/opt/perl/bin:${PATH}" \
    PERL5LIB="/opt/perl/lib/perl5"

# Set up application directory
WORKDIR /app

# Copy application code
COPY app/ ./

# Run as non-root user
RUN microdnf install -y shadow-utils \
    && useradd -m -u 1001 appuser \
    && chown -R appuser:appuser /app \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

USER appuser

# Default command
CMD ["/opt/perl/bin/perl", "app.pl"]
