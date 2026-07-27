# Arc trade primitives

Two money primitives for [Arc](https://developers.circle.com/arc), pulled out of a
working trade-finance product and cut down to the parts worth forking.

Both are abstract contracts. Inherit one, wire two or three hooks to your own
roles, and you are done. Neither assumes anything about the rest of your system.

| | What it gives you |
|---|---|
| [`AssignablePayouts`](src/assignment/AssignablePayouts.sol) | Sell a payee's future settlement to a financier. The escrow pays them first, so non-recourse financing works without trusting the payee to hand the money over. |
| [`USYCYieldVault`](src/usyc/USYCYieldVault.sol) | Park idle USDC in USYC so your float earns T-bill yield, with a liquid buffer, guarded oracle reads, and yield measured honestly. |

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
forge test
```

---

## 1. Assignable payouts

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
custody until proof of delivery was anchored — and the ordinary settlement path
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

## 2. USYC yield vault

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
the USDC received — reducing it by the proceeds books the gain into the basis and
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

`withdrawForYield` is a trusted role by construction — the operator holds the USDC
until they return it. Use a multisig, and add a cap or rate limit in your subclass
if the float is large.

---

## What is deliberately not here

The product these came from. No matching, no reputation, no disputes, no
milestones, no fee logic, no frontend. Those are opinions about a business.
These two files are not.

## License

MIT. See [LICENSE](./LICENSE).
