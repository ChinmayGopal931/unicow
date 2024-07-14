// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// import {BaseHook} from "v4-periphery/BaseHook.sol";
import {BaseHook} from "./forks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {console} from "forge-std/console.sol";
import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LibMulticaller} from "../lib/multicaller/src/LibMulticaller.sol";

contract UniCow is BaseHook {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();
    error LiquidityDoesntMeetMinimum();
    error LiquidityNotInWithdrwalQueue();

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct OrderObject {
        uint256 minPrice;
        uint256 deadline;
        uint256 amount;
    }

    mapping(PoolId => mapping(address => OrderObject)) public orders;

    uint128 public constant TOTAL_BIPS = 10000;

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Allow to set up the pool
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // Allow mint LP token
            beforeRemoveLiquidity: true, // Allow LP withdrawal delay and burning LP token
            afterRemoveLiquidity: false,
            beforeSwap: true, // Allow set up of dynamic swap fee
            afterSwap: true, // Allow redistribute fee and charge rent
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // Allow redistribute swap fee
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        (bool success, BeforeSwapDelta delta) = tryCOW(poolId, sender, key, params);
        if (success) {
            return (this.beforeSwap.selector, delta, 0);
        }

        // If no COW match, proceed with regular swap
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function tryCOW(PoolId poolId, address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        returns (bool, BeforeSwapDelta)
    {
        Order[] storage orderList = orders[poolId];
        for (uint256 i = 0; i < orderList.length; i++) {
            Order memory order = orderList[i];
            if (
                order.tokenIn == Currency.unwrap(params.zeroForOne ? key.currency1 : key.currency0)
                    && order.tokenOut == Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1)
                    && order.amountIn >= params.amountSpecified && order.expiry > block.timestamp
            ) {
                // Match found, execute COW
                BalanceDelta delta = BalanceDelta.wrap(0);
                if (params.zeroForOne) {
                    delta = BalanceDelta.wrap(
                        -int256(params.amountSpecified).toInt128(), int256(order.amountOut).toInt128()
                    );
                } else {
                    delta = BalanceDelta.wrap(
                        int256(order.amountOut).toInt128(), -int256(params.amountSpecified).toInt128()
                    );
                }

                // Transfer tokens
                IERC20(order.tokenIn).transferFrom(sender, order.owner, params.amountSpecified);
                IERC20(order.tokenOut).transferFrom(order.owner, sender, order.amountOut);

                // Remove the matched order
                orderList[i] = orderList[orderList.length - 1];
                orderList.pop();

                return (true, toBeforeSwapDelta(delta));
            }
        }

        return (false, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function placeOrder(
        PoolId poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 expiry
    ) external {
        orders[poolId].push(
            Order({
                owner: msg.sender,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                amountOut: amountOut,
                expiry: expiry
            })
        );
    }
}
