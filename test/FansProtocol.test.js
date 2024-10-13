const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("FansProtocol and FansToken", function () {
  let FansProtocol, FansToken, fansProtocol, fansToken;
  let owner, addr1, addr2;

  beforeEach(async function () {
    // 获取合约工厂和签名
    FansToken = await ethers.getContractFactory("FansToken");
    FansProtocol = await ethers.getContractFactory("FansProtocol");

    [owner, addr1, addr2, ...addrs] = await ethers.getSigners();

    // 部署FansToken合约
    fansToken = await FansToken.deploy(
      "Fans Token",
      "FT",
      ethers.utils.parseUnits("10000", 18),
      "A sample fan token",
      owner.address
    );

    // 部署FansProtocol合约
    fansProtocol = await FansProtocol.deploy();
  });

  it("Should create a new FansToken correctly", async function () {
    expect(await fansToken.name()).to.equal("Fans Token");
    expect(await fansToken.symbol()).to.equal("FT");
    expect(await fansToken.balanceOf(owner.address)).to.equal(
      ethers.utils.parseUnits("10000", 18)
    );
  });

  it("Should allow users to purchase tokens", async function () {
    const tokenId = 1;
    const initialSupply = ethers.utils.parseUnits("10000", 18);
    await fansProtocol.createToken("Fans Token", "FT", initialSupply, "Sample description");

    const tokenInfo = await fansProtocol.tokens(tokenId);

    expect(tokenInfo.name).to.equal("Fans Token");
    expect(tokenInfo.symbol).to.equal("FT");

    const purchaseAmount = ethers.utils.parseEther("1"); // 用户用 1 ETH 购买
    await fansProtocol.connect(addr1).purchaseTokenAMAP(tokenId, 0, { value: purchaseAmount });

    expect(await ethers.provider.getBalance(fansProtocol.address)).to.equal(purchaseAmount);
  });

  it("Should allow users to sell tokens", async function () {
    const tokenId = 1;
    const initialSupply = ethers.utils.parseUnits("10000", 18);
    await fansProtocol.createToken("Fans Token", "FT", initialSupply, "Sample description");

    // 先购买一些 tokens
    const purchaseAmount = ethers.utils.parseEther("1");
    await fansProtocol.connect(addr1).purchaseTokenAMAP(tokenId, 0, { value: purchaseAmount });

    // 然后卖出部分 tokens
    const sellAmount = ethers.utils.parseUnits("10", 18); // 卖出 10 tokens
    // 需要先批准合约从用户地址转移代币
    await fansToken.connect(addr1).approve(fansProtocol.address, sellAmount);

    await fansProtocol.connect(addr1).sellToken(tokenId, sellAmount);

    // 检查合约中的余额
    const contractBalance = await ethers.provider.getBalance(fansProtocol.address);
    expect(contractBalance).to.be.below(purchaseAmount);
  });
});
