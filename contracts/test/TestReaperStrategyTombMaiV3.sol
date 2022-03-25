// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../abstract/ReaperBaseStrategyv1_1.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

/**
 * @dev Deposit TOMB-MAI LP in TShareRewardsPool. Harvest TSHARE rewards and recompound.
 */
contract TestReaperStrategyTombMaiV3 is ReaperBaseStrategyv1_1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant DUMMY_CONST = 10_001;

    // 3rd-party contract addresses
    address public constant TOMB_ROUTER = address(0x6D0176C5ea1e44b08D3dd001b0784cE42F47a3A7);
    address public constant SPOOKY_ROUTER = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant TSHARE_REWARDS_POOL = address(0xcc0a87F7e7c693042a9Cc703661F5060c80ACb43);

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps.
     * {TSHARE} - Reward token for depositing LP into TShareRewardsPool.
     * {want} - Address of TOMB-MAI LP token. (lowercase name for FE compatibility)
     * {lpToken0} - TOMB (name for FE compatibility)
     * {lpToken1} - MAI (name for FE compatibility)
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant TSHARE = address(0x4cdF39285D7Ca8eB3f090fDA0C069ba5F4145B37);
    address public constant want = address(0x45f4682B560d4e3B8FF1F1b3A38FDBe775C7177b);
    address public constant lpToken0 = address(0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7);
    address public constant lpToken1 = address(0xfB98B335551a418cD0737375a2ea0ded62Ea213b);

    /**
     * @dev Paths used to swap tokens:
     * {tshareToWftmPath} - to swap {TSHARE} to {WFTM} (using SPOOKY_ROUTER)
     * {wftmToTombPath} - to swap {WFTM} to {lpToken0} (using SPOOKY_ROUTER)
     * {tombToMaiPath} - to swap half of {lpToken0} to {lpToken1} (using TOMB_ROUTER)
     */
    address[] public tshareToWftmPath;
    address[] public wftmToTombPath;
    address[] public tombToMaiPath;

    /**
     * @dev Tomb variables
     * {poolId} - ID of pool in which to deposit LP tokens
     */
    uint256 public poolId;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        tshareToWftmPath = [TSHARE, WFTM];
        wftmToTombPath = [WFTM, lpToken0];
        tombToMaiPath = [lpToken0, lpToken1];
        poolId = 2;
        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     *      It gets called whenever someone deposits in the strategy's vault contract.
     */
    function _deposit() internal override {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBalance != 0) {
            IMasterChef(TSHARE_REWARDS_POOL).deposit(poolId, wantBalance);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBal < _amount) {
            IMasterChef(TSHARE_REWARDS_POOL).withdraw(poolId, _amount - wantBal);
        }

        IERC20Upgradeable(want).safeTransfer(vault, _amount);
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     *      1. Claims {TSHARE} from the {TSHARE_REWARDS_POOL}.
     *      2. Swaps {TSHARE} to {WFTM} using {SPOOKY_ROUTER}.
     *      3. Claims fees for the harvest caller and treasury.
     *      4. Swaps the {WFTM} token for {lpToken0} using {SPOOKY_ROUTER}.
     *      5. Swaps half of {lpToken0} to {lpToken1} using {TOMB_ROUTER}.
     *      6. Creates new LP tokens and deposits.
     */
    function _harvestCore() internal override {
        IMasterChef(TSHARE_REWARDS_POOL).deposit(poolId, 0); // deposit 0 to claim rewards

        uint256 tshareBal = IERC20Upgradeable(TSHARE).balanceOf(address(this));
        _swap(tshareBal, tshareToWftmPath, SPOOKY_ROUTER);

        _chargeFees();

        uint256 wftmBal = IERC20Upgradeable(WFTM).balanceOf(address(this));
        _swap(wftmBal, wftmToTombPath, SPOOKY_ROUTER);
        uint256 tombHalf = IERC20Upgradeable(lpToken0).balanceOf(address(this)) / 2;
        _swap(tombHalf, tombToMaiPath, TOMB_ROUTER);

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
        uint256 wftmFee = (wftm.balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint256 callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            wftm.safeTransfer(msg.sender, callFeeToUser);
            wftm.safeTransfer(treasury, treasuryFeeToVault);
            wftm.safeTransfer(strategistRemitter, feeToStrategist);
        }
    }

    /**
     * @dev Core harvest function. Adds more liquidity using {lpToken0} and {lpToken1}.
     */
    function _addLiquidity() internal {
        uint256 lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));

        if (lp0Bal != 0 && lp1Bal != 0) {
            IUniswapV2Router02(TOMB_ROUTER).addLiquidity(
                lpToken0,
                lpToken1,
                lp0Bal,
                lp1Bal,
                0,
                0,
                address(this),
                block.timestamp
            );
        }
    }

    /**
     * @dev Function to calculate the total {want} held by the strat.
     *      It takes into account both the funds in hand, plus the funds in the MasterChef.
     */
    function balanceOf() public view override returns (uint256) {
        (uint256 amount, ) = IMasterChef(TSHARE_REWARDS_POOL).userInfo(poolId, address(this));
        return amount + IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        uint256 pendingReward = IMasterChef(TSHARE_REWARDS_POOL).pendingShare(poolId, address(this));
        uint256 totalRewards = pendingReward + IERC20Upgradeable(TSHARE).balanceOf(address(this));

        if (totalRewards != 0) {
            profit += IUniswapV2Router02(SPOOKY_ROUTER).getAmountsOut(totalRewards, tshareToWftmPath)[1];
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
        IMasterChef(TSHARE_REWARDS_POOL).deposit(poolId, 0); // deposit 0 to claim rewards

        uint256 tshareBal = IERC20Upgradeable(TSHARE).balanceOf(address(this));
        _swap(tshareBal, tshareToWftmPath, SPOOKY_ROUTER);

        uint256 wftmBal = IERC20Upgradeable(WFTM).balanceOf(address(this));
        _swap(wftmBal, wftmToTombPath, SPOOKY_ROUTER);
        uint256 tombHalf = IERC20Upgradeable(lpToken0).balanceOf(address(this)) / 2;
        _swap(tombHalf, tombToMaiPath, TOMB_ROUTER);

        _addLiquidity();

        (uint256 poolBal, ) = IMasterChef(TSHARE_REWARDS_POOL).userInfo(poolId, address(this));
        IMasterChef(TSHARE_REWARDS_POOL).withdraw(poolId, poolBal);

        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * Withdraws all funds leaving rewards behind.
     */
    function _reclaimWant() internal override {
        IMasterChef(TSHARE_REWARDS_POOL).emergencyWithdraw(poolId);
    }

    /**
     * @dev Gives all the necessary allowances to:
     *      - deposit {want} into {TSHARE_REWARDS_POOL}
     *      - swap {TSHARE} using {SPOOKY_ROUTER}
     *      - swap {WFTM} using {SPOOKY_ROUTER}
     *      - swap {lpToken0} using {TOMB_ROUTER}
     *      - add liquidity using {lpToken0} and {lpToken1} in {TOMB_ROUTER}
     */
    function _giveAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(TSHARE_REWARDS_POOL, 0);
        IERC20Upgradeable(want).safeApprove(TSHARE_REWARDS_POOL, type(uint256).max);
        IERC20Upgradeable(TSHARE).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(TSHARE).safeApprove(SPOOKY_ROUTER, type(uint256).max);
        IERC20Upgradeable(WFTM).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(WFTM).safeApprove(SPOOKY_ROUTER, type(uint256).max);
        IERC20Upgradeable(lpToken0).safeApprove(TOMB_ROUTER, 0);
        IERC20Upgradeable(lpToken0).safeApprove(TOMB_ROUTER, type(uint256).max);
        IERC20Upgradeable(lpToken1).safeApprove(TOMB_ROUTER, 0);
        IERC20Upgradeable(lpToken1).safeApprove(TOMB_ROUTER, type(uint256).max);
    }

    /**
     * @dev Removes all the allowances that were given above.
     */
    function _removeAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(TSHARE_REWARDS_POOL, 0);
        IERC20Upgradeable(TSHARE).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(WFTM).safeApprove(SPOOKY_ROUTER, 0);
        IERC20Upgradeable(lpToken0).safeApprove(TOMB_ROUTER, 0);
        IERC20Upgradeable(lpToken1).safeApprove(TOMB_ROUTER, 0);
    }
}
