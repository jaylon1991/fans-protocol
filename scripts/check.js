const { ethers } = require("ethers");

// 配置部分
const INFURA_PROJECT_ID = "fab352d1922c4a7d978d83bc82a111c9"; // 替换为您的 Infura 项目 ID
const provider = new ethers.JsonRpcProvider(`https://sepolia.infura.io/v3/${INFURA_PROJECT_ID}`);

// 合约地址
const routerAddress = "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008"; // Uniswap V2 Router
const pairAddress = "0x0b6470DC6fC15fac2caFbA3F125c57399Fe54862"; // 流动性池地址
const factoryAddress = "0x7E0987E5b3a30e3f2828572Bb659A548460a3003"; // Uniswap V2 Factory

const aaTokenAddress = "0x0f81457d8cFB1f6e764b1AE8121A677b41F79864"; // aa 代币地址
const eptTokenAddress = "0x780f73aF0349b12735bB67Aa91ed660e06D38623"; // EPT 代币地址

const contractAddress = "0x739f7B36fB2eB43436e7c034B2c00b6a3Ab488f7"; // 您的合约地址
const walletAddress = "0x73512531d449E4474B12dB14104CE79C59626AC8"; // 您的钱包地址

// 简化的 ERC20 ABI，仅包含所需的方法
const ERC20_ABI = [
    "function balanceOf(address owner) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)"
];

// Uniswap Factory ABI，包含 getPair 方法
const UNISWAP_FACTORY_ABI = [
    "function getPair(address tokenA, address tokenB) external view returns (address pair)"
];

async function main() {
    // 创建合约实例
    const aaToken = new ethers.Contract(aaTokenAddress, ERC20_ABI, provider);
    const eptToken = new ethers.Contract(eptTokenAddress, ERC20_ABI, provider);
    const pair = new ethers.Contract(pairAddress, ERC20_ABI, provider);
    const factory = new ethers.Contract(factoryAddress, UNISWAP_FACTORY_ABI, provider);

    try {
        // 获取 LP 代币总供应量
        const totalSupply = await pair.totalSupply();
        console.log(`LP 代币总供应量: ${ethers.formatUnits(totalSupply, 18)} LP`);

        // 获取合约地址持有的 LP 代币余额
        const lpBalance = await pair.balanceOf(contractAddress);
        console.log(`合约地址 (${contractAddress}) 的 LP 代币余额: ${ethers.formatUnits(lpBalance, 18)} LP`);

        // 获取 aa 代币余额
        const aaBalance = await aaToken.balanceOf(contractAddress);
        console.log(`合约地址 (${contractAddress}) 的 aa 代币余额: ${ethers.formatUnits(aaBalance, 18)} aa`);

        // 获取 EPT 代币余额
        const eptBalance = await eptToken.balanceOf(contractAddress);
        console.log(`合约地址 (${contractAddress}) 的 EPT 代币余额: ${ethers.formatUnits(eptBalance, 18)} EPT`);

        // 获取 aa 代币的批准额度
        const aaAllowance = await aaToken.allowance(contractAddress, routerAddress);
        console.log(`Uniswap Router (${routerAddress}) 对合约地址 (${contractAddress}) 的 aa 代币批准额度: ${ethers.formatUnits(aaAllowance, 18)} aa`);

        // 获取 EPT 代币的批准额度
        const eptAllowance = await eptToken.allowance(contractAddress, routerAddress);
        console.log(`Uniswap Router (${routerAddress}) 对合约地址 (${contractAddress}) 的 EPT 代币批准额度: ${ethers.formatUnits(eptAllowance, 18)} EPT`);

        // 获取 Pair 的储备量
        const reserves = await pair.getReserves();
        console.log(`流动性池储备量:`);
        console.log(`- reserve0 (aa): ${ethers.formatUnits(reserves.reserve0, 18)} aa`);
        console.log(`- reserve1 (EPT): ${ethers.formatUnits(reserves.reserve1, 18)} EPT`);

        // 获取 Pair 代币对
        const pairAddr = await factory.getPair(aaTokenAddress, eptTokenAddress);
        console.log(`查询到的 Pair 地址: ${pairAddr}`);
        
        // 验证 Pair 地址是否匹配
        const isPairMatch = pairAddr.toLowerCase() === pairAddress.toLowerCase();
        console.log(`Pair 地址验证: ${isPairMatch ? '匹配' : '不匹配'}`);

    } catch (error) {
        console.error("执行过程中发生错误:", error);
    }
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error("主程序执行错误:", error);
        process.exit(1);
    });