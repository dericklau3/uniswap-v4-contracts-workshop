// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPermissionsAdapter, IERC20} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionsAdapter} from "./PermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";

contract PermissionsAdapterFactory is IPermissionsAdapterFactory {
    address public immutable POOL_MANAGER;

    /// @notice 返回由本工厂创建的 adapter 对应的底层权限代币；尚未验证的 adapter 也会出现在此映射。
    mapping(address permissionsAdapter => address permissionedToken) public permissionsAdapterOf;
    /// @notice 返回已验证 adapter 对应的底层权限代币，未验证或非本工厂创建的地址返回零地址。
    mapping(address permissionsAdapter => address permissionedToken) public verifiedPermissionsAdapterOf;

    constructor(address poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @notice 为一个底层权限 ERC-20 部署新的 `PermissionsAdapter`。
    /// @param permissionedToken 要包装并接入 V4 的底层权限代币。
    /// @param initialOwner adapter 初始管理员。
    /// @param allowListChecker 用于判断 swap 和流动性权限的 checker。
    /// @return permissionsAdapter 新部署的 adapter 地址。
    function createPermissionsAdapter(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address permissionsAdapter) {
        permissionsAdapter = address(
            new PermissionsAdapter(permissionedToken, POOL_MANAGER, initialOwner, allowListChecker)
        );
        permissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
        emit PermissionsAdapterCreated(permissionsAdapter, address(permissionedToken));
    }

    /// @notice 验证 adapter 已实际收到其底层权限代币，从而证明发行方允许该 adapter 接收资产。
    /// @param permissionsAdapter 要验证的、由本工厂创建的 adapter。
    /// @dev 只有底层余额非零才写入 verified 映射；反向查询可防止任意人伪造普通代币 adapter。
    function verifyPermissionsAdapter(address permissionsAdapter) external {
        IERC20 permissionedToken = IERC20(permissionsAdapterOf[permissionsAdapter]);
        if (address(permissionedToken) == address(0)) revert PermissionsAdapterNotFound(permissionsAdapter);
        if (verifiedPermissionsAdapterOf[permissionsAdapter] != address(0)) {
            revert PermissionsAdapterAlreadyVerified(permissionsAdapter);
        }
        // 验证者必须能让 adapter 实际收到权限代币，通常意味着拥有代币或受发行方控制。
        if (permissionedToken.balanceOf(permissionsAdapter) == 0) {
            revert PermissionsAdapterNotVerified(permissionsAdapter);
        }
        verifiedPermissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
        emit PermissionsAdapterVerified(permissionsAdapter, address(permissionedToken));
    }
}
