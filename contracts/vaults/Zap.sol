// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.6.12;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import '../libraries/TransferHelper.sol';
import "../interfaces/common/IUniswapV2Pair.sol";
import "../interfaces/common/IFullRouterAVAX.sol";


interface IWrapped is IERC20Upgradeable {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

contract Zap is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== CONSTANT VARIABLES ========== */

    address public FULL;
    address public constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address public constant USDT = 0xde3A24028580884448a5397872046a019649b084;
    address public constant DAI = 0xbA7dEebBFC5fA1100Fb055a87773e1E99Cd3507a;
    address public constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    IFullRouterAVAX private ROUTER;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) private notLP;
    mapping(address => address) private routePairAddresses;
    address[] public tokens;

    /* ========== EVENT ========== */
    event ZapInToken(uint256 liquidity);

    /* ========== INITIALIZER ========== */

    function initialize(address _full, address _router) external initializer {
        __Ownable_init();
        require(owner() != address(0), "ZapETH: owner must be set");

        FULL = _full;
        ROUTER = IFullRouterAVAX(_router);
        
        // sanity check
        ROUTER.factory();
        IERC20Upgradeable(FULL).totalSupply();

        setNotLP(WAVAX);
        setNotLP(USDT);
        setNotLP(JOE);
        setNotLP(DAI);
    }

    receive() external payable {}

    /* ========== View Functions ========== */

    function isLP(address _address) public view returns (bool) {
        return !notLP[_address];
    }

    function routePair(address _address) external view returns (address) {
        return routePairAddresses[_address];
    }

    /* ========== External Functions ========== */

    function zapInToken(
        address _from,
        uint256 amount,
        address _to,
        uint256 amountOutMin
    ) external{
        uint256 liquidity = 0;
        IERC20Upgradeable(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (isLP(_to)) {
            IUniswapV2Pair pair = IUniswapV2Pair(_to);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (_from == token0 || _from == token1) {
                // swap half amount for other
                address other = _from == token0 ? token1 : token0;
                _approveTokenIfNeeded(other);
                uint256 sellAmount = amount.div(2);
                uint256 otherAmount = _swap(_from, sellAmount, other, address(this), amountOutMin);
                (,,liquidity) = ROUTER.addLiquidity(
                    _from,
                    other,
                    amount.sub(sellAmount),
                    otherAmount,
                    0,
                    0,
                    msg.sender,
                    block.timestamp
                );
            } else {
                uint256 avaxAmount = _swapTokenForAVAX(_from, amount, address(this), amountOutMin);
                liquidity = _swapAVAXToLP(_to, avaxAmount, msg.sender, amountOutMin);
            }
        } else {
            _swap(_from, amount, _to, msg.sender, amountOutMin);
        }
        emit ZapInToken(liquidity);
    }

    function zapIn(address _to) external payable {
        _swapAVAXToLP(_to, msg.value, msg.sender, 0);
    }

    // function zapOut(address _from, uint256 amount) external {
    //     IERC20Upgradeable(_from).safeTransferFrom(msg.sender, address(this), amount);
    //     _approveTokenIfNeeded(_from);

    //     if (!isLP(_from)) {
    //         _swapTokenForAVAX(_from, amount, msg.sender, 0);
    //     } else {
    //         IUniswapV2Pair pair = IUniswapV2Pair(_from);
    //         address token0 = pair.token0();
    //         address token1 = pair.token1();
    //         if (token0 == WAVAX || token1 == WAVAX) {
    //             ROUTER.removeLiquidityAVAX(
    //                 token0 != WAVAX ? token0 : token1,
    //                 amount,
    //                 0,
    //                 0,
    //                 msg.sender,
    //                 block.timestamp
    //             );
    //         } else {
    //             ROUTER.removeLiquidity(token0, token1, amount, 0, 0, msg.sender, block.timestamp);
    //         }
    //     }
    // }
    function zapOutToken(address _from, uint256 amount, address _to, uint256 amountOutMin,address receiver) external payable {
        // from an LP token to an ERC20 through specified router
        IERC20Upgradeable(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        address token0 = IUniswapV2Pair(_from).token0();
        address token1 = IUniswapV2Pair(_from).token1();
        _approveTokenIfNeeded(token0);
        _approveTokenIfNeeded(token1);
        uint256 amt0;
        uint256 amt1;
        if (token0 == WAVAX || token1 == WAVAX) {
            (amt0, amt1) = ROUTER.removeLiquidityAVAX(
                token0 != WAVAX ? token0 : token1,
                amount,
                0,
                0,
                address(this),
                block.timestamp
            );
            if(_to == WAVAX){
                _swapTokenForAVAX(token0 == WAVAX ? token1 : token0, amt0, receiver, amountOutMin);
                TransferHelper.safeTransferETH(receiver, amt1);
            }else{
                _swapAVAXForToken(token0 == WAVAX ? token1 : token0, amt1, receiver, amountOutMin);
                IERC20Upgradeable(_to).safeTransfer(receiver, amt0);
            }
        } else {
            (amt0, amt1) = ROUTER.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);
            if (token0 != _to) {
                amt0 = _swap(token0, amt0, _to, address(this), amountOutMin);
            }
            if (token1 != _to) {
                amt1 = _swap(token1, amt1, _to, address(this), amountOutMin);
            }
            IERC20Upgradeable(_to).safeTransfer(receiver, amt0.add(amt1));
        }

        // if (token0 != _to && _to != WAVAX) {
        //     amt0 = _swap(token0, amt0, _to, address(this), amountOutMin);
        // }
        // if (token1 != _to && _to != WAVAX) {
        //     amt1 = _swap(token1, amt1, _to, address(this), amountOutMin);
        // }

        // if (_to == WAVAX){
        //     _swapTokenForAVAX(token0 == WAVAX ? token1 : token0, amt1, address(this), amountOutMin);
        //     TransferHelper.safeTransferETH(msg.sender, amt0.add(amt1));
        // }else{
        //     IERC20Upgradeable(_to).safeTransfer(msg.sender, amt0.add(amt1));
        // }
    }


    /* ========== Private Functions ========== */

    function _approveTokenIfNeeded(address token) private {
        if (IERC20Upgradeable(token).allowance(address(this), address(ROUTER)) == 0) {
            IERC20Upgradeable(token).safeApprove(address(ROUTER), uint256(~0));
        }
    }

    function _swapAVAXToLP(
        address lp,
        uint256 amount,
        address receiver,
        uint256 amountOutMin
    ) private returns (uint256 ) {
        uint256 liquidity=0;
        uint256 amountA=0;
        uint256 amountB=0;
        uint256 newAmount = amount;
        uint256 newAmountOutMin = amountOutMin;
        address newReceiver = receiver;
        if (!isLP(lp)) {
            _swapAVAXForToken(lp, amount, receiver, amountOutMin);
        } else {
            // lp
            IUniswapV2Pair pair = IUniswapV2Pair(lp);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WAVAX || token1 == WAVAX) {
                address token = token0 == WAVAX ? token1 : token0;
                uint256 swapValue = newAmount.div(2);
                uint256 tokenAmount = _swapAVAXForToken(token, swapValue, address(this), newAmountOutMin);
                
                _approveTokenIfNeeded(token);
                (amountA,amountB, liquidity) = ROUTER.addLiquidityAVAX{value: newAmount.sub(swapValue)}(
                    token,
                    tokenAmount,
                    0,
                    0,
                    newReceiver,
                    block.timestamp
                );
            } else {
                uint256 swapValue = amount.div(2);
                uint256 token0Amount = _swapAVAXForToken(token0, swapValue, address(this), newAmountOutMin);
                uint256 token1Amount = _swapAVAXForToken(token1, newAmount.sub(swapValue), address(this), newAmountOutMin);

                _approveTokenIfNeeded(token0);
                _approveTokenIfNeeded(token1);
                ( amountA, amountB, liquidity) = ROUTER.addLiquidity(token0, token1, token0Amount, token1Amount, 0, 0, newReceiver, block.timestamp);
            }
        }
        return liquidity;
    }

    function _swapAVAXForToken(
        address token,
        uint256 value,
        address receiver,
        uint256 amountOutMin
    ) private returns (uint256) {
        address[] memory path;

        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = WAVAX;
            path[1] = routePairAddresses[token];
            path[2] = token;
        } else {
            path = new address[](2);
            path[0] = WAVAX;
            path[1] = token;
        }

        uint256[] memory amounts = ROUTER.swapExactAVAXForTokens{value: value}(amountOutMin, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForAVAX(
        address token,
        uint256 amount,
        address receiver,
        uint256 amountOutMin
    ) private returns (uint256) {
        address[] memory path;
        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = token;
            path[1] = routePairAddresses[token];
            path[2] = WAVAX;
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = WAVAX;
        }

        uint256[] memory amounts = ROUTER.swapExactTokensForAVAX(amount, amountOutMin, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swap(
        address _from,
        uint256 amount,
        address _to,
        address receiver,
        uint256 amountOutMin
    ) private returns (uint256) {
        address intermediate = routePairAddresses[_from];
        if (intermediate == address(0)) {
            intermediate = routePairAddresses[_to];
        }

        address[] memory path;
        if (intermediate != address(0) && (_from == WAVAX || _to == WAVAX)) {
            // [WAVAX, BUSD, VAI] or [VAI, BUSD, WAVAX]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (intermediate != address(0) && (_from == intermediate || _to == intermediate)) {
            // [VAI, BUSD] or [BUSD, VAI]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] == routePairAddresses[_to]) {
            // [VAI, DAI] or [VAI, USDC]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (
            routePairAddresses[_from] != address(0) &&
            routePairAddresses[_to] != address(0) &&
            routePairAddresses[_from] != routePairAddresses[_to]
        ) {
            // routePairAddresses[xToken] = xRoute
            // [VAI, BUSD, WAVAX, xRoute, xToken]
            path = new address[](5);
            path[0] = _from;
            path[1] = routePairAddresses[_from];
            path[2] = WAVAX;
            path[3] = routePairAddresses[_to];
            path[4] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] != address(0)) {
            // [VAI, BUSD, WAVAX, BUNNY]
            path = new address[](4);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = WAVAX;
            path[3] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_to] != address(0)) {
            // [BUNNY, WAVAX, BUSD, VAI]
            path = new address[](4);
            path[0] = _from;
            path[1] = WAVAX;
            path[2] = intermediate;
            path[3] = _to;
        } else if (_from == WAVAX || _to == WAVAX) {
            // [WAVAX, BUNNY] or [BUNNY, WAVAX]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            // [USDT, BUNNY] or [BUNNY, USDT]
            path = new address[](3);
            path[0] = _from;
            path[1] = WAVAX;
            path[2] = _to;
        }

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amount, amountOutMin, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setRoutePairAddress(address asset, address route) external onlyOwner {
        routePairAddresses[asset] = route;
    }

    function setNotLP(address token) public onlyOwner {
        bool needPush = notLP[token] == false;
        notLP[token] = true;
        if (needPush) {
            tokens.push(token);
        }
    }

    function removeToken(uint256 i) external onlyOwner {
        address token = tokens[i];
        notLP[token] = false;
        tokens[i] = tokens[tokens.length - 1];
        tokens.pop();
    }

    function sweep() external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint256 amount = IERC20Upgradeable(token).balanceOf(address(this));
            if (amount > 0) {
                if (token == WAVAX) {
                    IWrapped(token).withdraw(amount);
                } else {
                    _swapTokenForAVAX(token, amount, owner(), 0);
                }
            }
        }

        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(owner()).transfer(balance);
        }
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IERC20Upgradeable(token).transfer(owner(), IERC20Upgradeable(token).balanceOf(address(this)));
    }
}
