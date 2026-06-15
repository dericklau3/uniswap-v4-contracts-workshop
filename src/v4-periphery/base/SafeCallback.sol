// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title 安全解锁回调
/// @notice 保证只有绑定的 Uniswap V4 `PoolManager` 可以进入 `unlockCallback`。
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @notice 接收 `PoolManager.unlock` 触发的回调并转交内部实现。
    /// @param data 发起解锁时传入的原始数据。
    /// @return 子合约回调逻辑返回的数据。
    /// @dev 外部函数固定执行 `onlyPoolManager`，子合约只能覆盖其后的内部函数，无法绕过调用者校验。
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev 由子合约实现具体逻辑；进入此函数前已经确认调用者是 `PoolManager`。
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
