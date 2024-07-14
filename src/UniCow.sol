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

    event OrderPartiallyFilled(
        PoolId indexed poolId, address indexed owner, uint256 filledAmount, uint256 remainingAmount, bool isZeroForOne
    );
    event OrderCancelled(PoolId indexed poolId, address indexed owner, uint256 cancelledAmount, bool isZeroForOne);

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

        (bool success, BeforeSwapDelta delta) = findCOW(poolId, sender, key, params);
        if (success) {
            return (this.beforeSwap.selector, delta, 0);
        }

        // If no COW match, proceed with regular swap
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function findCOW(PoolId poolId, address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        returns (bool, BeforeSwapDelta)
    {
        bool zeroForOne = params.zeroForOne;
        uint256 amountSpecified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

        for (uint256 i = 0; i < orderOwners[poolId].length; i++) {
            address orderOwner = orderOwners[poolId][i];
            OrderObject memory order = orders[poolId][orderOwner];

            if (order.isZeroForOne != zeroForOne && order.deadline > block.timestamp && order.amount >= amountSpecified)
            {
                // Execute the COW
                if (zeroForOne) {
                    key.currency0.take(poolManager, sender, amountSpecified, false);
                    key.currency1.settle(poolManager, orderOwner, amountSpecified, false);
                } else {
                    key.currency1.take(poolManager, sender, amountSpecified, false);
                    key.currency0.settle(poolManager, orderOwner, amountSpecified, false);
                }

                // Update the order
                order.amount -= amountSpecified;
                if (order.amount == 0) {
                    removeOrderOwner(poolId, orderOwner);
                } else {
                    orders[poolId][orderOwner] = order;
                }

                // Create BeforeSwapDelta
                BeforeSwapDelta delta =
                    toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified));

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

    function cancelExpiredOrder(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        OrderObject memory order = orders[poolId][msg.sender];

        require(order.amount > 0, "No active order");
        require(block.timestamp > order.deadline, "Order not expired");

        // Calculate the remaining amount
        uint256 initialBalance =
            order.isZeroForOne ? userBalances0[poolId][msg.sender] : userBalances1[poolId][msg.sender];
        uint256 remainingAmount = Math.min(initialBalance, order.amount);

        // Refund the remaining tokens
        if (order.isZeroForOne) {
            userBalances0[poolId][msg.sender] -= remainingAmount;
            IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, remainingAmount);
        } else {
            userBalances1[poolId][msg.sender] -= remainingAmount;
            IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, remainingAmount);
        }

        // Check if the order was partially filled
        if (remainingAmount < order.amount) {
            emit OrderPartiallyFilled(
                poolId, msg.sender, order.amount - remainingAmount, remainingAmount, order.isZeroForOne
            );
        }

        // Remove the order
        delete orders[poolId][msg.sender];
        removeOrderOwner(poolId, msg.sender);

        emit OrderCancelled(poolId, msg.sender, remainingAmount, order.isZeroForOne);
    }

    function removeOrderOwner(PoolId poolId, address owner) internal {
        require(isOrderOwner[poolId][owner], "Not an order owner");

        // Find the index of the owner
        uint256 index;
        for (uint256 i = 0; i < orderOwners[poolId].length; i++) {
            if (orderOwners[poolId][i] == owner) {
                index = i;
                break;
            }
        }

        // Move the last element to the place of the removed one
        orderOwners[poolId][index] = orderOwners[poolId][orderOwners[poolId].length - 1];
        orderOwners[poolId].pop();

        // Update the mapping
        isOrderOwner[poolId][owner] = false;
    }
}
