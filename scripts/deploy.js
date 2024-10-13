async function main() {
    // Get the contract factory for FansProtocol
    const FansProtocol = await ethers.getContractFactory("FansProtocol");
  
    // Deploy the contract
    const fansProtocol = await FansProtocol.deploy();
  
    // Wait for the contract to be deployed (mined)
    await fansProtocol.deployTransaction.wait();
  
    // Output the deployed contract address
    console.log("FansProtocol deployed to:", fansProtocol.address);
  }
  
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
  