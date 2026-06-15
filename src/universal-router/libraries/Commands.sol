// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Universal Router 命令常量
/// @notice 定义单字节命令的标志位与类型值，供 Dispatcher 按数值区间低成本解码。
library Commands {
    // 位掩码：最高位表示该命令是否允许失败，低 7 位表示实际命令类型。
    bytes1 internal constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 internal constant COMMAND_TYPE_MASK = 0x7f;

    // 命令类型按数值区间排列，并由嵌套 `if` 分发，以减少比较次数和 gas。
    // 内置命令当前主要位于 0x00-0x3f，0x40 起保留给第三方集成。

    // 0x00 <= value <= 0x07：第一层分支中的 V3、Permit2 与支付命令。
    uint256 constant V3_SWAP_EXACT_IN = 0x00;
    uint256 constant V3_SWAP_EXACT_OUT = 0x01;
    uint256 constant PERMIT2_TRANSFER_FROM = 0x02;
    uint256 constant PERMIT2_PERMIT_BATCH = 0x03;
    uint256 constant SWEEP = 0x04;
    uint256 constant TRANSFER = 0x05;
    uint256 constant PAY_PORTION = 0x06;
    uint256 constant PAY_PORTION_FULL_PRECISION = 0x07;

    // 0x08 <= value <= 0x0f：第二层分支中的 V2、Permit2、ETH/WETH 与余额检查命令。
    uint256 constant V2_SWAP_EXACT_IN = 0x08;
    uint256 constant V2_SWAP_EXACT_OUT = 0x09;
    uint256 constant PERMIT2_PERMIT = 0x0a;
    uint256 constant WRAP_ETH = 0x0b;
    uint256 constant UNWRAP_WETH = 0x0c;
    uint256 constant PERMIT2_TRANSFER_FROM_BATCH = 0x0d;
    uint256 constant BALANCE_CHECK_ERC20 = 0x0e;
    // COMMAND_PLACEHOLDER = 0x0f；预留命令位。

    // 0x10 <= value <= 0x20：第三层分支中的 V4 与 V3/V4 头寸管理命令。
    uint256 constant V4_SWAP = 0x10;
    uint256 constant V3_POSITION_MANAGER_PERMIT = 0x11;
    uint256 constant V3_POSITION_MANAGER_CALL = 0x12;
    uint256 constant V4_INITIALIZE_POOL = 0x13;
    uint256 constant V4_POSITION_MANAGER_CALL = 0x14;
    // COMMAND_PLACEHOLDER = 0x15 -> 0x20；预留命令区间。

    // 0x21 <= value <= 0x3f：嵌套子计划及后续内置扩展。
    uint256 constant EXECUTE_SUB_PLAN = 0x21;
    // 0x22 -> 0x3f 为预留命令区间。

    // 0x40 <= value <= 0x5f：第三方协议集成命令区间。
    uint256 constant ACROSS_V4_DEPOSIT_V3 = 0x40;
}
