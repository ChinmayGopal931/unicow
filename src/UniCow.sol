// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "./forks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract UniCow is BaseHook {
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct OrderObject {
        uint256 minPrice;
        uint256 deadline;
        uint256 amount;
        bool isZeroForOne;
    }

    mapping(PoolId => mapping(address => OrderObject)) public orders;
    mapping(PoolId => address[]) public orderOwners;
    mapping(PoolId => mapping(address => bool)) public isOrderOwner;

    event OrderPlaced(
        PoolId indexed poolId,
        address indexed owner,
        uint256 amount,
        uint256 minPrice,
        uint256 deadline,
        bool isZeroForOne
    );
    event OrderCancelled(PoolId indexed poolId, address indexed owner, uint256 cancelledAmount, bool isZeroForOne);
    event OrderPartiallyFilled(
        PoolId indexed poolId, address indexed owner, uint256 filledAmount, uint256 remainingAmount, bool isZeroForOne
    );

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
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
        bool zeroForOne = params.zeroForOne;
        uint256 amountSpecified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        (, Currency outputCurrency,) = _getInputOutputAndAmount(key, params);

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

                emit OrderPartiallyFilled(poolId, orderOwner, amountSpecified, order.amount, order.isZeroForOne);

                return (true, delta);
            }
        }

        return (false, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function _getInputOutputAndAmount(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        pure
        returns (Currency input, Currency output, uint256 amount)
    {
        (input, output) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }

    function placeOrder(PoolKey calldata key, uint256 minPrice, uint256 deadline, uint256 amount, bool zeroForOne)
        external
    {
        PoolId poolId = key.toId();
        require(deadline > block.timestamp, "Invalid deadline");

        orders[poolId][msg.sender] =
            OrderObject({minPrice: minPrice, deadline: deadline, amount: amount, isZeroForOne: zeroForOne});

        if (!isOrderOwner[poolId][msg.sender]) {
            orderOwners[poolId].push(msg.sender);
            isOrderOwner[poolId][msg.sender] = true;
        }

        // Transfer tokens to the contract
        if (zeroForOne) {
            key.currency0.take(poolManager, msg.sender, amount, false);
        } else {
            key.currency1.take(poolManager, msg.sender, amount, false);
        }

        emit OrderPlaced(poolId, msg.sender, amount, minPrice, deadline, zeroForOne);
    }

    function cancelExpiredOrder(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        OrderObject memory order = orders[poolId][msg.sender];

        require(order.amount > 0, "No active order");
        require(block.timestamp > order.deadline, "Order not expired");

        // Refund the tokens
        if (order.isZeroForOne) {
            key.currency0.settle(poolManager, msg.sender, order.amount, false);
        } else {
            key.currency1.settle(poolManager, msg.sender, order.amount, false);
        }

        // Remove the order
        delete orders[poolId][msg.sender];
        removeOrderOwner(poolId, msg.sender);

        emit OrderCancelled(poolId, msg.sender, order.amount, order.isZeroForOne);
    }

    function removeOrderOwner(PoolId poolId, address owner) internal {
        require(isOrderOwner[poolId][owner], "Not an order owner");

        uint256 index;
        for (uint256 i = 0; i < orderOwners[poolId].length; i++) {
            if (orderOwners[poolId][i] == owner) {
                index = i;
                break;
            }
        }

        orderOwners[poolId][index] = orderOwners[poolId][orderOwners[poolId].length - 1];
        orderOwners[poolId].pop();

        isOrderOwner[poolId][owner] = false;
    }
}
