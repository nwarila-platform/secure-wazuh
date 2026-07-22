# =============================================================================
# Makefile — Developer Convenience Targets
# =============================================================================
#   make install         Install dev dependencies + git hooks
#   make lint            yamllint + ansible-lint
#   make tf-fmt          terraform fmt check on the tfvars (best-effort)
#   make allowlist-check Fail if a deliverable file is not allowlisted in .gitignore
#   make docs-layout     Check Diátaxis quadrant + ADR placement for docs/*.md
#   make pre-commit      Run the full pre-commit suite
#   make ci              What CI runs: lint + tf-fmt + allowlist-check + docs-layout
#   make clean           Remove Python/Ansible cache artifacts
# =============================================================================

.DEFAULT_GOAL := help
.PHONY: help install lint yamllint ansible-lint tf-fmt allowlist-check docs-layout pre-commit ci clean

# Deliverable trees the allowlist guard patrols, and the intentionally-ignored
# paths within them (state, caches, the framework-owned role composed in at runtime).
DELIVERABLE_DIRS := ansible terraform docs .github
GUARD_EXCLUDE    := (/\.terraform/|\.tfstate|__pycache__|\.retry$$|/linux_disk_manager/|/wazuh_agent/)

help:
	@echo ""
	@echo "  make install         Install dev deps (requirements-dev.txt) + pre-commit hooks"
	@echo "  make lint            yamllint + ansible-lint"
	@echo "  make tf-fmt          terraform fmt check on tfvars (best-effort)"
	@echo "  make allowlist-check Fail if a deliverable file is not allowlisted in .gitignore"
	@echo "  make docs-layout     Check Diátaxis quadrant + ADR placement for docs/*.md"
	@echo "  make pre-commit      Run the full pre-commit suite against all files"
	@echo "  make ci              Aggregate gate CI runs: lint + tf-fmt + allowlist-check + docs-layout"
	@echo "  make clean           Remove Python/Ansible cache artifacts"
	@echo ""

install:
	pip install -r requirements-dev.txt
	pre-commit install
	pre-commit install --hook-type commit-msg

lint: yamllint ansible-lint

# Lint only tracked YAML (the deliverable) — never the git-ignored provider
# cache, dev lab, or compose output.
yamllint:
	git ls-files -z -- '*.yml' '*.yaml' | xargs -0 -r yamllint --config-file .yamllint.yml

# The product roles resolve fully only inside the composed framework tree; CI runs
# ansible-lint there. This target lints what resolves standalone.
ansible-lint:
	ansible-lint

tf-fmt:
	@if command -v terraform >/dev/null 2>&1; then \
	  terraform fmt -check -diff terraform/ ; \
	else \
	  echo "tf-fmt: terraform not installed — skipped" ; \
	fi

# Deny-all allowlist guard: a deliverable-area file that is ignored means someone
# added a file but forgot the matching `!/<path>` line in .gitignore — it would be
# silently dropped from the repo. Fail loudly.
allowlist-check:
	@ignored=$$(git ls-files --others --ignored --exclude-standard -- $(DELIVERABLE_DIRS) 2>/dev/null \
	  | grep -vE '$(GUARD_EXCLUDE)' || true); \
	if [ -n "$$ignored" ]; then \
	  printf 'ERROR: deliverable-area files are NOT allowlisted in .gitignore:\n'; \
	  printf '%s\n' "$$ignored" | sed 's/^/  /'; \
	  printf 'Add an explicit "!/<path>" line to .gitignore, or move it out of the deliverable tree.\n'; \
	  exit 1; \
	else \
	  printf 'allowlist-check: OK — every deliverable file is explicitly allowlisted\n'; \
	fi

# Diátaxis layout gate: every Markdown file must live in a quadrant subtree, ADRs under
# decision-records/{org,template,repo}/, and docs/README.md is the only doc-root Markdown file.
docs-layout:
	python3 tools/check_docs_layout.py

pre-commit:
	pre-commit run --all-files

ci: lint tf-fmt allowlist-check docs-layout

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	find . -type f -name "*.retry" -delete 2>/dev/null || true
