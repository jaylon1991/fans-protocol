// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FansToken.sol";

// Uniswap V2 Router interface
interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

contract FansProtocol is Ownable, ReentrancyGuard {
    IERC20 public currencyToken;

    // Bonding Curve parameters
    uint256 public constant A = 1073000191;
    uint256 public constant B = 32190005730;
    uint256 public constant PROGRESS_THRESHOLD = 263300 * 10**18; // 100% PROGRESS
    bool public isDEXPhase;

    // Platform fees
    uint256 public constant PLATFORM_FEE_BP = 50; // 0.5% (basis points)
    uint256 public constant DEX_FEE_BP = 50; // 0.5% (basis points)

    // Uniswap V2 Router address (Ethereum mainnet)
    address private constant UNISWAP_V2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
    IUniswapV2Router02 public uniswapRouter;

    uint256 public tokenCount = 1;
    uint256 public totalFeeCollected;
    mapping(uint256 => TokenInfo) public tokens;

    // Structs
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        address creator;
        uint256 tokenSold; //// Denominated in wei
        uint256 currencyCollected; // Denominated in wei
    }

    // Events
    event TokenCreation(
        uint256 tokenId, address tokenAddress, string name, string symbol, uint256 launchTime, address tokenCreator
    );

    event TokenTrade(
        bool isTokenPurchase,
        uint256 tokenId,
        address indexed tokenAddress,
        address indexed trader,
        uint256 tokenAmount,
        uint256 currencyAmount
    );

    event DEXPoolCreation(address token, uint256 amountETH, uint256 amountToken);

    constructor(IERC20 _currencyToken) Ownable(msg.sender) {
        currencyToken = _currencyToken;
        uniswapRouter = IUniswapV2Router02(UNISWAP_V2_ROUTER);
    }

    // Create new fan token
    function createToken(string memory name, string memory symbol, bytes32 _salt)
        external
        nonReentrant
        returns (address)
    {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "Invalid name or symbol");

        //user transfer fan token creation fee to contract
        require(currencyToken.balanceOf(msg.sender) >= 50 * 10**18, "Insufficient currency token");
        currencyToken.transferFrom(msg.sender, address(this), 50 * 10**18);
        totalFeeCollected += 50 * 10**18;

        FansToken token = new FansToken{salt: _salt}(name, symbol, address(this));
        require(address(token) != address(0));
        require((tokens[tokenCount]).tokenAddress == address(0), "Invalid tokenId");

        tokens[tokenCount] = TokenInfo({
            tokenAddress: address(token),
            name: name,
            symbol: symbol,
            creator: msg.sender,
            tokenSold: 0,
            currencyCollected: 0
        });

        emit TokenCreation(tokenCount, address(token), name, symbol, block.timestamp, msg.sender);

        tokenCount++;

        return address(token);
    }

    // Purchase tokens: User buy fan tokens with specified amount of currency tokens
    function purchaseTokenWithCurrency(uint256 tokenId, uint256 currencyAmount) external nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        // Check if market cap threshold is reached
        checkProgress(tokenId);

        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");
        require(
            currencyAmount > 0 && currencyToken.balanceOf(msg.sender) >= currencyAmount, "Insufficient currency token"
        );

        //user transfer currency token to contract
        currencyToken.transferFrom(msg.sender, address(this), currencyAmount);

        // Calculate platform fee
        uint256 fee = (currencyAmount * PLATFORM_FEE_BP) / 10000;
        totalFeeCollected += fee;
        uint256 netFunds = currencyAmount - fee;

        // Calculate amount of currency already collected
        uint256 x1 = tokenInfo.currencyCollected;
        uint256 y1 = tokenInfo.tokenSold;
        uint256 denominator = 30 * 10**18  + (x1 + netFunds) / 3000;

        // Calculate the supply after trade based on Bonding Curve formula
        uint256 y2 = A * 10**18 - (B * 10**36 / denominator) ;
        uint256 tokenAmount = y2 - y1;

        // avoiding too deep stack error
        {
        // Check if the contract has enough tokens to transfer
        IERC20 fansToken = IERC20(tokenInfo.tokenAddress);
        uint256 contractTokenBalance = fansToken.balanceOf(address(this));
        require(contractTokenBalance > tokenAmount, "ERC20InsufficientBalance");

        // Transfer tokens to user
        fansToken.transfer(msg.sender, tokenAmount);
        }

        // Update tokeninfo
        tokenInfo.currencyCollected += netFunds;
        tokenInfo.tokenSold += tokenAmount;

        // Check if progress threshold is reached
        checkProgress(tokenId);

        emit TokenTrade(true, tokenId, tokenInfo.tokenAddress, msg.sender, tokenAmount, currencyAmount);
    }

    // Purchase tokens: User specifies purchase amount of fan token
    function purchaseToken(uint256 tokenId, uint256 tokenAmount) external nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        // Check if progress threshold is reached
        checkProgress(tokenId);

        require(tokenAmount > 0, "Amount must be greater than zero");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Current token info
        uint256 x1 = tokenInfo.currencyCollected;
        uint256 y1 = tokenInfo.tokenSold;

        // Calculate token info after trade
        uint256 y2 = y1 + tokenAmount;

        uint256 x2 = (B * 10**36 / (A * 10**18 - y2) - 30 * 10**18) * 3000;

        // Calculate required funds
        uint256 netFunds = x2 - x1; // Currency token required in wei

        // Calculate fee
        uint256 fee = (netFunds * PLATFORM_FEE_BP) / 10000;
        uint256 requiredFunds = netFunds + fee;

        //user transfer currency token to contract
        require(requiredFunds > 0 && currencyToken.balanceOf(msg.sender) >= requiredFunds, "Insufficient currency token");
        currencyToken.transferFrom(msg.sender, address(this), requiredFunds);

        totalFeeCollected += fee;
        tokenInfo.currencyCollected += netFunds;

        // Transfer tokens to user
        tokenInfo.tokenSold = y2;

        // Check if the contract has enough tokens to transfer
        IERC20 fansToken = IERC20(tokenInfo.tokenAddress);
        uint256 contractTokenBalance = fansToken.balanceOf(address(this));
        require(contractTokenBalance > tokenAmount, "ERC20InsufficientBalance");

        FansToken(tokenInfo.tokenAddress).transfer(msg.sender, tokenAmount);

        // Check if market cap threshold is reached
        checkProgress(tokenId);

        emit TokenTrade(true, tokenId, tokenInfo.tokenAddress, msg.sender, tokenAmount, requiredFunds);
    }

    // Sell tokens: User sells fan tokens back to the contract for currency token
    function sellToken(uint256 tokenId, uint256 tokenAmount) external nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        // Check if progress threshold is reached
        checkProgress(tokenId);

        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");
        require(tokenAmount > 0 && IERC20(tokenInfo.tokenAddress).balanceOf(msg.sender) >= tokenAmount, "Insufficient fan token");

        // Calculate
        uint256 x1 = tokenInfo.currencyCollected;
        uint256 y1 = tokenInfo.tokenSold;
        uint256 y2 = y1 - tokenAmount;
        uint256 x2 = (B * 10**36 / (A * 10**18 - y2) - 30 * 10**18) * 3000;

        // Calculate currency amount to pay
        uint256 currencyToPay = x1 - x2;
        require(currencyToken.balanceOf(address(this)) >= currencyToPay, "Insufficient ETH in contract");

        // Calculate fee
        uint256 fee = (currencyToPay * PLATFORM_FEE_BP) / 10000;
        totalFeeCollected += fee;
        uint256 netCurrencyToPay = currencyToPay - fee;

        // Update toke info before external calls
        tokenInfo.currencyCollected = x2;
        tokenInfo.tokenSold = y2;

        // Transfer tokens from user to contract and burn them
        FansToken(tokenInfo.tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);

        // Transfer currency token to user
        currencyToken.transfer(msg.sender, netCurrencyToPay);

        emit TokenTrade(false, tokenId, tokenInfo.tokenAddress, msg.sender, tokenAmount, currencyToPay);
    }

    // Check if market cap threshold is reached, if so, transition to DEX phase
    function checkProgress(uint256 tokenId) internal {
        TokenInfo storage tokenInfo = tokens[tokenId];

        if (tokenInfo.currencyCollected >= PROGRESS_THRESHOLD) {
            isDEXPhase = true;
        }

        if(isDEXPhase) {
            // Transfer remaining fan tokens and collected ether to Trading Protocol to form permanent LP
            transferToDEX(tokenId);
        }
    }

    // Add tokens and ETH to Uniswap liquidity pool
    function transferToDEX(uint256 tokenId) internal {
        TokenInfo storage tokenInfo = tokens[tokenId];
        uint256 tokenAmount = FansToken(tokenInfo.tokenAddress).balanceOf(address(this));
        totalFeeCollected += 20000 * 10**18; // DEX Listing fee
        uint256 currencyAmount = tokenInfo.currencyCollected - 20000 * 10**18;

        if (tokenAmount > 0 && currencyAmount > 0) {
            // Approve Uniswap Router to spend tokens
            FansToken(tokenInfo.tokenAddress).approve(address(uniswapRouter), tokenAmount);

            // Add liquidity
            uniswapRouter.addLiquidityETH{value: currencyAmount}(
                tokenInfo.tokenAddress,
                tokenAmount,
                0, // Accept any amount of fan tokens
                0, // Accept any amount of currency token
                address(this), // Liquidity tokens held by the contract itself
                block.timestamp
            );

            emit DEXPoolCreation(tokenInfo.tokenAddress, tokenAmount, currencyAmount);
        }
    }

    // Withdraw platform fees to platform address
    function withdrawFees(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount <= totalFeeCollected, "Insufficient balance");
        currencyToken.transfer(to, amount);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
