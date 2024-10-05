// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
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

contract FansProtocol is Ownable {
    // Bonding Curve parameters
    uint256 constant A = 1073000191;
    uint256 constant B = 32190005730;
    uint256 public constant MARKET_CAP_THRESHOLD = 60000 ether; // 60,000 USD, needs to be adjusted based on ETH price
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
        uint256 virtualLiquidity;
        uint256 tradingVolume;
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
    ) external returns (address) {
        require(!isDEXPhase, "Cannot create tokens in DEX phase");

        FansToken token = new FansToken(name, symbol, initialSupply, description, msg.sender);
        tokenCount += 1;

        tokens[tokenCount] = TokenInfo({
            tokenAddress: address(token),
            name: name,
            symbol: symbol,
            creator: msg.sender,
            description: description,
            launchTime: block.timestamp,
            totalSupply: initialSupply,
            virtualLiquidity: 0,
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
    function purchaseTokenAMAP(uint256 tokenId, uint256 funds, uint256 minAmount) external payable {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Calculate x value (amount of tokens already paid)
        uint256 x = tokenInfo.virtualLiquidity;
        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / (30 + (12 * x)));

        // Calculate token amount
        uint256 tokenAmount = (funds * 1e18) / y; // Assuming y is priced in wei
        require(tokenAmount >= minAmount, "Slippage too high");

        // Calculate fee
        uint256 fee = (funds * PLATFORM_FEE_BP) / 10000;
        uint256 netFunds = funds - fee;
        totalEPTCollected += netFunds;

        // Transfer ETH to contract
        // Already received by payable function

        // Mint tokens to user
        FansToken(tokenInfo.tokenAddress).transfer(msg.sender, tokenAmount);

        // Update virtual liquidity and trading volume
        tokenInfo.virtualLiquidity += netFunds;
        tokenInfo.tradingVolume += tokenAmount;

        // Check if market cap threshold is reached
        checkMarketCap(tokenId);

        emit TokenPurchase(tokenInfo.tokenAddress, msg.sender, tokenAmount, netFunds);
    }

    // Purchase tokens: User specifies purchase amount
    function purchaseToken(uint256 tokenId, uint256 amount, uint256 maxFunds) external payable {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Calculate x value (amount of tokens already paid)
        uint256 x = tokenInfo.virtualLiquidity;
        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / (30 + (12 * x)));

        // Calculate required funds
        uint256 funds = (amount * y) / 1e18; // Assuming y is priced in wei
        require(funds <= maxFunds, "Exceeds max funds");

        // Calculate fee
        uint256 fee = (funds * PLATFORM_FEE_BP) / 10000;
        uint256 netFunds = funds - fee;
        totalEPTCollected += netFunds;

        // Transfer ETH to contract
        // Already received by payable function

        // Mint tokens to user
        FansToken(tokenInfo.tokenAddress).transfer(msg.sender, amount);

        // Update virtual liquidity and trading volume
        tokenInfo.virtualLiquidity += netFunds;
        tokenInfo.tradingVolume += amount;

        // Check if market cap threshold is reached
        checkMarketCap(tokenId);

        emit TokenPurchase(tokenInfo.tokenAddress, msg.sender, amount, netFunds);
    }

    // Sell tokens: User sells fan tokens back to the contract for ETH
    function sellToken(uint256 tokenId, uint256 amount) external {
        require(!isDEXPhase, "DEX phase: Use DEX to trade");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Calculate x value (amount of tokens already paid)
        uint256 x = tokenInfo.virtualLiquidity - (amount / 1e18);
        // Calculate current price Y based on Bonding Curve formula
        uint256 y = A - (B / (30 + (12 * x)));

        // Calculate ETH amount
        uint256 etherAmount = (amount * y) / 1e18;
        require(address(this).balance >= etherAmount, "Insufficient ETH in contract");

        // Calculate fee
        uint256 fee = (etherAmount * PLATFORM_FEE_BP) / 10000;
        uint256 netEther = etherAmount - fee;
        totalEPTCollected -= netEther;

        // Transfer ETH to user
        payable(msg.sender).transfer(netEther);

        // Burn tokens
        FansToken(tokenInfo.tokenAddress).transferFrom(msg.sender, address(this), amount);
        FansToken(tokenInfo.tokenAddress).burn(amount);

        // Update virtual liquidity and trading volume
        tokenInfo.virtualLiquidity -= etherAmount;
        tokenInfo.tradingVolume += amount;

        emit TokenSale(tokenInfo.tokenAddress, msg.sender, amount, netEther);
    }

    // Calculate token amount required for purchase (based on Bonding Curve)
    function getTokenAmount(uint256 funds, uint256 x) public pure returns (uint256) {
        uint256 y = A - (B / (30 + (12 * x)));
        return (funds * 1e18) / y; // Token amount, assuming y is priced in wei
    }

    // Calculate funds required to sell tokens (based on Bonding Curve)
    function getFundsAmount(uint256 amount, uint256 x) public pure returns (uint256) {
        uint256 y = A - (B / (30 + (12 * x)));
        return (amount * y) / 1e18; // ETH amount, assuming y is priced in wei
    }

    // Check if market cap threshold is reached, if so, transition to DEX phase
    function checkMarketCap(uint256 tokenId) internal {
        TokenInfo storage tokenInfo = tokens[tokenId];
        uint256 marketCap = tokenInfo.virtualLiquidity; // This needs to be adjusted based on actual market cap calculation method

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
                0, // Set to 0 to accept any amount of tokens
                0, // Set to 0 to accept any amount of ETH
                owner(), // Liquidity token recipient
                block.timestamp
            );

            emit LiquidityAdded(tokenInfo.tokenAddress, amountToken, amountETH, liquidity);
        }
    }

    // Add liquidity to DEX, users can use this function to add liquidity and earn fee income
    function addLiquidity(uint256 tokenId, uint256 amount, uint256 ethAmount) external payable {
        require(isDEXPhase, "Liquidity can only be added in DEX phase");
        TokenInfo storage tokenInfo = tokens[tokenId];
        require(tokenInfo.tokenAddress != address(0), "Invalid token");

        // Transfer tokens to contract
        FansToken(tokenInfo.tokenAddress).transferFrom(msg.sender, address(this), amount);

        // Approve Uniswap Router to spend tokens
        FansToken(tokenInfo.tokenAddress).approve(address(uniswapRouter), amount);

        // Add liquidity
        (uint amountToken, uint amountETH, uint liquidity) = uniswapRouter.addLiquidityETH{value: ethAmount}(
            tokenInfo.tokenAddress,
            amount,
            0, // Set to 0 to accept any amount of tokens
            0, // Set to 0 to accept any amount of ETH
            msg.sender, // Liquidity token recipient
            block.timestamp
        );

        emit LiquidityAdded(tokenInfo.tokenAddress, amountToken, amountETH, liquidity);
    }

    // Withdraw platform fees to platform address
    function withdrawFees(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(address(this).balance >= amount, "Insufficient balance");
        to.transfer(amount);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}