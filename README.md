# Uniswap v4 核心功能整理

Uniswap v4 是一个更加模块化、可编程、低成本的 AMM 协议版本。

它的核心变化不是简单修改兑换公式，而是围绕以下几个方向升级：

- 池子逻辑可扩展
- 所有池子统一管理
- 内部记账，最后统一结算
- 支持动态手续费
- 支持自定义 Hook 逻辑
- 支持原生 ETH
- 支持更灵活的仓位管理
- 支持 LP 仓位订阅通知机制

下面整理 Uniswap v4 主要的 9 个核心功能。

---

## 1. Hooks：池子插件系统

Hooks 是 Uniswap v4 最核心的新功能。

Hook 可以理解为挂在 Pool 上的插件合约。

当用户进行 swap、添加流动性、移除流动性、初始化池子等操作时，PoolManager 会在特定时机调用 Hook 合约，让开发者可以插入自定义逻辑。

常见 Hook 回调包括：

```solidity
beforeInitialize()
afterInitialize()

beforeAddLiquidity()
afterAddLiquidity()

beforeRemoveLiquidity()
afterRemoveLiquidity()

beforeSwap()
afterSwap()

beforeDonate()
afterDonate()
```

Hooks 可以实现很多自定义玩法，例如：

```text
1. 动态手续费
2. 限价单
3. TWAMM，大单拆分交易
4. 自动复投手续费
5. LP 激励
6. 交易返佣
7. 白名单交易池
8. 防 MEV / 防三明治攻击
9. 买卖税
10. 自定义预言机
11. 自定义做市策略
12. 特殊交易规则
```

通俗理解：

```text
Uniswap v4 = AMM 底座 + Hook 插件系统
```

Hooks 的意义是：

```text
开发者可以基于 Uniswap v4 的流动性底座，设计自己的池子规则、交易逻辑、LP 激励和资产结算方式。
```

---

## 2. Singleton PoolManager：所有池子统一管理

Uniswap v4 使用 Singleton 架构。

所有池子都不再是独立合约，而是统一由一个核心合约 `PoolManager` 管理。

在 v4 中，不同的池子是 PoolManager 里面的一份状态。

一个池子通常由 `PoolKey` 唯一标识：

```solidity
PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}
```

也就是说，一个 v4 pool 由以下内容决定：

```text
currency0 + currency1 + fee + tickSpacing + hooks = 一个唯一的 pool
```

其中：

```text
currency0    = 第一个 token 或 ETH
currency1    = 第二个 token 或 ETH
fee          = 手续费参数
tickSpacing  = tick 间距
hooks        = 绑定的 Hook 合约地址
```

Singleton PoolManager 的好处：

```text
1. 创建池子的成本更低
2. 多跳交易更省 gas
3. 池子状态统一管理
4. 更适合复杂组合交易
5. 更适合和 Flash Accounting 配合
6. 更方便 Hook 统一接入池子生命周期
```

通俗理解：

```text
所有池子都放在 PoolManager 这个大管理器里面。
创建新池子，不是部署新合约，而是在 PoolManager 里初始化一份新的池子状态。
```

---

## 3. Flash Accounting：内部 delta 记账，最后统一结算

Flash Accounting 是 Uniswap v4 的核心结算机制。

它的核心思想是：

```text
操作过程中先不频繁真实转账
而是先记录每个地址、每种资产的余额变化 delta
最后再统一结算
```

在 v4 中，swap、添加流动性、移除流动性等操作都会产生资产变化。

这些变化不会每一步都立刻通过 ERC20 transfer 完成，而是先在 PoolManager 内部记录。

例如：

```text
用户最终应该支付多少 token0
用户最终应该收到多少 token1
PoolManager 内部先记录这些变化
最后统一 settle / take
```

delta 可以简单理解为：

```text
delta > 0：PoolManager 欠你资产
delta < 0：你欠 PoolManager 资产
```

例如：

```text
用户 swap 后应该收到 100 USDC
那么用户对 USDC 的 delta 可能是正数

用户 swap 时需要支付 0.05 ETH
那么用户对 ETH 的 delta 可能是负数
```

Flash Accounting 的好处：

```text
1. 减少真实 token transfer 次数
2. 降低 gas 成本
3. 支持复杂多步骤操作
4. 方便多跳交易
5. 方便组合 swap、LP、take、settle 等操作
```

通俗理解：

```text
先记账，最后统一结账。
```

---

## 4. Custom Accounting：Hook 可以影响最终结算

Custom Accounting 是 Uniswap v4 和 Hooks 配套的重要能力。

Hook 不只是能在 swap 前后执行代码，还可以通过返回自定义 delta 的方式影响最终结算结果。

也就是说，Hook 可以参与 PoolManager 的资产结算。

Custom Accounting 可以实现：

```text
1. swap 时额外收取费用
2. swap 后返还部分 token
3. 给 LP 分配额外奖励
4. 给交易者返佣
5. 实现买卖税
6. 实现特殊手续费分配
7. 实现特殊 AMM 行为
8. 实现自定义资产流向
```

例如，一个带买卖税的 Hook 可以这样设计：

