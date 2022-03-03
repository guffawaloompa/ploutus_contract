// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./ERC20.sol"; 
import "../Interfaces/DividendPayingTokenInterface.sol"; 
import "../Interfaces/DividendPayingTokenOptionalInterface.sol"; 
import "../Libraries/SafeMath.sol"; 
import "../Libraries/SafeMathUint.sol"; 
import "../Libraries/SafeMathInt.sol"; 
import "../Staking/IStakingPool.sol";

contract DividendPayingToken is ERC20, DividendPayingTokenInterface, DividendPayingTokenOptionalInterface {
  using SafeMath for uint256;
  using SafeMathUint for uint256;
  using SafeMathInt for int256;

  uint256 constant internal magnitude = 2**128;

  uint256 internal magnifiedDividendPerShare;

  mapping(address => int256) internal magnifiedDividendCorrections;
  mapping(address => uint256) internal withdrawnDividends;
  mapping(address => bool) internal excludeFromStakingDividend;

  mapping(address => mapping(address => uint256)) internal contractUserStaked;
  mapping(address => uint256) internal totalUserAmountStaked;
  uint256 internal totalStaked;

  uint256 public totalDividendsDistributed;

  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {

  }

  receive() external payable {
    distributeDividends();
  }

  function distributeDividends() public override payable {
    require(totalSupply().add(totalStaked) > 0);

    if (msg.value > 0) {
      magnifiedDividendPerShare = magnifiedDividendPerShare.add(
        (msg.value).mul(magnitude) / totalSupply().add(totalStaked)
      );
      emit DividendsDistributed(msg.sender, msg.value);

      totalDividendsDistributed = totalDividendsDistributed.add(msg.value);
    }
  }

  function withdrawDividend() public virtual override {
    _withdrawDividendOfUser(payable(msg.sender));
  }

  function _withdrawDividendOfUser(address payable user) internal returns (uint256) {
    uint256 _withdrawableDividend = withdrawableDividendOf(user);
    if (_withdrawableDividend > 0) {
      withdrawnDividends[user] = withdrawnDividends[user].add(_withdrawableDividend);
      emit DividendWithdrawn(user, _withdrawableDividend);
      (bool success,) = user.call{value: _withdrawableDividend, gas: 3000}("");

      if(!success) {
        withdrawnDividends[user] = withdrawnDividends[user].sub(_withdrawableDividend);
        return 0;
      }
      return _withdrawableDividend;
    }
    return 0;
  }

  function dividendOf(address _owner) public view override returns(uint256) {
    return withdrawableDividendOf(_owner);
  }

  function withdrawableDividendOf(address _owner) public view override returns(uint256) {
    return accumulativeDividendOf(_owner).sub(withdrawnDividends[_owner]);
  }

  function withdrawnDividendOf(address _owner) public view override returns(uint256) {
    return withdrawnDividends[_owner];
  }

  function accumulativeDividendOf(address _owner) public view override returns(uint256) {
    return magnifiedDividendPerShare.mul(balanceOf(_owner).add(totalUserAmountStaked[_owner])).toInt256Safe()
      .add(magnifiedDividendCorrections[_owner]).toUint256Safe() / magnitude;
  }

  function totalAmountStaked() public view returns(uint256) {
    return totalStaked;
  }

  function userAmountStaked(address account) public view returns(uint256) {
    return totalUserAmountStaked[account];
  }
  function userAmountStakedAtContract(address account, address stakingContract) public view returns(uint256) {
    return contractUserStaked[account][stakingContract];
  }

  function getCurrentStakingBalance(address account, address stakingContract) private view returns (uint256){
    return IStakingPool(stakingContract).BalanceOf(account);
  }

  function _transfer(address from, address to, uint256 value) internal virtual override {
    require(false);

    int256 _magCorrection = magnifiedDividendPerShare.mul(value).toInt256Safe();
    magnifiedDividendCorrections[from] = magnifiedDividendCorrections[from].add(_magCorrection);
    magnifiedDividendCorrections[to] = magnifiedDividendCorrections[to].sub(_magCorrection);
  }

  function _mint(address account, uint256 value) internal override {
    super._mint(account, value);

    magnifiedDividendCorrections[account] = magnifiedDividendCorrections[account]
      .sub( (magnifiedDividendPerShare.mul(value)).toInt256Safe() );
  }

  function _burn(address account, uint256 value) internal override {
    super._burn(account, value);

    magnifiedDividendCorrections[account] = magnifiedDividendCorrections[account]
      .add( (magnifiedDividendPerShare.mul(value)).toInt256Safe() );
  }

  function enterStaking(address account, address stakingContract, uint256 amount) internal {
    if(!excludeFromStakingDividend[account]){
      
      contractUserStaked[account][stakingContract] = contractUserStaked[account][stakingContract].add(amount);
      
      totalUserAmountStaked[account] = totalUserAmountStaked[account].add(amount);
      totalStaked = totalStaked.add(amount);

    //On the send to staking contract, the users has magnified didvidend correction, this negates it, since no correction is needed
      magnifiedDividendCorrections[account] = magnifiedDividendCorrections[account]
      .sub( (magnifiedDividendPerShare.mul(amount)).toInt256Safe() );
    }
  }

  function exitStakingOrClaim(address account, address stakingContract, uint256 amount) internal {

      uint256 currentStakingBalanceOfUser = getCurrentStakingBalance(account, stakingContract);
      uint256 stakingAmountChange = contractUserStaked[account][stakingContract].sub(currentStakingBalanceOfUser);
      uint256 rewards = amount.sub(stakingAmountChange);

      contractUserStaked[account][stakingContract] = contractUserStaked[account][stakingContract].sub(stakingAmountChange);
      totalUserAmountStaked[account] = totalUserAmountStaked[account].sub(stakingAmountChange);
      totalStaked = totalStaked.sub(stakingAmountChange);

      //When recieving from the staking contract, it can be both rewards plus deposits. Rewards are a new balance change, while deposites
      //are not, thus rewards must be removed from the magnified dividend correction. 
      magnifiedDividendCorrections[account] = magnifiedDividendCorrections[account]
      .add( (magnifiedDividendPerShare.mul(amount.sub(rewards))).toInt256Safe());
  }
  function _excludeFromStakingDividends (address account) internal {
    excludeFromStakingDividend[account] = true;
  }

  function _setBalance(address account, uint256 newBalance) internal {
    uint256 currentBalance = balanceOf(account);

    if(newBalance > currentBalance) {
      uint256 mintAmount = newBalance.sub(currentBalance);
      _mint(account, mintAmount);
    } else if(newBalance < currentBalance) {
      uint256 burnAmount = currentBalance.sub(newBalance);
      _burn(account, burnAmount);
    }
  }
}