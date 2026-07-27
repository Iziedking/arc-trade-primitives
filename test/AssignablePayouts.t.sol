// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssignablePayouts} from "../src/assignment/AssignablePayouts.sol";
import {MinimalAssignableEscrow} from "../src/assignment/examples/MinimalAssignableEscrow.sol";

contract MockUSDC is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        if (allowance[from][msg.sender] < type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A financier that does it RIGHT: assigns and pays the payee in one call.
contract SafeFinancier {
    MinimalAssignableEscrow public escrow;
    MockUSDC public usdc;

    constructor(MinimalAssignableEscrow _escrow, MockUSDC _usdc) {
        escrow = _escrow;
        usdc = _usdc;
    }

    function advance(bytes32 id, address payee, uint128 principal, uint128 repay) external {
        escrow.assignPayout(id, msg.sender, repay);
        usdc.transferFrom(msg.sender, payee, principal);
    }
}

/// A financier that does it WRONG, kept deliberately. It assigns at funding
/// time but parks the advance in its own custody behind a condition that the
/// ordinary settlement path never satisfies. This is the exact shape of a bug
/// that shipped to production in the escrow this primitive came from, and the
/// reason the invariant is stated so loudly in AssignablePayouts.
contract CustodyFinancier {
    MinimalAssignableEscrow public escrow;
    MockUSDC public usdc;
    mapping(bytes32 => uint256) public held;
    mapping(bytes32 => bool) public deliveryProven;

    constructor(MinimalAssignableEscrow _escrow, MockUSDC _usdc) {
        escrow = _escrow;
        usdc = _usdc;
    }

    function advance(bytes32 id, uint128 principal, uint128 repay) external {
        escrow.assignPayout(id, msg.sender, repay);
        held[id] = principal;
        usdc.transferFrom(msg.sender, address(this), principal);
    }

    function proveDelivery(bytes32 id) external {
        deliveryProven[id] = true;
    }

    function releaseToPayee(bytes32 id, address payee) external {
        require(deliveryProven[id], "no proof of delivery");
        uint256 amount = held[id];
        held[id] = 0;
        usdc.transfer(payee, amount);
    }
}

contract AssignablePayoutsTest is Test {
    MockUSDC usdc;
    MinimalAssignableEscrow escrow;

    address buyer = makeAddr("buyer");
    address payee = makeAddr("payee");
    address financier = makeAddr("financier");
    /// Zero-balance stand-in for seniority tests, so raw balance assertions
    /// are not skewed by the advance capital `financier` starts with.
    address assignee = makeAddr("assignee");
    address stranger = makeAddr("stranger");

    bytes32 constant ID = keccak256("deal-1");
    uint256 constant DEAL = 100e6;
    uint128 constant PRINCIPAL = 90e6;
    uint128 constant REPAY = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new MinimalAssignableEscrow(usdc);

        usdc.mint(buyer, DEAL);
        usdc.mint(financier, PRINCIPAL);

        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(buyer);
        escrow.fund(ID, payee, DEAL);
    }

    /* ========================= the core guarantees ========================= */

    function test_AssigneeIsPaidAheadOfThePayee() public {
        _assignTo(assignee, REPAY);

        vm.prank(buyer);
        escrow.release(ID, DEAL);

        assertEq(usdc.balanceOf(assignee), REPAY, "assignee paid first");
        assertEq(usdc.balanceOf(payee), 0, "payee gets only what is left");
    }

    /// Seniority has to hold on EVERY tranche. Guarding only the final release
    /// would let the first one slip past the redirect entirely.
    function test_AssigneeIsSeniorAcrossPartialReleases() public {
        _assignTo(assignee, REPAY);

        vm.prank(buyer);
        escrow.release(ID, 40e6);
        assertEq(usdc.balanceOf(assignee), 40e6, "first tranche went to the assignee");
        assertEq(usdc.balanceOf(payee), 0);

        vm.prank(buyer);
        escrow.release(ID, 60e6);
        assertEq(usdc.balanceOf(assignee), REPAY, "assignee made whole");
        assertEq(usdc.balanceOf(payee), 0);
    }

    /// Once the assignee is whole the rest belongs to the payee.
    function test_RemainderFlowsToThePayeeOnceTheAssigneeIsWhole() public {
        _assignTo(assignee, 60e6);

        vm.prank(buyer);
        escrow.release(ID, DEAL);

        assertEq(usdc.balanceOf(assignee), 60e6);
        assertEq(usdc.balanceOf(payee), DEAL - 60e6, "payee keeps the surplus");
    }

    /// An assignee owed more than the deal will ever pay takes a haircut. The
    /// alternative, reverting, would let a financing detail hold the payee's
    /// settlement hostage forever.
    function test_OverAssignmentCapsInsteadOfReverting() public {
        _assignTo(assignee, 500e6);

        vm.prank(buyer);
        escrow.release(ID, DEAL);

        assertEq(usdc.balanceOf(assignee), DEAL, "capped at what the deal held");
        assertEq(usdc.balanceOf(payee), 0);
        assertEq(escrow.outstandingAssignment(ID), 400e6, "the rest stays owed, off chain");
    }

    /// Conservation: the two transfers always sum to the amount released.
    function testFuzz_ConservationHolds(uint128 assigned, uint96 releaseAmount) public {
        assigned = uint128(bound(assigned, 1, 1_000e6));
        uint256 amount = bound(releaseAmount, 1, DEAL);

        _assignTo(assignee, assigned);

        vm.prank(buyer);
        escrow.release(ID, amount);

        assertEq(
            usdc.balanceOf(assignee) + usdc.balanceOf(payee),
            amount,
            "nothing minted, nothing stranded"
        );
    }

    /* ============================ access control =========================== */

    function test_OnlyAuthorizedAssignersCanSellAPayout() public {
        vm.prank(stranger);
        vm.expectRevert(AssignablePayouts.NotAssigner.selector);
        escrow.assignPayout(ID, stranger, REPAY);
    }

    /// Irrevocable and single-use: a financier underwrites against the redirect
    /// existing, so one that could be overwritten would be worth nothing.
    function test_AnAssignmentCannotBeOverwritten() public {
        _assignTo(financier, REPAY);

        vm.prank(address(this));
        vm.expectRevert(AssignablePayouts.AlreadyAssigned.selector);
        escrow.assignPayout(ID, stranger, REPAY);
    }

    function test_CannotAssignAnUnknownDeal() public {
        escrow.setAssigner(address(this), true);
        vm.expectRevert(MinimalAssignableEscrow.BadState.selector);
        escrow.assignPayout(keccak256("nope"), financier, REPAY);
    }

    function test_CannotAssignASettledDeal() public {
        vm.prank(buyer);
        escrow.release(ID, DEAL);

        escrow.setAssigner(address(this), true);
        vm.expectRevert(MinimalAssignableEscrow.BadState.selector);
        escrow.assignPayout(ID, financier, REPAY);
    }

    /// A refund returns the BUYER's money and must not pay the assignee. Paying
    /// them here would let a payee sell a receivable and then collude with the
    /// buyer to cancel, taking the advance out of the buyer's pocket.
    function test_RefundIgnoresTheAssignment() public {
        _assignTo(assignee, REPAY);

        vm.prank(buyer);
        escrow.refund(ID);

        assertEq(usdc.balanceOf(buyer), DEAL, "buyer whole");
        assertEq(usdc.balanceOf(assignee), 0, "assignee not paid from a refund");
    }

    /* ================= the invariant, kept as a regression ================= */

    /// THE BUG THIS PRIMITIVE EXISTS TO WARN ABOUT.
    ///
    /// The financier assigns at funding time but holds the advance behind a
    /// proof-of-delivery condition. The ordinary settlement path never sets
    /// that condition, so the escrow pays the financier out of the payee's
    /// settlement while the payee's advance sits locked in the financier's
    /// contract. The payee delivers and receives NOTHING.
    ///
    /// The primitive behaves correctly throughout. The defect is entirely in
    /// the consumer, which is exactly why the invariant is documented on
    /// `assignPayout` rather than enforced by it: the escrow cannot see whether
    /// its caller paid the payee.
    function test_Regression_AssigningBeforePayingTheAdvanceStrandsThePayee() public {
        CustodyFinancier bad = new CustodyFinancier(escrow, usdc);
        escrow.setAssigner(address(bad), true);

        vm.prank(financier);
        usdc.approve(address(bad), type(uint256).max);
        vm.prank(financier);
        bad.advance(ID, PRINCIPAL, REPAY);

        // Settle the ordinary way. Nobody proves delivery, because nothing on
        // this path ever does.
        vm.prank(buyer);
        escrow.release(ID, DEAL);

        assertEq(usdc.balanceOf(payee), 0, "payee delivered and was paid nothing");
        assertEq(usdc.balanceOf(address(bad)), PRINCIPAL, "the advance is stranded in custody");
        assertEq(usdc.balanceOf(financier), REPAY, "financier took the whole settlement");
    }

    /// The same financing, done the way the docs require: assignment and
    /// advance in one transaction. Both sides end on the agreed spread.
    function test_AssigningAtomicallyWithTheAdvanceLeavesBothSidesWhole() public {
        SafeFinancier good = new SafeFinancier(escrow, usdc);
        escrow.setAssigner(address(good), true);

        vm.prank(financier);
        usdc.approve(address(good), type(uint256).max);
        vm.prank(financier);
        good.advance(ID, payee, PRINCIPAL, REPAY);

        assertEq(usdc.balanceOf(payee), PRINCIPAL, "payee has the advance immediately");

        vm.prank(buyer);
        escrow.release(ID, DEAL);

        assertEq(usdc.balanceOf(payee), PRINCIPAL, "payee keeps it");
        assertEq(usdc.balanceOf(financier), REPAY, "financier repaid by the escrow");
        assertEq(REPAY - PRINCIPAL, 10e6, "the spread is the only cost");
    }

    /* ================================ helpers ============================== */

    function _assignTo(address to, uint128 amount) internal {
        escrow.setAssigner(address(this), true);
        escrow.assignPayout(ID, to, amount);
    }
}
