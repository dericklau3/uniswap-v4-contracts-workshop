// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PositionManager,
    PoolKey,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    Currency
} from "../../PositionManager.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {Actions} from "../../libraries/Actions.sol";
import {CalldataDecoder} from "../../libraries/CalldataDecoder.sol";

contract PermissionedPositionManager is PositionManager {
    using CalldataDecoder for bytes;

    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    mapping(Currency currency => mapping(IHooks hooks => bool)) public isAllowedHooks;

    event AllowedHooksUpdated(Currency currency, IHooks hooks, bool allowed);
    event CurrencyUnwound(
        uint256 indexed tokenId,
        Currency indexed currency,
        address indexed recipient,
        address caller,
        address lp,
        uint256 amount,
        bool asClaim
    );
    event ClaimWithdrawn(Currency indexed currency, address indexed from, address indexed to, uint256 amount);

    error InvalidHook();
    error TransferDisabled();
    error NotPermissionsAdapterAdmin();
    error NoVerifiedAdapter();

    /// @dev 本合约需要通过工厂验证 adapter 并在铸仓前检查 hook 白名单，因此部署时必须注入 adapter 工厂。
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IPermissionsAdapterFactory _permissionsAdapterFactory
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        PERMISSIONS_ADAPTER_FACTORY = _permissionsAdapterFactory;
        /// @dev EIP-712 域分隔符仍使用构造父合约时的名称 "Uniswap v4 Positions NFT"，不可随展示名称一起改变。
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
    }

    /// @notice 配置某个权限 adapter 货币允许搭配使用的 V4 hook。
    /// @dev 仅 adapter owner 可调用。撤销 hook 后，会阻止新铸仓及现有仓位继续增加流动性；
    /// 减少流动性和销毁不受影响，确保用户权限被撤销后仍然能够退出。
    /// @param currency 权限 adapter 本身作为 V4 池货币的地址封装。
    /// @param hooks 要配置的 hook。
    /// @param allowed 是否允许该 adapter 与 hook 组合。
    function setAllowedHook(Currency currency, IHooks hooks, bool allowed) external {
        if (_getOwner(currency) != msg.sender) {
            revert NotPermissionsAdapterAdmin();
        }
        bool oldAllowed = isAllowedHooks[currency][hooks];
        if (oldAllowed == allowed) return;
        isAllowedHooks[currency][hooks] = allowed;
        emit AllowedHooksUpdated(currency, hooks, allowed);
    }

    /// @notice 强制 LP 退出仓位：取消订阅、销毁 NFT、移除全部流动性，并分别路由两种货币。
    /// @dev 任一侧权限 adapter 的管理员均可调用。每种货币的兜底接收人由 `_getOwner` 链上确定；
    /// 若底层代币因合规限制无法转给 LP 或管理员，则铸造 ERC-6909 claim，因此整个退出保持原子且最终分支不回退。
    /// 每一侧货币都会发出一个 `CurrencyUnwound`。
    /// @param tokenId 要强制退出的仓位 NFT。
    function unwindPosition(uint256 tokenId) external isNotLocked {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address lp = ownerOf(tokenId);

        // 预先授权管理员，使 unlock 内的 BURN_POSITION 通过 onlyIfApproved。
        // ERC-721 _burn 会清除 getApproved，因此该临时授权会随销毁自动清理。
        getApproved[tokenId] = msg.sender;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.UNSUBSCRIBE),
            uint8(Actions.BURN_POSITION),
            uint8(Actions.UNWIND_WITH_FALLBACK),
            uint8(Actions.UNWIND_WITH_FALLBACK)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(tokenId);
        params[1] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        // BURN_POSITION 会清空 positionInfo[tokenId]，所以后续退出动作必须自带完整 PoolKey。
        params[2] = abi.encode(poolKey, poolKey.currency0, lp, tokenId);
        params[3] = abi.encode(poolKey, poolKey.currency1, lp, tokenId);
        poolManager.unlock(abi.encode(actions, params));
    }

    /// @notice 销毁 `PoolManager` 中的 ERC-6909 claim，并把对应底层货币转给 `to`。
    /// @dev 调用者必须持有 claim，或已通过 `PoolManager.setOperator(permPosm, true)` 授权本合约。
    /// 对权限货币，`to` 还必须通过发行方在解包时执行的合规校验。`to` 支持标准 `Actions.TAKE`
    /// 哨兵地址：`address(1)` 映射为调用者，`address(2)` 映射为本合约；事件记录解析后的真实地址。
    /// @param currency 要销毁 claim 并提取底层资产的货币。
    /// @param amount claim 销毁数量及对应底层资产数量。
    /// @param to 底层货币收款人或特殊哨兵地址。
    function withdrawClaim(Currency currency, uint256 amount, address to) external isNotLocked {
        address resolvedTo = _mapRecipient(to);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(currency, msg.sender, amount);
        params[1] = abi.encode(currency, resolvedTo, amount);
        poolManager.unlock(abi.encode(actions, params));

        emit ClaimWithdrawn(currency, msg.sender, resolvedTo, amount);
    }

    /// @notice 权限代币仓位 NFT 不允许转让。
    /// @dev 仓位 owner 是持续合规校验的一部分；转让会绕过铸仓时的 `LIQUIDITY_ALLOWED` 检查，因此始终回退。
    function transferFrom(address from, address to, uint256 id) public override onlyIfPoolManagerLocked {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert TransferDisabled();
    }

    /// @dev 铸仓时校验 owner 对每种权限货币均拥有 `LIQUIDITY_ALLOWED`，防止不合规账户通过单边流动性进入池。
    /// 同时要求至少一侧是工厂验证过的 adapter；两侧都不是权限资产时使用本合约没有额外价值，
    /// 却会得到永久不可转让的 NFT，因此直接拒绝。
    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal override {
        // 至少一侧货币必须是工厂验证过的权限 adapter。
        if (
            _verifiedPermissionedTokenOf(poolKey.currency0) == address(0)
                && _verifiedPermissionedTokenOf(poolKey.currency1) == address(0)
        ) revert NoVerifiedAdapter();
        // 用户权限在 adapter/hook 调用链中校验；此处另外确认 hook 本身获得发行方管理员允许。
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        _checkRecipientAllowed(poolKey.currency0, owner);
        _checkRecipientAllowed(poolKey.currency1, owner);
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev 每次增仓都重新检查 hook 白名单，防止已撤销 hook 继续通过旧仓位接收新增资金；
    /// 也重新确认仓位 owner 对每种权限货币仍具备 `LIQUIDITY_ALLOWED`。
    /// 减仓和销毁刻意不做这些检查，确保权限或 hook 被撤销后持有人仍可退出。
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal override {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        address owner = ownerOf(tokenId);
        _checkRecipientAllowed(poolKey.currency0, owner);
        _checkRecipientAllowed(poolKey.currency1, owner);
        super._increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
    }

    /// @dev delta 推导增仓版本沿用 `_increase` 的 hook 与持有人权限复检；该入口本身仍是已弃用路径。
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        override
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        address owner = ownerOf(tokenId);
        _checkRecipientAllowed(poolKey.currency0, owner);
        _checkRecipientAllowed(poolKey.currency1, owner);
        super._increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
    }

    function _checkRecipientAllowed(Currency currency, address recipient) internal view {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return;
        if (!IPermissionsAdapter(Currency.unwrap(currency)).isAllowed(recipient, PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
    }

    function _checkAllowedHooks(PoolKey memory poolKey) internal view returns (bool) {
        return
            _checkAllowedHook(poolKey.currency0, poolKey.hooks) && _checkAllowedHook(poolKey.currency1, poolKey.hooks);
    }

    function _checkAllowedHook(Currency currency, IHooks hooks) internal view returns (bool) {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return true;
        return isAllowedHooks[currency][hooks];
    }

    /// @dev 结算权限货币时，先把底层权限代币转入 adapter，再由 adapter 向 `PoolManager` 铸造等额包装币。
    /// 同时按原始用户而非中间付款合约检查 `LIQUIDITY_ALLOWED`，维持真实参与者的合规边界。
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            // 普通货币沿用基础 PositionManager 的 Permit2/自有余额付款路径。
            super._pay(currency, payer, amount);
            return;
        }
        // 权限货币必须经 adapter 包装后，才能成为 PoolManager 内部持有的池货币。
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        // 对真实原始用户检查流动性权限，不能只检查代付地址或路由合约。
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
        } else {
            permit2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
        }
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
        return PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
    }

    /// @notice 解析结算数量；权限 adapter 货币使用本合约持有的底层代币余额，而不是 adapter token 余额。
    function _mapSettleAmount(uint256 amount, Currency currency) internal view override returns (uint256) {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }

    /// @dev 当 adapter 货币通过 TAKE 转给本合约时，adapter 的 `_update` 会自动解包，
    /// 因而本合约最终持有的是底层权限代币而非 adapter token。必须扫转底层资产，
    /// 避免余额残留并被后续调用者通过共享路由上下文领取。
    function _sweep(Currency currency, address to) internal override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            super._sweep(currency, to);
            return;
        }
        Currency underlying = Currency.wrap(permissionedToken);
        uint256 balance = underlying.balanceOfSelf();
        if (balance > 0) underlying.transfer(to, balance);
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IPermissionsAdapter(permissionsAdapter).owner();
    }

    /// @dev 增加 `unwindPosition` 使用的级联路由动作、取消订阅动作和 `withdrawClaim` 使用的 BURN_6909 原语；
    /// 其他动作继续交给基础 `PositionManager` 分派。
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.UNWIND_WITH_FALLBACK) {
            (PoolKey memory poolKey, Currency currency, address lp, uint256 tokenId) =
                abi.decode(params, (PoolKey, Currency, address, uint256));
            // 调用者必须是该仓位任一权限 adapter 的管理员，且 currency 必须属于该 PoolKey。
            address sender = msgSender();
            if (!((currency == poolKey.currency0 || currency == poolKey.currency1)
                        && (sender == _getOwner(poolKey.currency0) || sender == _getOwner(poolKey.currency1)))) revert Unauthorized();
            _unwindWithFallback(currency, lp, tokenId);
            return;
        }
        if (action == Actions.UNSUBSCRIBE) {
            uint256 tokenId = abi.decode(params, (uint256));
            // 取消订阅前，调用者必须拥有仓位或获得 ERC-721 授权。
            if (!_isApprovedOrOwner(msgSender(), tokenId)) revert NotApproved(msgSender());
            if (positionInfo[tokenId].hasSubscriber()) _unsubscribe(tokenId);
            return;
        }
        if (action == Actions.BURN_6909) {
            (Currency currency, address from, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            // 只允许动作执行者销毁自己的 claim，不能借内部动作指定任意受害者。
            if (from != msgSender()) revert Unauthorized();
            poolManager.burn(from, currency.toId(), amount);
            return;
        }
        super._handleAction(action, params);
    }

    /// @dev 权限货币按 `take 给 LP → take 给管理员 → 给管理员铸造 6909 claim` 级联；
    /// 普通货币按 `take 给 LP → 给 LP 铸造 6909 claim` 级联，管理员无权取得普通 ERC-20。
    /// 最后的 claim 铸造不会因接收方代币合规规则回退，因此保证退出可完成。
    /// `CurrencyUnwound` 的 `recipient/asClaim` 记录实际最终去向。
    function _unwindWithFallback(Currency currency, address lp, uint256 tokenId) internal {
        uint256 amount = _getFullCredit(currency);
        if (amount == 0) return;

        // 首选把底层货币直接交还原 LP。
        try poolManager.take(currency, lp, amount) {
            emit CurrencyUnwound(tokenId, currency, lp, msgSender(), lp, amount, false);
            return;
        } catch {}

        // 若 LP 因合规限制不能接收权限货币，尝试交给 adapter 管理员。
        address admin = _getOwner(currency);
        // 普通货币没有 adapter 管理员，由 LP 以可转让 6909 claim 继续持有经济权益。
        if (admin == address(0)) {
            poolManager.mint(lp, currency.toId(), amount);
            emit CurrencyUnwound(tokenId, currency, lp, msgSender(), lp, amount, true);
            return;
        }
        // 权限货币的第二顺位是直接转给发行方/adapter 管理员。
        try poolManager.take(currency, admin, amount) {
            emit CurrencyUnwound(tokenId, currency, admin, msgSender(), lp, amount, false);
            return;
        } catch {}
        // 若管理员也无法接收底层代币，则给管理员铸造 PoolManager 内部 claim 作为最终兜底。
        poolManager.mint(admin, currency.toId(), amount);
        emit CurrencyUnwound(tokenId, currency, admin, msgSender(), lp, amount, true);
    }
}
