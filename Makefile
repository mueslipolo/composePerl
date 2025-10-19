.PHONY: help status bundle dev runtime all test-load-dev test-load-runtime test-full clean

# Default target - show help
help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

status: ## Check status of bundles and images
	@./scripts/status.sh

bundle: ## Generate CPAN bundle from cpanfile.snapshot
	@./scripts/bundle-create.sh bundle

dev: ## Build the development image (myapp:dev)
	@./scripts/build-image.sh dev

runtime: ## Build the runtime image (myapp:runtime)
	@./scripts/build-image.sh runtime

all: bundle ## Generate bundle and build both dev and runtime images
	@./scripts/build-image.sh all

test-load-dev: ## Quick test: verify all Perl libraries can be loaded in dev image
	@./scripts/test-load-modules.sh dev

test-load-runtime: ## Quick test: verify all Perl libraries can be loaded in runtime image
	@./scripts/test-load-modules.sh runtime

test-full: ## Run full CPAN test suites in dev image (use MODULE=name to test single module)
	@./scripts/test-run-suites.sh $(MODULE)

clean: ## Remove images (bundles are preserved)
	@echo "==> Cleaning up images..."
	@podman rmi -f myapp:carton-runner myapp:dev myapp:runtime 2>/dev/null || true
	@echo "==> Clean complete (bundles preserved)"
