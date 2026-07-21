.PHONY: help status base dev-tools bundle update update-all dev runtime all fetch-artifacts check-artifacts test-load-dev test-load-runtime test-full test-container-build clean

# Optional: override the UBI base image to target a different RHEL/UBI version.
# Default is UBI9 (set in Containerfile). Example:
#   make bundle UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
UBI_IMAGE ?=

# Perl version is defined once in the Containerfile; read it from there so the
# artifact check always matches what COPY will look for.
PERL_VERSION := $(shell sed -n 's/^ARG PERL_VERSION=//p' Containerfile)

# Default target - show help
help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
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

base: check-artifacts ## Build the shared base stage (myapp:base)
	@UBI_IMAGE="$(UBI_IMAGE)" podman build --target base -t myapp:base \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

dev-tools: check-artifacts ## Build the dev-tools stage (myapp:dev-tools; shared by dev and Containerfile.deps)
	@UBI_IMAGE="$(UBI_IMAGE)" podman build --target dev-tools -t myapp:dev-tools \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

bundle: check-artifacts ## Generate CPAN bundle from cpanfile.snapshot
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh bundle

update: check-artifacts ## Update one module in cpanfile.snapshot (usage: make update MODULE=Name)
	@if [ -z "$(MODULE)" ]; then \
	    echo "ERROR: MODULE=name required (e.g. make update MODULE=DBI)"; exit 2; \
	fi
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh update --module $(MODULE)

update-all: check-artifacts ## Update all modules in cpanfile.snapshot to latest satisfying cpanfile
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh update --all

dev: check-artifacts ## Build the development image (myapp:dev)
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh dev

runtime: check-artifacts ## Build the runtime image (myapp:runtime)
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh runtime

all: bundle ## Generate bundle and build both dev and runtime images
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh all

test-load-dev: ## Quick test: verify all Perl libraries can be loaded in dev image
	@./scripts/test-load-modules.sh dev

test-load-runtime: ## Quick test: verify all Perl libraries can be loaded in runtime image
	@./scripts/test-load-modules.sh runtime

test-full: ## Run full CPAN test suites in dev image (use MODULE=name)
	@ ./scripts/test-run-suites.sh $(MODULE)

fetch-artifacts: ## Download perl source, cpanm, cpm, and Oracle Instant Client into artifacts/
	@./scripts/fetch-artifacts.sh

test-container-build: ## Full end-to-end build + lifecycle test with curated ~11-module cpanfile
	@set -e; \
	WORKDIR="$$(bash tests/container-build/setup.sh)"; \
	echo "==> container-build workspace: $$WORKDIR"; \
	echo ""; \
	echo "==> Phase 1: Initial bundle + image build from committed snapshot"; \
	cd "$$WORKDIR" && UBI_IMAGE="$(UBI_IMAGE)" $(MAKE) bundle; \
	cd "$$WORKDIR" && UBI_IMAGE="$(UBI_IMAGE)" $(MAKE) all; \
	cd "$$WORKDIR" && $(MAKE) test-load-dev; \
	cd "$$WORKDIR" && $(MAKE) test-load-runtime; \
	echo ""; \
	echo "==> Phase 2: Verify baseline pinned versions (Try::Tiny should be 0.30)"; \
	podman run --rm -v "$$WORKDIR/test-load.pl:/tmp/test-load.pl:ro" myapp:dev \
	    /opt/perl/bin/perl /tmp/test-load.pl --expect-try-tiny-max=0.30; \
	echo ""; \
	echo "==> Phase 3: Snapshot pathnames before update"; \
	grep -E "^  [A-Za-z]" "$$WORKDIR/cpanfile.snapshot" | sort > /tmp/pathnames-before.txt; \
	echo "   captured $$(wc -l < /tmp/pathnames-before.txt) distribution pins"; \
	echo ""; \
	echo "==> Phase 4: Update Try::Tiny (real carton update in carton-runner container)"; \
	cd "$$WORKDIR" && UBI_IMAGE="$(UBI_IMAGE)" $(MAKE) update MODULE=Try::Tiny; \
	echo ""; \
	echo "==> Phase 5: Assert scoped update — only Try-Tiny pathname changed"; \
	grep -E "^  [A-Za-z]" "$$WORKDIR/cpanfile.snapshot" | sort > /tmp/pathnames-after.txt; \
	diff /tmp/pathnames-before.txt /tmp/pathnames-after.txt > /tmp/pathnames-diff.txt || true; \
	if ! grep -q "Try-Tiny" /tmp/pathnames-diff.txt; then \
	    echo "FAIL: Try-Tiny did not change in snapshot after 'carton update Try::Tiny'"; \
	    cat /tmp/pathnames-diff.txt; exit 1; \
	fi; \
	other_changes=$$(grep -v "Try-Tiny" /tmp/pathnames-diff.txt | grep -E "^[<>]" || true); \
	if [ -n "$$other_changes" ]; then \
	    echo "FAIL: carton update Try::Tiny changed distributions other than Try-Tiny:"; \
	    echo "$$other_changes"; exit 1; \
	fi; \
	echo "   OK: only Try-Tiny changed, all other pins intact"; \
	echo ""; \
	echo "==> Phase 6: Rebuild bundle + images from updated snapshot"; \
	rm -f "$$WORKDIR/bundles/bundle-latest.tar.gz" "$$WORKDIR"/bundles/bundle-*.tar.gz; \
	podman rmi -f myapp:carton-runner myapp:dev myapp:runtime 2>/dev/null || true; \
	cd "$$WORKDIR" && UBI_IMAGE="$(UBI_IMAGE)" $(MAKE) bundle; \
	cd "$$WORKDIR" && UBI_IMAGE="$(UBI_IMAGE)" $(MAKE) all; \
	echo ""; \
	echo "==> Phase 7: Verify upgraded modules load and Try::Tiny > 0.30"; \
	cd "$$WORKDIR" && $(MAKE) test-load-dev; \
	cd "$$WORKDIR" && $(MAKE) test-load-runtime; \
	podman run --rm -v "$$WORKDIR/test-load.pl:/tmp/test-load.pl:ro" myapp:dev \
	    /opt/perl/bin/perl /tmp/test-load.pl --expect-try-tiny-min=0.31; \
	echo ""; \
	echo "==> ALL PHASES PASSED"

clean: ## Remove images (bundles are preserved)
	@echo "==> Cleaning up images..."
	@podman rmi -f myapp:base myapp:dev-tools myapp:carton-runner myapp:dev myapp:runtime 2>/dev/null || true
	@echo "==> Clean complete (bundles preserved)"