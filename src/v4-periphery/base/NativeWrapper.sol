// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title 原生币包装组件
/// @notice 在动作批处理中完成原生币与 WETH9 的包装和解包。
abstract contract NativeWrapper is ImmutableState {
    /// @notice 当前链使用的 WETH9 合约。
    IWETH9 public immutable WETH9;

    /// @notice 非 WETH9 解包或 PoolManager 结算路径向本合约发送 ETH 时回退。
    error InvalidEthSender();

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    /// @dev 调用前应已保证 `amount` 不超过本合约 ETH 余额。
    function _wrap(uint256 amount) internal {
        if (amount > 0) WETH9.deposit{value: amount}();
    }

    /// @dev 调用前应已保证 `amount` 不超过本合约 WETH9 余额。
    function _unwrap(uint256 amount) internal {
        if (amount > 0) WETH9.withdraw(amount);
    }

    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }
}
