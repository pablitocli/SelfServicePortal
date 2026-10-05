# Contributing

Thanks for your interest in improving the Self-Service Portal. This guide explains how to propose changes.

## Ways to contribute

- **Report a bug** - open an issue with the *Bug report* template (version, OS, steps, expected / actual result, relevant lines of `logs/portal.log` or the job log, with secrets removed).
- **Propose a catalog item or feature** - open an issue with the *Feature request* template. Check [docs/roadmap.md](docs/roadmap.md) first.
- **Security issues** - do **not** open a public issue. Follow [SECURITY.md](SECURITY.md).
- **Code, catalog items, handlers and documentation** - pull requests are welcome.

## Development setup

1. PowerShell 7.4+ and Pode 2.14.x (`Install-Module Pode -RequiredVersion 2.14.1`).
2. Clone the repository and run the offline test suite:

   ```powershell
   pwsh -File ./tests/Invoke-SmokeTest.ps1
   ```

   The suite copies the portal to a temporary folder and needs no vCenter, directory or cloud account.
   Optional live LDAP tests run when `LDAPTLS_CACERT` (or `SSP_TEST_LDAP_*`) points to a test directory, see [docs/operations.md](docs/operations.md).
3. Run the portal locally on HTTP: `pwsh -File ./Start-Portal.ps1 -Http` and sign in with `admin` / `ChangeMe-2026!` (you will be asked to change it and to enrol MFA).

## Pull request checklist

- [ ] `tests/Invoke-SmokeTest.ps1` passes; new behaviour has tests.
- [ ] No secrets, internal host names, customer names or real IP addresses in code, items, tests or docs.
- [ ] Catalog items validate (`tools/Test-CatalogItem.ps1`) and follow [docs/catalog-authoring.md](docs/catalog-authoring.md).
- [ ] Handlers take credentials only as `[pscredential]` parameters bound from the vault, never as plain text inputs.
- [ ] Documentation updated (README / docs) and an entry added to `CHANGELOG.md` under *Unreleased*.
- [ ] `Start-Portal.ps1` stays parseable by Windows PowerShell 5.1 (it relaunches itself in pwsh): no `??`, `?.`, ternary or other PowerShell 7-only syntax in that file.

## Coding conventions

- PowerShell 7.2+ in modules, `Set-StrictMode -Version Latest`, approved verbs, `[CmdletBinding()]`.
- Keep routes in `Start-Portal.ps1` thin; put logic in `modules/` so it can be tested without a web server.
- Every state-changing action writes an audit event (`Write-PortalAudit`).
- Front-end: plain JavaScript, no build step, no external CDN at runtime; escape all dynamic text (`esc()`).
- Shell scripts: `bash -n` and `shellcheck` clean.

## Licensing

By contributing you agree that your contributions are licensed under the same terms as the project: the [Apache License 2.0 with the Commons Clause License Condition](LICENSE).
