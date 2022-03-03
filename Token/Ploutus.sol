// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./ERC20.sol";
import "../TokenUtility/Ownable.sol";
import "../Libraries/SafeMath.sol";
import "../Interfaces/IUniswapV2Router02.sol";
import "../Interfaces/IUniswapV2Factory.sol";
import "./DividendPayingToken.sol";
import "./TokenDividendTracker.sol";

contract Ploutus is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    TokenDividendTracker public dividendTracker;

    address public immutable uniswapV2Pair;
    address public liquidityWallet = 0x8b779013d5AAB2279D747207128f696e30B4E2cc;
    address public deadwallet = 0x000000000000000000000000000000000000dEaD;
    address public manualFeeWallet = 0x110194b2C00cE6C1Aeb8D8E5C9AA2d0fba5462Ff; //If there are issues with auto liquidity, manual fee distribution can be enabled.
    address public marketingWallet = 0xf7BbE3214E5598AE6B61dFb008270B436030Ef9A;
    address public ecosystemWallet = 0x10F4154917d7F3F3180380156C4D3Cb9f2bd6966; //Will be holding 45% procent of supply on launch (does not get dividend!) for ecosystem growthm like events, staking, games, competition and partnerships.

    bool private swapping;
    bool public burnEnabled = true;
    bool public tradingIsEnabled = false;
    bool public swapAndLiquifyEnabled = true;

    uint256 public swapTokensAtAmount = 500000 * (10**18); //Every 500K    
    uint256 public TLOSRewardsFee = 5;
    uint256 public liquidityFee = 2;
    uint256 public marketingFee = 1;
    uint256 public burnFee = 1;
    uint256 public totalFees = TLOSRewardsFee.add(liquidityFee).add(marketingFee).add(burnFee);
    uint256 public gasForProcessing = 300000;
    uint256 public constant MAX_FEE_RATE = 10;
    uint256 public initialSupply = 100000000 * (10**18);
    uint256 public blacklistedTokens;

    mapping (address => bool) public _isExcludedFromFees;
    mapping (address => bool) private canTransferBeforeTradingIsEnabled;
    mapping (address => bool) public liquidityPairs;
    mapping (address => bool) public stakingContracts;
    mapping (address => bool) public blackListedWallets;
    mapping (address => bool) public teamWallets;
    mapping (address => uint256) public teamWalletReleaseTime;
    
    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);
    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event AddStakingContract(address indexed account, bool excludeFromFees);
    event SetLiquidityPair(address indexed pair, bool indexed value);
    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event EcosystemWalletUpdated(address indexed newEcosystemWallet, address indexed oldEcosystemWallet);
    event MarketingWalletUpdated(address indexed newMarketingWallet, address indexed oldMarketingWallet);
    event ManualFeeWalletUpdated(address indexed newManualFeeWallet, address indexed oldManualFeeWallet);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event SendDividends(uint256 tokensSwapped, uint256 amount);
    event ProcessedDividendTracker(uint256 iterations, uint256 claims, uint256 lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);
    event SwapAndLiquifyEnabledUpdated(bool enabled);

    constructor() ERC20("Ploutus", "PLOU") {

    	dividendTracker = new TokenDividendTracker();
    	IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0xB9239AF0697C8efb42cBA3568424b06753c6da71);
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;
        _SetLiquidityPair(_uniswapV2Pair, true);

        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(0x000000000000000000000000000000000000dEaD);
        dividendTracker.excludeFromDividends(address(0x10F4154917d7F3F3180380156C4D3Cb9f2bd6966)); //Ecosystem wallet with 45% supply will NOT recieve dividends
        dividendTracker.excludeFromDividends(address(0xB9239AF0697C8efb42cBA3568424b06753c6da71));

        excludeFromFees(address(0x8b779013d5AAB2279D747207128f696e30B4E2cc), true);
        excludeFromFees(address(0x10F4154917d7F3F3180380156C4D3Cb9f2bd6966), true);
        excludeFromFees(address(this), true);
        excludeFromFees(owner(), true);

        canTransferBeforeTradingIsEnabled[owner()] = true;
        canTransferBeforeTradingIsEnabled[0x8b779013d5AAB2279D747207128f696e30B4E2cc] = true;

        //Mint can never be called again
         _mint(owner(), 100000000 * (10**18));
    }

    receive() external payable {}


    function setSwapTokensAtAmount(uint256 _swapAmount) external onlyOwner {
        swapTokensAtAmount = _swapAmount * (10**18);
    }

    function enableBurn(uint8 _burnFee) external onlyOwner {
        require(!burnEnabled, "Burn is already enabled");
        burnEnabled = true;
        burnFee = _burnFee;
    }
    
    function disableBurn() external onlyOwner {
        require(burnEnabled, "Burn is already enabled");
        burnEnabled = false;
        burnFee = 0;
    }

    function updateMinimumBalanceForDividends(uint256 newMinimumBalance) external onlyOwner {    
        dividendTracker.updateMinimumTokenBalanceForDividends(newMinimumBalance);
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function excludeFromDividends(address account) public onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    function SetLiquidityPairs(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "The LP pair cannot be removed from liquidityPairs");
        _SetLiquidityPair(pair, value);
    }

    function _SetLiquidityPair(address pair, bool value) private {
        require(liquidityPairs[pair] != value, "LP pair is already set to that value");
        liquidityPairs[pair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(pair);
        }
        emit SetLiquidityPair(pair, value);
    }

    function setSwapAndLiquify(bool _enabled) public onlyOwner {
        require(swapAndLiquifyEnabled =! _enabled, "swapAndLiquifyEnabled is already set this this boolean");
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function updateLiquidityWallet(address newLiquidityWallet) public onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "The liquidity wallet is already this address");
        excludeFromFees(newLiquidityWallet, true);
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);
        liquidityWallet = newLiquidityWallet;
    }

    function updateManualFeeWallet(address newManualFeeWallet) public onlyOwner {
        require(newManualFeeWallet != manualFeeWallet, "The manual fee wallet is already this address");
        excludeFromFees(newManualFeeWallet, true);
        emit ManualFeeWalletUpdated(newManualFeeWallet, manualFeeWallet);
        manualFeeWallet = newManualFeeWallet;
    }
    function updateMarketingWallet(address newMarketingWallet) external onlyOwner {
        require(newMarketingWallet != marketingWallet, "The marketing wallet is already this address");   
        emit MarketingWalletUpdated(newMarketingWallet, marketingWallet);
        marketingWallet = newMarketingWallet;
    }
    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue != gasForProcessing, "Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function addAccountToBlacklist(address account) external onlyOwner {
        require(!blackListedWallets[account], "Account already added to blacklist");
        blackListedWallets[account] = true;
        dividendTracker.excludeFromDividends(account);
        blacklistedTokens = blacklistedTokens.add(balanceOf(account));
    }

    function addTeamWalletAndLock(address teamWallet, uint256 lockDurationInDays) external onlyOwner {
        require(teamWallets[teamWallet] != true, "Team wallet already added");
        teamWallets[teamWallet] = true;
        teamWalletReleaseTime[teamWallet] = block.timestamp.add(lockDurationInDays * 1 days);
    }

    function updateFees(uint8 reflection, uint8 liquidity, uint8 marketing, uint8 burn) external onlyOwner {
        TLOSRewardsFee = reflection;
        liquidityFee = liquidity;
        marketingFee = marketing;
        burnFee = burn;
        totalFees = TLOSRewardsFee.add(marketingFee).add(liquidityFee).add(burnFee);
    }
    
    function addStakingContracts(address stakingContract, bool includeInDividendTracking, bool excludedFromFees) external onlyOwner {
        if(excludedFromFees){
            excludeFromFees(stakingContract, true);
        }

        //Staking contract must never get dividends, so excluding from recieving is mandatory
        dividendTracker.excludeFromDividends(stakingContract);
        stakingContracts[stakingContract] = true;

        if(includeInDividendTracking){
            dividendTracker.addStakingContract(stakingContract);
        }
        emit AddStakingContract(stakingContract, excludedFromFees);
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }     

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

	function dividendHoldingBalanceOf(address account) external view returns (uint256, uint256) {
		return (dividendTracker.balanceOf(account), dividendTracker._userAmountStaked(account));
	}
    
    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

	function processDividendTracker(uint256 gas) external {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
		dividendTracker.processAccount(payable(msg.sender), false);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function setTrading(bool enabled) external onlyOwner {
	    tradingIsEnabled = enabled;
  	}

    function userAmountStakedAtContract(address account, address stakingContract) public view returns (uint256) {
        return dividendTracker._userAmountStakedAtContract(account, stakingContract);
    }
    function totalAmountStaked() public view returns (uint256) {
        return dividendTracker._totalAmountStaked();
    }                                                                                                                                                                                                                 


    function _transfer(address from, address to, uint256 amount
    ) internal override {
        require(from != address(0), "Transfer from the zero address");
        require(to != address(0), "Transfer to the zero address");
        require(!blackListedWallets[from], "Blacklisted address");

        //Team wallets will be locked for 3 months
        if(teamWallets[from]){
            require (teamWalletReleaseTime[from] <= block.timestamp, "Error, teamwallet is locked");
        }

        if(!tradingIsEnabled) {
            require(canTransferBeforeTradingIsEnabled[from], "This account cannot send tokens until trading is enabled");
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if(stakingContracts[to] || stakingContracts[from]){
            super._transfer(from, to, amount);
            
            if (stakingContracts[to]){
                dividendTracker._enterStaking(from, to, amount);
                try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
            }else {
                dividendTracker._exitStakingOrClaim(to, from, amount);
                try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}
            }
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if(tradingIsEnabled && canSwap && !swapping && !liquidityPairs[from] && from != liquidityWallet && to != liquidityWallet) {
            
            swapping = true;

            if(swapAndLiquifyEnabled){
                
                uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(totalFees);
                swapAndLiquify(swapTokens);

                if(burnEnabled){
                    uint256 tokensToBurn = contractTokenBalance.mul(burnFee).div(totalFees);
                    burnTokens(tokensToBurn);
                }

                uint256 swapMarketingTokens = contractTokenBalance.mul(marketingFee).div(totalFees);
                swapTokensToWallet(swapMarketingTokens, marketingWallet);

                uint256 tokensForDividend = balanceOf(address(this));
                swapAndSendDividends(tokensForDividend);
                
            }
            else{
                swapTokensToWallet(balanceOf(address(this)), manualFeeWallet);
            }  
            swapping = false;
        }

        bool takeFee = tradingIsEnabled && !swapping;

        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
            uint256 fees = amount.mul(totalFees).div(100);
            amount = amount.sub(fees);
            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if(!swapping) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            } 
            catch {
            }
        }
    }
    
    function burnTokens(uint256 tokenAmount) private {
        require(burnEnabled, "burn is disabled");
        super._transfer(address(this), deadwallet, tokenAmount);
        }

    function swapAndLiquify(uint256 tokens) private {
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);
        uint256 initialBalance = address(this).balance;
        swapTokensForEth(half);
        uint256 newBalance = address(this).balance.sub(initialBalance);
        addLiquidity(otherHalf, newBalance);
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );   
    }
    
    function swapTokensToWallet(uint256 tokenAmount, address wallet) private {

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            wallet,
            block.timestamp
        );        
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            liquidityWallet,
            block.timestamp
        );        
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);
        uint256 dividends = address(this).balance;
        (bool success,) = address(dividendTracker).call{value: dividends}("");

        if(success) {
   	 		emit SendDividends(tokens, dividends);
        }
    }
}