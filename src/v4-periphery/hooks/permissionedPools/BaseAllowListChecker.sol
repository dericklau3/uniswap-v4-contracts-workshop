// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAllowlistChecker, PermissionFlag, IERC165} from "./interfaces/IAllowlistChecker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice 权限代币 allowlist checker 的抽象基类。
/// @dev 具体发行方实现 `checkAllowlist`，按账户和底层代币返回 swap、流动性等权限位；
/// adapter 通过 ERC-165 先确认 checker 遵循统一接口，再把结果用于 V4 付款、铸仓和增仓边界。
abstract contract BaseAllowlistChecker is IAllowlistChecker, ERC165 {
    /// @notice 查询账户针对指定权限代币拥有的权限位。
    /// @param account 要检查的真实用户地址。
    /// @param tokenAddress 适用权限规则的底层代币地址。
    /// @return 可按位组合的权限标志。
    function checkAllowlist(address account, address tokenAddress) public view virtual returns (PermissionFlag);

    /// @notice 声明同时支持 `IAllowlistChecker` 与父级 ERC-165 接口。
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IAllowlistChecker).interfaceId || super.supportsInterface(interfaceId);
    }
}
