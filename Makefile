.PHONY: help status base dev-tools bundle update update-all dev runtime all run run-runtime fetch-artifacts mirror-artifacts check-artifacts test test-load-dev test-load-runtime test-full test-container-build clean sbom security-audit bundle-common bundle-component common-dev common-runtime publish-platform registry-login compose-up compose-down

# Multi-component: directory holding the shared common cpanfile(.snapshot).
COMMON_DIR ?= common

# Optional extra flags for `podman push` in `make publish-platform` — e.g.
# PODMAN_PUSH_FLAGS=--tls-verify=false for a throwaway local plain-HTTP
# registry (docs/multi-component.md's registry validation section).
PODMAN_PUSH_FLAGS ?=

# Optional: override the UBI base image to target a different RHEL/UBI version.
# Default is UBI9 (set in Containerfile). Example:
#   make bundle UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
UBI_IMAGE ?=

# Optional: override the image repository name. Default is "myapp". Threaded
# through every script the same way UBI_IMAGE already is. Example:
#   make all IMAGE_NAME=billing-service
IMAGE_NAME ?= myapp

# Optional corporate proxy for microdnf/cpanm/carton network access during the
# build. Usually already set as real env vars (in which case these ?= are a
# no-op) — declared here mainly so `make bundle https_proxy=http://...` works
# as a CLI override too, consistent with UBI_IMAGE/IMAGE_NAME above. See
# docs/proxy.md — scripts/*.sh also accept the uppercase HTTP_PROXY/
# HTTPS_PROXY/NO_PROXY form as a fallback; Make itself does not need to.
http_proxy ?=
https_proxy ?=
no_proxy ?=

# Exported so every recipe's shell sees these without repeating VAR="$(VAR)"
# on each line — also means a future target can't forget to thread one
# through and silently fall back to the default.
export UBI_IMAGE IMAGE_NAME http_proxy https_proxy no_proxy

# Perl version is defined once in the Containerfile; read it from there so the
# artifact check always matches what COPY will look for.
PERL_VERSION := $(shell sed -n 's/^ARG PERL_VERSION=//p' Containerfile)

# Default target - show help
help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

status: ## Check status of bundles and images
	@./scripts/status.sh

check-artifacts: ## Verify build artifacts exist (auto-runs fetch-artifacts if missing)
	@check() { \
	    m=""; \
	    [ -f "artifacts/perl-$(PERL_VERSION).tar.gz" ] || m="$$m artifacts/perl-$(PERL_VERSION).tar.gz"; \
	    [ -f artifacts/cpanm ] || m="$$m artifacts/cpanm"; \
	    [ -f artifacts/cpm ]   || m="$$m artifacts/cpm"; \
	    ls artifacts/instantclient-basiclite*.zip >/dev/null 2>&1 || m="$$m artifacts/instantclient-basiclite*.zip"; \
	    ls artifacts/instantclient-sdk*.zip      >/dev/null 2>&1 || m="$$m artifacts/instantclient-sdk*.zip"; \
	    echo "$$m"; \
	}; \
	m="$$(check)"; \
	if [ -n "$$m" ]; then \
	    echo "==> Missing build artifacts:"; \
	    for f in $$m; do echo "      $$f"; done; \
	    echo "==> Running 'make fetch-artifacts' to download them..."; \
	    $(MAKE) fetch-artifacts; \
	    m="$$(check)"; \
	    if [ -n "$$m" ]; then \
	        echo "==> ERROR: artifacts still missing after fetch-artifacts:"; \
	        for f in $$m; do echo "      $$f"; done; \
	        exit 1; \
	    fi; \
	fi

base: check-artifacts ## Build the shared base stage ($(IMAGE_NAME):base)
	@podman build --target base -t $(IMAGE_NAME):base \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

dev-tools: check-artifacts ## Build the dev-tools stage ($(IMAGE_NAME):dev-tools; shared by dev and Containerfile.deps)
	@podman build --target dev-tools -t $(IMAGE_NAME):dev-tools \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

bundle: check-artifacts ## Generate CPAN bundle from cpanfile.snapshot
	@./scripts/deps.sh bundle

update: check-artifacts ## Update one or more modules in cpanfile.snapshot (usage: make update MODULE=Name, or MODULE="Name1 Name2" for several)
	@if [ -z "$(MODULE)" ]; then \
	    echo "ERROR: MODULE=name required (e.g. make update MODULE=DBI, or MODULE=\"DBI Try::Tiny\" for several)"; exit 2; \
	fi
	@./scripts/deps.sh update --module $(MODULE)

update-all: check-artifacts ## Update all modules in cpanfile.snapshot to latest satisfying cpanfile
	@./scripts/deps.sh update --all

dev: check-artifacts ## Build the development image ($(IMAGE_NAME):dev)
	@./scripts/build-image.sh dev

runtime: check-artifacts ## Build the runtime image ($(IMAGE_NAME):runtime)
	@./scripts/build-image.sh runtime

all: bundle ## Generate bundle and build both dev and runtime images
	@./scripts/build-image.sh all

