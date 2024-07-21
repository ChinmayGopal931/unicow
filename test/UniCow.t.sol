// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {UniCow} from "../src/UniCow.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";

contract UniCowTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolId constant POOL_0 = PoolId.wrap(bytes32(0));
    PoolId POOL_1;

    UniCow hook;

    address user0 = makeAddr("USER_0");
    address user1 = makeAddr("USER_1");
    address user2 = makeAddr("USER_2");

    uint128 internal constant K = 24; // 24 windows (hours)
    uint256 internal constant EPOCH_SIZE = 1 hours;
    address internal constant hookAddress =
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURN_DELTA_FLAG));

    PoolKey key;
    ERC20Mock token0;
    ERC20Mock token1;

    function setUp() public {
        // Deploy mock tokens
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Mint and approve tokens for users
        token0.mint(user1, 1000 ether);
        token1.mint(user2, 1000 ether);

        // Deploy v4-core manager
        deployFreshManagerAndRouters();

        // Initialize currencies
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // Deploy UniCow hook
        hook = new UniCow(manager);

        // Initialize pool key
        key = PoolKey(currency0, currency1, 3000, 60, hook);

        // Initialize the pool
        manager.initialize(key, SQRT_PRICE_1_1, "");

        // Assign Pool ID
        POOL_1 = key.toId();
    }

    function testPlaceOrder() public {
        vm.startPrank(user1);
        token0.approve(address(hook), 1000 ether);
        hook.placeOrder(key, 1, block.timestamp + 1 days, 1000 ether, true);
        vm.stopPrank();

        (uint256 minPrice, uint256 deadline, uint256 amount, bool isZeroForOne) = hook.orders(POOL_1, user1);
        assertEq(minPrice, 1);
        assertEq(deadline, block.timestamp + 1 days);
        assertEq(amount, 1000 ether);
        assertTrue(isZeroForOne);
    }

    function testCancelExpiredOrder() public {
        vm.startPrank(user1);
        token0.approve(address(hook), 1000 ether);
        hook.placeOrder(key, 1, block.timestamp + 1 days, 1000 ether, true);
        vm.warp(block.timestamp + 2 days);
        hook.cancelExpiredOrder(key);
        vm.stopPrank();

        (uint256 minPrice, uint256 deadline, uint256 amount, bool isZeroForOne) = hook.orders(POOL_1, user1);
        assertEq(amount, 0);
    }

    function testTryCOW() public {
        vm.startPrank(user1);
        token0.approve(address(hook), 1000 ether);
        hook.placeOrder(key, 1, block.timestamp + 1 days, 1000 ether, true);
        vm.stopPrank();

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1000 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(user2);
        (bool success, BeforeSwapDelta delta) = hook.tryCOW(POOL_1, user2, key, params);
        vm.stopPrank();

        assertTrue(success);
        assertEq(delta.amount0, -1000 ether);
        assertEq(delta.amount1, 1000 ether);
    }
}
