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

    uint128 public constant TOTAL_BIPS = 10000;
    uint128 public constant WITHDRAWAL_FEE_RATIO = 100;
    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId id => uint40) internal _lastChargedEpoch;
    mapping(PoolId id => mapping(address => mapping(int256 => uint40))) public withdrawalQueue;

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

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));

        _setBidToken(poolToken);

        poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});

        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        address payer = abi.decode(hookData, (address));
        PoolInfo storage pool = poolInfo[poolId];

        int256 liquidity = params.liquidityDelta;

        UniswapV4ERC20(pool.liquidityToken).mint(payer, uint256(liquidity));

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];
        address payer = abi.decode(hookData, (address));

        uint40 currentEpoch = _getEpoch(poolId, block.timestamp);
        IAmAmm.Bid memory _bid = getLastManager(poolId, currentEpoch);
        uint128 rent = _bid.rent;

        int256 liquidity = params.liquidityDelta;

        uint40 withdrawLiquidityEpoch = withdrawalQueue[poolId][payer][liquidity];

        // delay withdrwal when there's manager
        if (rent > 0 && (withdrawLiquidityEpoch == 0 || currentEpoch <= withdrawLiquidityEpoch)) {
            revert LiquidityNotInWithdrwalQueue();
        }
        // burn LP token
        UniswapV4ERC20(pool.liquidityToken).burn(payer, uint256(-liquidity));

        return (this.beforeRemoveLiquidity.selector);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
