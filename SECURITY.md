# Security Policy

## Scope

This policy covers security issues in:

- The Move package (`sources/access_gate.move`) — capability forgery or cross-gate reuse,
  double-spend of a single-use pass, soulbound-transfer escape, commission/payment mis-routing,
  arithmetic over/underflow, or a bypass of the gate-freeze (immutability) guard
- The published testnet package at
  `0x0bedd0b27d993d3292ca6a5315f7562de8bc0ff3752b445b4c53252c76f2d20d`
- The deployment scripts (`scripts/publish.sh`) as they affect capability custody

It does not cover:

- The Sui framework or Move standard library (report to the
  [Sui project](https://github.com/MystenLabs/sui/security))
- The **off-chain verifier's** replay discipline — the on-chain `AccessConsumedEvent` `nonce` is
  caller-supplied and unvalidated by design; a gateway that grants access must bind the consumption
  to `(gate_id, nft_id, sender, server-issued nonce)` and enforce uniqueness itself
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
4. **Commission is bounded.** `commission_bps` is capped at 1000 (10%, `E_COMMISSION_TOO_HIGH`);
   the split math cannot overflow at realistic values, and the operator share cannot underflow.
5. **A frozen gate's config is immutable.** After `make_gate_immutable`, every setter and `airdrop`
   aborts (`E_GATE_FROZEN`); the freeze is irreversible.

## Versioning and immutability

Each published version of this package is **permanently immutable**: the `UpgradeCap` is burned on
publish via `scripts/publish.sh --make-immutable` (`0x2::package::make_immutable`). Once burned, the
package bytecode and module semantics can never change.

**Future protocol changes ship as a new package at a new address.** The old version and all its
gates, NFTs, and `PlatformConfig` remain valid forever. No one is forced to migrate.

**For integrators and gateway operators:**

- When a new version ships, the platform will announce the new package address. You may continue
  using the old version or migrate by pointing at the new address — the choice is yours.
- If you monitor `AccessConsumedEvent` for access control, you must subscribe to events from
  **every package address you trust**. Add new addresses; never remove old ones while gates from
  that version are still in use.
- An NFT minted under v1 (`0x<v1_addr>::access_gate::AccessNFT`) cannot be consumed by a v2
  `consume` call. Route each consume transaction to the package version that minted the NFT.

The `UpgradeCap` listed in the audit (while still live) is itself in scope for security reporting:
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
