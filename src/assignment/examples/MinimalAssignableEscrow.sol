// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AssignablePayouts} from "../AssignablePayouts.sol";

/// @title MinimalAssignableEscrow
/// @notice The smallest escrow that shows `AssignablePayouts` doing its job.
///         A buyer funds a deal, releases it in whole or in part, and a
///         financier who bought the payout is paid ahead of the payee out of
///         every release.
///
///         Reference code, not a product. It has no disputes, no deadlines, no
///         fees and no access control worth the name. What it does have is the
///         one thing worth copying: every path that pays the payee goes through
///         `_paySellerSide`, and there is no way to pay them around it.
contract MinimalAssignableEscrow is AssignablePayouts {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Funded,
        Settled
    }

    struct Deal {
        address buyer;
        address payee;
        uint256 balance;
        State state;
    }

    IERC20 public immutable token;
    address public owner;
    mapping(bytes32 => Deal) public deals;

    event Funded(bytes32 indexed id, address indexed buyer, address indexed payee, uint256 amount);
    event Released(bytes32 indexed id, uint256 amount);
    event Refunded(bytes32 indexed id, uint256 amount);

    error NotOwner();
    error NotBuyer();
    error BadState();
    error ZeroAmount();
    error TooMuch();

    constructor(IERC20 _token) {
        token = _token;
        owner = msg.sender;
    }

    function _payoutToken() internal view override returns (IERC20) {
        return token;
    }

    /// A payout can only be sold while the deal is funded and unsettled. Without
    /// this, a financier could be sold a claim on a deal that has already paid
    /// out, or on one that never existed.
    function _requireAssignable(bytes32 id) internal view override {
        if (deals[id].state != State.Funded) revert BadState();
    }

    function setAssigner(address assigner, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        _setAssigner(assigner, allowed);
    }

    function fund(bytes32 id, address payee, uint256 amount) external {
        if (deals[id].state != State.None) revert BadState();
        if (amount == 0) revert ZeroAmount();
        deals[id] = Deal({buyer: msg.sender, payee: payee, balance: amount, state: State.Funded});
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(id, msg.sender, payee, amount);
    }

    /// Partial release. Note it pays through `_paySellerSide`, so an assignee is
    /// senior on each tranche rather than only on the last one. Guarding just
    /// the final release would let the first tranche slip past the redirect.
    function release(bytes32 id, uint256 amount) external {
        Deal storage d = deals[id];
        if (d.state != State.Funded) revert BadState();
        if (msg.sender != d.buyer) revert NotBuyer();
        if (amount == 0) revert ZeroAmount();
        if (amount > d.balance) revert TooMuch();

        d.balance -= amount;
        if (d.balance == 0) d.state = State.Settled;

        _paySellerSide(id, d.payee, amount);
        emit Released(id, amount);
    }

    /// Refunds return the BUYER's money and deliberately do not touch the
    /// assignment. A financier's recourse against a refunded deal is whatever
    /// collateral they took from the payee, not the buyer's deposit. Paying an
    /// assignee out of a refund would let a payee sell a receivable and then
    /// collude with the buyer to cancel, taking the advance out of the buyer's
    /// pocket.
    function refund(bytes32 id) external {
        Deal storage d = deals[id];
        if (d.state != State.Funded) revert BadState();
        if (msg.sender != d.buyer) revert NotBuyer();

        uint256 amount = d.balance;
        d.balance = 0;
        d.state = State.Settled;

        token.safeTransfer(d.buyer, amount);
        emit Refunded(id, amount);
    }
}
