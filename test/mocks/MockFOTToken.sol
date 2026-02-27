// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFOTToken is ERC20 {
    uint256 public feeBasisPoints;

    constructor(string memory name_, string memory symbol_, uint256 feeBps) ERC20(name_, symbol_) {
        feeBasisPoints = feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBasisPoints) / 10000;
        _transfer(msg.sender, to, amount - fee);
        _burn(msg.sender, fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * feeBasisPoints) / 10000;
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        return true;
    }
}
