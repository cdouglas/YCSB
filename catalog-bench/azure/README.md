# Azure catalog-bench setup

Notes specific to driving the Azure sweep with `bench.sh`.  Generic
configuration lives in [`../README.md`](../README.md); this file covers
**only** the Azure-specific bootstrapping.

## Workstation prerequisites

`bench.sh init azure --apply` and the per-cell `bench.sh up/run/...`
calls all use the workstation's `az login` identity (no SAS for control
plane).  The Azure principal needs:

- Sufficient role on the subscription to manage `Microsoft.Storage`,
  `Microsoft.Network`, and `Microsoft.Compute` resources.  Subscription
  **Contributor** or **Owner** is the simplest; `az role assignment list
  --assignee <upn> --subscription <sub>` shows what you have.
- `az login` authenticated session (re-runnable; no expiry config
  needed for sponsorship subscriptions).
- For SAS-token *regeneration* (`generate_sas_keys.sh`), you need
  `Microsoft.Storage/storageAccounts/listkeys/action` on both storage
  accounts (covered by Contributor / Owner / Storage Account
  Contributor).

## Standard storage account (`lstnsgym`) adoption

This is **not auto-imported**.  The Standard SA exists out-of-band (it
held the original Jan 2026 benchmark data), and the import requires
your subscription ID and resource group, which `bench.sh` cannot
discover.  First-time setup:

```bash
catalog-bench/bin/bench.sh init azure
# prints the import command with placeholders
```

Run the printed `terraform import` with your real subscription + RG,
e.g.:

```bash
terraform -chdir=catalog-bench/azure/infra import \
  azurerm_storage_account.adls_standard \
  "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/lstnsgym"
```

Then re-run `bench.sh init azure --apply`.  The Premium SA
(`lstnsgymx3serug`) and the SAS scaffold are managed entirely by
terraform (no import needed).

## SAS token regeneration

The benchmark uses one SAS token per concurrent JVM, served from
`azure/tokens/<SA>_<container>_sas<N>_<DATE>.json`.  These are
generated via `azure/generate_sas_keys.sh`, which calls
`az storage account show-connection-string` then
`az storage container generate-sas` (so it needs the `listkeys`
permission noted above).

```bash
cd catalog-bench/azure
./generate_sas_keys.sh lstnsgym         lst-ns-consistency 16   # Standard SA
./generate_sas_keys.sh lstnsgymx3serug  lstx-consistency   16   # Premium SA
```

Defaults to 16 tokens (matches `SWEEP_THREAD_RANGE` max=8 with
JVM-per-thread headroom; 7-day expiry, more than enough for one
sweep).

`lst.sh` derives the SAS filename from the active `BUCKET` (per-tier
SA + container) and the most recent date stamp it finds in
`tokens/`, so manual filename changes aren't needed.  The script
fail-fasts if the expected SAS file isn't present (added May 2026
after a misconfigured run produced 0-throughput silently).

## Quota

The default Sponsorship subscription's **Total Regional vCPU** quota
in `westus` is **10 cores**.  This benchmark uses
`Standard_D8s_v3` (8 cores) which fits.  Bumping
`AZURE_VM_SIZE=Standard_D16s_v3` (16 cores) requires a quota-increase
request via the Azure portal (typically 0.5–2 hr to approve).

## Other Azure-specific bootstrapping

- **VM image**: pinned in `azure/benchmark/main.tf`; update if it gets
  deprecated.
- **System-assigned identity**: each benchmark VM gets a managed
  identity granted Storage Blob Data Contributor on both SAs.  This is
  what unblocks the Java-side ADLS reads/writes during the workload.
- **Stale SAS tokens**: SAS tokens expire 7 days after generation.
  Re-run `generate_sas_keys.sh` before any sweep that's more than a
  week after the previous one.
