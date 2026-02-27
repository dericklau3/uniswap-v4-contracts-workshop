// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransientStateLibrary} from '@uniswap/v4-core/src/libraries/TransientStateLibrary.sol';

import {console} from "forge-std/console.sol";

contract SwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        console.log("beforeSwapCount", beforeSwapCount[key.toId()]);
        console.log("sender", sender);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        console.log("token0", IERC20(token0).balanceOf(sender));
        console.log("token1", IERC20(token1).balanceOf(sender));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(sender), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(sender), key.currency1));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(POOL_MANAGER), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(POOL_MANAGER), key.currency1));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(this), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(this), key.currency1));
        console.log(params.zeroForOne);
        console.log(params.amountSpecified);
        console.log(params.sqrtPriceLimitX96);
        console.logBytes(hookData);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        console.log("afterSwapCount", afterSwapCount[key.toId()]);
        console.log("sender", sender);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        console.log("token0", IERC20(token0).balanceOf(sender));
        console.log("token1", IERC20(token1).balanceOf(sender));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(sender), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(sender), key.currency1));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(POOL_MANAGER), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(POOL_MANAGER), key.currency1));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(this), key.currency0));
        console.log(IPoolManager(POOL_MANAGER).currencyDelta(address(this), key.currency1));
        console.log("delta.amount0()", delta.amount0());
        console.log("delta.amount1()", delta.amount1());
        console.log(params.zeroForOne);
        console.log(params.amountSpecified);
        console.log(params.sqrtPriceLimitX96);
        console.log(delta.amount0());
        console.log(delta.amount1());
        console.logBytes(hookData);
        return (BaseHook.afterSwap.selector, 0);
    }

}
