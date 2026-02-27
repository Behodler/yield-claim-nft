// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMintable {
    function mint(address recipient, uint256 amount) external;
}