# ── Multi-component platform (design: docs/multi-component.md) ────────────────
bundle-common: check-artifacts ## Build the shared common BOM bundle into bundles/common/ (container path, like `make bundle`)
	@./scripts/deps.sh bundle-common

bundle-component: ## Resolve+gate+bundle one component against common into bundles/<name>/ (COMPONENT=components/<name>; needs carton)
	@if [ -z "$(COMPONENT)" ]; then \
	    echo "ERROR: COMPONENT=components/<name> required (e.g. make bundle-component COMPONENT=components/example)"; exit 2; \
	fi
	@./scripts/bundle-component.sh "$(COMMON_DIR)" "$(COMPONENT)"

common-dev: check-artifacts ## Build the common-dev platform image ($(IMAGE_NAME):common-dev; needs bundle-common first)
	@podman build --target common-dev -t $(IMAGE_NAME):common-dev \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

common-runtime: check-artifacts ## Build the common-runtime platform image ($(IMAGE_NAME):common-runtime)
	@podman build --target common-runtime -t $(IMAGE_NAME):common-runtime \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

registry-login: ## Authenticate podman against REGISTRY_HOST (e.g. a Nexus Docker registry) — needed before publish-platform or a build that pulls UBI_IMAGE through it
	@if [ -z "$(REGISTRY_HOST)" ] || [ -z "$(REGISTRY_USER)" ] || [ -z "$(REGISTRY_PASSWORD)" ]; then \
	    echo "ERROR: REGISTRY_HOST, REGISTRY_USER, and REGISTRY_PASSWORD all required" >&2; \
	    echo "  (e.g. make registry-login REGISTRY_HOST=nexus.example.org REGISTRY_USER=svc-ci REGISTRY_PASSWORD=...)" >&2; \
	    exit 2; \
	fi
	@echo "$(REGISTRY_PASSWORD)" | podman login "$(REGISTRY_HOST)" -u "$(REGISTRY_USER)" --password-stdin

publish-platform: ## Tag+push common-dev/common-runtime to REGISTRY (e.g. REGISTRY=localhost:5000/myapp) — needs common-dev/common-runtime built first; run `make registry-login` first if REGISTRY needs auth
	@if [ -z "$(REGISTRY)" ]; then \
	    echo "ERROR: REGISTRY=host[:port]/path required (e.g. make publish-platform REGISTRY=localhost:5000/myapp)"; exit 2; \
	fi
	@podman tag $(IMAGE_NAME):common-dev $(REGISTRY):common-dev
	@podman tag $(IMAGE_NAME):common-runtime $(REGISTRY):common-runtime
	@podman push $(PODMAN_PUSH_FLAGS) $(REGISTRY):common-dev
	@podman push $(PODMAN_PUSH_FLAGS) $(REGISTRY):common-runtime
	@echo "==> Published $(REGISTRY):common-dev and $(REGISTRY):common-runtime"

compose-up: ## Bundle both demo components and bring up the compose/Traefik routing demo (compose/README.md)
	@./scripts/bundle-component.sh common components/example
	@./scripts/bundle-component.sh common components/billing
	@cp "$$(readlink -f bundles/example/bundle-latest.tar.gz)" components/example/bundle-latest.tar.gz
	@cp "$$(readlink -f bundles/billing/bundle-latest.tar.gz)" components/billing/bundle-latest.tar.gz
	@cd compose && podman-compose up --build -d
	@echo "==> Up. Try: curl localhost:8080/example/  curl localhost:8080/billing/"

compose-down: ## Tear down the compose/Traefik routing demo
	@cd compose && podman-compose down

run: ## Run the app in the dev image (podman run --rm $(IMAGE_NAME):dev)
	@podman run --rm $(IMAGE_NAME):dev

run-runtime: ## Run the app in the runtime image (podman run --rm $(IMAGE_NAME):runtime)
	@podman run --rm $(IMAGE_NAME):runtime

test: ## Fast unit tests: run the bats suite (no containers/Oracle/internet, ~10s)
	@if command -v bats >/dev/null 2>&1; then \
	    bats tests/bats/; \
	else \
	    echo "ERROR: bats not installed. Install bats-core:"; \
	    echo "  git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core && sudo /tmp/bats-core/install.sh /usr/local"; \
	    echo "  (see tests/README.md)"; \
	    exit 1; \
	fi

test-load-dev: ## Quick test: verify all Perl libraries can be loaded in dev image
	@./scripts/test-load-modules.sh dev

test-load-runtime: ## Quick test: verify all Perl libraries can be loaded in runtime image
	@./scripts/test-load-modules.sh runtime

test-full: ## Run full CPAN test suites in dev image (use MODULE=name)
	@./scripts/test-run-suites.sh $(MODULE)

fetch-artifacts: ## Download perl source, cpanm, cpm, and Oracle Instant Client into artifacts/
	@./scripts/fetch-artifacts.sh

mirror-artifacts: ## Fetch real artifacts from the internet and upload them into Nexus (needs NEXUS_URL/NEXUS_USER/NEXUS_PASSWORD)
	@./scripts/fetch-artifacts.sh --mirror

