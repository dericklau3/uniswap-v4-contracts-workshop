// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 动作特殊常量
/// @notice 定义动作参数中表示“动态数量”或“动态地址”的哨兵值。
/// @dev 使用常量比在每次编码时传入完整字面值更节省 gas。
library ActionConstants {
    /// @notice 表示动作应使用 `PoolManager` 中尚未关闭的完整 delta，或上下文约定的动态余额。
    uint128 internal constant OPEN_DELTA = 0;
    /// @notice 表示动作应使用本合约持有的某种货币全部余额。
    /// 数值等于 `1 << 255`，即只设置最高有效位。
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice 表示动作收款人应映射为 `msgSender()` 返回的原始调用者。
    address internal constant MSG_SENDER = address(1);

    /// @notice 表示动作收款人应映射为当前路由/仓位管理合约。
    address internal constant ADDRESS_THIS = address(2);
}
