# Locus developer task runner.
#
# Thin wrappers over scripts/ and the underlying toolchains (xcodebuild, cargo);
# the real logic lives in scripts/ so there is a single source of truth.
# Run `make` (or `make help`) to list targets.

PROJECT := apps/mac/Locus/Locus.xcodeproj
SCHEME  := Locus
DEST    := platform=macOS,arch=arm64

.DEFAULT_GOAL := help

.PHONY: help run run-release build build-release test unit perf core-test core-lint clean

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

run: ## Build (Debug) and launch the app
	scripts/mac/run-app.sh --debug

run-release: ## Build (Release) and launch the app — use this to judge speed/feel
	scripts/mac/run-app.sh --release

build: ## Build (Debug) without launching
	scripts/mac/run-app.sh --debug --no-open

build-release: ## Build (Release) without launching
	scripts/mac/run-app.sh --release --no-open

test: ## Run the full macOS test suite (unit + UI)
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

unit: ## Run only the unit tests (fast)
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -only-testing:LocusTests

perf: ## Run the speed/size smoke budgets
	scripts/perf-smoke.sh

core-test: ## Run the Rust core tests
	cd core && cargo test

core-lint: ## Check Rust formatting and clippy (warnings as errors)
	cd core && cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings

clean: ## Remove the Xcode build products
	rm -rf .build/xcode-derived
