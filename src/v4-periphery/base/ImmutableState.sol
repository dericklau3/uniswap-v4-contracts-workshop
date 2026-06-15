// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title 不可变核心状态
/// @notice 集中保存多个 V4 外围合约共同依赖的不可变 `PoolManager` 地址。
contract ImmutableState is IImmutableState {
    /// @notice 返回本外围合约绑定的 Uniswap V4 `PoolManager`。
    IPoolManager public immutable poolManager;

    /// @notice 调用者不是绑定的 `PoolManager` 时回退。
    error NotPoolManager();

    /// @notice 仅允许绑定的 `PoolManager` 调用，用于保护解锁回调等信任边界。
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
