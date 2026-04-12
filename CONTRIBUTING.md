# Contributing

Thanks for helping improve this blueprint.

## Ground rules

- Keep changes **minimal and focused**.
- Do not introduce new public exposure (ports/endpoints) without clearly documenting it and calling it out in the changelog.
- Do not commit secrets (mnemonics, auth keys, API keys, private keys). Prefer `.gitignore` + local files.
- Prefer **idempotent** Ansible tasks and rerunnable scripts.

## Where things live

- Terraform: `terraform/`
- Ansible: `ansible/`
- Ops scripts + verification: `scripts/`
- Docs: `docs/`

## Development workflow

1) Update/extend documentation (as needed)
- User-facing docs: `docs/user/GUIDE.md`, `README.md`, `docs/README.md`
- Technical docs: `docs/technical/ARCHITECTURE.md`, `docs/technical/OPERATIONS.md`

2) Add/adjust verification
- Prefer adding/adjusting scripts under `scripts/tests/`.

3) Validate

```bash
# From repo root
./scripts/tests/run.sh bootstrap-smoke
```

If you changed Terraform:

```bash
cd terraform
terraform fmt
terraform validate
```

4) Keep changelog/version aligned

- Update `CHANGELOG.md` for user-visible changes.
- Bump `VERSION` appropriately.

## Pull requests

Please include:

- What changed
- Why it changed
- How to validate (exact commands)
- Risks and rollback notes (if any)
