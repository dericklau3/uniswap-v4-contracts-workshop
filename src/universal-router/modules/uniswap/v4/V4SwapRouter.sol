// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {UniswapImmutables} from '../UniswapImmutables.sol';
import {Permit2Payments} from '../../Permit2Payments.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PermissionedV4Router} from '@uniswap/v4-periphery/src/hooks/permissionedPools/PermissionedV4Router.sol';
import {
    IPermissionsAdapterFactory
} from '@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol';
import {
    IPermissionsAdapter
} from '@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol';

/// @title Uniswap V4 交易路由模块
/// @notice 连接 Universal Router 的统一付款逻辑与 V4 标准池、permissioned pool 的锁内结算流程。
abstract contract V4SwapRouter is PermissionedV4Router, Permit2Payments {
    constructor(address _poolManager, address _permissionsAdapterFactory)
        PermissionedV4Router(IPoolManager(_poolManager), IPermissionsAdapterFactory(_permissionsAdapterFactory))
    {}

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        // 标准 V4 pool 直接向 PoolManager 结算：路由器余额付款走 `pay`，用户付款走 Permit2。
        payOrPermit2Transfer(Currency.unwrap(currency), payer, address(poolManager), amount);
    }

    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal override {
        // 权限代币不能直接进入 PoolManager：先由 Permit2 转给 permissionsAdapter，
        // 再由适配器包装成池可接受的资产并完成入账。
        PERMIT2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
        permissionsAdapter.wrapToPoolManager(amount);
    }
}
