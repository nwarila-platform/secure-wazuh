# Description

<!-- Summarize the change and the motivation behind it. Link any related issues. -->

Fixes # (issue)

## Type of change

<!-- Check all that apply. The type must match your Conventional Commit prefix. -->

- [ ] Bug fix (`fix:`)
- [ ] New feature (`feat:`)
- [ ] Security fix (`security:`)
- [ ] CI/CD change (`ci:`)
- [ ] Documentation update (`docs:`)
- [ ] Refactor (`refactor:`)
- [ ] Chore (`chore:`)
- [ ] Breaking change (append `!` to the type, e.g. `feat!:`)

## Checklist

- [ ] My commits follow [Conventional Commits](https://www.conventionalcommits.org/) and the inherited [organization contribution guidelines](https://github.com/nwarila-platform/.github/blob/main/CONTRIBUTING.md)
- [ ] I have run `pre-commit run --all-files` locally and all hooks pass
- [ ] I have run `make lint` (yamllint + ansible-lint) locally with no errors
- [ ] I have run `make allowlist-check` so every new deliverable file is allowlisted in `.gitignore`
- [ ] I have updated documentation under `docs/` where applicable
- [ ] I have described how this change was tested below

## Testing

<!-- Describe how you verified this change on a real target: the Proxmox permanent all-in-one, an ephemeral AWS deploy -> test -> destroy run, or a Vagrant lab. Note ok/changed/failed task counts and any cluster / agent-enrollment checks. -->

## Additional notes

<!-- Anything else reviewers should know? Trade-offs, follow-ups, or security considerations. -->
