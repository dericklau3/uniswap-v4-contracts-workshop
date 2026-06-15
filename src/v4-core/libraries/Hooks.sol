// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "../types/PoolKey.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {SafeCast} from "./SafeCast.sol";
import {LPFeeLibrary} from "./LPFeeLibrary.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../types/BeforeSwapDelta.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "../types/PoolOperation.sol";
import {ParseBytes} from "./ParseBytes.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @notice V4 通过检查 hooks 合约部署地址的最低若干 bit，决定需要调用哪些 hook。
/// @dev 例如 hooks 地址 0x0000000000000000000000000000000000002400 的低位是
///      '10 0100 0000 0000'，因此会启用 'before initialize' 与 'after add liquidity' hook。
///      这种地址即权限的设计省去了单独存储配置，但要求 hook 使用 CREATE2 等方式部署到匹配权限位的地址。
library Hooks {
    using LPFeeLibrary for uint24;
    using Hooks for IHooks;
    using SafeCast for int256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using ParseBytes for bytes;
    using CustomRevert for bytes4;

    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;

    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;

    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;

    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;

    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }

    /// @notice hooks 地址编码的权限位与声明权限不一致时抛出。
    /// @param hooks hooks 合约地址。
    error HookAddressNotValid(address hooks);

    /// @notice Hook 未返回与被调用函数一致的 selector。
    error InvalidHookResponse();

    /// @notice hook 调用失败时，为 ERC-7751 包装错误提供附加上下文。
    error HookCallFailed();

    /// @notice hook 返回的 delta 把兑换从 exactIn 翻转成 exactOut，或从 exactOut 翻转成 exactIn。
    error HookDeltaExceedsSwapAmount();

    /// @notice 供 hook 构造函数使用，验证部署地址会启用预期的 hook 集合。
    /// @param permissions 该合约声明希望启用的 hook 权限。
    /// @dev 构造期间调用本函数，因此 permissions 参数使用 memory。
    function validateHookPermissions(IHooks self, Permissions memory permissions) internal pure {
        if (
            permissions.beforeInitialize != self.hasPermission(BEFORE_INITIALIZE_FLAG)
                || permissions.afterInitialize != self.hasPermission(AFTER_INITIALIZE_FLAG)
                || permissions.beforeAddLiquidity != self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)
                || permissions.afterAddLiquidity != self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG)
                || permissions.beforeRemoveLiquidity != self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)
                || permissions.afterRemoveLiquidity != self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                || permissions.beforeSwap != self.hasPermission(BEFORE_SWAP_FLAG)
                || permissions.afterSwap != self.hasPermission(AFTER_SWAP_FLAG)
                || permissions.beforeDonate != self.hasPermission(BEFORE_DONATE_FLAG)
                || permissions.afterDonate != self.hasPermission(AFTER_DONATE_FLAG)
                || permissions.beforeSwapReturnDelta != self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterSwapReturnDelta != self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterAddLiquidityReturnDelta != self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || permissions.afterRemoveLiquidityReturnDelta
                    != self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            HookAddressNotValid.selector.revertWith(address(self));
        }
    }

    /// @notice 验证 hook 地址至少设置一个权限位、或服务于动态费率池；零地址也可表示完全不使用 hook。
    /// @param self 要验证的 hook。
    /// @param fee 使用该 hook 的池费率配置。
    /// @return bool hook 地址与费率组合有效时返回 true。
    function isValidHookAddress(IHooks self, uint24 fee) internal pure returns (bool) {
        // 只有启用了对应 action hook，才能再启用该 action 的 return delta 权限。
        if (!self.hasPermission(BEFORE_SWAP_FLAG) && self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_SWAP_FLAG) && self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG) && self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG))
        {
            return false;
        }
        if (
            !self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                && self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) return false;

        // 未设置 hook 合约时不能使用动态费率。
        // 设置 hook 合约后，地址必须至少包含一个权限位，或该池必须是动态费率池。
        return address(self) == address(0)
            ? !fee.isDynamicFee()
            : (uint160(address(self)) & ALL_HOOK_MASK > 0 || fee.isDynamicFee());
    }

    /// @notice 使用给定 calldata 调用 hook，并取得完整返回数据；该层本身不解释 delta。
    /// @dev 调用失败时包装并冒泡原始错误；成功后还会验证返回 selector 与请求 selector 一致。
    /// @return result hook 返回的完整数据。
    function callHook(IHooks self, bytes memory data) internal returns (bytes memory result) {
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), self, 0, add(data, 0x20), mload(data), 0, 0)
        }
        // 使用 HookCallFailed 包装回滚，并向上携带 hook 返回的原始错误信息。
        if (!success) CustomRevert.bubbleUpAndRevertWith(address(self), bytes4(data), HookCallFailed.selector);

        // 调用成功，读取完整返回数据。
        assembly ("memory-safe") {
            // 从 free memory pointer 分配 result byte array。
            result := mload(0x40)
            // 数组末尾按 32 byte 对齐后，写回新的 free memory pointer。
            mstore(0x40, add(result, and(add(returndatasize(), 0x3f), not(0x1f))))
            // 在内存中写入数组长度。
            mstore(result, returndatasize())
            // 把返回数据复制到 result。
            returndatacopy(add(result, 0x20), 0, returndatasize())
        }

        // 返回数据至少需要 32 byte 才能容纳 ABI 编码的 selector，并且返回 selector 必须与预期一致。
        if (result.length < 32 || result.parseSelector() != data.parseSelector()) {
            InvalidHookResponse.selector.revertWith();
        }
    }

    /// @notice 调用 hook，并按权限决定是否解析其返回的 32 byte delta。
    /// @return int256 hook 返回的 delta；未启用 return delta 权限时固定为 0。
    function callHookWithReturnDelta(IHooks self, bytes memory data, bool parseReturn) internal returns (int256) {
        bytes memory result = callHook(self, data);

        // 若该 hook 未被授权返回 delta，则忽略额外返回含义并使用 0。
        if (!parseReturn) return 0;

        // 返回 bytes4 与一个 32 byte delta 的 ABI 编码总长度必须为 64 byte。
        if (result.length != 64) InvalidHookResponse.selector.revertWith();
        return result.parseReturnDelta();
    }

    /// @notice 当某次操作由 hook 自己发起时，跳过回调该 hook，避免递归自调用。
    modifier noSelfCall(IHooks self) {
        if (msg.sender != address(self)) {
            _;
        }
    }

    /// @notice 若地址包含权限位，则调用 beforeInitialize hook 并验证返回值。
    function beforeInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96) internal noSelfCall(self) {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeInitialize, (msg.sender, key, sqrtPriceX96)));
        }
    }

    /// @notice 若地址包含权限位，则调用 afterInitialize hook 并验证返回值。
    function afterInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96, int24 tick)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterInitialize, (msg.sender, key, sqrtPriceX96, tick)));
        }
    }

    /// @notice 根据 liquidityDelta 的正负调用获授权的 beforeAddLiquidity 或 beforeRemoveLiquidity hook。
    function beforeModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) internal noSelfCall(self) {
        if (params.liquidityDelta > 0 && self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeAddLiquidity, (msg.sender, key, params, hookData)));
        } else if (params.liquidityDelta <= 0 && self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeRemoveLiquidity, (msg.sender, key, params, hookData)));
        }
    }

    /// @notice 根据 liquidityDelta 调用获授权的 afterAddLiquidity 或 afterRemoveLiquidity hook，并应用 hook delta。
    /// @dev hookDelta 从 callerDelta 中扣除：正 delta 表示相应资产划给 hook，负 delta 表示 hook 补贴调用方。
    function afterModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal returns (BalanceDelta callerDelta, BalanceDelta hookDelta) {
        if (msg.sender == address(self)) return (delta, BalanceDeltaLibrary.ZERO_DELTA);

        callerDelta = delta;
        if (params.liquidityDelta > 0) {
            if (self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeCall(
                            IHooks.afterAddLiquidity, (msg.sender, key, params, delta, feesAccrued, hookData)
                        ),
                        self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                    )
                );
                callerDelta = callerDelta - hookDelta;
            }
        } else {
            if (self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeCall(
                            IHooks.afterRemoveLiquidity, (msg.sender, key, params, delta, feesAccrued, hookData)
                        ),
                        self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
                    )
                );
                callerDelta = callerDelta - hookDelta;
            }
        }
    }

    /// @notice 调用获授权的 beforeSwap hook，应用指定资产 delta，并读取可选的动态 LP fee 覆盖值。
    /// @dev hook 可以减少或增加实际进入 AMM 曲线的 amountToSwap，但不得改变原始 exactIn/exactOut 类型。
    function beforeSwap(IHooks self, PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        internal
        returns (int256 amountToSwap, BeforeSwapDelta hookReturn, uint24 lpFeeOverride)
    {
        amountToSwap = params.amountSpecified;
        if (msg.sender == address(self)) return (amountToSwap, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);

        if (self.hasPermission(BEFORE_SWAP_FLAG)) {
            bytes memory result = callHook(self, abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));

            // 返回 bytes4、一个 32 byte delta 与 LP fee 的 ABI 编码总长度必须为 96 byte。
            if (result.length != 96) InvalidHookResponse.selector.revertWith();

            // 动态费率池若要覆盖缓存费率，应返回带 override flag 的有效费率。
            // 若设置 flag 却返回无效费率，交易会回滚；未设置时继续使用池当前 LP fee。
            if (key.fee.isDynamicFee()) lpFeeOverride = result.parseFee();

            // 仅在获准返回 delta 时解析并应用该逻辑。
            if (self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
                hookReturn = BeforeSwapDelta.wrap(result.parseReturnDelta());

                // unspecified 部分暂不影响 AMM 输入，留到 afterSwap 阶段统一处理。
                int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();

                // 根据 hook 返回值更新实际兑换数量，并检查兑换类型仍保持 exact input/output 不变。
                if (hookDeltaSpecified != 0) {
                    bool exactInput = amountToSwap < 0;
                    amountToSwap += hookDeltaSpecified;
                    if (exactInput ? amountToSwap > 0 : amountToSwap < 0) {
                        HookDeltaExceedsSwapAmount.selector.revertWith();
                    }
                }
            }
        }
    }

    /// @notice 调用获授权的 afterSwap hook，合并 before/after 两阶段 delta，并调整调用方最终结算差额。
    function afterSwap(
        IHooks self,
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData,
        BeforeSwapDelta beforeSwapHookReturn
    ) internal returns (BalanceDelta, BalanceDelta) {
        if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);

        int128 hookDeltaSpecified = beforeSwapHookReturn.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapHookReturn.getUnspecifiedDelta();

        if (self.hasPermission(AFTER_SWAP_FLAG)) {
            hookDeltaUnspecified += self.callHookWithReturnDelta(
                abi.encodeCall(IHooks.afterSwap, (msg.sender, key, params, swapDelta, hookData)),
                self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
            ).toInt128();
        }

        BalanceDelta hookDelta;
        if (hookDeltaUnspecified != 0 || hookDeltaSpecified != 0) {
            hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

            // 调用方需要支付 hook 的正 delta，或接收 hook 提供的负 delta。
            swapDelta = swapDelta - hookDelta;
        }
        return (swapDelta, hookDelta);
    }

    /// @notice 若地址包含权限位，则调用 beforeDonate hook 并验证返回值。
    function beforeDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(BEFORE_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    /// @notice 若地址包含权限位，则调用 afterDonate hook 并验证返回值。
    function afterDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    function hasPermission(IHooks self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}
