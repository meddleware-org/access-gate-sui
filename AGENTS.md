# AGENTS.md — access_gate

Deployment and integration guide for the `access_gate` Move package. Claude-specific
technical notes are in [CLAUDE.md](CLAUDE.md); these general rules layer under it.

## Package

- Name: `access_gate`; module: `access_gate::access_gate`; edition 2024; 0BSD.
- NFT type strings after publish: `<PACKAGE_ID>::access_gate::AccessNFT` and
  `<PACKAGE_ID>::access_gate::SoulboundAccessNFT`. A verifier filters `getOwnedObjects` by
  the type matching the gate's `soulbound` flag.

## Deploy

```bash
sui move test
./scripts/publish.sh <network> [--create-gate]
```

`publish.sh` writes `.env.<network>` with `ACCESS_GATE_PACKAGE_ID`, `ACCESS_NFT_TYPE`,
`SOULBOUND_NFT_TYPE`, and (with `--create-gate`) `ACCESS_GATE_GATE_ID` /
`ACCESS_GATE_ADMIN_CAP_ID`. Consumers read these.

## Per-network isolation

Publish and create a **distinct gate per network** (testnet/mainnet). The NFT type embeds
the package ID, so a testnet NFT can never satisfy a mainnet gate check. Never share a gate
ID or NFT type across networks.

## UpgradeCap

`publish.sh` records `ACCESS_GATE_UPGRADE_CAP_ID`. Custody follows [CUSTODY.md](CUSTODY.md): transfer to
the multisig (`transfer-platform-authority.sh --include-upgrade-cap`), verify, then burn on the planned
date (`make-immutable.sh`). An upgrade in the window bumps `VERSION` and calls `migrate`.

## Verification

```bash
sui client object <GATE_ID> --json | jq '.data.content.fields'   # price/paused/flags
sui client object <PACKAGE_ID> --json | jq -r '.data.owner'      # Immutable if frozen
```

## Working rules

- ABI changes ripple to `@meddleware/access-gate-client` and the `nft-gate` gateways. Update all of them.
- No secrets in scripts; only public IDs/addresses are written to `.env.<network>`.
- Generate tests with behaviour changes.
