// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice USYC Teller, ERC-4626 shaped. Verified against Circle's docs at
///         developers.circle.com/tokenized/usyc/subscribe-and-redeem.
interface IUSYCTeller {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}

/// @notice Hashnote USYC/USD price oracle. `latestRoundData()` returns an
///         EIGHTEEN decimal price on Arc. Wiring it as 8 decimals, the usual
///         Chainlink assumption, reverts or misprices by 10 orders of
///         magnitude. This is the single most common way to get USYC wrong.
interface IPriceOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title USYCYieldVault
/// @notice Parks idle USDC in USYC so a protocol's float earns the T-bill yield
///         instead of sitting dead, while keeping a liquid buffer so the money
///         it owes people is always payable on demand.
///
///         Inherit it and wire `_yieldAdmin` / `_yieldKeeper` to your own roles.
///
/// ## The entitlement problem, which is the real reason this exists
///
/// USYC is permissioned. The Teller checks the **direct caller** against
/// Hashnote's entitlement list. It does not care who the beneficiary is, and it
/// does not walk a call chain. So:
///
/// - If YOUR CONTRACT is entitled, it can call `deposit`/`redeem` itself.
///   `sweepToUSYC` and `redeemFromUSYC` below are that path.
/// - If your contract is NOT entitled but an operator EOA is, the contract can
///   never wrap directly no matter how it is called. The operator has to pull
///   the USDC out, wrap it in their own name, and return the proceeds later.
///   `withdrawForYield` / `depositYield` are that path, with `outForYield`
///   tracking the debt so the accounting still closes.
///
/// Getting an entitlement is a manual process with Hashnote, and **it does not
/// transfer when you redeploy**. Plan for a redeployed contract to be
/// unentitled on day one, which is exactly why both paths exist here.
///
/// ## Measuring the yield honestly
///
/// USYC appreciates against USD continuously; its price does not reset when you
/// buy. So `holdings * currentPrice - principal` is NOT your yield. It counts
/// every cent the token appreciated before you ever held it.
///
/// Record the price you actually bought at and measure against that. This
/// contract stores `costBasisUsdc`, the USDC you put in, and exposes
/// `accruedYield()` as the excess of current value over it. If you hold USYC
/// across more than one vault or generation, sum the cost bases too: a single
/// operator pool measured against one vault's basis reports a wildly inflated
/// number.
abstract contract USYCYieldVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    /// @notice Settable rather than immutable on purpose: a frozen oracle or a
    ///         replaced Teller should be a repoint, not a redeploy. Teller and
    ///         token move together because they are one integration.
    IUSYCTeller public teller;
    IERC20 public usyc;
    IPriceOracle public oracle;

    /// @notice USDC kept liquid for outbound payments. Sweeping never dips
    ///         below this, so money owed to users is payable without unwinding
    ///         a yield position first.
    uint256 public liquidFloor;

    /// @notice USDC handed to the operator for off-chain wrapping and not yet
    ///         returned. Counts as an asset: it is out earning, not spent.
    uint256 public outForYield;

    /// @notice USDC actually converted into the USYC this contract holds. The
    ///         denominator for any honest yield figure.
    uint256 public costBasisUsdc;

    /// @notice How stale an oracle answer may be before reads revert. Default
    ///         24h matches USYC's NAV cadence. Testnets with a frozen oracle
    ///         can widen it rather than repointing to a fake feed.
    uint256 public maxPriceAge = 24 hours;

    event TellerSet(address indexed teller, address indexed usyc);
    event OracleSet(address indexed oracle);
    event LiquidFloorSet(uint256 floorAmount);
    event MaxPriceAgeSet(uint256 secs);
    event SweptToUSYC(uint256 usdcIn, uint256 usycOut);
    event RedeemedFromUSYC(uint256 usycIn, uint256 usdcOut);
    event WithdrawnForYield(address indexed keeper, uint256 amount, uint256 outForYieldAfter);
    event DepositedFromYield(
        address indexed keeper, uint256 amount, uint256 outForYieldAfter, uint256 surplus
    );

    error NotYieldAdmin();
    error NotYieldKeeper();
    error TellerNotSet();
    error OracleNotSet();
    error ZeroAmount();
    error NothingToSweep();
    error BelowLiquidFloor();
    error StalePrice();
    error BadPrice();

    /// @dev Sets adapters and parameters. Redeems. Your owner or multisig.
    function _yieldAdmin() internal view virtual returns (address);

    /// @dev Runs the routine sweep and the off-chain yield round trip. The
    ///      entitled EOA, when the contract itself is not entitled.
    function _yieldKeeper() internal view virtual returns (address);

    modifier onlyYieldAdmin() {
        if (msg.sender != _yieldAdmin()) revert NotYieldAdmin();
        _;
    }

    modifier onlyYieldKeeper() {
        if (msg.sender != _yieldKeeper()) revert NotYieldKeeper();
        _;
    }

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    // ============================ Configuration ============================

    /// @notice Teller and token move together; they are one integration. Zero
    ///         disables wrapping without disturbing anything already held.
    function setTeller(address _teller, address _usyc) external onlyYieldAdmin {
        teller = IUSYCTeller(_teller);
        usyc = IERC20(_usyc);
        emit TellerSet(_teller, _usyc);
    }

    function setOracle(address _oracle) external onlyYieldAdmin {
        oracle = IPriceOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setLiquidFloor(uint256 floorAmount) external onlyYieldAdmin {
        liquidFloor = floorAmount;
        emit LiquidFloorSet(floorAmount);
    }

    function setMaxPriceAge(uint256 secs) external onlyYieldAdmin {
        if (secs == 0) revert ZeroAmount();
        maxPriceAge = secs;
        emit MaxPriceAgeSet(secs);
    }

    // ============================ Oracle reads =============================

    /// @notice USYC/USD price, 18 decimals. Reverts rather than returning a
    ///         number nobody should act on: a non-positive answer, an answer
    ///         older than `maxPriceAge`, or one from a superseded round.
    ///
    ///         Every one of those has a real failure behind it. A zero price
    ///         values the whole position at nothing; a stale price prices a
    ///         redemption off yesterday's NAV; an out-of-round answer is the
    ///         feed telling you it has not settled yet.
    function usycPrice() public view returns (uint256) {
        if (address(oracle) == address(0)) revert OracleNotSet();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (answeredInRound < roundId) revert StalePrice();
        // forge-lint flags the block.timestamp comparison. Staleness is measured
        // in hours against a NAV feed that updates daily, so the seconds a
        // validator could shift it by cannot change the outcome.
        if (updatedAt == 0 || block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        // Safe: `answer <= 0` already reverted above, so this is positive.
        return uint256(answer);
    }

    /// @notice Current USDC value of the USYC held. Price is 18 decimals and
    ///         USYC is 6, so the product is scaled back down by 1e18.
    function usycValueUsdc() public view returns (uint256) {
        if (address(usyc) == address(0)) return 0;
        uint256 shares = usyc.balanceOf(address(this));
        if (shares == 0) return 0;
        return (shares * usycPrice()) / 1e18;
    }

    /// @notice Everything this contract controls: liquid USDC, the USYC
    ///         position at market, and USDC out with the operator.
    function totalAssetsUsdc() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + usycValueUsdc() + outForYield;
    }

    /// @notice Yield earned SINCE THIS CONTRACT BOUGHT, which is the only
    ///         figure that is true. Measured against cost basis, not against
    ///         zero and not against par. Zero rather than negative if the
    ///         position is briefly underwater on rounding.
    function accruedYield() public view returns (uint256) {
        uint256 value = usycValueUsdc();
        return value > costBasisUsdc ? value - costBasisUsdc : 0;
    }

    // ===================== Direct path (contract entitled) =================

    /// @notice Wrap idle USDC above the liquid floor into USYC. Keeper-only.
    ///         Requires THIS CONTRACT to be entitled with Hashnote; if only an
    ///         operator EOA is, use `withdrawForYield` instead.
    function sweepToUSYC() external onlyYieldKeeper returns (uint256 usycOut) {
        if (address(teller) == address(0)) revert TellerNotSet();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal <= liquidFloor) revert NothingToSweep();

        uint256 toSweep = bal - liquidFloor;
        usdc.forceApprove(address(teller), toSweep);
        usycOut = teller.deposit(toSweep, address(this));

        costBasisUsdc += toSweep;
        emit SweptToUSYC(toSweep, usycOut);
    }

    /// @notice Redeem USYC back to USDC. Admin-only, because unwinding a yield
    ///         position is a treasury decision rather than a routine one.
    ///
    ///         Cost basis is reduced PROPORTIONALLY to the shares redeemed, not
    ///         by the USDC received. Reducing it by the proceeds would book the
    ///         gain into the basis and quietly zero out the reported yield on
    ///         the remainder.
    function redeemFromUSYC(uint256 usycAmount) external onlyYieldAdmin returns (uint256 usdcOut) {
        if (address(teller) == address(0)) revert TellerNotSet();
        if (usycAmount == 0) revert ZeroAmount();

        uint256 heldBefore = usyc.balanceOf(address(this));
        usyc.forceApprove(address(teller), usycAmount);
        usdcOut = teller.redeem(usycAmount, address(this), address(this));

        if (heldBefore > 0) {
            uint256 basisOut = (costBasisUsdc * usycAmount) / heldBefore;
            costBasisUsdc = costBasisUsdc > basisOut ? costBasisUsdc - basisOut : 0;
        }
        emit RedeemedFromUSYC(usycAmount, usdcOut);
    }

    // ================= Operator path (only the EOA entitled) ===============

    /// @notice Hand USDC to the entitled operator so they can wrap it in their
    ///         own name. Never dips below the liquid floor. The amount is
    ///         recorded in `outForYield` and still counts as an asset, because
    ///         it is out earning rather than spent.
    ///
    ///         This is a trusted role by construction: the operator holds the
    ///         USDC until they return it. Use a multisig, and cap or rate-limit
    ///         it in your subclass if the float is large.
    function withdrawForYield(uint256 amount) external onlyYieldKeeper {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal < amount || bal - amount < liquidFloor) revert BelowLiquidFloor();

        outForYield += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit WithdrawnForYield(msg.sender, amount, outForYield);
    }

    /// @notice Return USDC from the operator. Anything above what went out is
    ///         the yield earned and is reported separately, so a caller can
    ///         tell a repayment from a profit without diffing balances.
    function depositYield(uint256 amount) external onlyYieldKeeper {
        if (amount == 0) revert ZeroAmount();

        uint256 principalBack = amount > outForYield ? outForYield : amount;
        uint256 surplus = amount - principalBack;
        outForYield -= principalBack;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedFromYield(msg.sender, amount, outForYield, surplus);
    }
}
