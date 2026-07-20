.PHONY: help status base bundle update update-all dev runtime all test-load-dev test-load-runtime test-full clean

# Optional: override the UBI base image to target a different RHEL/UBI version.
# Default is UBI9 (set in Containerfile). Example:
#   make bundle UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
UBI_IMAGE ?=

# Default target - show help
help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

status: ## Check status of bundles and images
	@./scripts/status.sh

base: ## Build the shared base stage (myapp:base)
	@UBI_IMAGE="$(UBI_IMAGE)" podman build --target base -t myapp:base \
	    $(if $(UBI_IMAGE),--build-arg UBI_IMAGE=$(UBI_IMAGE),) \
	    -f Containerfile .

bundle: ## Generate CPAN bundle from cpanfile.snapshot
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh bundle

update: ## Update one module in cpanfile.snapshot (usage: make update MODULE=Name)
	@if [ -z "$(MODULE)" ]; then \
	    echo "ERROR: MODULE=name required (e.g. make update MODULE=DBI)"; exit 2; \
	fi
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh update --module $(MODULE)

update-all: ## Update all modules in cpanfile.snapshot to latest satisfying cpanfile
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/deps.sh update --all

dev: ## Build the development image (myapp:dev)
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh dev

runtime: ## Build the runtime image (myapp:runtime)
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh runtime

all: bundle ## Generate bundle and build both dev and runtime images
	@UBI_IMAGE="$(UBI_IMAGE)" ./scripts/build-image.sh all

test-load-dev: ## Quick test: verify all Perl libraries can be loaded in dev image
	@./scripts/test-load-modules.sh dev

test-load-runtime: ## Quick test: verify all Perl libraries can be loaded in runtime image
	@./scripts/test-load-modules.sh runtime

test-full: ## Run full CPAN test suites in dev image (use MODULE=name)
	@ ./scripts/test-run-suites.sh $(MODULE)

clean: ## Remove images (bundles are preserved)
	@echo "==> Cleaning up images..."
	@podman rmi -f myapp:base myapp:carton-runner myapp:dev myapp:runtime 2>/dev/null || true
	@echo "==> Clean complete (bundles preserved)"
