// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Hooks} from "./libraries/Hooks.sol";
import {Pool} from "./libraries/Pool.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Position} from "./libraries/Position.sol";
import {LPFeeLibrary} from "./libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {NoDelegateCall} from "./NoDelegateCall.sol";
import {IHooks} from "./interfaces/IHooks.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./interfaces/callback/IUnlockCallback.sol";
import {ProtocolFees} from "./ProtocolFees.sol";
import {ERC6909Claims} from "./ERC6909Claims.sol";
import {PoolId} from "./types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "./types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {BeforeSwapDelta} from "./types/BeforeSwapDelta.sol";
import {Lock} from "./libraries/Lock.sol";
import {CurrencyDelta} from "./libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "./libraries/NonzeroDeltaCount.sol";
import {CurrencyReserves} from "./libraries/CurrencyReserves.sol";
import {Extsload} from "./Extsload.sol";
import {Exttload} from "./Exttload.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";

//  4
//   44
//     444
//       444                   4444
//        4444            4444     4444
//          4444          4444444    4444                           4
//            4444        44444444     4444                         4
//             44444       4444444       4444444444444444       444444
//           4   44444     44444444       444444444444444444444    4444
//            4    44444    4444444         4444444444444444444444  44444
//             4     444444  4444444         44444444444444444444444 44  4
//              44     44444   444444          444444444444444444444 4     4
//               44      44444   44444           4444444444444444444 4 44
//                44       4444     44             444444444444444     444
//                444     4444                        4444444
//               4444444444444                     44                      4
//              44444444444                        444444     444444444    44
//             444444           4444               4444     4444444444      44
//             4444           44    44              4      44444444444
//            44444          444444444                   444444444444    4444
//            44444          44444444                  4444  44444444    444444
//            44444                                  4444   444444444    44444444
//           44444                                 4444     44444444    4444444444
//          44444                                4444      444444444   444444444444
//         44444                               4444        44444444    444444444444
//       4444444                             4444          44444444         4444444
//      4444444                            44444          44444444          4444444
//     44444444                           44444444444444444444444444444        4444
//   4444444444                           44444444444444444444444444444         444
//  444444444444                         444444444444444444444444444444   444   444
//  44444444444444                                      444444444         44444
// 44444  44444444444         444                       44444444         444444
// 44444  4444444444      4444444444      444444        44444444    444444444444
//  444444444444444      4444  444444    4444444       44444444     444444444444
//  444444444444444     444    444444     444444       44444444      44444444444
//   4444444444444     4444   444444        4444                      4444444444
//    444444444444      4     44444         4444                       444444444
//     44444444444           444444         444                        44444444
//      44444444            444444         4444                         4444444
//                          44444          444                          44444
//                          44444         444      4                    4444
//                          44444        444      44                   444
//                          44444       444      4444
//                           444444  44444        444
//                             444444444           444
//                                                  44444   444
//                                                      444

