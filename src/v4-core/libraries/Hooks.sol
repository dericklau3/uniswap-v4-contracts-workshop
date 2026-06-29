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

/// @notice V4 的 Hook 权限解析库，负责判断一个池子在初始化、增减流动性、换币、捐赠等阶段是否要回调外部 Hook。
/// @dev V4 不为每个池子单独部署池合约，而是在 `PoolManager` 里统一管理池状态。
///      如果某个池子想接入自定义业务逻辑，例如动态手续费、限价单、流动性挖矿、KYC 白名单、
///      MEV 保护、自动再平衡或协议抽成，就把 Hook 合约地址写进 `PoolKey`。
///
///      Hook 是否被调用不是存在 storage 配置里，而是编码在 Hook 合约地址的最低 14 个 bit 中：
///      - bit 为 1 表示对应生命周期回调已启用；
///      - bit 为 0 表示 `PoolManager` 会跳过该回调；
///      - 后 4 个 bit 还控制某些 hook 是否被允许返回 delta，从而改变最终结算金额。
///
///      例如 hooks 地址 0x0000000000000000000000000000000000002400 的低位是
///      '10 0100 0000 0000'，因此会启用 'before initialize' 与 'after add liquidity' hook。
///      这种“地址即权限”的设计省去了每次读 storage 的成本，也让池配置天然携带 Hook 能力；
///      代价是 Hook 开发者通常需要用 CREATE2 反复寻找 salt，把合约部署到低位 bit 匹配的地址。
library Hooks {
    using LPFeeLibrary for uint24;
    using Hooks for IHooks;
    using SafeCast for int256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using ParseBytes for bytes;
    using CustomRevert for bytes4;

    // 低 14 位是 V4 目前使用的全部 Hook 权限位。校验地址时用它快速判断“这个非零地址是否真的声明了 Hook 能力”。
    // ALL_HOOK_MASK = 0x3fff. 二进制是：11 1111 1111 1111
    // 也就是低 14 位全是 1。用它可以取出一个地址的低 14 位：
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    // 初始化前后：常用于限制谁能建池、校验初始价格、记录池子元数据，或在建池后初始化外部业务状态。
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;

    // 加流动性前后：常用于白名单、激励记账、收取入池费用，或把一部分新增流动性收益分配给 Hook。
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;

    // 移除流动性前后：常用于退出限制、解锁期、赎回费用、收益结算或惩罚性扣款。
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;

    // 换币前后：是 Hook 最常用的业务入口，可实现动态手续费、限价单、TWAMM、路由保护和订单簿式扩展。
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;

    // 捐赠前后：donate 会把 token 捐给当前区间 LP，Hook 可用它做外部奖励、积分或协议激励分发的联动。
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    // return delta 权限：只有设置了这些位，Hook 返回的金额调整才会被 PoolManager 采纳。
    // 这相当于给 Hook “改账本”的授权；没有这些位时，即便 Hook 函数返回了额外数据，也只能当普通回调处理。
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

    /// @notice Hook 合约在构造函数里声明的权限清单。
    /// @dev 这份结构体不是池子的运行时配置，而是给 Hook 自检用的“业务意图说明”。
    ///      Hook 开发者通常会在构造函数中调用 `validateHookPermissions`，确认当前部署地址低位 bit
    ///      与自己准备实现的回调完全一致。这样可以尽早发现 CREATE2 salt 找错、地址权限少开或多开的问题。
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
    /// @dev 典型场景是 Hook 构造函数声明自己要接收 `beforeSwap`，但实际部署地址低位没有打开对应 bit。
    ///      如果不在部署时拦住，池子后续会以为该 Hook 没有这个能力，业务逻辑就会静默失效。
    /// @param hooks hooks 合约地址。
    error HookAddressNotValid(address hooks);

    /// @notice Hook 未返回与被调用函数一致的 selector。
    /// @dev V4 要求每个 Hook 回调都先返回自己的函数 selector，类似 ERC721 接收回调的确认机制。
    ///      这样可以防止误调用到不符合 IHooks 约定的合约，或 Hook 忘记按 ABI 返回预期数据。
    error InvalidHookResponse();

    /// @notice hook 调用失败时，为 ERC-7751 包装错误提供附加上下文。
    /// @dev 包装后，上层不仅能看到原始 revert，还能知道是哪个 Hook、哪个 selector 触发失败，
    ///      方便路由器、前端和调试工具定位到底是核心池逻辑失败，还是外部 Hook 业务规则拒绝了操作。
    error HookCallFailed();

    /// @notice hook 返回的 delta 把兑换从 exactIn 翻转成 exactOut，或从 exactOut 翻转成 exactIn。
    /// @dev 例如用户原本发起 exact input 换币，`amountSpecified` 为负数，Hook 可以减少实际进入 AMM 的输入量，
    ///      但不能把数量加到正数并变成 exact output。V4 用这个错误保护换币语义不被 Hook 改到完全相反。
    error HookDeltaExceedsSwapAmount();

    /// @notice 供 hook 构造函数使用，验证部署地址会启用预期的 hook 集合。
    /// @dev 这一步是 Hook 合约自己的“部署期保险丝”。由于权限写在地址低位，合约代码本身无法决定
    ///      `PoolManager` 会不会调用它；只有部署后的地址决定权限。本函数逐项对比声明权限和地址权限，
    ///      防止业务方以为已经启用某个风控、收费或记账回调，实际上地址 bit 没打开。
    /// @param permissions 该合约声明希望启用的 hook 权限。
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
    /// @dev `PoolManager.initialize` 会调用本函数校验 `PoolKey.hooks` 与 `PoolKey.fee` 的组合。
    ///      对业务来说，合法组合有三类：
    ///      - 不使用 Hook：hooks 为零地址，且池子不能是动态费率池；
    ///      - 使用普通 Hook：hooks 非零地址，且低 14 位至少打开一个权限；
    ///      - 只为动态费率服务：hooks 非零地址，即使没有生命周期权限，也可以作为动态费率池的 fee manager。
    ///
    ///      另外，return delta 位必须依附于对应的 action 位。比如只打开 `beforeSwapReturnDelta`
    ///      却没有打开 `beforeSwap` 没有意义，因为 `beforeSwap` 根本不会被调用，也就没有 delta 可解析。
    /// @param self 要验证的 hook。
    /// @param fee 使用该 hook 的池费率配置。
    /// @return bool hook 地址与费率组合有效时返回 true。
    function isValidHookAddress(IHooks self, uint24 fee) internal pure returns (bool) {
        // 只有启用了对应 action hook，才能再启用该 action 的 return delta 权限。
        // 这避免出现“允许改账本，但根本没有回调入口”的无效权限组合。
        // returns delta 权限不能单独存在
        // 如果没有启用 beforeSwap，就不能启用 beforeSwap returns delta。
        if (!self.hasPermission(BEFORE_SWAP_FLAG) && self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) return false;
        // 如果没有启用 afterSwap，就不能启用 afterSwap returns delta。
        if (!self.hasPermission(AFTER_SWAP_FLAG) && self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)) return false;
        // 如果没有启用 afterAddLiquidity，就不能启用 afterAddLiquidity returns delta。
        if (!self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG) && self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG))
        {
            return false;
        }
        // 如果没有启用 afterRemoveLiquidity，就不能启用 afterRemoveLiquidity returns delta。
        if (
            !self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                && self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) return false;

        // 未设置 hook 合约时不能使用动态费率，因为动态费率需要外部逻辑更新或覆盖 LP fee。
        // 设置 hook 合约后，地址必须至少包含一个生命周期权限位，或该池必须是动态费率池：
        // 后者允许“只管理费率、不接收生命周期回调”的特殊 Hook 地址存在。
        return address(self) == address(0)
            ? !fee.isDynamicFee()
            : (uint160(address(self)) & ALL_HOOK_MASK > 0 || fee.isDynamicFee());
    }

    /// @notice 使用给定 calldata 调用 hook，并取得完整返回数据；该层本身不解释 delta。
    /// @dev 这是所有 Hook 回调的底层入口。它直接使用 assembly `call`，原因是：
    ///      - 需要保留并包装 Hook 原始 revert 数据，方便外层定位失败原因；
    ///      - 需要读取完整 returndata，再交给不同业务回调解析 selector、delta 或 fee；
    ///      - Hook 是外部可插拔合约，核心协议必须统一做响应格式检查。
    ///
    ///      成功返回并不代表业务一定有效，还必须确认返回的第一个 ABI word 中包含正确 selector。
    ///      如果 Hook 返回错 selector，说明它不是预期的回调实现，或者返回数据格式被破坏。
    /// @return result hook 返回的完整数据。
    function callHook(IHooks self, bytes memory data) internal returns (bytes memory result) {
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), self, 0, add(data, 0x20), mload(data), 0, 0)
        }
        // 使用 HookCallFailed 包装回滚，并向上携带 hook 返回的原始错误信息。
        if (!success) CustomRevert.bubbleUpAndRevertWith(address(self), bytes4(data), HookCallFailed.selector);

        // 调用成功，读取完整返回数据。
        // 后续有些 Hook 只需要 selector，有些还要解析 BalanceDelta、BeforeSwapDelta 或 LP fee。
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
        // 这相当于 Hook 对 PoolManager 说：“我确实处理了你调用的这个生命周期函数”。
        if (result.length < 32 || result.parseSelector() != data.parseSelector()) {
            InvalidHookResponse.selector.revertWith();
        }
    }

    /// @notice 调用 hook，并按权限决定是否解析其返回的 32 byte delta。
    /// @dev delta 是 Hook 对本次操作最终结算的调整值。它不是立即转账，而是进入 V4 的闪电记账系统：
    ///      后续 `PoolManager` 会把调用方和 Hook 的 delta 分别记到账本里，要求 unlock 结束前全部结清。
    ///      因为 delta 能改变谁付钱、谁收钱，所以必须由地址权限位显式授权。
    /// @return int256 hook 返回的 delta；未启用 return delta 权限时固定为 0。
    function callHookWithReturnDelta(IHooks self, bytes memory data, bool parseReturn) internal returns (int256) {
        bytes memory result = callHook(self, data);

        // 若该 hook 未被授权返回 delta，则忽略额外返回含义并使用 0。
        // 业务含义是：这个 Hook 可以观察或校验操作，但不能影响最终资产结算。
        if (!parseReturn) return 0;

        // 返回 bytes4 与一个 32 byte delta 的 ABI 编码总长度必须为 64 byte。
        // 长度不对通常表示 Hook ABI 写错，继续解析会把错误数据当成金额。
        if (result.length != 64) InvalidHookResponse.selector.revertWith();
        return result.parseReturnDelta();
    }

    /// @notice 当某次操作由 hook 自己发起时，跳过回调该 hook，避免递归自调用。
    /// @dev Hook 内部有时会调用 `PoolManager` 再做一次换币、增减流动性或捐赠。
    ///      如果不跳过自调用，Hook 调用 PoolManager，PoolManager 又回调同一个 Hook，
    ///      很容易形成无限递归，或让 Hook 自己触发自己的风控/收费逻辑。
    modifier noSelfCall(IHooks self) {
        if (msg.sender != address(self)) {
            _;
        }
    }

    /// @notice 若地址包含权限位，则在建池状态写入前调用 beforeInitialize hook 并验证返回值。
    /// @dev 业务上常用来阻止不合规建池，例如限制初始价格范围、只允许特定创建者、
    ///      检查 currency0/currency1 是否属于允许资产，或为后续池子状态预先做校验。
    function beforeInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96) internal noSelfCall(self) {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeInitialize, (msg.sender, key, sqrtPriceX96)));
        }
    }

    /// @notice 若地址包含权限位，则在池子初始化完成后调用 afterInitialize hook 并验证返回值。
    /// @dev 此时核心池状态已经存在，Hook 可以记录新池的初始 tick、初始化外部奖励参数、
    ///      建立池子到业务配置的映射，或发起与新池有关的后续动作。
    function afterInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96, int24 tick)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterInitialize, (msg.sender, key, sqrtPriceX96, tick)));
        }
    }

    /// @notice 根据 liquidityDelta 的正负调用获授权的 beforeAddLiquidity 或 beforeRemoveLiquidity hook。
    /// @dev `PoolManager.modifyLiquidity` 同时承载加仓、减仓和零流动性刷新手续费三类动作。
    ///      本函数用 `liquidityDelta` 的方向把它们路由到对应 Hook：
    ///      - 大于 0：用户准备增加区间流动性；
    ///      - 小于或等于 0：用户准备移除流动性，或用 0 触发手续费结算/仓位刷新。
    ///
    ///      before 阶段还没有改变池子流动性，适合做准入控制、时间锁、仓位范围限制或提前收费检查。
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
    /// @dev after 阶段发生在核心池流动性已经更新、费用已经计算之后，因此 Hook 能看到本次操作的真实 delta。
    ///      这适合做“结果相关”的业务，例如：
    ///      - 加仓后按投入金额收取协议服务费；
    ///      - 减仓后扣除提前退出费；
    ///      - 根据 `feesAccrued` 记录奖励、分润或积分；
    ///      - 在返回 delta 权限打开时，把一部分 token 记给 Hook，或让 Hook 补贴用户。
    ///
    ///      `hookDelta` 从 `callerDelta` 中扣除：正 delta 表示相应资产划给 Hook，负 delta 表示 Hook 补贴调用方。
    ///      注意这里仍然只是 V4 闪电记账中的账面增减，真正代币转入转出要等 unlock 结算。
    function afterModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal returns (BalanceDelta callerDelta, BalanceDelta hookDelta) {
        // 如果操作由 Hook 自己发起，不再回调同一个 Hook，也不产生额外 Hook delta。
        // 这样 Hook 可以安全地在内部管理仓位，而不会对自己的动作重复收费或重复记账。
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
                // Hook 的 delta 由 Hook 自己结算，调用方最终只承担扣除 Hook 份额后的 callerDelta。
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
                // 移除流动性同理：Hook 可以拿走退出费，也可以返回负 delta 补贴退出者。
                callerDelta = callerDelta - hookDelta;
            }
        }
    }

    /// @notice 调用获授权的 beforeSwap hook，应用指定资产 delta，并读取可选的动态 LP fee 覆盖值。
    /// @dev beforeSwap 发生在 AMM 曲线计算之前，是 Hook 影响换币路径最强的位置。
    ///      业务上可用于动态费率、限价单撮合、外部库存先成交、反 MEV 检查、订单流收费等场景。
    ///
    ///      `params.amountSpecified` 的正负表示用户是 exact output 还是 exact input。
    ///      Hook 可以通过 specified delta 调整真正进入 AMM 的数量：
    ///      - exact input 时，Hook 可以先拿走一部分输入，剩余输入再进池子；
    ///      - exact output 时，Hook 可以先提供一部分输出，池子只需补足剩余输出。
    ///
    ///      但 Hook 不能把交易类型翻转，例如不能把 exact input 改成 exact output。
    ///      unspecified delta 暂存在 `hookReturn` 中，等 afterSwap 把两阶段 Hook delta 一起转换成 token0/token1 账目。
    function beforeSwap(IHooks self, PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        internal
        returns (int256 amountToSwap, BeforeSwapDelta hookReturn, uint24 lpFeeOverride)
    {
        // 默认情况下，整个用户指定金额都进入 AMM 曲线；只有 beforeSwap Hook 返回 delta 后才会调整。
        amountToSwap = params.amountSpecified;
        if (msg.sender == address(self)) return (amountToSwap, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);

        if (self.hasPermission(BEFORE_SWAP_FLAG)) {
            bytes memory result = callHook(self, abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));

            // 返回 bytes4、一个 32 byte delta 与 LP fee 的 ABI 编码总长度必须为 96 byte。
            // 即使当前 Hook 没有 return delta 权限，beforeSwap 的 ABI 仍规定返回这三个字段。
            if (result.length != 96) InvalidHookResponse.selector.revertWith();

            // 动态费率池若要覆盖缓存费率，应返回带 override flag 的有效费率。
            // 若设置 flag 却返回无效费率，交易会回滚；未设置时继续使用池当前 LP fee。
            // 业务例子：波动率升高时 Hook 临时提高 LP fee，低波动或做市激励期再降低 fee。
            if (key.fee.isDynamicFee()) lpFeeOverride = result.parseFee();

            // 仅在获准返回 delta 时解析并应用该逻辑。
            // 没有该权限的 Hook 可以检查、记录或覆盖动态费率，但不能改变换币金额结算。
            if (self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
                hookReturn = BeforeSwapDelta.wrap(result.parseReturnDelta());

                // specified 部分对应用户指定的那一侧资产，会直接改变进入 AMM 的数量。
                // unspecified 部分对应另一侧资产，暂不影响 AMM 输入，留到 afterSwap 阶段统一处理。
                int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();

                // 根据 hook 返回值更新实际兑换数量，并检查兑换类型仍保持 exact input/output 不变。
                // 例如 exact input 不能因为 Hook 拿走过多输入而变成正数，否则后续池子会按 exact output 语义执行。
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
    /// @dev afterSwap 发生在 AMM 已经算出 `swapDelta` 之后。Hook 可以读取真实成交结果，
    ///      再决定是否对未指定资产追加 delta，例如收取输出侧费用、发放返佣、结算限价单剩余部分等。
    ///
    ///      beforeSwap 返回的是“specified/unspecified”维度，afterSwap 最终要落到 token0/token1 维度。
    ///      本函数会根据换币方向和 exactIn/exactOut 模式，把 Hook delta 转换成 `BalanceDelta`，
    ///      然后从调用方 `swapDelta` 中扣除，形成“用户账”和“Hook 账”两份最终结算差额。
    function afterSwap(
        IHooks self,
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData,
        BeforeSwapDelta beforeSwapHookReturn
    ) internal returns (BalanceDelta, BalanceDelta) {
        // Hook 自己发起换币时跳过 Hook 回调，避免自触发策略逻辑导致递归或重复收费。
        if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);

        // specified delta 来自 beforeSwap，已经影响过 AMM 实际成交数量；
        // unspecified delta 会在这里与 afterSwap 返回值相加，再统一转换成 token0/token1 delta。
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
            // `BalanceDelta` 固定是 token0/token1 维度，但 Hook 返回的是 specified/unspecified 维度。
            // 这里用 exact input/output 与 zeroForOne 判断哪一边资产是用户指定的资产。
            hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

            // 调用方需要支付 hook 的正 delta，或接收 hook 提供的负 delta。
            // PoolManager 随后会分别把 `swapDelta` 记到调用方，把 `hookDelta` 记到 Hook 地址。
            swapDelta = swapDelta - hookDelta;
        }
        return (swapDelta, hookDelta);
    }

    /// @notice 若地址包含权限位，则在 donate 更新池子手续费增长前调用 beforeDonate hook 并验证返回值。
    /// @dev donate 会把 token0/token1 直接捐给当前 in-range LP，常用于协议激励或外部奖励分发。
    ///      beforeDonate 可用于限制捐赠来源、校验奖励资产比例，或在捐赠前记录外部活动状态。
    function beforeDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(BEFORE_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    /// @notice 若地址包含权限位，则在 donate 已经计入池子后调用 afterDonate hook 并验证返回值。
    /// @dev 此时捐赠已经影响 LP 的手续费增长。Hook 可以记录奖励发放结果、更新积分系统、
    ///      向外部合约同步激励数据，或做与本次捐赠金额相关的后续业务处理。
    function afterDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    /// @notice 判断 hook 地址是否打开了某个权限位。
    /// @dev 本函数只是按位与检查，不会判断权限组合是否合理；组合合法性由 `isValidHookAddress` 负责。
    ///      由于 Solidity 地址是 160 bit，这里把地址转成 uint160 后读取最低位标记。
    function hasPermission(IHooks self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}
