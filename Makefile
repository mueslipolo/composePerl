.PHONY: help status bundle dev runtime all test-dev test-runtime clean

# Default target - show help
help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

status: ## Check status of bundles and images
	@./scripts/check-status.sh

bundle: ## Generate CPAN bundle from cpanfile.snapshot
	@./scripts/manage-perl-deps.sh bundle

dev: ## Build the development image (myapp:dev)
	@./scripts/build-images.sh dev

runtime: ## Build the runtime image (myapp:runtime)
	@./scripts/build-images.sh runtime

all: bundle ## Generate bundle and build both dev and runtime images
	@./scripts/build-images.sh all

test-dev: ## Test Perl libraries in the dev image
	@./scripts/test-image.sh dev

test-runtime: ## Test Perl libraries in the runtime image
	@./scripts/test-image.sh runtime

clean: ## Remove images (bundles are preserved)
	@echo "==> Cleaning up images..."
	@podman rmi -f myapp:carton-runner myapp:dev myapp:runtime 2>/dev/null || true
	@echo "==> Clean complete (bundles preserved)"