```text
用户买入 token
Hook 在 afterSwap 中计算税费
最终结算时，用户实际收到的 token 减少一部分
减少的部分进入项目方、奖励池或回购地址
```

再比如，一个返佣 Hook 可以这样设计：

```text
用户完成 swap
Hook 根据交易量计算返佣
最终结算时，额外给用户返回一部分 token 或积分
```

通俗理解：

```text
Hooks 负责插入逻辑
Custom Accounting 负责让这些逻辑影响最终资产结算
```

它让 Uniswap v4 不只是一个固定规则 AMM，而是变成了一个可以自定义结算规则的流动性平台。

---

## 5. Dynamic Fee：动态手续费

Uniswap v4 支持动态手续费。

动态手续费的意思是：

```text
池子的手续费不一定固定
可以根据市场状态、交易行为、Hook 逻辑动态变化
```

手续费可以根据很多因素调整，例如：

```text
1. 当前市场波动率
2. 当前交易量
3. 当前流动性深度
4. 当前时间段
5. 买入还是卖出
6. 单笔交易大小
7. 是否疑似 MEV 行为
8. 是否触发特殊 Hook 条件
```

示例：

```text
市场平稳时：手续费 0.05%
市场波动较大时：手续费 0.3%
极端行情时：手续费 1%
```

动态手续费的作用：

```text
1. 在高波动时提高 LP 收益补偿
2. 在低波动时降低交易成本
3. 针对不同交易行为设置不同费率
4. 配合 Hook 实现更复杂的费用策略
```

例如：

```text
大额交易收更高手续费
普通小额交易收较低手续费
疑似三明治攻击的交易收更高手续费
特定白名单用户享受低手续费
```

通俗理解：

```text
手续费不再必须是固定值，而是可以由 Hook 根据规则动态决定。
```

---

## 6. Native ETH：支持原生 ETH

Uniswap v4 支持原生 ETH。

在 v4 中，ETH 可以作为一种特殊的 Currency 被 PoolManager 识别和处理。

这意味着用户在部分场景中可以直接使用 ETH，而不一定需要手动包装成 WETH。

相关概念：

```text
ETH  = 原生链币
WETH = ERC20 形式的 ETH
```

Native ETH 的好处：

```text
1. 用户体验更直接
2. 减少 ETH / WETH 包装步骤
3. 节省部分 gas
4. 方便前端和 Router 设计更自然的交易流程
```

在开发中需要注意：

```text
1. ETH 和 ERC20 token 的转账方式不同
2. v4 使用 Currency 抽象 ETH 和 ERC20
3. periphery 合约通常会处理 ETH / WETH 包装和解包装
4. Hook 和 Router 需要正确处理原生 ETH 结算
```

通俗理解：

```text
v4 可以更自然地支持 ETH，不再完全依赖 WETH 作为中间包装形式。
```

---

## 7. ERC-6909：内部余额 / claim 表示

Uniswap v4 引入了 ERC-6909 相关机制，用来更高效地表示 PoolManager 内部的余额或 claim。

可以简单理解为：

```text
PoolManager 内部可能会记录用户对某种资产的 claim
ERC-6909 用来表示这些内部 claim
```

在 v4 的结算模型中，很多操作不是马上真实转账，而是先形成内部余额关系。

例如：

```text
PoolManager 欠用户一些 token
用户欠 PoolManager 一些 token
用户在 PoolManager 里有某种可领取余额
```

ERC-6909 可以让这些内部余额表示更加轻量。

它和以下机制关系很深：

```text
1. Flash Accounting
2. PoolManager 内部结算
3. settle 操作
4. take 操作
5. mint claim
6. burn claim
7. 多币种余额管理
```

对普通用户来说，ERC-6909 感知不强。

但对开发者来说，它会影响：

```text
1. Router 如何处理余额
2. PositionManager 如何处理结算
3. Hook 如何处理资产变化
4. PoolManager 如何减少真实 token transfer
```

通俗理解：

```text
ERC-6909 是 v4 内部余额和 claim 的一种高效表示方式。
```

---

## 8. PositionManager Actions：命令式批处理仓位操作

Uniswap v4 的 PositionManager 使用命令式 action 设计。

核心思想是：

```text
把多个仓位操作编码成一组 actions
然后在一笔交易里批量执行
```

常见调用方式类似：

```solidity
modifyLiquidities(actions, params, deadline)
```

其中：

```text
actions = 要执行的操作列表
params  = 每个操作对应的参数
deadline = 交易截止时间
```

常见 actions 包括：

```text
MINT_POSITION
INCREASE_LIQUIDITY
DECREASE_LIQUIDITY
BURN_POSITION

SETTLE
SETTLE_PAIR
TAKE
TAKE_PAIR

CLOSE_CURRENCY
CLEAR_OR_TAKE

SWEEP
WRAP
UNWRAP
```

例如，创建一个 LP position 可能包含：

```text
1. MINT_POSITION
2. SETTLE_PAIR
```

含义是：

```text
1. 创建 LP 仓位
2. 支付 token0 / token1，完成结算
```

再比如，减少流动性并取回资产可能包含：

