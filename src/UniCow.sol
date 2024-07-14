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
    using Currency for Currency;

    struct OrderObject {
        uint256 minPrice;
        uint256 deadline;
        uint256 amount;
        bool isZeroForOne; // true if swapping token0 for token1
    }

    mapping(PoolId => mapping(address => OrderObject)) public orders;
    mapping(PoolId => mapping(address => uint256)) public userBalances0;
    mapping(PoolId => mapping(address => uint256)) public userBalances1;

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
        bool zeroForOne = params.zeroForOne;
        uint256 amountSpecified = uint256(params.amountSpecified);

        for (uint256 i = 0; i < orderOwners[poolId].length; i++) {
            address orderOwner = orderOwners[poolId][i];
            OrderObject memory order = orders[poolId][orderOwner];

            if (
                order.isZeroForOne != zeroForOne && order.deadline > block.timestamp
                    && (
                        (zeroForOne && order.minPrice <= params.sqrtPriceLimitX96)
                            || (!zeroForOne && order.minPrice >= params.sqrtPriceLimitX96)
                    )
            ) {
                uint256 fillAmount = Math.min(order.amount, amountSpecified);
                uint256 receiveAmount = (fillAmount * order.minPrice) / 1e18; // Simplified price calculation

                // Execute the COW
                if (zeroForOne) {
                    userBalances0[poolId][sender] -= fillAmount;
                    userBalances1[poolId][orderOwner] -= receiveAmount;
                    userBalances1[poolId][sender] += receiveAmount;
                    userBalances0[poolId][orderOwner] += fillAmount;
                } else {
                    userBalances1[poolId][sender] -= fillAmount;
                    userBalances0[poolId][orderOwner] -= receiveAmount;
                    userBalances0[poolId][sender] += receiveAmount;
                    userBalances1[poolId][orderOwner] += fillAmount;
                }

                // Update or remove the order
                if (fillAmount == order.amount) {
                    delete orders[poolId][orderOwner];
                } else {
                    orders[poolId][orderOwner].amount -= fillAmount;
                }

                // Create BeforeSwapDelta
                int128 amount0 = zeroForOne ? -int128(uint128(fillAmount)) : int128(uint128(receiveAmount));
                int128 amount1 = zeroForOne ? int128(uint128(receiveAmount)) : -int128(uint128(fillAmount));
                BeforeSwapDelta delta = toBeforeSwapDelta(BalanceDelta.wrap(amount0, amount1));

                return (true, delta);
            }
        }

        return (false, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function placeOrder(PoolKey calldata key, uint256 minPrice, uint256 deadline, uint256 amount, bool zeroForOne)
        external
    {
        PoolId poolId = key.toId();
        require(deadline > block.timestamp, "Invalid deadline");

        orders[poolId][msg.sender] =
            OrderObject({minPrice: minPrice, deadline: deadline, amount: amount, isZeroForOne: zeroForOne});

        // Transfer tokens to the contract
        if (zeroForOne) {
            IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount);
            userBalances0[poolId][msg.sender] += amount;
        } else {
            IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount);
            userBalances1[poolId][msg.sender] += amount;
        }
    }

    function getOrderOwners(PoolId poolId) internal view returns (address[] memory) {
        // This function should return an array of addresses that have placed orders for the given poolId
        // Implementation details depend on how you want to store and retrieve this information
    }

    // Additional helper functions and logic...
}
