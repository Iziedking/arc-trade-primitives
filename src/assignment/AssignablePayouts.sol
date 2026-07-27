// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AssignablePayouts
/// @notice Lets an escrow sell a payee's future settlement to a third party.
///         Inherit it, call `_paySellerSide` wherever you would have paid the
///         payee, and a financier who advanced against the deal is paid by the
///         contract instead of chasing the payee for repayment.
///
///         This is the piece that makes non-recourse trade finance work on
///         chain. Without it, a financier who advances against a receivable has
///         to trust the payee to hand the settlement over when it lands, which
///         is precisely the risk they were trying to price.
///
/// ## What it guarantees
///
/// 1. **Irrevocable and single-use.** Once assigned, an id cannot be reassigned,
///    by anyone, including the assigner. A financier can underwrite against the
///    redirect existing.
/// 2. **Senior across every payout path.** As long as you route all payee-side
///    transfers through `_paySellerSide`, the assignee is paid first out of each
///    one, including partial or milestone payouts.
/// 3. **Capped, never reverting.** An assignee owed more than the deal will ever
///    pay takes a haircut instead of stranding the settlement for everyone. A
///    payout path that can revert on a financing detail is a payout path that
///    holds the payee hostage.
/// 4. **Conservation.** The two transfers inside `_paySellerSide` always sum to
///    the amount passed in. Nothing is minted, nothing is stuck.
///
/// ## The invariant a caller MUST hold
///
/// **Never let an assignment exist while the advance is unpaid.**
///
/// Assign in the same transaction that the money reaches the payee, or assign
/// only after it has. If you assign at the moment you commit funds but release
/// those funds to the payee later, behind some other condition, then any path
/// that settles before that condition is met pays the assignee out of the
/// payee's proceeds while the payee is still holding nothing.
///
/// This is not hypothetical. The escrow this was extracted from shipped exactly
/// that bug: the financing contract assigned at funding time but held the
/// advance in its own custody until proof of delivery was anchored, and the
/// ordinary settlement path never anchored proof of delivery. The default
/// outcome was that the seller delivered, received nothing, and the financier
/// finished a full repay amount ahead. See `test/AssignablePayouts.t.sol`,
/// which keeps that scenario as a regression.
///
/// The safe shape, in one line:
///
/// ```solidity
/// escrow.assignPayout(id, financier, repayAmount);
/// usdc.safeTransferFrom(financier, payee, principal);   // same transaction
/// ```
abstract contract AssignablePayouts {
    using SafeERC20 for IERC20;

    struct Assignment {
        address assignee;
        uint128 amount;
        uint128 paid;
    }

    /// @notice Contracts allowed to sell a payout. Keep this list short: an
    ///         assigner can redirect any settlement this escrow holds.
    mapping(address => bool) public authorizedAssigners;

    /// @notice The redirect recorded against a payout id, if any.
    mapping(bytes32 => Assignment) public assignmentOf;

    event AssignerSet(address indexed assigner, bool allowed);
    event PayoutAssigned(bytes32 indexed id, address indexed assignee, uint128 amount);
    event AssignedPayout(bytes32 indexed id, address indexed assignee, uint256 amount);

    error NotAssigner();
    error InvalidAssignment();
    error AlreadyAssigned();

    /// @dev The token every payout settles in.
    function _payoutToken() internal view virtual returns (IERC20);

    /// @dev Revert unless `id` is in a state where selling its payout is valid.
    ///      Implement this to reject ids that do not exist, are already settled,
    ///      or are otherwise past the point where a redirect makes sense. The
    ///      default accepts everything, which is almost never what you want.
    function _requireAssignable(bytes32 id) internal view virtual {}

    /// @dev Wire this to your own admin control.
    function _setAssigner(address assigner, bool allowed) internal {
        authorizedAssigners[assigner] = allowed;
        emit AssignerSet(assigner, allowed);
    }

    /// @notice Sell the payout on `id` to `assignee` for up to `amount`.
    ///         Irrevocable and single-use by design: a financier underwrites
    ///         against the redirect existing, so a redirect that could be
    ///         cancelled or overwritten would be worth nothing.
    ///
    ///         The caller is responsible for the invariant in the contract
    ///         docs: the payee must receive the advance in this same
    ///         transaction, or have received it already.
    function assignPayout(bytes32 id, address assignee, uint128 amount) external {
        if (!authorizedAssigners[msg.sender]) revert NotAssigner();
        if (assignee == address(0) || amount == 0) revert InvalidAssignment();
        if (assignmentOf[id].assignee != address(0)) revert AlreadyAssigned();
        _requireAssignable(id);

        assignmentOf[id] = Assignment({assignee: assignee, amount: amount, paid: 0});
        emit PayoutAssigned(id, assignee, amount);
    }

    /// @notice How much `id` still owes its assignee. Zero when unassigned or
    ///         fully paid. Useful for deciding whether a financing line is
    ///         whole before acting on it off chain.
    function outstandingAssignment(bytes32 id) public view returns (uint256) {
        Assignment storage a = assignmentOf[id];
        if (a.assignee == address(0) || a.paid >= a.amount) return 0;
        return uint256(a.amount) - uint256(a.paid);
    }

    /// @dev Pay a payee-side amount, routing the assigned portion to the
    ///      assignee first. Call this from EVERY path that pays the payee. One
    ///      path that transfers directly is one path a financier is not senior
    ///      on, and they have no way to see that from outside.
    ///
    ///      Conservation holds: the two transfers always sum to `amount`.
    function _paySellerSide(bytes32 id, address payeeTo, uint256 amount) internal {
        if (amount == 0) return;

        Assignment storage a = assignmentOf[id];
        uint256 cut;
        if (a.assignee != address(0) && a.paid < a.amount) {
            uint256 owed = uint256(a.amount) - uint256(a.paid);
            cut = amount < owed ? amount : owed;
            // forge-lint flags this cast. It cannot truncate: `cut` is at most
            // `owed`, which is at most `a.amount`, which is already a uint128.
            a.paid += uint128(cut);
            _payoutToken().safeTransfer(a.assignee, cut);
            emit AssignedPayout(id, a.assignee, cut);
        }
        if (amount > cut) {
            _payoutToken().safeTransfer(payeeTo, amount - cut);
        }
    }
}
