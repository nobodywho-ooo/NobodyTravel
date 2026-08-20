default: help

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#' Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: install
install: # Install dependencies with uv.
	uv sync

.PHONY: format
format: # Format the codebase with ruff.
	uv lock --check
	uv run ruff check . --fix --unsafe-fixes
	uv run ruff format .

.PHONY: check
check: # Run linting, type checks, and dependency checks.
	uv lock --check
	uv run ruff format --check .
	uv run ruff check .
	uv run ty check
	uv run deptry .

.PHONY: lint
lint: check

.PHONY: clean
clean: # Clean up temporary files.
	@rm -rf .pytest_cache
	@rm -rf **/.pytest_cache
	@rm -rf __pycache__
	@rm -rf **/__pycache__
	@rm -rf build
	@rm -rf dist
