// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

interface IFullToken {
  // FULL specific functions
  function mint(address _to, uint256 _amount) external;

  // Generic ERC20 functions
  function totalSupply() external view returns (uint256);

  function balanceOf(address account) external view returns (uint256);

  function transfer(address recipient, uint256 amount) external returns (bool);

  function allowance(address owner, address spender) external view returns (uint256);

  function approve(address spender, uint256 amount) external returns (bool);

  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) external returns (bool);

  // Getter functions
  function startReleaseBlock() external view returns (uint256);

  function endReleaseBlock() external view returns (uint256);

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
}
