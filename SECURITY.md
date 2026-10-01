# Security Policy

## Scope

This policy covers security issues in:

- The Move package (`sources/access_gate.move`) — capability forgery or cross-gate reuse,
  double-spend of a single-use pass, soulbound-transfer escape, commission/fee/payment mis-routing or evasion,
  arithmetic over/underflow, or a bypass of the gate-freeze (immutability) guard
- The published testnet package at
  `0x1a81ca177db039585e575beeeee4759466e55910e936a6733e38dbb65025eea4` (and the superseded
  `0x0bedd0b27d993d3292ca6a5315f7562de8bc0ff3752b445b4c53252c76f2d20d` while gates created on it
  are in use)
- The deployment scripts (`scripts/publish.sh`) as they affect capability custody

It does not cover:

- The Sui framework or Move standard library (report to the
  [Sui project](https://github.com/MystenLabs/sui/security))
- The **off-chain verifier's** replay discipline — on-chain, `consume` only enforces a minimum
  nonce length (≥ 8 bytes, `E_INVALID_NONCE`) and records `consumer` (the sender) in
  `AccessConsumedEvent`; it does **not** enforce nonce uniqueness or freshness. A gateway that grants
  access MUST bind the consumption to `(gate_id, nft_id, consumer, server-issued nonce, consume tx
  digest)`, accept each nonce once, and enforce its own freshness window
- Operator key custody of the `PlatformAdminCap`, `Publisher`, `Display`, or `UpgradeCap` (these are
  deployment/operational decisions — see the audit's pre-mainnet gate)

## Security model (invariants)

These invariants are load-bearing. A report demonstrating that any is violated is in scope and
treated as high severity:

1. **Capabilities are per-gate and non-forgeable.** `AdminCap` is mintable only inside `create_gate`;
   every privileged entrypoint asserts `cap.gate_id == object::id(gate)` (`E_WRONG_GATE`). A cap for
   gate A can never act on gate B.
2. **A single-use pass is spent on-chain by its owner only.** `consume` takes the NFT by value
   (Sui ownership), decrements atomically, and emits before delete. It cannot be double-spent
   on-chain.
3. **Soulbound NFTs are non-transferable.** `SoulboundAccessNFT` has `key` without `store`, so
   `public_transfer` does not type-check; only in-module consume/burn can move or destroy it.
4. **Commission is bounded and exact.** A paid mint pays `max(price × bps / 10000, min_commission)`,
   never more than 10% of the price (`commission_bps` itself is capped at 1000,
   `E_COMMISSION_TOO_HIGH`); computed in u128 so no price can overflow, and the operator share cannot
   underflow. The platform treasury can never be set to the zero address (`E_ZERO_ADDRESS`).
5. **The platform is always paid.** A paid price is at least `min_paid_price_mist`
   (`E_PRICE_TOO_LOW`); a price of 0 requires the free-gate fee (`E_FREE_FEE_UNPAID`); every
   purchase and airdrop of a paid gate carries the commission.
6. **A frozen gate's config is immutable.** After `make_gate_immutable`, every setter and `airdrop`
   aborts (`E_GATE_FROZEN`); the freeze is irreversible.
7. **A gate's policy is immutable and honoured.** `GatePolicy` is fixed at creation (no setter);
   `freeze_requires_unpaused` makes a paused freeze abort (`E_FREEZE_WHILE_PAUSED`),
   `pause_blocks_access` makes `consume` abort while paused, and commission terms locked at freeze
   are the only terms ever applied to that gate.

## Versioning and immutability

Each full release follows [CUSTODY.md](CUSTODY.md): the package is published, its `UpgradeCap` moves
to the custody multisig, and the multisig burns it (`0x2::package::make_immutable`) on a planned date
after a verification window. From then on the package bytecode can never change. **Current state:** the
testnet package `0x1a81ca…` has a live `UpgradeCap` (`0xf04a1d87…32bc`, compatible policy, held by the
publisher EOA); it is superseded by the version-gated republish and its cap is burned then. The older
`0x0bedd0…` and the stray test publishes are immutable (their caps were burned on 2026-09-28).

**Version gating.** `PlatformConfig.version` names the only package version allowed to act: every
function that changes shared state, mints or consumes aborts with `E_WRONG_VERSION` (13) under any other
version. An upgrade during the verification window bumps `VERSION`, and the `PlatformAdminCap` holder
calls `migrate` (forward only, `E_NOT_UPGRADE` = 14), which retires every older version at once — so a
fixed defect cannot be reached through the old code. Views and holder `burn`s stay ungated.

**After the burn, protocol changes ship as a new package at a new address.** The old version and all its
gates, NFTs, and `PlatformConfig` remain valid forever. No one is forced to migrate.

**For integrators and gateway operators:**

- When a new version ships, the platform will announce the new package address. You may continue
  using the old version or migrate by pointing at the new address — the choice is yours.
- If you monitor `AccessConsumedEvent` for access control, you must subscribe to events from
  **every package address you trust**. Add new addresses; never remove old ones while gates from
  that version are still in use.
- An NFT minted under v1 (`0x<v1_addr>::access_gate::AccessNFT`) cannot be consumed by a v2
  `consume` call. Route each consume transaction to the package version that minted the NFT.

The `UpgradeCap` (while it exists) and the custody multisig are themselves in scope for security reporting:
compromise would give an attacker upgrade authority over all existing gates.

## Supported versions

Only the latest published package version receives security fixes.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report vulnerabilities by emailing **<security@meddleware.co.uk>**. Include:

- A description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept (if available)
- The package address or commit SHA you tested against

You will receive an acknowledgement within **3 business days** and a resolution plan within
**14 days** for confirmed issues. Critical issues (CVSS ≥ 9.0) are prioritised for same-day
acknowledgement.

## Disclosure

Once a fix is released, a security advisory will be published on the GitHub repository. Reporters
may be credited by name unless they prefer to remain anonymous.
