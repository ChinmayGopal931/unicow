// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./mocks/ERC20Mock.sol";
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
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

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
        address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

    PoolKey testKey;
    ERC20Mock token0;
    ERC20Mock token1;

    function setUp() public {
        // Deploy v4-core manager
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        deployCodeTo("UniCow.sol", abi.encode(manager), hookAddress);

        // Deploy UniCow hook
        hook = UniCow(hookAddress);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Assign Pool ID
        POOL_1 = key.toId();

        // Add liquidty to Pool
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(address(this)), false, false);
    }

    function testPlaceOrder() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        console.log("balanceBefore1: ", balanceBefore1);
        console.log("balanceBefore0: ", balanceBefore0);

        vm.startPrank(user1);
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
}
