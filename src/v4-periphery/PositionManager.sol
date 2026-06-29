// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {PoolInitializer_v4} from "./base/PoolInitializer_v4.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";
import {Notifier} from "./base/Notifier.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {SlippageCheck} from "./libraries/SlippageCheck.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

//                                           444444444
//                                444444444444      444444
//                              444              44     4444
//                             44         4      44        444
//                            44         44       44         44
//                           44          44        44         44
//                          44       444444          44        44
//                         444          4444           4444    44
//                         44             4444                 444444444444444444
//                         44             44  4                44444           444444
//        444444444444    44              4                444                      44
//        44        44444444              4             444                         44
//       444              44                          44                           444
//        44               4  4444444444444444444444444           4444444444     4444
//         44              44444444444444444444444444      444               44444
//          444                                  44 44444444444444444444444444
//           4444                             444444444444444444444444
//              4444                      444444    444444444444444
//                 44444              444444        44444444444444444444444
//                     444444444444444    4           44444 44444444444444444444
//                           444                          444444444444444444444444444
//                           444                           44444  44444444444     44444444
//                          444                               4   44444444444444   444444444
//                         4444 444                               44 4444444444444     44444444
//                         44  44444         44444444             44444444444444444444     44444
//                        444 444444        4444  4444             444444444444444444     44  4444
//                 4444   44  44444        44444444444             444444444444444444444    44444444
//                     44444   4444        4444444444             444444444444444444444444     44444
//                 44444 44444 444         444444                4444444444444444444444444       44444
//                       4444 44         44                     4 44444444444444444444444444   444 44444
//                   44444444 444  44   4    4         444444  4 44444444444444444444444444444   4444444
//                        444444    44       44444444444       44444444444444 444444444444444      444444
//                     444444 44   4444      44444       44     44444444444444444444444 4444444      44444
//                   44    444444   44   444444444 444        4444444444444444444444444444444444   4444444
//                       44  4444444444444    44  44  44       4444444444444444444444444444444       444444
//                      44  44444444444444444444444444  4   44 4444444444444444444444444444444    4   444444
//                     4    4444                     4    4 4444444444444444444444444              44 4444444
//                          4444                          4444444444444444444444444    4   4444     44444444
//                          4444                         444444444444444444444444  44444     44444 4444444444
//                          44444  44                  444444444444444444444444444444444444444444444444444444
//                          44444444444               4444444444444444444444444444444444444444444444444444444
//                           4444444444444           44444444444444444444444444444444444444444444444444444444
//                           444444444444444         444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     4444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     44444444444444444444444444444444444444444444444444444444
//                            44444444444444444444  444444444444444444444444444444444444444444444444444444444
//                            444444444444444444444 444444444444444444444444444444444444444444444444444444444
//                              444444444444444444444 4444444444444444444444444444444444444444444444444444444
//                              44444444444444444444444444444444444444444444444444444444444444444444444444444
//                               444444444444444444444444444444444444444444444444444444444444444444444444444
//                                44444444444444444444444444444444444444444444444444444444444444444444444444
//                               44444444444444444444444444444444444444444444444444      444444444444444444
//                             444444444444444444444444444444444444444444444444       44444444444444444444
//                           444   444   444   44  444444444444444444444 4444      444444444444444444444
//                           444  444    44    44  44444444 4444444444444       44444444444444444444444
//                            444 444   4444   4444 4444444444444444         44444444444444444444444444
//                      4444444444444444444444444444444444444444        44444444444444444444444444444
//                       444        4444444444444444444444444       44444444444444444444444444444444
//                          4444444       444444444444         4444444444444444444444444444444444
//                             4444444444                 44444444444444444444444444444444444
//                                444444444444444444444444444444444444444444444444444444
//                                     44444444444444444444444444444444444444444
//                                              4444444444444444444

