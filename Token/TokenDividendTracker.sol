// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "../TokenUtility/Ownable.sol";
import "./DividendPayingToken.sol";
import "../Libraries/SafeMath.sol";
import "../Libraries/SafeMathInt.sol";
import "../TokenUtility/IterableMapping.sol";

contract TokenDividendTracker is DividendPayingToken, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    IterableMapping.Map private stakingUserMap;
    IterableMapping.Map private stakingContractsMap;

    mapping (address => bool) public excludedFromDividends;
    mapping (address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public minimumTokenBalanceForDividends;
    uint256 public lastProcessedIndex;

    event ExcludeFromDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(address indexed account, uint256 amount, bool indexed automatic);
    event AddedToDividendsAgain(address indexed account);

    constructor() DividendPayingToken("xPloutus", "xPLOU") {
    	claimWait = 3600;
        minimumTokenBalanceForDividends = 100000 * (10**18);
    }

    function _transfer(address, address, uint256) internal override {
        require(false, "No dividend token transfers allowed");
    }

    function withdrawDividend() public override {
        require(false, "withdrawDividend disabled. Use the 'claim' function on the main token contract.");
    }

    function updateMinimumTokenBalanceForDividends(uint256 _newMinimumBalance) external onlyOwner {
        minimumTokenBalanceForDividends = _newMinimumBalance * (10**18);
    }
    
    function excludeFromDividends(address account) external onlyOwner {
    	require(!excludedFromDividends[account], "Account already excluded from dividends.");
    	excludedFromDividends[account] = true;

    	_setBalance(account, 0);
        _excludeFromStakingDividends(account);
    	tokenHoldersMap.remove(account);

    	emit ExcludeFromDividends(account);
    }

    function _isExcludedFromDividends(address account) public view returns(bool) {
    	return excludedFromDividends[account];
    }
    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(newClaimWait >= 3600 && newClaimWait <= 172800, "claimWait must be updated to between 1 and 48 hours.");
        require(newClaimWait != claimWait, "Cannot update claimWait to same value.");
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getAccount(address _account)
        public view returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable) {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if(index >= 0) {
            if(uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(int256(lastProcessedIndex));
            }
            else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length > lastProcessedIndex ?
                                                        tokenHoldersMap.keys.length.sub(lastProcessedIndex) :
                                                        0;

                iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
            }
        }

        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ?
                                    lastClaimTime.add(claimWait) :
                                    0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp ?
                                                    nextClaimTime.sub(block.timestamp) :
                                                    0;
    }

    function getAccountAtIndex(uint256 index)
        public view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	if(index >= tokenHoldersMap.size()) {
            return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0, 0, 0, 0);
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
    	if(lastClaimTime > block.timestamp)  {
    		return false;
    	}

    	return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
    	
        uint256 newBalanceIncludingStakedTokens = newBalance.add(userAmountStaked(account));
        if(excludedFromDividends[account]) {
    		return;
    	}

    	if(newBalanceIncludingStakedTokens >= minimumTokenBalanceForDividends) {
            
            _setBalance(account, newBalance);
    		tokenHoldersMap.set(account, newBalanceIncludingStakedTokens);
    	}
    	else {
            _setBalance(account, 0);
    		tokenHoldersMap.remove(account);
    	}

    	processAccount(account, true);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
    	uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    	if(numberOfTokenHolders == 0) {
    		return (0, 0, lastProcessedIndex);
    	}

    	uint256 _lastProcessedIndex = lastProcessedIndex;
    	uint256 gasUsed = 0;
    	uint256 gasLeft = gasleft();
    	uint256 iterations = 0;
    	uint256 claims = 0;

    	while(gasUsed < gas && iterations < numberOfTokenHolders) {
    		_lastProcessedIndex++;

    		if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
    			_lastProcessedIndex = 0;
    		}

    		address account = tokenHoldersMap.keys[_lastProcessedIndex];

    		if(canAutoClaim(lastClaimTimes[account])) {
    			if(processAccount(payable(account), true)) {
    				claims++;
    			}
    		}

    		iterations++;

    		uint256 newGasLeft = gasleft();

    		if(gasLeft > newGasLeft) {
    			gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
    		}

    		gasLeft = newGasLeft;
    	}

    	lastProcessedIndex = _lastProcessedIndex;

    	return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address payable account, bool automatic) public onlyOwner returns (bool) {
        uint256 amount = _withdrawDividendOfUser(account);

    	if(amount > 0) {
    		lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
    		return true;
    	}
    	return false;
    }

    function addStakingContract(address stakingContract) external onlyOwner {
        require(!stakingContractsMap.getInserted(stakingContract), "Staking contract already added");
        stakingContractsMap.set(stakingContract, block.timestamp);
    }

    function _enterStaking(address account, address stakingContract, uint256 amountSent) external onlyOwner {
        enterStaking(account, stakingContract, amountSent);
    }

    function _exitStakingOrClaim(address account, address stakingContract, uint256 amountRecieved) external onlyOwner {
        exitStakingOrClaim(account, stakingContract, amountRecieved);
    }
    
    function _userAmountStaked(address user) public view returns (uint256) {
        return userAmountStaked(user);
    }      
    
    function _userAmountStakedAtContract(address account, address stakingContract) public view returns (uint256) {
        return userAmountStakedAtContract(account, stakingContract);
    }
    function _totalAmountStaked() public view returns (uint256) {
        return totalAmountStaked();
    }                                                                                                                                                                                                                 

    function numberOfStakingContracts() public view returns (uint256){
        return stakingContractsMap.size();
    }
}