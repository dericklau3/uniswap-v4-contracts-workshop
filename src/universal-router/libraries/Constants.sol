// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Universal Router 常量
/// @notice 汇总付款哨兵值、V3 path 编码长度与逐 hop 价格精度。
library Constants {
    /// @dev V2 精确输入使用的哨兵值，表示首个 Pair 已经收到输入代币，无需再次付款。
    uint256 internal constant ALREADY_PAID = 0;

    /// @dev 表示原生 ETH 的特殊地址标志。
    address internal constant ETH = address(0);

    /// @dev bytes 编码中一个地址占用的字节数。
    uint256 internal constant ADDR_SIZE = 20;

    /// @dev V3 path 中一个 fee 占用的字节数。
    uint256 internal constant V3_FEE_SIZE = 3;

    /// @dev 跳过一个 token 地址（20）和一个 pool fee（3）所需的偏移量。
    uint256 internal constant NEXT_V3_POOL_OFFSET = ADDR_SIZE + V3_FEE_SIZE;

    /// @dev 一个 V3 pool 段的完整编码长度。
    /// Token (20) + Fee (3) + Token (20) = 43
    uint256 internal constant V3_POP_OFFSET = NEXT_V3_POOL_OFFSET + ADDR_SIZE;

    /// @dev 包含两个或更多 V3 pool 的 path 最小编码长度。
    uint256 internal constant MULTIPLE_V3_POOLS_MIN_LENGTH = V3_POP_OFFSET + NEXT_V3_POOL_OFFSET;

    /// @dev 逐 hop 最低价格计算的精度乘数；1e36 可同时保留不同 decimals 代币兑换时的精度。
    uint256 internal constant PRICE_PRECISION = 1e36;
}
