// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FansToken is ERC20, Ownable {
    string public description;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        string memory _description,
        address creator
    ) ERC20(name, symbol) Ownable(creator) {
        _mint(creator, initialSupply * (10 ** decimals()));
        description = _description;
    }

    /**
     * @dev Allows the contract owner to burn tokens
     */
    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
}