// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;
import "../TokenUtility/Ownable.sol";
import "../TokenUtility/Pausable.sol";
import "../TokenUtility/ReentrancyGuard.sol";
import "../Libraries/SafeMath.sol";
import "../Interfaces/IERC20.sol";
import "../Libraries/SafeERC20.sol";
import "../Token/ERC20.sol";
import "./IStakingPool.sol"

contract WSGStaking is ReentrancyGuard, Pausable, Ownable, IStakingPool {
    using SafeMath for uint256;
  
    // STATE VARIABLES

    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    
    uint public lockupDuration = 1 hours;

    uint256 public rewardsDuration = 7890000; // 3 months

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint) private _userStartTime;

    uint256 private _totalStaked;
    mapping(address => uint256) private _balances;

    // CONSTRUCTOR

    constructor(
       // address _rewardsToken,
        // address _stakingToken
    ) {
        //require(_rewardsToken != address(0) &&
          //  _stakingToken != address(0), '!null');

        rewardsToken = IERC20(0xac5aC9c1b174fFF5FA8F3992F204b906Be663A3b);
        stakingToken = IERC20(0xac5aC9c1b174fFF5FA8F3992F204b906Be663A3b);
    }

    // VIEWS

    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(_totalStaked)
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            _balances[account]
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    // PUBLIC FUNCTIONS
   
    function stake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot stake 0");
    
        _userStartTime[_msgSender()] = block.timestamp;
         
        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 actualReceived = balAfter.sub(balBefore);

        _totalStaked = _totalStaked.add(actualReceived);
        _balances[msg.sender] = _balances[msg.sender].add(actualReceived);
        
        emit Staked(msg.sender, actualReceived);
    }

    function withdraw(uint256 amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot withdraw 0");
        require(block.timestamp >= _userStartTime[_msgSender()].add(lockupDuration), "Stake lock still active");
        _totalStaked = _totalStaked.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {

        require(block.timestamp >= _userStartTime[_msgSender()].add(lockupDuration), "Stake lock still active");

        withdraw(_balances[msg.sender]);
        
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function lockTimeRemailing () external view returns (uint)
    {
        if(_userStartTime[_msgSender()].add(lockupDuration) < block.timestamp){
            return 0;
        }
        else{
            return _userStartTime[_msgSender()].add(lockupDuration).sub(block.timestamp);
        }
    }

    // RESTRICTED FUNCTIONS

    function notifyRewardAmount(uint256 reward)
        external
        restricted
        updateReward(address(0))
    {
        uint256 balBefore = rewardsToken.balanceOf(address(this));
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        uint256 balAfter = rewardsToken.balanceOf(address(this));
        uint256 actualReceived = balAfter.sub(balBefore);
        require(actualReceived == reward, "Whitelist the pool to exclude fees");

        //Initialization, first time rewards set
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } 
        //Add more rewards
        else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(
            rewardRate <= balance.div(rewardsDuration),
            "Provided reward too high"
        );

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // Cannot recover the staking token or the rewards token
        require(
            tokenAddress != address(stakingToken) &&
                tokenAddress != address(rewardsToken),
            "Cannot withdraw the staking or rewards tokens"
        );
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external restricted {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    // *** MODIFIERS ***

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    modifier restricted {
        require(
            msg.sender == owner(),
            '!restricted'
        );

        _;
    }

    // EVENTS

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}