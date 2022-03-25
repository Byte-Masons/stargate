// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

interface ILPStaking {
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    function userInfo(uint256 _poolId, address _userAddress) external view returns (uint256 amount, uint256 rewardDebt);

    function deposit(uint256 _pid, uint256 _amount) public;

    function withdraw(uint256 _pid, uint256 _amount) public;

    function emergencyWithdraw(uint256 _pid) public;

    function pendingStargate(uint256 _pid, address _user) external view returns (uint256);
}
