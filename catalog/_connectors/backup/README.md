# Backup connectors

The `backup-policy` catalog item (handler `automation/handlers/Set-PortalBackupPolicy.ps1`) is vendor-agnostic.
The only **active** connector is `vsphereTag`, configured in `config/backup.json` (Admin > Data files > Backup policies):

- the VM receives the vSphere tag `<tagCategory>/<policy id>` (for example `Backup-Policy/Gold`);
- the tag category is created on first use (cardinality Single, entity VirtualMachine);
- policy `None` removes the tag, so the VM drops out of every tag-based backup selection;
- the backup product selects its VMs by tag (Veeam "vSphere tag" job objects, Commvault VM rules, Rubrik/Cohesity
  tag-based SLA assignment, NetBackup VMware Intelligent Policy queries, PowerProtect Data Manager protection rules).

This keeps the portal independent from the backup product: the policy lives in vCenter, the product reads it.

## Templates in this folder

One JSON file per vendor (`veeam.json`, `commvault.json`, `rubrik.json`, `cohesity.json`, `netbackup.json`,
`powerprotect.json`). Each describes what a **future direct connector** would need. They are **documentation only**:

- `status` is always `template — not approved`; nothing in the portal loads these files;
- they never contain secrets: credentials would live in the portal vault and be referenced by `credentialRef`;
- `policyMapping` explains how a portal policy id (Gold, Silver, Bronze, None) would map to the vendor object
  (job, plan, SLA domain, protection policy) and what `None` would do.

Until a product is approved, `Set-PortalBackupPolicy.ps1` refuses any `connector` other than `vsphereTag`
("connector X is not active"), and `Test-PortalDataFile` rejects it when the data file is saved.

## Activating a vendor connector (future work)

1. Get the product approved and a least-privilege service account created.
2. Store the credential in the portal vault (`tools/Register-PortalCredential.ps1`), scope it to the backup item.
3. Implement the connector in the handler (one function per vendor, same input: VM list + policy id; same output:
   previous / new policy per VM) and extend `Test-PortalDataFile` to accept the connector name.
4. Keep the vSphere tag in place as well: it documents the intended policy in vCenter even when the product is
   driven directly.
