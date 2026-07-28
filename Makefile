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

# Local composed trees and CI use this framework-plus-product layout.
# Override when a caller uses a different throwaway composition path.
ANSIBLE_LINT_ROOT ?= _dev-build

# The deny-all guard scans the whole repository. Only rooted, known local artifacts are excluded:
# local workspaces/state, caches, and the two framework-owned roles composed in at runtime.
GUARD_EXCLUDE := ^(_handoff/|_dev-build/|\.ansible/|\.cache/|\.env$$|terraform/\.terraform/|terraform/[^/]+\.tfstate(\.backup)?$$|terraform/\.terraform\.tfstate\.lock\.info$$|ansible/applications/(wazuh_agent|linux_disk_manager)/|([^/]+/)*(__pycache__|\.cache)/|([^/]+/)*[^/]+\.(py[co]|retry)$$)

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

# Lint cached or otherwise visible YAML (the deliverable) — never deleted paths,
# the git-ignored provider cache, dev lab, or compose output.
yamllint:
	@git ls-files --cached --others --exclude-standard -- '*.yml' '*.yaml' \
	  | while read -r file; do test -f "$$file" && printf '%s\0' "$$file"; done \
	  | xargs -0 -r yamllint --config-file .yamllint.yml

# Lint the Git-cached or otherwise visible product Ansible YAML explicitly inside
# the composed tree. CI calls this target after composing the same path, so local
# and hosted lint cannot silently select different files.
ansible-lint:
	@root="$$(cd "$(ANSIBLE_LINT_ROOT)" 2>/dev/null && pwd)" || { \
	  printf 'ERROR: %s is not a composed Ansible tree; compose it first (rsync the pinned framework, then ansible/ over it)\n' \
	    "$(ANSIBLE_LINT_ROOT)" >&2; \
	  exit 1; \
	}; \
	test -f "$$root/ansible.cfg" || { \
	  printf 'ERROR: %s/ansible.cfg is missing; rebuild the composed Ansible tree\n' \
	    "$$root" >&2; \
	  exit 1; \
	}; \
	install -m 0644 "$(CURDIR)/.yamllint.yml" "$$root/.yamllint.yml"; \
	files=$$(git ls-files --cached --others --exclude-standard -- ansible \
	  | while read -r file; do test -f "$(CURDIR)/$$file" && printf '%s\n' "$$file"; done \
	  | grep -E '\.ya?ml$$' | sed 's|^ansible/||' | sort -u); \
	test -n "$$files" || { \
	  printf 'ERROR: no cached or visible product Ansible YAML files found\n' >&2; \
	  exit 1; \
	}; \
	missing=$$(printf '%s\n' "$$files" | while read -r file; do \
	  test -f "$$root/$$file" || printf '%s\n' "$$file"; \
	done); \
	test -z "$$missing" || { \
	  printf 'ERROR: composed tree is missing product lint inputs:\n%s\n' "$$missing" >&2; \
	  exit 1; \
	}; \
	printf 'ansible-lint: %s explicit product YAML inputs in %s\n' \
	  "$$(printf '%s\n' "$$files" | wc -l)" "$$root"; \
	cd "$$root" && ANSIBLE_CONFIG="$$root/ansible.cfg" \
	  ansible-lint --config-file="$(CURDIR)/.ansible-lint" $$files

tf-fmt:
	@if command -v terraform >/dev/null 2>&1; then \
	  terraform fmt -check -diff terraform/ ; \
	else \
	  echo "tf-fmt: terraform not installed — skipped" ; \
	fi

# Deny-all allowlist guard: a repository file that is ignored means someone added a file but
# forgot the matching `!/<path>` line in .gitignore — it would be silently dropped. Fail loudly.
allowlist-check:
	@ignored=$$(git ls-files --others --ignored --exclude-standard -- . 2>/dev/null \
	  | grep -vE '$(GUARD_EXCLUDE)' || true); \
	if [ -n "$$ignored" ]; then \
	  printf 'ERROR: repository files are NOT allowlisted in .gitignore:\n'; \
	  printf '%s\n' "$$ignored" | sed 's/^/  /'; \
	  printf 'Add an explicit "!/<path>" line to .gitignore, or remove the non-deliverable artifact.\n'; \
	  exit 1; \
	else \
	  printf 'allowlist-check: OK — every repository file is explicitly allowlisted\n'; \
	fi
	@# This reverse check intentionally polices only rooted !/ entries.
	@orphans=$$(grep '^!/' .gitignore | sed 's|^!/||; s|/\*\*$$||' | while read -r p; do \
	  case "$$p" in \
	    */) git ls-files --cached --others --exclude-standard -- "$${p%/}" | grep -q . \
	          || echo "$$p" ;; \
	    *)  git ls-files --cached --others --exclude-standard -- "$$p" | grep -qx "$$p" \
	          || echo "$$p" ;; \
	  esac; \
	done); \
	if [ -n "$$orphans" ]; then \
	  printf 'ERROR: .gitignore allowlists paths not in the tracked set:\n'; \
	  printf '%s\n' "$$orphans" | sed 's|^|  !/|'; \
	  exit 1; \
	else \
	  printf 'allowlist-check: OK — every rooted allowlist entry resolves\n'; \
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
