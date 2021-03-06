// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint wad) external;
}