/// @title Uniswap V4 资金池总管理器
/// @notice 统一保存并操作所有 V4 池子的状态，同时负责闪电记账、代币结算、协议费与 Hook 生命周期。
/// @dev V4 不再为每个交易对部署独立池合约，而是由本合约通过 `PoolId` 管理全部池子。
/// 用户在一次 `unlock` 会话中可以连续完成换币、增减流动性和资金划转；会话结束时，
/// 每种货币产生的临时欠款与应收款都必须净额结清，否则整笔交易回滚。
contract PoolManager is IPoolManager, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using SafeCast for *;
    using Pool for *;
    using Hooks for IHooks;
    using CurrencyDelta for Currency;
    using LPFeeLibrary for uint24;
    using CurrencyReserves for Currency;
    using CustomRevert for bytes4;

    // 1
    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    // type(int16).max
    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice 仅允许在管理器已解锁的结算会话中执行函数。
    /// @dev 需要产生货币增减额的操作必须位于 `unlock` 回调内，防止调用者绕过最终的净额结算检查。
    modifier onlyWhenUnlocked() {
        if (!Lock.isUnlocked()) ManagerLocked.selector.revertWith();
        _;
    }

    constructor(address initialOwner) ProtocolFees(initialOwner) {}

    /// @notice 开启一次闪电记账会话，并回调调用者完成具体业务操作。
    /// @dev 调用者必须实现 `IUnlockCallback.unlockCallback`。回调期间可以进行换币、增减流动性、
    /// 提取或支付资产等多步操作；回调结束后，所有地址与货币的未结算增减额必须归零。
    /// @param data 原样传给调用者回调的业务数据。
    /// @return result 调用者回调返回的数据。
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();

        Lock.unlock();

        // 具体业务全部由调用者在回调中执行，包括通过 `settle` 支付欠款以及通过 `take` 提取应收资产。
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        Lock.lock();
    }

    /// @notice 按给定池配置和初始价格创建一个新的 V4 池。
    /// @dev 货币必须按地址升序排列，tickSpacing 与 Hook 地址也必须合法。初始化前后分别调用
    /// Hook 的 `beforeInitialize` 和 `afterInitialize`，使扩展合约可以校验或记录建池过程。
    /// 当总换币费达到 100% 时，精确输出换币无法完成，因为输入金额会全部被手续费消耗。
    /// @param key 唯一描述池子的配置，包括两种货币、费率、tick 间距和 Hook。
    /// @param sqrtPriceX96 初始价格的平方根，以 Q64.96 定点数表示。
    /// @return tick 与初始价格对应的 tick。
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external noDelegateCall returns (int24 tick) {
        // tickSpacing 过大会使 TickBitmap 的压缩 tick 计算溢出，具体边界推导见 TickBitmap。
        // [1, 32767]
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        // Hooks.isValidHookAddress 验证hook地址+fee 是否合法
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

        // 获取LP fee，动态费率池初始化时费率为 0
        uint24 lpFee = key.fee.getInitialLPFee();

        // 调用hooks的beforeInitialize，允许hook在建池前做一些校验或记录
        key.hooks.beforeInitialize(key, sqrtPriceX96);

        // poolId = keccak256(abi.encode(poolKey))，PoolKey 由 5 个 32 byte 槽位组成，总长度为 0xa0。
        // PoolId.toId()
        PoolId id = key.toId();

        // 初始化池子状态，包括设置初始价格，lp fee，并返回sqrtPriceX96对应的tick
        tick = _pools[id].initialize(sqrtPriceX96, lpFee);

        // 先发事件再调用 afterInitialize，确保链上日志始终按照“核心状态变化 -> 后置 Hook”的顺序出现。
        // PoolKey 不会整体存入 storage，后续调用必须再次提供，因此事件需要完整记录建池配置。
        // `fee` 既可能是固定费率，也可能是表示动态费率池的特殊标记值。
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);

        key.hooks.afterInitialize(key, sqrtPriceX96, tick);
    }

    /// @notice 增加、减少或仅刷新指定价格区间的流动性仓位。
    /// @dev `liquidityDelta` 为正表示加仓，为负表示减仓，为零可用于领取或刷新已累积手续费。
    /// 返回给调用者的增减额由本金、区间手续费以及 Hook 可能追加的增减额共同组成。
    /// `feesAccrued` 仅供展示，恶意参与者可通过捐赠并在同一回调中收取手续费来人为放大该值，
    /// 集成方不能把它当作可信的收益证明。
    /// @param key 目标池配置。
    /// @param params 仓位上下 tick、流动性变化量和区分同区间仓位的 salt。
    /// @param hookData 原样传给增减流动性 Hook 的附加业务数据。
    /// @return callerDelta 本次操作最终计入调用者的两种货币增减额。
    /// @return feesAccrued 该仓位区间本次结算出的手续费增减额，仅供参考。
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        {
            Pool.State storage pool = _getPool(id);
            // 检查池子是否已初始化，未初始化的池子无法增减流动性。
            pool.checkPoolInitialized();

            key.hooks.beforeModifyLiquidity(key, params, hookData);

            BalanceDelta principalDelta;
            (principalDelta, feesAccrued) = pool.modifyLiquidity(
                Pool.ModifyLiquidityParams({
                    owner: msg.sender,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: params.liquidityDelta.toInt128(),
                    tickSpacing: key.tickSpacing,
                    salt: params.salt
                })
            );

            // 本金变化和已累积手续费都属于仓位操作者，先合并后再交给 afterModifyLiquidity 调整。
            callerDelta = principalDelta + feesAccrued;
        }

        // 在后置 Hook 前发出核心事件，使不同池操作的日志顺序稳定且便于索引。
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);

        BalanceDelta hookDelta;
        (callerDelta, hookDelta) = key.hooks.afterModifyLiquidity(key, params, callerDelta, feesAccrued, hookData);

        // 只有声明了“可返回增减额”权限的 Hook 才能产生 hookDelta，否则 Hooks 库保证它恒为零。
        // hookDelta 表示 Hook 自己相对池子的两币种账面增减额，而不是用户的增减额。
        // 典型业务场景：
        // - Hook 对加仓收服务费：hookDelta 为正，表示池子欠 Hook，调用方的 callerDelta 已被扣掉这部分；
        // - Hook 补贴用户或替用户承担一部分成本：hookDelta 为负，表示 Hook 欠池子，调用方少付或多收；
        // - Hook 没有 return-delta 权限或本次不收费/不补贴：hookDelta 为 0。
        //
        // 非零时必须把这笔账记到 Hook 合约地址名下，因为 unlock 结束前，Hook 也要像普通用户一样
        // 通过 settle/take 把自己的债权债务结清。若这里不单独记账，Hook 返回的费用或补贴只会改变
        // callerDelta，却不会在 Hook 账户下留下待结算记录，闪电记账就无法守住“所有资产净额平衡”的约束。
        // 为 0 时跳过调用只是省 gas：_accountPoolBalanceDelta 最终也会忽略 0 delta。
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));

        _accountPoolBalanceDelta(key, callerDelta, msg.sender);
    }

    /// @notice 在指定池中执行换币，并把最终的两种货币增减额记到调用者名下。
    /// @dev `amountSpecified` 的正负决定精确输入或精确输出模式。低流动性池可能无法完全满足指定金额；
    /// 若 Hook 开启换币增减额返回权限，它还可以改变实际输入或输出，因此集成方必须检查 `swapDelta`
    /// 并自行执行滑点、最低输出或最高输入保护。
    /// @param key 目标池配置。
    /// @param params 换币方向、指定金额及价格边界。
    /// @param hookData 原样传给换币 Hook 的附加业务数据。
    /// @return swapDelta 换币和 Hook 调整后计入调用者的两种货币增减额。
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta)
    {
        if (params.amountSpecified == 0) SwapAmountCannotBeZero.selector.revertWith();
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        BeforeSwapDelta beforeSwapDelta;
        {
            int256 amountToSwap;
            uint24 lpFeeOverride;
            (amountToSwap, beforeSwapDelta, lpFeeOverride) = key.hooks.beforeSwap(key, params, hookData);

            // 执行核心换币、累计输入币种的协议费并发出事件。
            // 抽到 `_swap` 中可缩短当前作用域内变量生命周期，避免 Solidity 的栈过深错误。
            swapDelta = _swap(
                pool,
                id,
                Pool.SwapParams({
                    tickSpacing: key.tickSpacing,
                    zeroForOne: params.zeroForOne,
                    amountSpecified: amountToSwap,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    lpFeeOverride: lpFeeOverride
                }),
                params.zeroForOne ? key.currency0 : key.currency1 // 按换币方向确定收取协议费的输入币种
            );
        }

        BalanceDelta hookDelta;
        (swapDelta, hookDelta) = key.hooks.afterSwap(key, params, swapDelta, hookData, beforeSwapDelta);

        // 未开启返回增减额权限时 hookDelta 必为零；非零时将其记在 Hook 合约自己的账上。
        // afterSwap 的 hookDelta 只可能影响“非指定币种”一侧，Hooks.afterSwap 会把它转换成
        // currency0/currency1 形式的 BalanceDelta。业务上它常用于：
        // - Hook 从换币结果中抽取额外费用；
        // - Hook 给交易者返佣、补贴或做外部激励；
        // - Hook 根据 beforeSwap 记录的业务数据，在成交后再调整一小部分输出/输入。
        //
        // 这笔 delta 的归属方是 Hook 合约，不是交易者。PoolManager 先把 Hook 自己的增减额记到
        // address(key.hooks)，再把最终 swapDelta 记到 msg.sender，这样用户和 Hook 会分别在同一个
        // unlock 会话里结算各自的债务或应收。若 hookDelta 为 0，则没有额外 Hook 账目需要记录。
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);
    }

    /// @notice 执行池内换币、累计输入币种协议费并发出核心换币事件。
    /// @param pool 目标池的存储状态。
    /// @param id 目标池的唯一标识。
    /// @param params 已包含最终费率覆盖值的底层换币参数。
    /// @param inputCurrency 本次交易的输入币种，协议费按该币种累计。
    /// @return 调用者相对于池子的两种货币增减额。
    function _swap(Pool.State storage pool, PoolId id, Pool.SwapParams memory params, Currency inputCurrency)
        internal
        returns (BalanceDelta)
    {
        (BalanceDelta delta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result) =
            pool.swap(params);

        // 协议费从输入资产中扣取，因此按 inputCurrency 分币种累计，等待控制器后续领取。
        if (amountToProtocol > 0) _updateProtocolFees(inputCurrency, amountToProtocol);

        // 事件在外层 afterSwap Hook 前发出，保持所有换币日志一致的生命周期顺序。
        emit Swap(
            id,
            msg.sender,
            delta.amount0(),
            delta.amount1(),
            result.sqrtPriceX96,
            result.liquidity,
            result.tick,
            swapFee
        );

        return delta;
    }

    /// @notice 将两种货币按当前有效流动性比例捐赠给池内处于价格范围内的 LP。
    /// @dev 捐赠可能被即时流动性抢跑并分走收益，业务方应自行设计防抢跑机制。
    /// 分配依据是 `slot0.tick`；在价格正好位于 tick 边界的少数情形中，它可能与根据平方根价格
    /// 反推的 tick 相差 1，具体原因见 `Pool.swap` 的边界说明。
    /// @param key 接收捐赠的池配置。
    /// @param amount0 捐赠的 currency0 数量。
    /// @param amount1 捐赠的 currency1 数量。
    /// @param hookData 原样传给捐赠 Hook 的附加业务数据。
    /// @return delta 捐赠后计入调用者的两种货币负债。
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        Pool.State storage pool = _getPool(poolId);
        pool.checkPoolInitialized();

        key.hooks.beforeDonate(key, amount0, amount1, hookData);

        delta = pool.donate(amount0, amount1);

        _accountPoolBalanceDelta(key, delta, msg.sender);

        // 先记录核心捐赠事件，再进入 afterDonate，保持 Hook 生命周期对应的日志顺序。
        emit Donate(poolId, msg.sender, amount0, amount1);

        key.hooks.afterDonate(key, amount0, amount1, hookData);
    }

    /// @notice 记录管理器当前持有的某 ERC20 余额，作为后续 `settle` 计算实际到账量的检查点。
    /// @dev 支付 ERC20 前必须先调用本函数，再转币并调用 `settle`。原生币通过 `msg.value`
    /// 直接确定支付量，无需保存余额；传入原生币还可清除先前尚未结算的 ERC20 检查点。
    /// @param currency 即将用于结算的币种。
    function sync(Currency currency) external {

        // 在用户准备给 PoolManager 支付某个 ERC20 之前，先记录 PoolManager 当前持有多少这个 token。后面用户转账进来，
        // 再通过 settle() 计算“到底新到账了多少”。

        // address(0) 代表原生币。
        if (currency.isAddressZero()) {
            // 原生币不依赖 ERC20 balanceOf 差值，只需清除当前同步币种，避免沿用旧检查点。
            CurrencyReserves.resetCurrency();
        } else {
            uint256 balance = currency.balanceOfSelf();
            CurrencyReserves.syncCurrencyAndReserves(currency, balance);
        }
    }

    /// @notice 从管理器向指定地址转出资产，用于兑现调用者账上的正向应收额。
    /// @dev 转出前先给调用者记一笔负增减额；若其可用应收不足，会在会话结束时因未结清而回滚。
    /// 该机制也允许在同一解锁会话内借出并归还资产，形成免费的闪电流动性。
    /// @param currency 要转出的币种。
    /// @param to 接收资产的地址。
    /// @param amount 转出数量。
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // amount 是无符号数，转为 int128 后取负用于表示调用者从管理器取走资产。
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            currency.transfer(to, amount);
        }
    }

    /// @notice 支付调用者自己欠管理器的资产。
    /// @return paid 本次根据原生币金额或 ERC20 余额差确认的实付数量。
    function settle() external payable onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    /// @notice 支付资产并把到账额度记到另一个地址名下。
    /// @param recipient 获得正向结算额度的地址。
    /// @return paid 本次根据原生币金额或 ERC20 余额差确认的实付数量。
    function settleFor(address recipient) external payable onlyWhenUnlocked returns (uint256) {
        return _settle(recipient);
    }

    /// @notice 主动放弃一笔精确等于当前正向增减额的资产。
    /// @dev 本操作只清账而不转币，资金会永久留在管理器内且无法取回，通常仅用于清理小额尘埃。
    /// 必须传入完整的正向余额，避免调用者在不清楚金额时误删部分权益。
    /// @param currency 要清理的币种。
    /// @param amount 必须与调用者当前正向增减额完全相等。
    function clear(Currency currency, uint256 amount) external onlyWhenUnlocked {
        int256 current = currency.getDelta(msg.sender);
        // 输入类型是 uint256，因此只能清理正向应收额，不能借此抹除欠款。
        int128 amountDelta = amount.toInt128();
        if (amountDelta != current) MustClearExactPositiveDelta.selector.revertWith();
        // amountDelta 已确认是正值，取负后用于把当前应收额精确冲为零。
        unchecked {
            _accountDelta(currency, -(amountDelta), msg.sender);
        }
    }

    /// @notice 将调用者在某币种上的应收价值转换为可持有、转让的 ERC6909 凭证。
    /// @dev `id` 的低 160 位解释为币种地址，高 12 字节会被截断。铸造凭证的同时给调用者
    /// 记同额负增减额，因此必须拥有足够应收或在会话结束前补足欠款。
    /// @param to 接收 ERC6909 凭证的地址。
    /// @param id 以 uint256 表示的币种地址。
    /// @param amount 铸造数量。
    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            Currency currency = CurrencyLibrary.fromId(id);
            // amount 是无符号数，负号表示将等值资产从调用者临时账本转入 ERC6909 凭证。
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            _mint(to, currency.toId(), amount);
        }
    }

    /// @notice 销毁 ERC6909 币种凭证，并把对应价值记为调用者可用于结算的正向增减额。
    /// @dev `id` 的低 160 位解释为币种地址，高 12 字节会被截断。
    /// @param from 被销毁凭证的持有人。
    /// @param id 以 uint256 表示的币种地址。
    /// @param amount 销毁数量。
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        Currency currency = CurrencyLibrary.fromId(id);
        _accountDelta(currency, amount.toInt128(), msg.sender);
        _burnFrom(from, currency.toId(), amount);
    }

    /// @notice 更新已启用动态费率池的 LP 换币费。
    /// @dev 只有该池绑定的 Hook 可以调用，且新费率必须合法。100% 费率会使精确输出交易不可完成。
    /// @param key 需要更新动态 LP 费率的池配置。
    /// @param newDynamicLPFee 新的 LP 换币费率，以百万分之一为精度。
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        if (!key.fee.isDynamicFee() || msg.sender != address(key.hooks)) {
            UnauthorizedDynamicLPFeeUpdate.selector.revertWith();
        }
        newDynamicLPFee.validate();
        PoolId id = key.toId();
        _pools[id].setLPFee(newDynamicLPFee);
    }

    // 即使支付原生币，集成方也应先对原生币调用 `sync`，清除可能残留的 ERC20 检查点以避免拒绝服务。
    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = CurrencyReserves.getSyncedCurrency();

        // 未同步币种或同步槽已重置时，当前结算被解释为原生币支付。
        if (currency.isAddressZero()) {
            paid = msg.value;
        } else {
            if (msg.value > 0) NonzeroNativeValue.selector.revertWith();
            // 币种和检查点余额总是同时写入，因此读到 ERC20 币种时一定存在对应的 reservesBefore。
            uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
            uint256 reservesNow = currency.balanceOfSelf();
            paid = reservesNow - reservesBefore;
            CurrencyReserves.resetCurrency();
        }

        _accountDelta(currency, paid.toInt128(), recipient);
    }

    /// @notice 为目标地址累计某币种的临时增减额，并维护全局未结清项计数。
    /// @dev V4 的核心资金模型是“先记账、后结算”。swap、增减流动性、donate、mint/burn、
    /// take/settle 等操作不会立刻要求每一步都完成 ERC20/native 转账，而是在本次 `unlock`
    /// 会话里把每个地址、每个币种的净额暂存在 transient storage 中。
    ///
    /// 正值表示管理器欠目标地址：例如用户 swap 后应收到输出币，或 LP 减仓后应取回本金/手续费；
    /// 目标地址之后可以调用 `take` 提走资产，或用 `clear` 放弃小额尘埃。
    ///
    /// 负值表示目标地址欠管理器：例如用户加仓需要支付 token，或 swap 需要支付输入币；
    /// 目标地址之后必须调用 `settle`/`settleFor` 把资产转入管理器，或用其他操作抵消这笔负债。
    ///
    /// `NonzeroDeltaCount` 只统计“仍未结清的 address+currency 组合数量”。只有从零变为非零或从
    /// 非零归零时才调整计数，这样 `unlock` 结束时不用遍历全部用户和币种，只需要检查计数是否为 0。
    /// 这也是闪电记账能支持复杂多步组合操作的关键：中途可以欠款或应收，但离开 unlock 前必须清零。
    /// @param currency 发生记账的币种。
    /// @param delta 本次追加的有符号增减量。
    /// @param target 被记账的地址。
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        // 0 delta 不改变任何地址的债权债务，也不会影响未结清项数量，直接返回可以减少一次 tload/tstore。
        if (delta == 0) return;

        // CurrencyDelta.applyDelta 等价于：
        // deltas[target][currency] = deltas[target][currency] + delta
        // 但它写入的是 transient storage，交易结束会自动清空，不会长期占用合约 storage。
        (int256 previous, int256 next) = currency.applyDelta(target, delta);

        // 如果本次记账后余额归零，说明该 address+currency 的债权债务已经完全抵消或结清。
        if (next == 0) {
            NonzeroDeltaCount.decrement();
        // 如果本次记账前为 0、之后非 0，说明出现了一项新的待结算账目。
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }
    }

    /// @notice 将一个池的 currency0 与 currency1 增减额同时记到目标地址名下。
    /// @dev BalanceDelta 是池操作返回的“两币种净额包”：amount0 对应 PoolKey.currency0，
    /// amount1 对应 PoolKey.currency1。Pool.swap、Pool.modifyLiquidity、Pool.donate 只关心
    /// 这个池里的两种资产，所以外层管理器要把它拆成两笔单币种账目写入闪电记账系统。
    ///
    /// 业务上可以把本函数理解成“把某次池操作的结果过账到某个账户”：
    /// - target 是 msg.sender 时，表示用户这次换币、加仓、减仓或捐赠产生的净应收/应付；
    /// - target 是 Hook 地址时，表示 Hook 通过 return-delta 权限从用户结果中抽成或提供补贴；
    /// - 正数代表 target 可以从管理器拿走对应币种，负数代表 target 必须向管理器补入对应币种。
    ///
    /// 这里不直接转 token，只调用 `_accountDelta` 写入临时账本；真正的资金流动由同一 unlock 会话中的
    /// `take`、`settle`、`mint`、`burn` 或后续抵消操作完成。
    /// @param key 用于确定两种币种的池配置。
    /// @param delta 已打包的两币种增减额。
    /// @param target 被记账的地址。
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }

    /// @notice 向协议费模块提供指定池的存储引用。
    /// @dev `ProtocolFees` 通过该实现更新池级协议费，而无需直接持有 `_pools` 映射。
    /// @param id 目标池标识。
    /// @return 指定池的存储状态。
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice 向协议费模块返回管理器当前是否处于解锁会话。
    /// @return 管理器已解锁时为 true。
    function _isUnlocked() internal view override returns (bool) {
        return Lock.isUnlocked();
    }
}
