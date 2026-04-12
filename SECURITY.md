# Security Policy

## Supported versions

This repository is a blueprint and may evolve quickly. Security fixes are provided on a best-effort basis on the `main` branch.

## Reporting a vulnerability

If you believe you have found a security issue:

- Do not open a public issue with sensitive details.
- Share a minimal reproduction and impact description.

If there is no private disclosure channel configured for this repo yet, open an issue with **high-level** details only (no exploit steps, no secrets), and request a private follow-up channel.

## Operational security notes

- Treat `terraform/terraform.tfvars`, Headscale preauth keys, and any generated inventory outputs as sensitive.
- Never commit mnemonics, auth keys, API keys, or private keys.
- Prefer running post-deploy administration from a tailnet-connected device; public SSH is intended to be locked down.
