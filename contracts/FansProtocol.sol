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
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract FansProtocol is Ownable, ReentrancyGuard {
    // Bonding Curve parameters
    uint256 constant A = 1073000191;
    uint256 constant B = 32190005730;
    uint256 public constant MARKET_CAP_THRESHOLD = 60000 ether; // Adjusted as per ETH price
    uint256 public totalEPTCollected;
    bool public isDEXPhase;

    // Platform fees
    uint256 public constant PLATFORM_FEE_BP = 100; // 1% (basis points)
    uint256 public constant DEX_FEE_BP = 50; // 0.5% (basis points)

    // Uniswap V2 Router address (Ethereum mainnet)
    address private constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IUniswapV2Router02 public uniswapRouter;

    // Events
    event TokenCreate(
        address indexed creator,
        address token,
        uint256 requestId,
        string name,
        string symbol,
        uint256 totalSupply,
        uint256 launchTime
    );
    event TokenPurchase(
        address indexed token,
        address indexed account,
        uint256 tokenAmount,
        uint256 etherAmount
    );
    event TokenSale(
        address indexed token,
        address indexed account,
        uint256 tokenAmount,
        uint256 etherAmount
    );
    event LiquidityAdded(
        address indexed token,
        uint256 tokenAmount,
        uint256 etherAmount,
        uint256 liquidity
    );

    // Structs
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        address creator;
        string description;
        uint256 launchTime;
        uint256 totalSupply;
        uint256 virtualLiquidity; // Denominated in ETH
        uint256 tradingVolume;    // Denominated in tokens
    }

    uint256 public tokenCount;
    mapping(uint256 => TokenInfo) public tokens;

    constructor() Ownable(msg.sender) {
        uniswapRouter = IUniswapV2Router02(UNISWAP_V2_ROUTER);
    }

    // Create new fan token
    function createToken(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        string memory description
    ) external payable returns (address) {
        require(!isDEXPhase, "Cannot create tokens in DEX phase");
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "Invalid name or symbol");
        require(initialSupply > 0, "Initial supply must be greater than zero");

        FansToken token = new FansToken(name, symbol, initialSupply, description, address(this));
        tokenCount += 1;

        tokens[tokenCount] = TokenInfo({
            tokenAddress: address(token),
            name: name,
            symbol: symbol,
            creator: msg.sender,
            description: description,
            launchTime: block.timestamp,
            totalSupply: initialSupply * (10 ** token.decimals()),
            virtualLiquidity: msg.value,
            tradingVolume: 0
        });

        emit TokenCreate(
            msg.sender,
            address(token),
            tokenCount,
            name,
            symbol,
            initialSupply,
            block.timestamp
        );
        
        return address(token);
    }

    // Purchase tokens: User pays ETH to buy fan tokens
    function purchaseTokenAMAP(uint256 tokenId, uint256 minAmount) external payable nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");
        require(msg.value > 0, "Ether amount must be greater than zero");

        uint256 funds = msg.value;

        // Calculate x value (amount of ETH already collected)
        uint256 x = tokenInfo.virtualLiquidity;
        uint256 denominator = 30 + (12 * x);
        require(denominator != 0, "Denominator cannot be zero");

        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / denominator); // y is price per token in wei

        // Calculate token amount to transfer based on funds
        // Ensure that tokenAmount is in smallest unit by considering token decimals
        uint256 tokenDecimals = IERC20Metadata(tokenInfo.tokenAddress).decimals();
        uint256 tokenAmount = (funds * (10 ** tokenDecimals)) / y; // tokens with tokenDecimals

        require(tokenAmount >= minAmount, "Slippage too high"); // minAmount is in smallest unit

        // Calculate platform fee
        uint256 fee = (funds * PLATFORM_FEE_BP) / 10000;
        uint256 netFunds = funds - fee;
        totalEPTCollected += netFunds;

        // Check if the contract has enough tokens to transfer
        IERC20 fansToken = IERC20(tokenInfo.tokenAddress);
        uint256 contractTokenBalance = fansToken.balanceOf(address(this));
        require(contractTokenBalance >= tokenAmount, "ERC20InsufficientBalance");

        // Transfer tokens to user
        fansToken.transfer(msg.sender, tokenAmount);

        // Update virtual liquidity and trading volume
        tokenInfo.virtualLiquidity += netFunds;
        tokenInfo.tradingVolume += tokenAmount;

        // Refund excess Ether if any
        uint256 refund = funds - netFunds;
        if (refund > 0) {
            (bool success, ) = payable(msg.sender).call{value: refund}("");
            require(success, "Refund failed");
        }

        // Check if market cap threshold is reached
        checkMarketCap(tokenId);

        emit TokenPurchase(tokenInfo.tokenAddress, msg.sender, tokenAmount, netFunds);
    }

    // Purchase tokens: User specifies purchase amount
    function purchaseToken(uint256 tokenId, uint256 amount) external payable nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        require(amount > 0, "Amount must be greater than zero");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");
        require(msg.value > 0, "Ether amount must be greater than zero");

        // Calculate x value (amount of ETH already collected)
        uint256 x = tokenInfo.virtualLiquidity;
        uint256 denominator = 30 + (12 * x);
        require(denominator != 0, "Denominator cannot be zero");

        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / denominator);

        // Calculate required funds
        uint256 requiredFunds = amount * y; // Ether required in wei
        require(msg.value >= requiredFunds, "Insufficient Ether sent");

        // Calculate fee
        uint256 fee = (requiredFunds * PLATFORM_FEE_BP) / 10000;
        uint256 netFunds = requiredFunds - fee;
        totalEPTCollected += netFunds;

        // Transfer tokens to user
        FansToken(tokenInfo.tokenAddress).transfer(msg.sender, amount);

        // Update virtual liquidity and trading volume
        tokenInfo.virtualLiquidity += netFunds;
        tokenInfo.tradingVolume += amount;

        // Refund excess Ether
        if (msg.value > requiredFunds) {
            uint256 refund = msg.value - requiredFunds;
            payable(msg.sender).transfer(refund);
        }

        // Check if market cap threshold is reached
        checkMarketCap(tokenId);

        emit TokenPurchase(tokenInfo.tokenAddress, msg.sender, amount, netFunds);
    }


    // Sell tokens: User sells fan tokens back to the contract for ETH
    function sellToken(uint256 tokenId, uint256 amount) external nonReentrant {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        require(amount > 0, "Amount must be greater than zero");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Calculate x value (amount of ETH already collected)
        uint256 x = tokenInfo.virtualLiquidity;
        uint256 denominator = 30 + (12 * x);
        require(denominator != 0, "Denominator cannot be zero");

        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / denominator);

        // Calculate ETH amount
        uint256 etherAmount = (amount * y) / 1e18;
        require(address(this).balance >= etherAmount, "Insufficient ETH in contract");

        // Calculate fee
        uint256 fee = (etherAmount * PLATFORM_FEE_BP) / 10000;
        uint256 netEther = etherAmount - fee;

        // Update virtual liquidity and trading volume before external calls
        tokenInfo.virtualLiquidity -= netEther;
        tokenInfo.tradingVolume += amount;
        totalEPTCollected -= netEther;

        // Transfer tokens from user to contract and burn them
        FansToken(tokenInfo.tokenAddress).transferFrom(msg.sender, address(this), amount);
        FansToken(tokenInfo.tokenAddress).burn(amount);

        // Transfer ETH to user
        payable(msg.sender).transfer(netEther);

        emit TokenSale(tokenInfo.tokenAddress, msg.sender, amount, netEther);
    }

    // Calculate token amount required for purchase (based on Bonding Curve)
    function getTokenAmount(uint256 funds, uint256 x) public pure returns (uint256) {
        uint256 denominator = 30 + (12 * x);
        require(denominator != 0, "Denominator cannot be zero");
        uint256 y = A - (B / denominator);
        return (funds * 1e18) / y; // Token amount in wei
    }

    // Calculate funds required to sell tokens (based on Bonding Curve)
    function getFundsAmount(uint256 amount, uint256 x) public pure returns (uint256) {
        uint256 denominator = 30 + (12 * x);
        require(denominator != 0, "Denominator cannot be zero");
        uint256 y = A - (B / denominator);
        return (amount * y) / 1e18; // Ether amount in wei
    }

    // Check if market cap threshold is reached, if so, transition to DEX phase
    function checkMarketCap(uint256 tokenId) internal {
        TokenInfo storage tokenInfo = tokens[tokenId];
        uint256 marketCap = tokenInfo.virtualLiquidity; // Adjust as per actual market cap calculation

        if (marketCap >= MARKET_CAP_THRESHOLD && !isDEXPhase) {
            isDEXPhase = true;
            // Transfer remaining fan tokens and collected EPT to Trading Protocol to form permanent LP
            transferToTradingProtocol(tokenId);
        }
    }

    // Add tokens and ETH to Uniswap liquidity pool
    function transferToTradingProtocol(uint256 tokenId) internal {
        TokenInfo storage tokenInfo = tokens[tokenId];
        uint256 tokenAmount = FansToken(tokenInfo.tokenAddress).balanceOf(address(this));
        uint256 ethAmount = address(this).balance;

        if (tokenAmount > 0 && ethAmount > 0) {
            // Approve Uniswap Router to spend tokens
            FansToken(tokenInfo.tokenAddress).approve(address(uniswapRouter), tokenAmount);

            // Add liquidity
            (uint amountToken, uint amountETH, uint liquidity) = uniswapRouter.addLiquidityETH{value: ethAmount}(
                tokenInfo.tokenAddress,
                tokenAmount,
                0, // Accept any amount of tokens
                0, // Accept any amount of ETH
                address(this), // Liquidity tokens held by the contract itself
                block.timestamp
            );

            emit LiquidityAdded(tokenInfo.tokenAddress, amountToken, amountETH, liquidity);
        }
    }

    // Add liquidity to DEX, users can use this function to add liquidity and earn fee income
    function addLiquidity(uint256 tokenId, uint256 tokenAmount) external payable nonReentrant {
        require(isDEXPhase, "Liquidity can only be added in DEX phase");
        require(tokenAmount > 0, "Token amount must be greater than zero");
        require(msg.value > 0, "Ether amount must be greater than zero");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Transfer tokens from user to contract
        FansToken(tokenInfo.tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);

        // Approve Uniswap Router to spend tokens
        FansToken(tokenInfo.tokenAddress).approve(address(uniswapRouter), tokenAmount);

        // Add liquidity
        (uint amountToken, uint amountETH, uint liquidity) = uniswapRouter.addLiquidityETH{value: msg.value}(
            tokenInfo.tokenAddress,
            tokenAmount,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            msg.sender, // Liquidity tokens sent to the user
            block.timestamp
        );

        // Refund excess tokens to user
        uint256 remainingTokens = FansToken(tokenInfo.tokenAddress).balanceOf(address(this));
        if (remainingTokens > 0) {
            FansToken(tokenInfo.tokenAddress).transfer(msg.sender, remainingTokens);
        }

        emit LiquidityAdded(tokenInfo.tokenAddress, amountToken, amountETH, liquidity);
    }

    // Withdraw platform fees to platform address
    function withdrawFees(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount <= address(this).balance, "Insufficient balance");
        to.transfer(amount);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
