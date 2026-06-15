// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC20 as SafeERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionsAdapter is ERC20, Ownable2Step, IPermissionsAdapter {
    using SafeTransferLib for SafeERC20;

    /// @notice 返回唯一允许持有 adapter token 的 Uniswap V4 `PoolManager` 地址。
    address public immutable POOL_MANAGER;

    /// @notice 返回由本 adapter 托管并执行发行方合规规则的底层权限 ERC-20。
    IERC20 public immutable PERMISSIONED_TOKEN;

    /// @notice 返回当前负责计算账户权限位的 allowlist checker。
    IAllowlistChecker public allowListChecker;

    /// @notice 返回权限池是否允许执行 swap；管理员可独立暂停兑换而保留退出能力。
    bool public swappingEnabled;

    /// @notice 返回某地址是否可把底层权限代币包装进 `PoolManager`。
    mapping(address wrapper => bool) public allowedWrappers;

    constructor(
        IERC20 permissionedToken,
        address poolManager,
        address initialOwner,
        IAllowlistChecker allowListChecker_
    ) ERC20(_getName(permissionedToken), _getSymbol(permissionedToken)) Ownable(initialOwner) {
        PERMISSIONED_TOKEN = permissionedToken;
        POOL_MANAGER = poolManager;
        _updateAllowListChecker(allowListChecker_);
    }

    /// @notice 把已经转入 adapter 的底层权限代币包装为等额 adapter token，并铸给 `PoolManager`。
    /// @param amount 要包装的底层代币数量。
    /// @dev 仅白名单 wrapper 可调用，且可用余额按 `底层余额 - adapter 总供应量` 计算，防止无抵押铸造。
    function wrapToPoolManager(uint256 amount) external {
        if (!allowedWrappers[msg.sender]) revert UnauthorizedWrapper(msg.sender);
        uint256 availableBalance = PERMISSIONED_TOKEN.balanceOf(address(this)) - totalSupply();
        if (amount > availableBalance) revert InsufficientBalance(amount, availableBalance);
        _mint(POOL_MANAGER, amount);
    }

    /// @notice 从调用者拉取底层权限代币，作为发行方已允许该 adapter 的链上验证信号。
    /// @param amount 要存入的底层代币数量。
    /// @dev 工厂后续以 adapter 的非零底层余额完成验证，并发出专用事件供链下索引。
    function depositForVerification(uint256 amount) external {
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransferFrom(msg.sender, address(this), amount);
        emit VerificationDeposit(msg.sender, amount);
    }

    /// @notice 更新负责判断账户权限位的 allowlist checker。
    /// @param newAllowListChecker 新 checker，必须通过 ERC-165 声明支持 `IAllowlistChecker`。
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external onlyOwner {
        _updateAllowListChecker(newAllowListChecker);
    }

    /// @notice 配置可触发包装流程的路由或仓位管理器。
    /// @param wrapper 要配置的外围合约。
    /// @param allowed 是否允许其包装底层权限代币。
    /// @dev wrapper 必须诚实传递原始调用者，并且只在 swap 或 modifyLiquidity 流程使用包装能力。
    function updateAllowedWrapper(address wrapper, bool allowed) external onlyOwner {
        _updateAllowedWrapper(wrapper, allowed);
    }

    /// @notice 启用或暂停权限池的兑换入口。
    /// @param enabled true 表示允许 swap，false 表示暂停。
    function updateSwappingEnabled(bool enabled) external onlyOwner {
        _updateSwappingEnabled(enabled);
    }

    /// @notice 检查账户是否同时具备请求的全部权限位。
    /// @param account 要检查的真实参与者地址。
    /// @param permission 请求的权限位组合。
    /// @return 账户返回的位标志是否覆盖全部请求权限。
    function isAllowed(address account, PermissionFlag permission) public view returns (bool) {
        return ((allowListChecker.checkAllowlist(account, address(PERMISSIONED_TOKEN))) & (permission)) == (permission);
    }

    function _updateAllowListChecker(IAllowlistChecker newAllowListChecker) internal {
        if (!ERC165Checker.supportsInterface(address(newAllowListChecker), type(IAllowlistChecker).interfaceId)) {
            revert InvalidAllowListChecker(newAllowListChecker);
        }
        allowListChecker = newAllowListChecker;
        emit AllowListCheckerUpdated(newAllowListChecker);
    }

    function _updateAllowedWrapper(address wrapper, bool allowed) internal {
        allowedWrappers[wrapper] = allowed;
        emit AllowedWrapperUpdated(wrapper, allowed);
    }

    function _updateSwappingEnabled(bool enabled) internal {
        swappingEnabled = enabled;
        emit SwappingEnabledUpdated(enabled);
    }

    /// @dev 覆盖 ERC-20 `_update`，把 adapter token 变成仅供 PoolManager 内部记账的包装凭证：
    /// - `settle` 前，wrapper 先存入底层权限代币，再向 PoolManager 铸造等额 adapter token；
    /// - `take` 时，PoolManager 把 adapter token 转向收款人，本函数立即销毁并释放等额底层代币；
    /// - 任意时刻 adapter token 的唯一持有人都必须是 PoolManager，用户只接触底层权限代币。
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(0)) {
            // 销毁路径直接交给父实现，避免 `_unwrap -> _burn -> _update` 形成递归循环。
            super._update(from, to, amount);
            return;
        }
        if (from == address(0)) {
            assert(to == POOL_MANAGER);
            // 铸造只允许给 PoolManager，表示等额底层权限代币已经存入 adapter。
            super._update(from, to, amount);
            return;
        } else if (from != POOL_MANAGER) {
            // 只有 PoolManager 可转出 adapter token；其他持有人转账说明不变量已被破坏。
            revert InvalidTransfer(from, to);
        }
        // 拒绝 PoolManager 自转账，否则会把底层权限代币错误解包回 PoolManager 地址。
        if (to == POOL_MANAGER) revert InvalidTransfer(from, to);
        super._update(from, to, amount);
        _unwrap(to, amount);
        // 转出后立即解包，剩余 adapter token 仍必须全部由 PoolManager 持有。
        assert(balanceOf(POOL_MANAGER) == totalSupply());
    }

    function _unwrap(address account, uint256 amount) internal {
        _burn(account, amount);
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransfer(account, amount);
    }

    /// @dev 使用底层 staticcall 并手动验证 ABI 布局。try/catch 无法捕获返回数据解码失败，
    /// 因此需显式处理返回 bytes32（如 MKR 风格）或其他非 string 形状的代币元数据。
    function _readString(address token, bytes4 selector, string memory fallback_) private view returns (string memory) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 64) return fallback_;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        if (offset != 0x20 || length == 0 || length > data.length - 64) return fallback_;
        return abi.decode(data, (string));
    }

    function _getName(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat(
            "Uniswap v4 ", _readString(address(permissionedToken), IERC20Metadata.name.selector, "Permissioned Token")
        );
    }

    function _getSymbol(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("v4", _readString(address(permissionedToken), IERC20Metadata.symbol.selector, "PT"));
    }

    function decimals() public view override returns (uint8) {
        (bool ok, bytes memory data) =
            address(PERMISSIONED_TOKEN).staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || data.length < 32) return 18;
        uint256 value = abi.decode(data, (uint256));
        return value > type(uint8).max ? 18 : uint8(value);
    }

    function owner() public view override(Ownable, IPermissionsAdapter) returns (address) {
        return super.owner();
    }
}
