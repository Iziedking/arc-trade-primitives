// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USYCYieldVault} from "../src/usyc/USYCYieldVault.sol";

contract MockToken is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

/// Teller stand-in that enforces the thing everyone gets wrong: entitlement is
/// checked against the DIRECT CALLER, not the receiver and not the tx origin.
contract MockTeller {
    MockToken public usdc;
    MockToken public usyc;
    mapping(address => bool) public entitled;
    uint256 public price = 1e18;

    constructor(MockToken _usdc, MockToken _usyc) {
        usdc = _usdc;
        usyc = _usyc;
    }

    function setEntitled(address who, bool ok) external {
        entitled[who] = ok;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(entitled[msg.sender], "not entitled");
        usdc.transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / price;
        usyc.mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        require(entitled[msg.sender], "not entitled");
        usyc.burn(owner, shares);
        assets = (shares * price) / 1e18;
        usdc.transfer(receiver, assets);
    }
}

contract MockOracle {
    int256 public answer = 1e18;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 u, uint80 r, uint80 air) external {
        answer = a;
        updatedAt = u;
        roundId = r;
        answeredInRound = air;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract TestVault is USYCYieldVault {
    address public admin;
    address public keeper;

    constructor(IERC20 _usdc, address _admin, address _keeper) USYCYieldVault(_usdc) {
        admin = _admin;
        keeper = _keeper;
    }

    function _yieldAdmin() internal view override returns (address) {
        return admin;
    }

    function _yieldKeeper() internal view override returns (address) {
        return keeper;
    }
}

contract USYCYieldVaultTest is Test {
    MockToken usdc;
    MockToken usyc;
    MockTeller teller;
    MockOracle oracle;
    TestVault vault;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockToken();
        usyc = new MockToken();
        teller = new MockTeller(usdc, usyc);
        oracle = new MockOracle();
        vault = new TestVault(usdc, admin, keeper);

        vm.startPrank(admin);
        vault.setTeller(address(teller), address(usyc));
        vault.setOracle(address(oracle));
        vault.setLiquidFloor(100e6);
        vm.stopPrank();

        usdc.mint(address(vault), 1_000e6);
        usdc.mint(address(teller), 1_000_000e6);
    }

    /* ============================== entitlement ============================ */

    /// The whole reason the operator path exists. An unentitled vault cannot
    /// wrap no matter who calls it.
    function test_SweepRevertsWhenTheVaultItselfIsNotEntitled() public {
        teller.setEntitled(keeper, true); // the EOA is entitled; the vault is not
        vm.prank(keeper);
        vm.expectRevert(bytes("not entitled"));
        vault.sweepToUSYC();
    }

    function test_SweepWorksWhenTheVaultIsEntitled() public {
        teller.setEntitled(address(vault), true);
        vm.prank(keeper);
        uint256 shares = vault.sweepToUSYC();

        assertEq(shares, 900e6, "wrapped everything above the floor");
        assertEq(usdc.balanceOf(address(vault)), 100e6, "floor untouched");
        assertEq(vault.costBasisUsdc(), 900e6, "basis recorded");
    }

    function test_SweepNeverDipsBelowTheLiquidFloor() public {
        teller.setEntitled(address(vault), true);
        vm.prank(admin);
        vault.setLiquidFloor(1_000e6);

        vm.prank(keeper);
        vm.expectRevert(USYCYieldVault.NothingToSweep.selector);
        vault.sweepToUSYC();
    }

    /* ============================== yield maths ============================ */

    /// The headline correctness point. USYC appreciates continuously, so value
    /// minus zero, or value minus par, counts appreciation from before you held
    /// it. Only value minus cost basis is true.
    function test_YieldIsMeasuredAgainstCostBasisNotPar() public {
        teller.setEntitled(address(vault), true);
        teller.setPrice(1.2e18);
        oracle.set(1.2e18, block.timestamp, 1, 1);

        vm.prank(keeper);
        vault.sweepToUSYC(); // 900 USDC in at 1.20 -> 750 USYC

        assertEq(vault.costBasisUsdc(), 900e6);
        assertEq(vault.usycValueUsdc(), 900e6, "no yield the instant you buy");
        assertEq(vault.accruedYield(), 0, "and none reported");

        // Now it actually appreciates 10%.
        teller.setPrice(1.32e18);
        oracle.set(1.32e18, block.timestamp, 2, 2);

        assertEq(vault.usycValueUsdc(), 990e6);
        assertEq(vault.accruedYield(), 90e6, "only the climb since we bought");
    }

    /// Reducing the basis by the USDC received instead of proportionally would
    /// book the gain into the basis and zero out reported yield on the rest.
    function test_RedeemReducesCostBasisProportionally() public {
        teller.setEntitled(address(vault), true);
        vm.prank(keeper);
        vault.sweepToUSYC(); // 900 in at 1.0 -> 900 USYC, basis 900

        teller.setPrice(1.1e18);
        oracle.set(1.1e18, block.timestamp, 2, 2);

        vm.prank(admin);
        vault.redeemFromUSYC(450e6); // half the shares

        assertEq(vault.costBasisUsdc(), 450e6, "half the basis left");
        assertEq(vault.usycValueUsdc(), 495e6);
        assertEq(vault.accruedYield(), 45e6, "yield on the remainder survives");
    }

    /* ============================ oracle guards ============================ */

    function test_PriceRevertsWhenStale() public {
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(USYCYieldVault.StalePrice.selector);
        vault.usycPrice();
    }

    function test_PriceRevertsOnNonPositiveAnswer() public {
        oracle.set(0, block.timestamp, 1, 1);
        vm.expectRevert(USYCYieldVault.BadPrice.selector);
        vault.usycPrice();
    }

    function test_PriceRevertsWhenAnsweredInAnEarlierRound() public {
        oracle.set(1e18, block.timestamp, 5, 4);
        vm.expectRevert(USYCYieldVault.StalePrice.selector);
        vault.usycPrice();
    }

    /// A frozen testnet oracle should be a parameter change, not a redeploy or
    /// a fake feed.
    function test_MaxPriceAgeCanBeWidenedForAFrozenFeed() public {
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        vault.setMaxPriceAge(72 hours);
        assertEq(vault.usycPrice(), 1e18);
    }

    /* =========================== operator path ============================= */

    function test_WithdrawForYieldTracksTheDebtAndKeepsTheFloor() public {
        vm.prank(keeper);
        vault.withdrawForYield(500e6);

        assertEq(usdc.balanceOf(keeper), 500e6);
        assertEq(vault.outForYield(), 500e6, "recorded as out, not spent");
        assertEq(vault.totalAssetsUsdc(), 1_000e6, "still counted as an asset");
    }

    function test_WithdrawForYieldRefusesToBreakTheFloor() public {
        vm.prank(keeper);
        vm.expectRevert(USYCYieldVault.BelowLiquidFloor.selector);
        vault.withdrawForYield(950e6);
    }

    function test_DepositYieldSeparatesPrincipalFromProfit() public {
        vm.prank(keeper);
        vault.withdrawForYield(500e6);

        usdc.mint(keeper, 30e6); // the yield they earned off chain
        vm.startPrank(keeper);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositYield(530e6);
        vm.stopPrank();

        assertEq(vault.outForYield(), 0, "debt cleared");
        assertEq(usdc.balanceOf(address(vault)), 1_030e6, "principal plus profit back");
    }

    function test_OnlyKeeperCanMoveYieldFunds() public {
        vm.expectRevert(USYCYieldVault.NotYieldKeeper.selector);
        vault.withdrawForYield(1e6);
    }

    function test_OnlyAdminCanRedeem() public {
        teller.setEntitled(address(vault), true);
        vm.prank(keeper);
        vault.sweepToUSYC();

        vm.prank(keeper);
        vm.expectRevert(USYCYieldVault.NotYieldAdmin.selector);
        vault.redeemFromUSYC(1e6);
    }
}
