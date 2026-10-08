# Arc trade primitives

[![CI](https://github.com/Iziedking/arc-trade-primitives/actions/workflows/ci.yml/badge.svg)](https://github.com/Iziedking/arc-trade-primitives/actions/workflows/ci.yml)

Contracts for trading safely with strangers on [Arc](https://developers.circle.com/arc),
taken from [Karwan](https://github.com/Iziedking/Karwan) and cut down to the
parts worth forking.

Two people who have never met need three things before money moves between
them: a way to know who they are dealing with, a way to pay that protects both
sides, and, as a track record builds, access to working capital against the
deals they win. Each contract here covers one of those, and none assumes
anything about the rest of your system.

| | What it gives you | Status |
|---|---|---|
| [`KarwanBusinessRegistry`](src/verification/KarwanBusinessRegistry.sol) | A tamper-evident record of who applied to trade as a verified business, which document they anchored, and who reviewed it. | **Live on Arc mainnet** |
| [`AssignablePayouts`](src/assignment/AssignablePayouts.sol) | Sell a payee's future settlement to a financier. The escrow pays them first, so non-recourse financing works without trusting the payee to hand the money over. | Tested. The pattern runs in Karwan's testnet escrow |
| [`USYCYieldVault`](src/usyc/USYCYieldVault.sol) | Park idle USDC in USYC so your float earns T-bill yield, with a liquid buffer, guarded oracle reads, and yield measured honestly. | Tested. The pattern runs in Karwan's testnet vaults |

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 foundry-rs/forge-std@v1.16.1
forge test
```

## Deployments

| Network | Contract | Address |
|---|---|---|
| Arc mainnet (5042) | `KarwanBusinessRegistry` | [`0x69eA60B6EFd13A126Eb00d25aB0f21A4AfC636eF`](https://explorer.arc.io/address/0x69eA60B6EFd13A126Eb00d25aB0f21A4AfC636eF) |

A 2-of-3 Safe (`0x489C6367E2e943A3cC017589f73cAA8A80d7D028`) owns the registry
and holds the reviewer role. The full record is in
[`deployments/arc-mainnet.json`](deployments/arc-mainnet.json).

Check that the code in this repo is the code running on mainnet:

```bash
bash script/verify-mainnet.sh
# OK   KarwanBusinessRegistry at 0x69eA60B6EFd13A126Eb00d25aB0f21A4AfC636eF (2206 bytes)
```

The script builds with the settings the contract was deployed with (the
`mainnet` profile in `foundry.toml`), reads the live bytecode, and compares the
two with the trailing compiler metadata removed. That metadata fingerprints the
build environment rather than the code, so it differs between repos; every
byte the EVM executes must match. CI runs the same check on every push.

---

## 1. Business verification registry

The problem: a buyer abroad cannot check whether the supplier they found in a
chat is a registered business, and a platform that says "verified" usually
offers nothing anyone can check later. The check happens once, in someone's
database, and the record of who checked what is gone.

`KarwanBusinessRegistry` keeps that record on chain. The applicant anchors the
hash of their registration or tax document. A reviewer approves or rejects
that exact document. Anyone can read the outcome.

```solidity
bytes32 doc = keccak256(registrationPdf);       // the document itself stays off chain
registry.submitRegistration(doc);                // applicant

registry.approve(applicant, doc);                // reviewer, naming the document they checked
registry.isVerified(applicant);                  // anyone: true
```

What you get:

- **The reviewer approves a document, not a wallet.** `approve` and `reject`
  take the document hash the reviewer actually checked and revert with
  `DocHashMismatch` if the applicant resubmitted in between. Without that, an
  applicant who swaps the document while the review is in flight gets a
  document nobody looked at marked verified.
  [`KarwanBusinessRegistryReviewRace.t.sol`](test/KarwanBusinessRegistryReviewRace.t.sol)
  keeps that race covered.
- **Revocation without a redeploy.** A business that turns out to be
  fraudulent, loses its licence, or was approved in error is moved from
  Verified to Rejected by the reviewer. It can apply again afterwards.
- **No personal data on chain.** Only the document hash and, on rejection or
  revocation, the hash of the reason. The documents and reasons stay with
  whoever ran the review.
- **No funds, no allowlist.** The registry holds no money and needs no Circle
  whitelist, so it can sit beside any escrow or marketplace that wants to gate
  on `isVerified`.
- **Explicit handover.** Ownership moves in two steps
  (`transferOwnership`, then `acceptOwnership` by the new owner), and the
  owner can rotate the reviewer.

Statuses: `0` none, `1` submitted, `2` verified, `3` rejected.

What it does not do: decide what counts as a valid business. The reviewer
does that off chain. The contract makes the decision and its subject
permanent and public.

---

## 2. Assignable payouts

The problem: a financier advances a supplier cash against a deal that has not
settled yet. When it does settle, the money lands in the supplier's wallet, and
the financier has to hope it comes back. That hope is the entire risk, and it is
what makes on-chain receivables financing hard to price.

`AssignablePayouts` moves the repayment into the escrow itself.

```solidity
contract MyEscrow is AssignablePayouts {
    function _payoutToken() internal view override returns (IERC20) {
        return usdc;
    }

    function _requireAssignable(bytes32 id) internal view override {
        if (deals[id].state != State.Funded) revert BadState();
    }

    function release(bytes32 id, uint256 amount) external {
        // ... your checks ...
        _paySellerSide(id, deals[id].payee, amount);   // <- not a raw transfer
    }
}
```

What you get:

- **Irrevocable and single-use.** Once assigned, an id cannot be reassigned by
  anyone, including the assigner. A financier can underwrite against the redirect
  existing.
- **Senior on every payout path**, including partial and milestone releases.
- **Capped, never reverting.** An assignee owed more than the deal will ever pay
  takes a haircut instead of stranding the settlement. A payout path that can
  revert on a financing detail is one that holds the payee hostage.
- **Conservation.** The two transfers always sum to the amount passed in.

Two rules that are not optional:

**Route every payee-side transfer through `_paySellerSide`.** One path that
transfers directly is one path the financier is not senior on, and there is no
way for them to see that from outside.

**Never let an assignment exist while the advance is unpaid.** Assign in the same
transaction the money reaches the payee, or after:

```solidity
escrow.assignPayout(id, financier, repayAmount);
usdc.safeTransferFrom(financier, payee, principal);   // same transaction
```

That second rule is the expensive one. The escrow this came from shipped a
financing contract that assigned at funding time but held the advance in its own
custody until proof of delivery was anchored, and the ordinary settlement path
never anchored proof of delivery. The default outcome was that the supplier
delivered, received nothing, and the financier finished a full repay amount ahead
having risked nothing. The primitive behaved correctly throughout; the defect was
entirely in the consumer. `test_Regression_AssigningBeforePayingTheAdvanceStrandsThePayee`
keeps that scenario alive so nobody rediscovers it.

Refunds deliberately ignore the assignment. A refund returns the *buyer's* money,
and a financier's recourse on a refunded deal is whatever collateral they took
from the payee. Paying an assignee out of a refund would let a payee sell a
receivable and then collude with the buyer to cancel, taking the advance out of
the buyer's pocket.

[`MinimalAssignableEscrow`](src/assignment/examples/MinimalAssignableEscrow.sol)
is a complete worked example: fund, partial release, refund. Reference code, not
a product.

---

## 3. USYC yield vault

[USYC](https://developers.circle.com/tokenized/usyc) is a tokenised T-bill fund.
Holding your idle float in it instead of raw USDC is close to free yield. Two
things make it harder than it looks, and both are handled here.

### Entitlement is checked on the direct caller

USYC is permissioned. The Teller checks **whoever called it**, not the receiver,
and it does not walk a call chain. So a contract that is not itself entitled can
never wrap, no matter who calls the contract. That surprises people.

Both paths are supported:

- **Contract entitled** → `sweepToUSYC()` / `redeemFromUSYC()` call the Teller
  directly.
- **Only an operator EOA entitled** → `withdrawForYield()` hands USDC to the
  operator, who wraps it in their own name and returns it via `depositYield()`.
  `outForYield` tracks the debt so it still counts as an asset rather than
  looking like a withdrawal.

Getting entitled is a manual process with Hashnote, and **it does not transfer
when you redeploy.** Assume a redeployed contract is unentitled on day one. That
is precisely why the operator path exists.

### Yield is measured against cost basis, not par

USYC appreciates continuously and its price does not reset when you buy. So
`holdings * price - principal` counts every cent it appreciated *before you held
it*. On a real position that is the difference between reporting $45 and
reporting $3,969.

`costBasisUsdc` records what you actually paid; `accruedYield()` measures against
it. Redemptions reduce the basis **proportionally to the shares sold**, not by
the USDC received. Reducing it by the proceeds books the gain into the basis and
quietly zeroes the reported yield on whatever is left.

If you hold USYC across several vaults or contract generations, sum the cost
bases too. One operator pool measured against a single vault's basis reports a
wildly inflated number.

### Other things baked in

- **The oracle is 18 decimals**, not the 8 everyone assumes from Chainlink.
  Wiring it as 8 reverts or misprices by ten orders of magnitude.
- **Guarded reads.** `usycPrice()` reverts on a non-positive answer, one older
  than `maxPriceAge`, or one from a superseded round. Each has a real failure
  behind it: a zero price values the position at nothing, a stale price prices a
  redemption off yesterday's NAV, an out-of-round answer is the feed saying it
  has not settled.
- **A liquid floor.** Sweeping never dips below it, so money you owe people stays
  payable without unwinding a yield position first.
- **`maxPriceAge` is settable**, so a frozen testnet oracle is a parameter change
  rather than a redeploy or a fake feed.

`withdrawForYield` is a trusted role by construction: the operator holds the USDC
until they return it. Use a multisig, and add a cap or rate limit in your subclass
if the float is large.

---

## How these fit together in Karwan

Karwan lets your reputation travel with you, and lets your agent use that
reputation to find, negotiate with, and transact with the right people. The
order matters: verify first, then protect the payment, then let financing
follow the record. A verified business with completed deals is one a
financier can price, and `AssignablePayouts` is how that financing gets repaid
out of the escrow rather than out of trust.

## What is deliberately not here

The product these came from. No matching, no agents, no reputation scoring, no
disputes, no milestones, no fee logic, no frontend. Those are opinions about a
business. These files are not.

## License

MIT. See [LICENSE](./LICENSE).
