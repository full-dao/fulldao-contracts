// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./libraries/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IJoePair.sol";
import "./interfaces/IJoeFactory.sol";

contract FullLens {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 private constant PRECISION = 1e18;

  address public immutable wavax; // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
  IJoePair public immutable wavaxUsdte; // 0xeD8CBD9F0cE3C6986b22002F03c6475CEb7a6256
  IJoePair public immutable wavaxUsdce; // 0xA389f9430876455C36478DeEa9769B7Ca4E3DDB1
  IJoePair public immutable wavaxUsdc; // 0xf4003f4efbe8691b60249e6afbd307abe7758adb
  IJoeFactory public immutable joeFactory; // 0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10
  bool private immutable isWavaxToken1InWavaxUsdte;
  bool private immutable isWavaxToken1InWavaxUsdce;
  bool private immutable isWavaxToken1InWavaxUsdc;

  constructor(
    address _wavax,
    IJoePair _wavaxUsdte,
    IJoePair _wavaxUsdce,
    IJoePair _wavaxUsdc,
    IJoeFactory _joeFactory
  ) public {
    wavax = _wavax;
    wavaxUsdte = _wavaxUsdte;
    wavaxUsdce = _wavaxUsdce;
    wavaxUsdc = _wavaxUsdc;
    joeFactory = _joeFactory;

    isWavaxToken1InWavaxUsdte = _wavaxUsdte.token1() == _wavax;
    isWavaxToken1InWavaxUsdce = _wavaxUsdce.token1() == _wavax;
    isWavaxToken1InWavaxUsdc = _wavaxUsdc.token1() == _wavax;
  }

  /// @notice Returns the price of avax in Usd
  /// @return uint256 the avax price, scaled to 18 decimals
  function getAvaxPrice() external view returns (uint256) {
    return _getAvaxPrice();
  }

  /// @notice Returns the Usd price of token
  /// @param token The address of the token
  /// @return uint256 the Usd price of token, scaled to 18 decimals
  function getTokenPrice(address token) external view returns (uint256) {
    return _getDerivedAvaxPriceOfToken(token).mul(_getAvaxPrice()).div(1e18);
  }

  /// @notice Returns the derived price of pair
  /// @param pair The address of the pair
  /// @return uint256 the pair derived price, scaled to 18 decimals
  function getPairPrice(IJoePair pair) external view returns (uint256) {
    uint256 totalSupply = pair.totalSupply();
    (uint256 reserve0, , ) = pair.getReserves();
    uint256 decimals0 = IERC20(pair.token0()).safeDecimals();
    uint256 token0Price = _getDerivedAvaxPriceOfToken(pair.token0()).mul(_getAvaxPrice()).div(1e18);

    return _scaleTo(reserve0, uint256(18).sub(decimals0)).mul(token0Price).mul(2).div(totalSupply);
  }

  /// @notice Returns the derived price of token, it needs to be paired with wavax
  /// @param token The address of the token
  /// @return uint256 the token derived price, scaled to 18 decimals
  function _getDerivedAvaxPriceOfToken(address token) private view returns (uint256) {
    if (token == wavax) {
      return PRECISION;
    }
    IJoePair pair = IJoePair(joeFactory.getPair(token, wavax));
    if (address(pair) == address(0)) {
      return 0;
    }
    // instead of testing wavax == pair.token0(), we do the opposite to save gas
    return _getDerivedTokenPriceOfPair(pair, token == pair.token1());
  }

  /// @notice Returns the price of avax in Usd internally
  /// @return uint256 the avax price, scaled to 18 decimals
  function _getAvaxPrice() private view returns (uint256) {
    return
      _getDerivedTokenPriceOfPair(wavaxUsdte, isWavaxToken1InWavaxUsdte)
        .add(_getDerivedTokenPriceOfPair(wavaxUsdce, isWavaxToken1InWavaxUsdce))
        .add(_getDerivedTokenPriceOfPair(wavaxUsdc, isWavaxToken1InWavaxUsdc))
        .div(3);
  }

  /// @notice Returns the derived price of token in the other token
  /// @param pair The address of the pair
  /// @param derivedtoken0 If price should be derived from token0 if true, or token1 if false
  /// @return uint256 the derived price, scaled to 18 decimals
  function _getDerivedTokenPriceOfPair(IJoePair pair, bool derivedtoken0) private view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
    uint256 decimals0 = IERC20(pair.token0()).safeDecimals();
    uint256 decimals1 = IERC20(pair.token1()).safeDecimals();

    if (derivedtoken0) {
      return _scaleTo(reserve0, decimals1.add(18).sub(decimals0)).div(reserve1);
    } else {
      return _scaleTo(reserve1, decimals0.add(18).sub(decimals1)).div(reserve0);
    }
  }

  /// @notice Returns the amount scaled to decimals
  /// @param amount The amount
  /// @param decimals The decimals to scale `amount`
  /// @return uint256 The amount scaled to decimals
  function _scaleTo(uint256 amount, uint256 decimals) private pure returns (uint256) {
    if (decimals == 0) return amount;
    return amount.mul(10**decimals);
  }
}
