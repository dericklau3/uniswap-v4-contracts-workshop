// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type PermissionFlag is bytes2;

// 为值类型提供按位或、按位与和相等比较，使多个业务权限可组合和完整匹配。
using {or as |} for PermissionFlag global;
using {and as &} for PermissionFlag global;
using {eq as ==} for PermissionFlag global;

function or(PermissionFlag a, PermissionFlag b) pure returns (PermissionFlag) {
    return PermissionFlag.wrap(PermissionFlag.unwrap(a) | PermissionFlag.unwrap(b));
}

function and(PermissionFlag a, PermissionFlag b) pure returns (PermissionFlag) {
    return PermissionFlag.wrap(PermissionFlag.unwrap(a) & PermissionFlag.unwrap(b));
}

function eq(PermissionFlag a, PermissionFlag b) pure returns (bool) {
    return PermissionFlag.unwrap(a) == PermissionFlag.unwrap(b);
}

library PermissionFlags {
    /// @notice 不授予任何权限。
    PermissionFlag constant NONE = PermissionFlag.wrap(0x0000);
    /// @notice 允许账户通过权限路由在相关 V4 池执行兑换。
    PermissionFlag constant SWAP_ALLOWED = PermissionFlag.wrap(0x0001);
    /// @notice 允许账户创建仓位或向现有仓位增加流动性。
    PermissionFlag constant LIQUIDITY_ALLOWED = PermissionFlag.wrap(0x0002);
    /// @notice 授予当前及未来定义的全部权限位。
    PermissionFlag constant ALL_ALLOWED = PermissionFlag.wrap(0xFFFF);
}