/// @notice PositionManager（简称 PosM）负责创建和管理 Uniswap V4 集中流动性仓位。
/// 每个仓位由一个 ERC-721 凭证表示，NFT 所有权决定谁可以增减流动性、领取手续费、转让或销毁仓位。
/// @dev PosM 自身是 `PoolManager` 中仓位的 owner，并使用 `tokenId` 作为 salt 隔离底层仓位状态；
/// 用户持有的 NFT 则是外围层权限凭证。动作批处理会在同一解锁周期内修改仓位并结清所有货币 delta。
contract PositionManager is
    IPositionManager,
    ERC721Permit_v4,
    PoolInitializer_v4,
    Multicall_v4,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    Notifier,
    Permit2Forwarder,
    NativeWrapper
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CalldataDecoder for bytes;
    using SlippageCheck for BalanceDelta;

    /// @notice 返回下一枚新流动性仓位 NFT 将使用的 token ID。
    /// @return 下一枚 token ID。
    /// @dev 从 1 开始并跳过 0，铸造时先取当前值再递增。
    uint256 public nextTokenId = 1;

    IPositionDescriptor public immutable tokenDescriptor;

    mapping(uint256 tokenId => PositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9
    )
        BaseActionsRouter(_poolManager)
        Permit2Forwarder(_permit2)
        ERC721Permit_v4("Uniswap v4 Positions NFT", "UNI-V4-POSM")
        Notifier(_unsubscribeGasLimit)
        NativeWrapper(_weth9)
    {
        tokenDescriptor = _tokenDescriptor;
    }

    /// @notice 校验批处理是否仍在用户允许的有效期内，过期则回退。
    /// @param deadline 调用者指定的 Unix 时间戳；区块时间超过该值后交易失效。
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice 校验调用者是否为仓位 NFT 的所有者或已获 ERC-721 授权。
    /// @param caller 要校验的调用者地址。
    /// @param tokenId 仓位 NFT 的唯一标识。
    /// @dev `caller` 可以是直接调用阶段的 `msg.sender`，也可以是回调阶段由 `msgSender()` 恢复的原始调用者。
    /// 除非调用链已有重入保护，否则只能在 `unlockCallback` 内使用 `msgSender()`，以免读取到陈旧的 locker。
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @notice 要求 `PoolManager` 当前处于锁定状态，避免仓位修改期间同时触发转让或订阅通知。
    modifier onlyIfPoolManagerLocked() override {
        if (poolManager.isUnlocked()) revert PoolManagerMustBeLocked();
        _;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IPositionDescriptor(tokenDescriptor).tokenURI(this, tokenId);
    }

    /// @notice 解锁 V4 `PoolManager`，并原子执行一组修改流动性及资金结算动作。
    /// @dev 这是 PosM 的标准入口。`unlockData` 编码动作字节和逐动作参数，执行结束前所有负 delta 必须结清。
    /// @param unlockData `(bytes actions, bytes[] params)` 的 ABI 编码。
    /// @param deadline 本批动作允许执行的最后时间戳。
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    /// @notice 在调用方已经解锁 `PoolManager` 的上下文中直接执行一组流动性动作。
    /// @dev 仅应由掌控当前解锁周期的可信合约调用；本函数不会再次调用 `PoolManager.unlock`。
    /// @param actions 按顺序执行的动作编号字节。
    /// @param params 与每个动作一一对应的 ABI 编码参数。
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        _executeActionsWithoutUnlock(actions, params);
    }

    /// @notice 返回触发当前动作批次的原始调用者。
    /// @dev 回调期间 `msg.sender` 是 `PoolManager`，因此从重入锁保存的 locker 中恢复用户地址。
    /// @return 当前批次的原始调用者。
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action < Actions.SETTLE) {
            if (action == Actions.INCREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                // 已弃用：按当前 delta 推导流动性会暴露三明治攻击面，请勿使用，详见 _increaseFromDeltas()。
                (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeIncreaseLiquidityFromDeltasParams();
                _increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _decrease(tokenId, liquidity, amount0Min, amount1Min, hookData);
                return;
            } else if (action == Actions.MINT_POSITION) {
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintParams();
                _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
                // 已弃用：按当前 delta 推导流动性会暴露三明治攻击面，请勿使用，详见 _mintFromDeltas()。
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintFromDeltasParams();
                _mintFromDeltas(poolKey, tickLower, tickUpper, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.BURN_POSITION) {
                // 若仓位仍有流动性，会先自动降至 0，再销毁 NFT。
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeBurnParams();
                _burn(tokenId, amount0Min, amount1Min, hookData);
                return;
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                _settlePair(currency0, currency1);
                return;
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = params.decodeCurrencyPairAndAddress();
                _takePair(currency0, currency1, _mapRecipient(recipient));
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = params.decodeCurrency();
                _close(currency);
                return;
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                _clearOrTake(currency, amountMax);
                return;
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
                return;
            } else if (action == Actions.WRAP) {
                uint256 amount = params.decodeUint256();
                _wrap(_mapWrapUnwrapAmount(CurrencyLibrary.ADDRESS_ZERO, amount, Currency.wrap(address(WETH9))));
                return;
            } else if (action == Actions.UNWRAP) {
                uint256 amount = params.decodeUint256();
                _unwrap(_mapWrapUnwrapAmount(Currency.wrap(address(WETH9)), amount, CurrencyLibrary.ADDRESS_ZERO));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    /// @dev 增加 0 流动性仍会触发底层仓位记账，从而把已累积手续费记为调用方可领取的正 delta。
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal virtual onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // tokenId 同时作为底层仓位 salt，确保每枚 NFT 在 PoolManager 中拥有独立存储。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // 滑点只约束新增流动性的本金支出；应从总 delta 中扣除本次同步到的历史手续费。
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @notice 已弃用：该按 delta 增仓方式容易遭受三明治攻击，请勿使用。
    /// @dev 与 `_mintFromDeltas` 相同，它只限制代币最大支出，却没有最低流动性保护。
    /// 攻击者可临时移动价格，使同样信用额只铸造更少流动性。应改用显式指定 `liquidity` 的 `_increase()`。
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        virtual
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity;
        {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

            // 把 PoolManager 中两种货币的全部正 delta 当作本次增仓可用金额。
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(info.tickLower()),
                TickMath.getSqrtPriceAtTick(info.tickUpper()),
                _getFullCredit(poolKey.currency0),
                _getFullCredit(poolKey.currency1)
            );
        }

        // tokenId 作为 salt，使每枚 NFT 对应独立的底层仓位。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // 仅对本金支出检查滑点，排除同步手续费对 delta 的影响。
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @dev 减少 0 流动性仍可同步仓位已累积手续费，并把它们记为调用方可领取的正 delta。
    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // 底层仓位使用 tokenId 作为 salt。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        // 最低收款检查仅针对移除流动性返还的本金，不把历史手续费混入滑点判断。
        (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
    }

    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal virtual {
        // 先铸造代表仓位所有权和操作权限的 ERC-721 凭证。
        uint256 tokenId;
        // 使用当前 nextTokenId，随后递增，为下一仓位预留新编号。
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // 初始化并保存池标识、价格区间及订阅状态等压缩仓位信息。
        // type PositionInfo is uint256;
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        positionInfo[tokenId] = info;

        // 同一池只保存一次完整 PoolKey，后续仓位通过压缩 poolId 复用。
        // V4 合法 tickSpacing 最小为 1，因此 0 可安全作为“尚未写入”的哨兵值。
        bytes25 poolId = info.poolId();
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        // 新仓位此前没有手续费快照，因此可忽略 feesAccrued，只校验实际投入本金的最大值。
        (BalanceDelta liquidityDelta,) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxIn(amount0Max, amount1Max);
    }

    /// @notice 已弃用：该按 delta 铸仓方式容易遭受三明治攻击，请勿使用。
    /// @dev 已结算到 PoolManager 的金额本身就是支出上限，所以 `amount0Max/amount1Max` 不能提供有效保护；
    /// 同时用户没有声明最低应得流动性。价格被临时操纵后，合约可能只使用较少代币、退回余款，
    /// 却也只铸造更少流动性，最大支出检查始终不会触发。应使用显式指定 `liquidity` 的 `_mint()`。
    function _mintFromDeltas(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // 使用 PoolManager 中已有的两种货币信用额计算可铸造流动性。
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _getFullCredit(poolKey.currency0),
            _getFullCredit(poolKey.currency1)
        );

        _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev 本函数与 `ERC721Permit_v4._burn` 重载：此处负责完整退出底层流动性，再销毁 NFT。
    function _burn(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        internal
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity = uint256(_getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper()));

        address owner = ownerOf(tokenId);

        // 先清空外围仓位信息，避免后续回调继续把 NFT 视为有效仓位。
        positionInfo[tokenId] = PositionInfoLibrary.EMPTY_POSITION_INFO;
        // 销毁代表仓位权限的 NFT。
        _burn(tokenId);

        // 仅在仍有流动性时调用底层移除；空仓位仍可直接销毁 NFT。
        BalanceDelta feesAccrued;
        if (liquidity > 0) {
            BalanceDelta liquidityDelta;
            // 销毁流程不发送普通 modify 通知，因此直接调用 PoolManager，最后单独发送 burn 通知。
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: -(liquidity.toInt256()),
                salt: bytes32(tokenId)
            });
            (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(poolKey, params, hookData);
            emit ModifyPosition(
                poolKey.toId(), msgSender(), params.tickLower, params.tickUpper, params.liquidityDelta, params.salt
            );
            // 最低收款只约束退出本金，已累积手续费单独从总 delta 中扣除。
            (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
        }

        // 若存在订阅者，先删除订阅关系，再通知仓位已销毁，防止通知期间重复使用旧状态。
        if (info.hasSubscriber()) _removeSubscriberAndNotifyBurn(tokenId, owner, info, liquidity, feesAccrued);
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // 当前批次的 locker 是最终付款方，分别结清两种货币的全部负 delta。
        address caller = msgSender();
        _settle(currency0, caller, _getFullDebt(currency0));
        _settle(currency1, caller, _getFullDebt(currency1));
    }

    function _takePair(Currency currency0, Currency currency1, address recipient) internal {
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
    }

    function _close(Currency currency) internal {
        // PosM 代表用户累计了整个批次的 delta；各业务动作已执行滑点检查，因此可在末尾安全关闭该货币的全部净额。
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        // locker 既可能需要补足负 delta，也可能接收正 delta。
        address caller = msgSender();
        if (currencyDelta < 0) {
            // 货币总供应量限制了 delta 范围，取负后转换为 uint256 是安全的。
            _settle(currency, caller, uint256(-currencyDelta));
        } else {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev 集成方可用 `clear` 主动放弃很小的正 delta，以避免领取零碎余额的成本。
    /// 若信用额超过用户允许放弃的 `amountMax`，则改为全部领取；没有信用额时不发起外部调用。
    function _clearOrTake(Currency currency, uint256 amountMax) internal {
        uint256 delta = _getFullCredit(currency);
        if (delta == 0) return;

        // 只有零碎信用额不超过用户上限时才放弃，否则完整转给原始调用者。
        if (delta <= amountMax) {
            poolManager.clear(currency, delta);
        } else {
            _take(currency, msgSender(), delta);
        }
    }

    /// @notice 将本合约持有的指定货币全部扫转给收款人，用于处理批次结束后的外围余额。
    function _sweep(Currency currency, address to) internal virtual {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    /// @dev 修改底层流动性后发出镜像事件；若仓位绑定订阅者，还会把流动性变化和手续费增量通知给订阅者。
    function _modifyLiquidity(
        PositionInfo info,
        PoolKey memory poolKey,
        int256 liquidityChange,
        bytes32 salt,
        bytes calldata hookData
    ) internal returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) {
        (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: info.tickLower(), tickUpper: info.tickUpper(), liquidityDelta: liquidityChange, salt: salt
            }),
            hookData
        );

        emit ModifyPosition(poolKey.toId(), msgSender(), info.tickLower(), info.tickUpper(), liquidityChange, salt);

        if (info.hasSubscriber()) {
            _notifyModifyLiquidity(uint256(salt), liquidityChange, feesAccrued);
        }
    }

    // 实现 DeltaResolver._pay：自有余额直接转账，用户余额通过 Permit2 授权划转。
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            // 单池可结算数量受代币总供应量限制，转换为 Permit2 使用的 uint160 是安全的。
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    /// @notice 供 `Notifier` 使用，在压缩仓位信息中设置“已订阅”标记。
    function _setSubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setSubscribe();
    }

    /// @notice 供 `Notifier` 使用，在压缩仓位信息中清除“已订阅”标记。
    function _setUnsubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
    }

    /// @dev 覆盖 Solmate `transferFrom`：转让带订阅仓位时先取消订阅，避免旧订阅者继续收到新持有人的仓位数据。
    /// `PoolManager` 已解锁时会回退，防止 hook 在仓位修改中途触发转让和通知。
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
        if (positionInfo[id].hasSubscriber()) _unsubscribe(id);
    }

    /// @notice 返回仓位 NFT 对应的完整池配置和压缩仓位信息。
    /// @param tokenId 仓位 NFT 的 token ID。
    /// @return poolKey 仓位所属 V4 池的完整键。
    /// @return info 包含 poolId、tickLower、tickUpper 和订阅标志的压缩信息。
    function getPoolAndPositionInfo(uint256 tokenId) public view returns (PoolKey memory poolKey, PositionInfo info) {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    /// @notice 返回仓位 NFT 当前在 `PoolManager` 中记录的流动性。
    /// @param tokenId 仓位 NFT 的 token ID。
    /// @return liquidity 仓位的流动性数量；可配合 `LiquidityAmounts` 换算为两种代币金额。
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
        liquidity = _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
    }

    function _getLiquidity(uint256 tokenId, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(poolKey.toId(), positionId);
    }
}
