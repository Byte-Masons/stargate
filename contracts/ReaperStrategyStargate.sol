// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./abstract/ReaperBaseStrategyv1_1.sol";
import "./interfaces/ILPStaking.sol";
import "./interfaces/IStargateRouter.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

/**
 * @dev Deposit USDC in router, get Stargate USDC, stake in LP staking. Harvest STG rewards and recompound.
 */
contract ReaperStrategyStargate is ReaperBaseStrategyv1_1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 3rd-party contract addresses
    address public constant STARGATE_ROUTER = address(0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6);
    address public constant SPOOKY_ROUTER = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant STARGATE_LP_STAKING = address(0x224D8Fd7aB6AD4c6eb4611Ce56EF35Dec2277F03);

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps
     * {STG} - Reward token for depositing
     * {USDC} - Used for liquidity routing to get to want
     * {want} - want token the strategy is compounding
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant STG = address(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
    address public constant USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address public constant want = address(0x12edeA9cd262006cC3C4E77c90d2CD2DD4b1eb97);

    /**
     * @dev Paths used to swap tokens:
     * {rewardToWftmPath} - to swap {STG} to {WFTM} (using SPOOKY_ROUTER)
     * {rewardtoUSDCPath} - to swap {STG} to {USDC} (using SPOOKY_ROUTER)
     */
    address[] public rewardToWftmPath;
    address[] public rewardToUSDCPath;

    /**
     * @dev Stargate variables
     * {poolId} - ID of pool in which to deposit LP tokens in LPStaking contract
     * {poolId} - ID of pool in which to deposit USDC in Router contract
     */
    uint256 public poolId;
    uint256 public routerPoolId;

    /**
     * @dev Initializes the strategy. Sets parameters and saves routes.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        rewardToWftmPath = [STG, USDC, WFTM];
        rewardToUSDCPath = [STG, USDC];
        poolId = 0;
        routerPoolId = 1;
        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     *      It gets called whenever someone deposits in the strategy's vault contract.
     */
    function _deposit() internal override {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBalance != 0) {
            ILPStaking(STARGATE_LP_STAKING).deposit(poolId, wantBalance);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBal < _amount) {
            ILPStaking(STARGATE_LP_STAKING).withdraw(poolId, _amount - wantBal);
        }

        IERC20Upgradeable(want).safeTransfer(vault, _amount);
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     *      1. Claims {STG} from the {STARGATE_LP_STAKING}.
     *      2. Swaps {STG} to {WFTM} using {SPOOKY_ROUTER}.
     *      3. Claims fees for the harvest caller and treasury.
     *      4. Swaps the {WFTM} token for {sWant} using {SPOOKY_ROUTER}.
     *      5. Swaps half of {sWant} to {lpToken1} using {STARGATE_ROUTER}.
     *      6. Creates new LP tokens and deposits.
     */
    function _harvestCore() internal override {
        ILPStaking(STARGATE_LP_STAKING).deposit(poolId, 0); // deposit 0 to claim rewards
        _chargeFees();
        uint256 stgBal = IERC20Upgradeable(STG).balanceOf(address(this));
        _swap(stgBal, rewardToUSDCPath, SPOOKY_ROUTER);
        _addLiquidity();
        deposit();
    }

    /**
     * @dev Helper function to swap tokens given an {_amount}, swap {_path}, and {_router}.
     */
    function _swap(
        uint256 _amount,
        address[] memory _path,
        address _router
    ) internal {
        if (_path.length < 2 || _amount == 0) {
            return;
        }

        IUniswapV2Router02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            0,
            _path,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev Core harvest function.
     *      Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        IERC20Upgradeable wftm = IERC20Upgradeable(WFTM);
        uint256 stgFee = (IERC20Upgradeable(STG).balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        _swap(stgFee, rewardToWftmPath, SPOOKY_ROUTER);
        uint256 wftmBal = wftm.balanceOf(address(this));
        if (wftmBal != 0) {
            uint256 callFeeToUser = (wftmBal * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (wftmBal * treasuryFee) / PERCENT_DIVISOR;
            uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            wftm.safeTransfer(msg.sender, callFeeToUser);
            wftm.safeTransfer(treasury, treasuryFeeToVault);
            wftm.safeTransfer(strategistRemitter, feeToStrategist);
        }
    }

    /**
     * @dev Core harvest function. Adds more liquidity using {sWant} and {lpToken1}.
     */
    function _addLiquidity() internal {
        uint256 usdcBal = IERC20Upgradeable(USDC).balanceOf(address(this));

        if (usdcBal != 0) {
            IStargateRouter(STARGATE_ROUTER).addLiquidity(routerPoolId, usdcBal, address(this));
        }
    }

    /**
     * @dev Function to calculate the total {want} held by the strat.
     *      It takes into account both the funds in hand, plus the funds in the MasterChef.
     */
    function balanceOf() public view override returns (uint256) {
        (uint256 amount, ) = ILPStaking(STARGATE_LP_STAKING).userInfo(poolId, address(this));
        return amount + IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        uint256 pendingReward = ILPStaking(STARGATE_LP_STAKING).pendingStargate(poolId, address(this));
        uint256 totalRewards = pendingReward + IERC20Upgradeable(STG).balanceOf(address(this));

        if (totalRewards != 0) {
            profit += IUniswapV2Router02(SPOOKY_ROUTER).getAmountsOut(totalRewards, rewardToWftmPath)[1];
        }

        profit += IERC20Upgradeable(WFTM).balanceOf(address(this));

        uint256 wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        profit -= wftmFee;
    }

    /**
     * @dev Function to retire the strategy. Claims all rewards and withdraws
     *      all principal from external contracts, and sends everything back to
     *      the vault. Can only be called by strategist or owner.
     *
     * Note: this is not an emergency withdraw function. For that, see panic().
     */
    function _retireStrat() internal override {
        _harvestCore();

        (uint256 poolBal, ) = ILPStaking(STARGATE_LP_STAKING).userInfo(poolId, address(this));
        ILPStaking(STARGATE_LP_STAKING).withdraw(poolId, poolBal);

        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * Withdraws all funds leaving rewards behind.
     */
    function _reclaimWant() internal override {
        ILPStaking(STARGATE_LP_STAKING).emergencyWithdraw(poolId);
    }

    /**
     * @dev Gives all the necessary allowances to:
     *      - deposit {want} into {STARGATE_LP_STAKING}
     *      - swap {STG} using {SPOOKY_ROUTER}
     *      - swap {WFTM} using {SPOOKY_ROUTER}
     *      - swap {sWant} using {STARGATE_ROUTER}
     *      - add liquidity using {sWant} and {lpToken1} in {STARGATE_ROUTER}
     */
    function _giveAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(STARGATE_LP_STAKING, 0);
        IERC20Upgradeable(want).safeApprove(STARGATE_LP_STAKING, type(uint256).max);
        IERC20Upgradeable(STG).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(STG).safeApprove(SPOOKY_ROUTER, type(uint256).max);
        IERC20Upgradeable(USDC).safeApprove(STARGATE_ROUTER, 0);
        IERC20Upgradeable(USDC).safeApprove(STARGATE_ROUTER, type(uint256).max);
    }

    /**
     * @dev Removes all the allowances that were given above.
     */
    function _removeAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(STARGATE_LP_STAKING, 0);
        IERC20Upgradeable(STG).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(USDC).safeApprove(STARGATE_ROUTER, 0);
    }
}