```text
1. DECREASE_LIQUIDITY
2. TAKE_PAIR
```

含义是：

```text
1. 减少 LP 仓位中的流动性
2. 取回 token0 / token1
```

这种设计的好处：

```text
1. 多个操作可以合并成一笔交易
2. 减少重复 approve 和 transfer
3. 更适合复杂仓位管理
4. 更适合和 Flash Accounting 配合
5. 更适合和 Universal Router 组合
6. 更适合前端构建复杂交易流程
```

通俗理解：

```text
v4 PositionManager 更像一个命令执行器。
用户不是只调用单个函数，而是提交一组 actions，让合约按顺序执行。
```

---

## 9. Subscriber / Notifier：仓位订阅通知机制

Subscriber / Notifier 是 Uniswap v4 的仓位通知机制。

它允许一个 LP position 订阅某个外部合约。

当这个 position 发生变化时，外部合约可以收到通知。

常见通知包括：

```solidity
notifySubscribe()
notifyUnsubscribe()
notifyModifyLiquidity()
notifyBurn()
```

对应场景：

```text
notifySubscribe       = 仓位订阅某个 Subscriber
notifyUnsubscribe     = 仓位取消订阅
notifyModifyLiquidity = 仓位增加或减少流动性
notifyBurn            = 仓位被销毁
```

这个机制适合用于：

```text
1. LP 挖矿
2. LP 积分
3. 做市奖励
4. 仓位排行榜
5. 自动策略记录
6. 仓位状态追踪
7. 第三方激励系统
```

核心思想是：

```text
用户的 LP position 仍然由用户自己控制
Subscriber 合约只接收通知
Subscriber 不需要托管用户的 LP position
```

这让 LP 激励系统更加安全。

### _unsubscribeGasLimit 的作用

在部署 v4 PositionManager 时，可以看到一个参数：

```solidity
_unsubscribeGasLimit
```

这个参数属于 Subscriber / Notifier 机制。

当用户取消订阅某个 Subscriber 时，PositionManager 会尝试调用 Subscriber 的通知函数：

```solidity
notifyUnsubscribe(...)
```

但是这个调用会受到 `_unsubscribeGasLimit` 限制。

也就是说：

```text
_unsubscribeGasLimit = 取消订阅时，通知 Subscriber 最多允许消耗的 gas
```

它的主要作用是防止恶意 Subscriber 通过消耗大量 gas 或故意 revert 来阻止用户取消订阅。

例如恶意 Subscriber 可能这样写：

```solidity
function notifyUnsubscribe(uint256 tokenId) external {
    while (true) {
        // 恶意消耗 gas
    }
}
```

或者：

```solidity
function notifyUnsubscribe(uint256 tokenId) external {
    revert("不允许取消订阅");
}
```

如果没有 gas 限制，用户可能会被恶意 Subscriber 卡住，无法正常退出订阅。

所以 v4 的设计是：

```text
用户取消订阅必须优先成功
通知 Subscriber 只是附加操作
Subscriber 不能反过来阻止用户退出
```

通俗理解：

```text
Subscriber 可以接收仓位变化通知
但不能绑架用户的 LP position
```

---

# 总结

Uniswap v4 的 9 个核心功能可以总结为：

```text
1. Hooks：池子插件系统
2. Singleton PoolManager：所有池子统一管理
3. Flash Accounting：内部 delta 记账，最后统一结算
4. Custom Accounting：Hook 可以影响最终结算
5. Dynamic Fee：动态手续费
6. Native ETH：支持原生 ETH
7. ERC-6909：内部余额 / claim 表示
8. PositionManager Actions：命令式批处理仓位操作
9. Subscriber / Notifier：仓位订阅通知机制
```

一句话理解：

```text
Uniswap v4 = 可编程 AMM 底座 + Hook 插件系统 + PoolManager 统一管理 + 内部记账结算 + 更灵活的仓位和激励机制。
```





### Uniswap V4 Contracts Workshop

forge script script/Uniswap.s.sol:UniswapV4DeployScript --rpc-url bsctest  --broadcast



bsctest

{
  "PoolManager": {
    "address": "0xe60Fc7C84A697270797986e342e2fe2A1A0310cA"
  },
  "PositionDescriptorImplementation": {
    "address": "0x4657dCcd7403117fd54F5c21A898613Ed5b1fd88"
  },
  "PositionDescriptor": {
    "address": "0xaFF74454D79d27E52256B5D3C563e03479bF4050"
  },
  "PositionDescriptorProxyAdmin": {
    "address": "0xf6E11333E0a3a3dac4f2cb74E82f1f0Ee7dBaa63"
  },
  "PositionManager": {
    "address": "0x38342ef4253091B8C4535eBcE1492077BAA7e023"
  },
  "StateView": {
    "address": "0x25c413Edc80F97dce81479fF4DAC67940095CcB5"
  },
  "V4Quoter": {
    "address": "0xbE46d4cA46aC3217e5547fB93b9B50Daf92bC213"
  },
  "UniversalRouter": {
    "address": "0x5EEA3b6053f56C0f1D48F7215D26c3c0ab6C67b1"
  }
}
