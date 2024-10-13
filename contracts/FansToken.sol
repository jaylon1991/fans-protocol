// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract FansToken is ERC20, ERC20Burnable {
    string public description;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        string memory _description,
        address creator
    ) ERC20(name, symbol) {
        _mint(creator, initialSupply * (10 ** decimals()));
        description = _description;
    }
}
