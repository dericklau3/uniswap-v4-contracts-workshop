// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice 定义外围合约批处理使用的标准动作编号。
/// @dev 这些是推荐的通用命令，具体合约可按需增加动作。部分编号不被当前 Router 或 PositionManager
/// 支持，但保留给其他外围集成使用。编号分区也供分派器用较少比较快速区分流动性、兑换和结算动作。
library Actions {
    // 池操作：流动性动作。
    uint256 internal constant INCREASE_LIQUIDITY = 0x00;
    uint256 internal constant DECREASE_LIQUIDITY = 0x01;
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant BURN_POSITION = 0x03;

    /// @notice 已弃用：存在三明治攻击风险，请勿使用。
    /// @dev 按 delta 推导流动性没有最低流动性保护，攻击者可操纵价格并减少用户得到的流动性。
    /// 应使用 `INCREASE_LIQUIDITY`。
    uint256 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;

    /// @notice 已弃用：存在三明治攻击风险，请勿使用。
    /// @dev 按 delta 推导流动性没有最低流动性保护，攻击者可操纵价格并减少用户得到的流动性。
    /// 应使用 `MINT_POSITION`。
    uint256 internal constant MINT_POSITION_FROM_DELTAS = 0x05;

    // 兑换动作。
    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_IN = 0x07;
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SWAP_EXACT_OUT = 0x09;

    // 捐赠动作；当前 PositionManager 和 Router 不支持。
    uint256 internal constant DONATE = 0x0a;

    // 关闭 PoolManager 瞬时 delta：偿还负 delta。
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    // 领取正 delta。
    uint256 internal constant TAKE = 0x0e;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant TAKE_PORTION = 0x10;
    uint256 internal constant TAKE_PAIR = 0x11;

    uint256 internal constant CLOSE_CURRENCY = 0x12;
    uint256 internal constant CLEAR_OR_TAKE = 0x13;
    uint256 internal constant SWEEP = 0x14;

    uint256 internal constant WRAP = 0x15;
    uint256 internal constant UNWRAP = 0x16;

    // 通过铸造/销毁 ERC-6909 claim 关闭 delta；基础 PositionManager 和 Router 不支持。
    uint256 internal constant MINT_6909 = 0x17;
    uint256 internal constant BURN_6909 = 0x18;

    // 权限池专用动作。
    // 级联路由正 delta：LP → 默认收款人 → 给默认收款人铸造 6909 claim。
    uint256 internal constant UNWIND_WITH_FALLBACK = 0x19;
    // 通过 PositionManager 订阅或取消订阅仓位通知。
    uint256 internal constant SUBSCRIBE = 0x1a;
    uint256 internal constant UNSUBSCRIBE = 0x1b;
}
