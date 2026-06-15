// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {V4Router, IPoolManager, Currency} from "../../V4Router.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";

/// @title 支持权限 V4 池的路由抽象基类
/// @notice 覆盖付款和结算数量解析，使权限代币先经 adapter 包装后再进入 `PoolManager`。
/// @dev UniversalRouter 的 V4SwapRouter 等具体路由应继承本合约，并实现普通代币与 Permit2 付款细节。
abstract contract PermissionedV4Router is V4Router {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    error Unauthorized();
    error SwappingDisabled();

    constructor(IPoolManager poolManager_, IPermissionsAdapterFactory permissionsAdapterFactory)
        V4Router(poolManager_)
    {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
    }

    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            _payStandard(currency, payer, amount);
            return;
        }
        // 权限代币先转入 adapter，由 adapter 向 PoolManager 铸造等额内部池货币。
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            _payPermissionedFromPayer(payer, permissionsAdapter, permissionedToken, amount);
        }
    }

    /// @notice 留给具体路由实现普通非权限货币的付款方式。
    function _payStandard(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice 留给具体路由实现从付款方到 adapter 的底层权限代币转账，例如使用 Permit2。
    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal virtual;

    /// @notice 解析结算数量；`CONTRACT_BALANCE` 对权限货币读取底层代币余额。
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual override returns (uint256) {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        // 只有权限货币且请求 CONTRACT_BALANCE 时使用底层余额，其余情况沿用标准解析。
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }
}
