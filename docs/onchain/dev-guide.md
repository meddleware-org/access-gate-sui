---
title: Access Gate — developer integration
---

# Access Gate — developer integration

How to integrate with `access_gate` on-chain: building transactions, reading state, verifying
passes, and consuming single-use passes **replay-safely**. For every function, type, event and abort
code see the [API reference](api-reference.md).

Package (testnet): `0x1a81ca177db039585e575beeeee4759466e55910e936a6733e38dbb65025eea4`, `PlatformConfig`
`0xe3b949cabe9a0574c03dfc924fb3f96e6f959f2bb86d053ed6229a241c3a23f7`.
The TypeScript builders live in `@meddleware/nft-gate-client`; the examples below use
`@mysten/sui` directly so the on-chain contract is explicit.

## Normative integration rules

These are requirements, not suggestions. They mirror the package audit's normative section.

1. **Consume MUST be called by the pass holder with the NFT by value.** `consume` /
   `consume_soulbound` take the NFT object itself, so only the owner's transaction can supply it.
   Never design a flow where a third party is expected to spend a user's pass.
2. **A consumption is replay-proof only when the verifier enforces it.** The chain checks that the
   nonce is at least 8 bytes and records `consumer = tx sender`; it does **not** enforce nonce
   uniqueness or freshness. A verifier that grants access based on `AccessConsumedEvent` MUST:
   - issue a random, single-use nonce (≥ 16 bytes recommended) with a short expiry;
   - accept a consumption only if its event carries **that** nonce, the expected `gate_id`, an
     `nft_id` of that gate, and `consumer` equal to the address that signed the access proof;
   - bind the grant to the consume **transaction digest** and accept each digest and each nonce
     **once**;
   - read the event from a finalised transaction (checkpointed), not from a client-supplied payload.
3. **Verify the pass against the gate on-chain.** Use `is_valid_for` / `is_valid_for_soulbound`
   (or compare `AccessData.gate_id`) — never trust a client's claim about which gate a pass belongs
   to.
4. **Handle both NFT types.** A gate mints either `AccessNFT` or `SoulboundAccessNFT` (see
   `gate_is_soulbound`); call the matching function variant.
5. **Route to the package that minted the pass.** A pass of package `0xA…` can only be consumed by
   `0xA…::access_gate::consume`. Subscribe to events from every package address you trust.

## Creating a gate (PTB)

Every gate is created with an immutable `GatePolicy`, built in the same PTB:

```ts
const [policy] = tx.moveCall({
  target: `${PKG}::access_gate::new_gate_policy`,
  arguments: [
    tx.pure.bool(freezeRequiresUnpaused), tx.pure.bool(lockCommissionOnFreeze),
    tx.pure.bool(pauseBlocksDecryption), tx.pure.bool(pauseBlocksAccess),
  ],
})
// Paid gate: price must be ≥ min_paid_price_mist(platform) (0.01 SUI by default), else abort 11.
tx.moveCall({
  target: `${PKG}::access_gate::create_gate`,
  arguments: [tx.object(PLATFORM_CONFIG_ID), tx.pure.u64(priceMist), /* recipient, uses, soulbound,
    auto-burn, name, image url, description */ ...values, policy],
})
// Free gate instead: pay the platform's free_gate_fee_mist.
// const [fee] = tx.splitCoins(tx.gas, [tx.pure.u64(freeGateFeeMist)])
// tx.moveCall({ target: `${PKG}::access_gate::create_free_gate`,
//   arguments: [tx.object(PLATFORM_CONFIG_ID), fee, ...values, policy] })
```

`@meddleware/nft-gate-client`'s `buildCreateGateTx(pkg, platformConfigId, { …, policy,
freeGateFeeMist })` does this; read the terms with `fetchPlatformConfig`. Admin calls that depend on
the platform terms — `set_price`, `make_gate_free`, `airdrop` (pays the commission) and
`make_gate_immutable` — take the shared `PlatformConfig`; the client builders read it from
`GateAdminContext.platformConfigId`.

## Buying a pass (PTB)

```ts
import { Transaction } from '@mysten/sui/transactions'

const tx = new Transaction()
const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(priceMist)])
tx.moveCall({
  target: `${PKG}::access_gate::purchase`,
  arguments: [tx.object(GATE_ID), tx.object(PLATFORM_CONFIG_ID), payment],
})
// Overpayment is refunded to the sender; the NFT is minted to the sender.
```

`purchase` aborts with `E_PAUSED (1)` if the gate is paused and `E_INSUFFICIENT_PAYMENT (2)` if the
coin is worth less than `gate_price_mist`.

## Consuming a single-use pass (PTB)

```ts
const tx = new Transaction()
tx.moveCall({
  target: `${PKG}::access_gate::${soulbound ? 'consume_soulbound' : 'consume'}`,
  arguments: [tx.object(NFT_ID), tx.object(GATE_ID), tx.pure.vector('u8', nonceBytes)],
})
```

The transaction emits `AccessConsumedEvent { nft_id, gate_id, nonce, consumer, uses_after,
timestamp_ms }`. If `uses_after == 0` and the gate has `auto_burn_at_zero`, the NFT is deleted and an
`AccessBurnedEvent` follows; otherwise the NFT is returned to the sender.

## Reading state (gRPC)

```ts
import { SuiGrpcClient } from '@mysten/sui/grpc'
const client = new SuiGrpcClient({ network: 'testnet', baseUrl: 'https://fullnode.testnet.sui.io:443' })

// A wallet's passes for one gate (filter by type, then by gate_id in the object JSON).
const { objects } = await client.listOwnedObjects({
  owner, type: `${PKG}::access_gate::SoulboundAccessNFT`, include: { json: true },
})
```

gRPC renders struct fields flat (`json.data.gate_id`) and may render framework addresses in long
form — match types tolerantly.

## Error handling

Abort codes are unique **within** `access_gate` (see the [API reference](api-reference.md)). Other
packages reuse the same small integers (e.g. `seal_policies::nft_gate` also uses 1–3), so always key
error messages on **`(module, code)`**, never on the code alone.

## Versioning

Published versions are intended to be immutable; a new version is a new package address. Existing
gates and passes remain valid under the version that created them — keep supporting every address
whose gates are still in use.
