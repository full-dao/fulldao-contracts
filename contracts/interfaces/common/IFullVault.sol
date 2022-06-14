// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

interface IFullVault {
  function vaultId() external returns (uint256);

  function totalSupply() external returns (uint256);

  function updatePool() external;

  function deposit(uint256 _amount) external;
}
