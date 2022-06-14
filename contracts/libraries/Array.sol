// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

library Array {
  function contains(uint256[] storage array, uint256 element) internal view returns (bool) {
    if (array.length == 0) {
      return false;
    }

    for (uint256 i = 0; i < array.length; i++) {
      if (array[i] == element) return true;
    }

    return false;
  }
}
