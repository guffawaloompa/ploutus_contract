// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;


interface IStakingPool {
    
    function BalanceOf(address user) external view returns (uint256);

    function TotalStaked() external view returns (uint256);

}