test-container-build: ## Full end-to-end build + lifecycle test with curated ~11-module cpanfile
	@set -e; \
	WORKDIR="$$(bash tests/container-build/setup.sh)"; \
	cleanup() { \
	    status=$$?; \
	    podman rmi -f $(IMAGE_NAME):base $(IMAGE_NAME):dev-tools $(IMAGE_NAME):carton-runner $(IMAGE_NAME):dev $(IMAGE_NAME):runtime >/dev/null 2>&1 || true; \
	    if [ "$$status" -eq 0 ]; then \
	        rm -rf "$$WORKDIR"; \
	    else \
	        echo "==> FAILED — workspace preserved for debugging: $$WORKDIR"; \
	    fi; \
	}; \
	trap cleanup EXIT; \
	echo "==> container-build workspace: $$WORKDIR"; \
	echo ""; \
	echo "==> Phase 1: Initial bundle + image build from committed snapshot"; \
	cd "$$WORKDIR" && $(MAKE) bundle; \
	cd "$$WORKDIR" && $(MAKE) all; \
	cd "$$WORKDIR" && $(MAKE) test-load-dev; \
	cd "$$WORKDIR" && $(MAKE) test-load-runtime; \
	echo ""; \
	echo "==> Phase 2: Verify baseline pinned versions (Try::Tiny should be 0.30)"; \
	podman run --rm -v "$$WORKDIR/test-load.pl:/tmp/test-load.pl:ro" $(IMAGE_NAME):dev \
	    /opt/perl/bin/perl /tmp/test-load.pl --expect-try-tiny-max=0.30; \
	echo ""; \
	echo "==> Phase 3: Snapshot pathnames before update"; \
	grep -E "^  [A-Za-z]" "$$WORKDIR/cpanfile.snapshot" | sort > "$$WORKDIR/pathnames-before.txt"; \
	echo "   captured $$(wc -l < "$$WORKDIR/pathnames-before.txt") distribution pins"; \
	echo ""; \
	echo "==> Phase 4: Update Try::Tiny (real carton update in carton-runner container)"; \
	cd "$$WORKDIR" && $(MAKE) update MODULE=Try::Tiny; \
	echo ""; \
	echo "==> Phase 5: Assert scoped update — only Try-Tiny pathname changed"; \
	grep -E "^  [A-Za-z]" "$$WORKDIR/cpanfile.snapshot" | sort > "$$WORKDIR/pathnames-after.txt"; \
	diff "$$WORKDIR/pathnames-before.txt" "$$WORKDIR/pathnames-after.txt" > "$$WORKDIR/pathnames-diff.txt" || true; \
	if ! grep -q "Try-Tiny" "$$WORKDIR/pathnames-diff.txt"; then \
	    echo "FAIL: Try-Tiny did not change in snapshot after 'carton update Try::Tiny'"; \
	    cat "$$WORKDIR/pathnames-diff.txt"; exit 1; \
	fi; \
	other_changes=$$(grep -v "Try-Tiny" "$$WORKDIR/pathnames-diff.txt" | grep -E "^[<>]" || true); \
	if [ -n "$$other_changes" ]; then \
	    echo "FAIL: carton update Try::Tiny changed distributions other than Try-Tiny:"; \
	    echo "$$other_changes"; exit 1; \
	fi; \
	echo "   OK: only Try-Tiny changed, all other pins intact"; \
	echo ""; \
	echo "==> Phase 6: Rebuild bundle + images from updated snapshot"; \
	rm -f "$$WORKDIR/bundles/bundle-latest.tar.gz" "$$WORKDIR"/bundles/bundle-*.tar.gz; \
	podman rmi -f $(IMAGE_NAME):carton-runner $(IMAGE_NAME):dev $(IMAGE_NAME):runtime 2>/dev/null || true; \
	cd "$$WORKDIR" && $(MAKE) bundle; \
	cd "$$WORKDIR" && $(MAKE) all; \
	echo ""; \
	echo "==> Phase 7: Verify upgraded modules load and Try::Tiny > 0.30"; \
	cd "$$WORKDIR" && $(MAKE) test-load-dev; \
	cd "$$WORKDIR" && $(MAKE) test-load-runtime; \
	podman run --rm -v "$$WORKDIR/test-load.pl:/tmp/test-load.pl:ro" $(IMAGE_NAME):dev \
	    /opt/perl/bin/perl /tmp/test-load.pl --expect-try-tiny-min=0.31; \
	echo ""; \
	echo "==> ALL PHASES PASSED"

clean: ## Remove images (bundles are preserved)
	@echo "==> Cleaning up images..."
	@podman rmi -f $(IMAGE_NAME):base $(IMAGE_NAME):dev-tools $(IMAGE_NAME):carton-runner $(IMAGE_NAME):dev $(IMAGE_NAME):runtime 2>/dev/null || true
	@echo "==> Clean complete (bundles preserved)"

sbom: ## Generate a CycloneDX SBOM (OS packages via syft + CPAN modules) — needs make runtime first
	@./scripts/generate-sbom.sh

security-audit: ## Check pinned CPAN/Perl-core modules against known CVE advisories
	@./scripts/security-audit.sh
