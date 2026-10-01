# Custody — access_gate

Who holds this package's authority objects, and how that changes over a release. The scripts named
here all run the same preflight (active env, chain identifier, CLI version, `MAINNET_CONFIRM=1` on
mainnet), are dry runs by default, and ask for a typed confirmation before anything irreversible.

## Authority objects

| Object | Created by | Controls | Long-term holder |
| --- | --- | --- | --- |
| `UpgradeCap` | publish | replacing the package code | the multisig, until it burns the cap on the planned date |
| `PlatformAdminCap` | `init` | treasury address, commission, minimum price, free-gate fee, `migrate` | the multisig, permanently |
| `Publisher` | `init` | future `Display` changes | the multisig, permanently |
| `Display<AccessNFT>`, `Display<SoulboundAccessNFT>` | `init` | how wallets render passes | the multisig, permanently |

A gate's `AdminCap` belongs to that gate's owner, not to the platform, and is outside this process.

## Release lifecycle (every full release)

1. **Publish** from the deploy key: `scripts/publish.sh <network>`. The deploy key holds every object
   above. `deployments.json` records `custody.upgradeCapOwner` as the deploy key.
2. **Transfer** to the multisig:
   `DRY_RUN=0 NETWORK=<network> MULTISIG_ADDRESS=0x… bash scripts/transfer-platform-authority.sh --include-upgrade-cap`.
   Each object is re-read on-chain (exact type, this package, owned by the deploy key) before it is
   sent. `deployments.json` then records the multisig as `custody.multisigAddress` and
   `custody.upgradeCapOwner`.
3. **Set the burn date.** Write `custody.plannedBurnDate` (`YYYY-MM-DD`) in `deployments.json` and
   commit it. The date ends the verification window.
4. **Launch and verify.** Point consumers at the new package. While the multisig holds the
   UpgradeCap, a defect found in this window can be fixed with an upgrade; version gating
   (`PlatformConfig.version`, `migrate`) retires the faulty version for every caller at once.
5. **Burn** on the planned date: `NETWORK=<network> DRY_RUN=0 bash scripts/make-immutable.sh` writes
   the unsigned `0x2::package::make_immutable` transaction with the multisig as sender and prints the
   signing steps (below). After execution, `custody.upgradeCapOwner` becomes `null` and
   `custody.burnedAt` the date.

`publish.sh --make-immutable` burns the cap straight after publishing. It is for publishes that are
never meant to be upgraded, such as a throwaway test package, and is not part of a full release.

## The multisig

Create the address once from its members' public keys (`sui keytool list`, field
`publicBase64Key`):

```bash
MULTISIG_PKS="<pk1> <pk2>" MULTISIG_WEIGHTS="1 1" MULTISIG_THRESHOLD=1 bash scripts/multisig-address.sh
```

Keep the exact keys, weights and threshold with the address: every signature combination needs them.
While the maintainer is the only signer, a 1-of-1 multisig of the maintainer's key is enough. To add
signers later, create a new multisig and transfer the objects to it from the old one (a multisig-signed
transfer, using the steps below).

The multisig address pays gas for its own transactions, so it must hold a little SUI.

## Signing a transaction as the multisig

Any action by an object the multisig owns — the burn, `migrate`, `set_commission_bps`, a transfer —
uses the same steps. `make-immutable.sh` does step 1 for the burn.

1. Build the transaction unsigned, with the multisig as sender:
   ```bash
   sui client ptb --move-call <target> <args…> \
     --sender @<multisig> --gas-budget 100000000 --serialize-unsigned-transaction > tx.b64
   ```
2. Each signer, until the threshold is met:
   `sui keytool sign --address <signer> --data "$(cat tx.b64)" --json` → `suiSignature`.
3. Combine: `sui keytool multi-sig-combine-partial-sig --pks <pk…> --weights <w…> --threshold <t> --sigs <suiSignature…> --json`
   → `multisigSerialized`.
4. Execute: `sui client execute-signed-tx --tx-bytes "$(cat tx.b64)" --signatures <multisigSerialized>`.

Signers can work on separate machines: only `tx.b64` and the signatures travel between them.

## Upgrading during the verification window

1. Bump `VERSION` in `sources/access_gate.move` and make the code change (struct layouts cannot
   change in an upgrade).
2. Build the upgrade transaction with the multisig as sender
   (`sui client upgrade --upgrade-capability <cap> --sender <multisig> --serialize-unsigned-transaction`)
   and sign it as above.
3. Call `migrate(&PlatformAdminCap, &mut PlatformConfig)` from the multisig. Every older version now
   aborts with `E_WRONG_VERSION` on any gated call.
4. Release the npm package and update consumers to the new `published-at`.

## Rehearsal

The whole lifecycle was rehearsed on localnet on 2026-10-01: publish, a 1-of-2 multisig from two local
keys, transfer of all five objects, then a burn signed by one member and executed through
`execute-signed-tx`. Repeat it with `sui start --with-faucet --force-regenesis` and a separate
`SUI_CONFIG_DIR` so the real client configuration is untouched.

## Current state

`deployments.json` is the record for each network. Mainnet has not been published yet.
