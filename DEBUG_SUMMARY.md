# Bridge Permit2 集成调试总结

## 📋 概述

本文档记录了 DripSwap Bridge 合约集成 Uniswap Permit2 协议的完整调试过程，包括遇到的所有问题、解决方案以及最终成功的交易记录。

---

## 🔍 问题背景

**目标**：实现 Bridge.sendToken 函数，支持用户通过 Permit2 签名授权的方式进行跨链转账，避免传统的 approve + transferFrom 两步操作。

**核心难点**：
1. Permit2 的 EIP-712 签名结构复杂
2. 函数选择器匹配问题
3. 参数编码和传递
4. 签名验证失败排查

---

## 🐛 踩坑记录

### 坑 1: EIP-712 签名结构缺少 `spender` 字段

**问题描述**：
- 签名一直失败，返回 `InvalidSigner` (0x815e1d64) 错误
- 计算出的 EIP-712 hash 与链上验证的 hash 不匹配

**错误的签名结构**：
```javascript
{
  permitted: [
    { token: "0x...", amount: "100..." },
    { token: "0x...", amount: "2..." }
  ],
  nonce: ...,
  deadline: ...
}
```

**正确的签名结构**：
```javascript
{
  permitted: [
    { token: "0x...", amount: "100..." },
    { token: "0x...", amount: "2..." }
  ],
  spender: "0x...",  // ✅ 必须包含 spender 字段！
  nonce: ...,
  deadline: ...
}
```

**根本原因**：
根据 Permit2 源码，`PermitBatchTransferFrom` 的 TypeHash 定义为：
```solidity
keccak256("PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)")
```

**spender 的含义**：
- `spender` 是被授权调用 `permitTransferFrom` 的地址
- 对于直接调用 Permit2：spender = 调用者的 EOA 地址
- 对于通过 Bridge 调用：spender = Bridge 合约地址

**解决方案**：
修改 `tools/sign-permit2.js`，在 types 和 message 中添加 spender 字段：

```javascript
const types = {
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  PermitBatchTransferFrom: [
    { name: "permitted", type: "TokenPermissions[]" },
    { name: "spender", type: "address" },  // ✅ 添加
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

const message = {
  permitted,
  spender: SPENDER,  // ✅ 添加
  nonce: NONCE,
  deadline: DEADLINE,
};
```

**验证方法**：
1. 对比本地计算的 DOMAIN_SEPARATOR 与链上的是否一致
2. 对比本地计算的 EIP-712 hash 与 Tenderly debug 中的 hash

---

### 坑 2: Tenderly 显示的函数名误导

**问题描述**：
- 发送的交易明明调用的是 `permitTransferFrom`
- 但 Tenderly trace 显示进入了 `permitWitnessTransferFrom`

**排查过程**：
1. 验证函数选择器：
   ```bash
   cast sig "permitTransferFrom(((address,uint256)[],uint256,uint256),(address,uint256)[],address,bytes)"
   # 输出: 0xedd9444b ✅ 正确
   
   cast sig "permitWitnessTransferFrom(((address,uint256)[],uint256,uint256),(address,uint256)[],address,bytes32,string,bytes)"
   # 输出: 0xfe8ec1a7 ❌ 不同
   ```

2. 查看交易的 input data，确认前 4 字节为 `0xedd9444b`

**真相**：
- 函数选择器是正确的
- **Tenderly 的 sourcemap 定位有误**，显示的函数名错误
- 实际执行路径是正确的 `permitTransferFrom`

**教训**：不要完全依赖调试工具的 UI 显示，要通过 selector 和 calldata 验证。

---

### 坑 3: Sepolia 网络不需要 `version` 字段

**问题描述**：
尝试在 EIP-712 domain 中添加 `version` 字段导致 DOMAIN_SEPARATOR 不匹配。

**错误示例**：
```javascript
const domain = {
  name: "Permit2",
  chainId: 11155111,
  verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  version: "1"  // ❌ Sepolia 不需要
};
```

**正确做法**：
```javascript
const domain = {
  name: "Permit2",
  chainId: 11155111,
  verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  // ✅ 不包含 version
};
```

**验证方法**：
```bash
cast call 0x000000000022D473030F116dDEE9F6B43aC78BA3 "DOMAIN_SEPARATOR()" --rpc-url $RPC_URL
# 输出: 0x94c1dec87927751697bfc9ebf6fc4ca506bed30308b518f0e9d6c5f74bbafdb8

# 本地计算的 DOMAIN_SEPARATOR 必须与此一致
```

---

### 坑 4: payInLink = false 时缺少 msg.value

**问题描述**：
调用 Bridge.sendToken 时，如果 `payInLink = false`，但没有传递足够的 `msg.value`，交易会 revert。

**费用计算**：
```javascript
// Bridge 需要的总费用
uint256 expectedMsgValue = serviceFee + (payInLink ? 0 : ccipFee);

// serviceFee: 0.001 ETH (Bridge 的服务费)
// ccipFee: 通过 quoteFee 查询得到
```

**正确做法**：
```bash
# 1. 先查询费用
cast call 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
  "quoteFee(address,uint64,address,uint256,bool)" \
  "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" \
  "2279865765895943307" \
  "0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2" \
  "100000000000000000000" \
  "false" \
  --rpc-url $RPC_URL

# 2. 计算总费用 = quoteFee 结果 + 0.001 ETH
# 3. 发送交易时传入 --value
```

---

### 坑 5: 错误的链选择器

**问题描述**：
最初使用了错误的 dstSelector，导致交易 revert。

**错误示例**：
```bash
# 错误: 使用了 Sepolia 的 selector
dstSelector = 16015286601757825753
```

**正确值**：
```bash
# 正确: 向 Scroll 发送应使用 Scroll 的 selector
dstSelector = 2279865765895943307
```

**配置参考**：
- Sepolia chain selector: `16015286601757825753`
- Scroll chain selector: `2279865765895943307`

---

### 坑 6: Solidity Tuple 参数编码规则

**问题描述**：
cast send 命令中，复杂的 tuple 和 array 参数编码非常容易出错，特别是嵌套结构。经常搞不清楚什么时候用 `()`，什么时候用 `[]`。

**核心规则**：

1. **struct (结构体) → 使用圆括号 `()`**
   ```solidity
   struct TokenPermissions {
       address token;
       uint256 amount;
   }
   // 编码为: (0xTokenAddress,AmountValue)
   ```

2. **array (数组) → 使用方括号 `[]`**
   ```solidity
   TokenPermissions[] permitted;
   // 编码为: [(token1,amount1),(token2,amount2)]
   ```

3. **嵌套结构 → 从内到外逐层编码**
   ```solidity
   struct PermitBatchTransferFrom {
       TokenPermissions[] permitted;  // array of struct
       uint256 nonce;
       uint256 deadline;
   }
   // 编码为: ([(token1,amount1),(token2,amount2)],nonce,deadline)
   //          ^数组部分用[]^  ^^struct整体用()^^
   ```

**实际案例对比**：

❌ **错误的编码**（缺少嵌套层级）：
```bash
# 错误: PermitInput 缺少外层括号
"[(0xE91d...,100...),(0x7798...,2...)],584369413500,1763635135,0x63e9..."
```

✅ **正确的编码**：
```bash
# 正确: PermitInput = (permit, signature)
#        其中 permit = (permitted[], nonce, deadline)
"(([(0xE91d...,100...),(0x7798...,2...)],584369413500,1763635135),0x63e9...)"
#  ^^外层PermitInput^^ ^^数组^^ ^nonce^ ^deadline^ ^^signature^^
```

**完整的函数签名分析**：

```solidity
function sendToken(
    address token,                    // 简单类型: 直接写地址
    uint64 dstSelector,               // 简单类型: 直接写数字
    address receiver,                 // 简单类型: 直接写地址
    uint256 amount,                   // 简单类型: 直接写数字
    bool payInLink,                   // 简单类型: true/false
    PermitInput calldata permitInput  // 复杂结构: 需要编码
)

// PermitInput 结构:
struct PermitInput {
    PermitBatchTransferFrom permit;  // struct 用 ()
    bytes signature;                 // bytes 用 0x...
}

// PermitBatchTransferFrom 结构:
struct PermitBatchTransferFrom {
    TokenPermissions[] permitted;    // array 用 []
    uint256 nonce;
    uint256 deadline;
}

// TokenPermissions 结构:
struct TokenPermissions {
    address token;                   // 简单类型
    uint256 amount;                  // 简单类型
}
```

**编码步骤拆解**：

```bash
# 步骤 1: 编码 TokenPermissions (struct 用圆括号)
TokenPermissions1 = (0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D,100000000000000000000)
TokenPermissions2 = (0x779877A7B0D9E8603169DdbD7836e478b4624789,2000000000000000000)

# 步骤 2: 编码 TokenPermissions[] (array 用方括号)
permitted = [(0xE91d...,100...),(0x7798...,2...)]

# 步骤 3: 编码 PermitBatchTransferFrom (struct 用圆括号)
permit = ([(0xE91d...,100...),(0x7798...,2...)],584369413500,1763635135)
#         ^permitted数组^                      ^nonce^      ^deadline^

# 步骤 4: 编码 PermitInput (struct 用圆括号)
permitInput = (([(0xE91d...,100...),(0x7798...,2...)],584369413500,1763635135),0x63e9...)
#              ^permit结构^                                                    ^signature^
```

**记忆技巧**：
- **看到 `struct` 关键字** → 用 `()` 包裹所有字段
- **看到 `[]` 在类型后面** → 用 `[]` 包裹数组元素
- **嵌套时** → 先编码最内层，再逐层往外包
- **bytes 类型** → 直接写 `0x` 开头的十六进制，不需要引号

---

## ✅ 成功的交易记录

### 测试 1: 直接调用 Permit2 (验证签名)

**目的**：验证 spender 字段修复后，Permit2 签名是否有效

**交易详情**：
- Hash: `0xdc2b3bf2da46006015c16f8b362d6fe7a043b77f8105001b642ebf2c21ac34b4`
- 网络: Sepolia
- 函数: `Permit2.permitTransferFrom`
- Spender: `0x5EEb1d4f90Ba69579C28e4DBa7f268AAFA9Fc69b` (EOA)
- 结果: ✅ Success
- 区块: 9667767

**签名参数**：
```javascript
{
  permitted: [
    { token: "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D", amount: "100000000000000000000" },
    { token: "0x779877A7B0D9E8603169DdbD7836e478b4624789", amount: "2000000000000000000" }
  ],
  spender: "0x5EEb1d4f90Ba69579C28e4DBa7f268AAFA9Fc69b",
  nonce: 26075463176,
  deadline: 1763634911
}
```

**日志**：成功转移了 100 vToken 和 2 LINK 到 Bridge 地址

---

### 测试 2: Bridge.sendToken (payInLink = true)

**目的**：测试完整的跨链流程，使用 LINK 支付 CCIP 费用

**交易详情**：
- Hash: `0xb0daa40c5eb42b9a72f4a209ef544f8a1ec1ffffbbd0f64b69e3361b20be8355`
- 网络: Sepolia → Scroll
- 函数: `Bridge.sendToken`
- Spender: `0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7` (Bridge 合约)
- 结果: ✅ Success
- 区块: 9667817
- Gas 消耗: 316,899

**调用参数**：
```bash
token: 0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D
dstSelector: 2279865765895943307
receiver: 0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2
amount: 100000000000000000000
payInLink: true
msg.value: 1000000000000000 (0.001 ETH, service fee only)
```

**签名参数**：
```javascript
{
  permitted: [
    { token: "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D", amount: "100000000000000000000" },
    { token: "0x779877A7B0D9E8603169DdbD7836e478b4624789", amount: "2000000000000000000" }
  ],
  spender: "0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7",
  nonce: 584369413500,
  deadline: 1763635135
}
```

**CCIP Message ID**: `0xb0e758b0ff405a4b2eae5be0f0afbef8322c02a69171e22cdbda28bd26d7a30b`

**关键日志**：
1. vToken 从用户转移到 Bridge: 100 tokens
2. LINK 从用户转移到 Bridge: ~2.38 tokens
3. LINK 从 Bridge 授权给 Router: 用于支付 CCIP 费用
4. CCIP 消息成功发送

---

### 测试 3: Bridge.sendToken (payInLink = false)

**目的**：测试使用原生 ETH 支付 CCIP 费用

**交易详情**：
- Hash: `0x74c2556b4fad3f1cf9ded8d46e6180b1b412e83f2d6839f83be96730ee06c109`
- 网络: Sepolia → Scroll
- 函数: `Bridge.sendToken`
- Spender: `0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7` (Bridge 合约)
- 结果: ✅ Success
- 区块: 9667887
- Gas 消耗: 309,117

**调用参数**：
```bash
token: 0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D
dstSelector: 2279865765895943307
receiver: 0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2
amount: 100000000000000000000
payInLink: false
msg.value: 1800000000000000 (0.0018 ETH, service fee + CCIP fee)
```

**费用详情**：
- CCIP fee (quoteFee): `695335187561303` wei (0.000695 ETH)
- Service fee: `1000000000000000` wei (0.001 ETH)
- 总计: `1695335187561303` wei
- 实际支付: `1800000000000000` wei (留有余量)

**签名参数**：
```javascript
{
  permitted: [
    { token: "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D", amount: "100000000000000000000" }
  ],
  spender: "0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7",
  nonce: 938128698200,
  deadline: 1763636382
}
```

**CCIP Message ID**: `0xd4a9220d86bfd6f864eb33f28f1bd0f6272557644836f71ab8025c4ed2efca0d`

**关键日志**：
1. vToken 从用户转移到 Bridge: 100 tokens
2. 原生 ETH 用于支付 CCIP 费用: 0.000695 ETH
3. CCIP 消息成功发送

---

## 📚 知识点总结

### 1. Permit2 签名结构

完整的 `PermitBatchTransferFrom` 签名需要包含：
- `permitted[]`: 授权的代币和数量列表
- `spender`: 被授权调用的地址（**关键！**）
- `nonce`: 随机数，防止重放攻击
- `deadline`: 签名过期时间

### 2. 两种支付方式对比

| 支付方式 | payInLink | 需要签名的代币 | msg.value | 优势 |
|---------|-----------|---------------|-----------|------|
| LINK 支付 | true | vToken + LINK (mode=2) | 仅 service fee (0.001 ETH) | 费用稳定,不受 gas 波动影响 |
| 原生币支付 | false | 仅 vToken (mode=1) | service fee + CCIP fee (~0.0017 ETH) | 不需要持有 LINK,更简单 |

### 3. 参数编码速查表

| Solidity 类型 | Cast 编码 | 示例 |
|--------------|-----------|------|
| `address` | 直接写地址 | `0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D` |
| `uint256` | 直接写数字 | `100000000000000000000` |
| `bool` | `true` 或 `false` | `true` |
| `bytes` | `0x` 开头的十六进制 | `0x63e96d8c...` |
| `struct { a, b }` | 用圆括号 `(a,b)` | `(0xE91d...,100...)` |
| `T[]` 数组 | 用方括号 `[e1,e2]` | `[(0xE91d...,100...),(0x7798...,2...)]` |
| 嵌套 `struct { T[] a, b }` | `([(e1,e2)],b)` | `([(token,amt)],nonce)` |

### 4. 调试技巧

1. **验证 DOMAIN_SEPARATOR**：
   ```bash
   cast call <PERMIT2_ADDRESS> "DOMAIN_SEPARATOR()" --rpc-url $RPC_URL
   ```

2. **验证函数选择器**：
   ```bash
   cast sig "functionName(types)"
   ```

3. **查询 CCIP 费用**：
   ```bash
   cast call <BRIDGE_ADDRESS> "quoteFee(...)" --rpc-url $RPC_URL
   ```

4. **使用 Tenderly 调试**：
   - 查看完整的执行 trace
   - 检查 revert 原因
   - **注意**：函数名显示可能不准确，以 selector 为准

---

## 🔧 完整的调用流程

### 步骤 1: 生成 Permit 签名

```bash
# payInLink = true (需要 vToken + LINK)
node tools/sign-permit2.js --network=sepolia --mode=2 --spender=<BRIDGE_ADDRESS>

# payInLink = false (仅需要 vToken)
node tools/sign-permit2.js --network=sepolia --mode=1 --spender=<BRIDGE_ADDRESS>
```

### 步骤 2: 查询 CCIP 费用 (payInLink = false 时)

```bash
cast call <BRIDGE_ADDRESS> \
  "quoteFee(address,uint64,address,uint256,bool)" \
  <TOKEN> <DST_SELECTOR> <RECEIVER> <AMOUNT> false \
  --rpc-url $RPC_URL
```

### 步骤 3: 调用 Bridge.sendToken

#### 方式 1: payInLink = true (使用 LINK 支付 CCIP 费用)

**完整命令**：
```bash
source .env.sepolia && cast send 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
"sendToken(address,uint64,address,uint256,bool,(((address,uint256)[],uint256,uint256),bytes))" \
"0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" \
"2279865765895943307" \
"0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2" \
"100000000000000000000" \
"true" \
"(([(0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D,100000000000000000000),(0x779877A7B0D9E8603169DdbD7836e478b4624789,2000000000000000000)],584369413500,1763635135),0x63e96d8ceeac2cf6e4c04988fefbea267ce0ecf925630cc1eb7f860a625246425018e83f0ec02af229ebccd412c6753a9ff2519712fe5b053cb35355ab2950611b)" \
--rpc-url $RPC_URL \
--private-key $DEPLOYER_PK \
--gas-limit 1000000 \
--value 1000000000000000
```

**返回结果**：
```
blockHash            0xff89cc3ad2b271e5a55d7077884daea0552d16027c1db85ecad1bb719e5c4c21
blockNumber          9667817
contractAddress      
cumulativeGasUsed    58414315
effectiveGasPrice    1125062
from                 0x5EEb1d4f90Ba69579C28e4DBa7f268AAFA9Fc69b
gasUsed              316899
status               1 (success)
transactionHash      0xb0daa40c5eb42b9a72f4a209ef544f8a1ec1ffffbbd0f64b69e3361b20be8355
```

**CCIP Message ID**: `0xb0e758b0ff405a4b2eae5be0f0afbef8322c02a69171e22cdbda28bd26d7a30b`

---

#### 方式 2: payInLink = false (使用原生 ETH 支付 CCIP 费用)

**第一步：查询所需费用**
```bash
source .env.sepolia && cast call 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
"quoteFee(address,uint64,address,uint256,bool)" \
"0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" \
"2279865765895943307" \
"0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2" \
"100000000000000000000" \
"false" \
--rpc-url $RPC_URL
```

**返回结果**：
```
0x0000000000000000000000000000000000000000000000000002786756dabb57
```

转换为十进制：
```bash
cast --to-dec 0x0000000000000000000000000000000000000000000000000002786756dabb57
# 输出: 695335187561303 (约 0.000695 ETH)

# 总费用 = CCIP fee + service fee
# 总费用 = 0.000695 + 0.001 = 0.001695 ETH
# 建议 msg.value = 0.0018 ETH (留有余量)
```

**第二步：发送交易**
```bash
source .env.sepolia && cast send 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
"sendToken(address,uint64,address,uint256,bool,(((address,uint256)[],uint256,uint256),bytes))" \
"0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" \
"2279865765895943307" \
"0xd8Df4816169c5a39E4E47533238d1CbAD48d8CE2" \
"100000000000000000000" \
"false" \
"(([(0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D,100000000000000000000)],938128698200,1763636382),0x24690abbb78653f387a8381f240d229f441858c0c607d83e5da2d857ef60d16206c8532743130c6e1829ee29b41b55f75a21aad0dc16e7f66eeaaae240e6e2421b)" \
--rpc-url $RPC_URL \
--private-key $DEPLOYER_PK \
--gas-limit 1000000 \
--value 1800000000000000
```

**返回结果**：
```
blockHash            0x9b9ea91bcfc3045b9282bc63695972a0ff6ad9a46e00aead1a4590763b3b8073
blockNumber          9667887
contractAddress      
cumulativeGasUsed    36494456
effectiveGasPrice    999993
from                 0x5EEb1d4f90Ba69579C28e4DBa7f268AAFA9Fc69b
gasUsed              309117
status               1 (success)
transactionHash      0x74c2556b4fad3f1cf9ded8d46e6180b1b412e83f2d6839f83be96730ee06c109
```

**CCIP Message ID**: `0xd4a9220d86bfd6f864eb33f28f1bd0f6272557644836f71ab8025c4ed2efca0d`

---

## 🎯 关键文件修改

### tools/sign-permit2.js

**主要修改**：
1. 添加 `spender` 字段到 types 和 message
2. 支持通过 `--spender` 参数指定 spender 地址
3. 添加 DOMAIN_SEPARATOR 验证
4. 输出计算的 EIP-712 hash 用于调试

---

## 📝 经验教训

1. **仔细阅读源码**：Permit2 的 TypeHash 定义明确包含 spender，不能省略
2. **验证每个环节**：DOMAIN_SEPARATOR、函数选择器、calldata 都要验证
3. **不要盲信工具**：Tenderly 的函数名显示可能错误，以实际 selector 为准
4. **分步调试**：先测试 Permit2，成功后再测试 Bridge
5. **记录每次尝试**：保存交易 hash、参数、错误信息，便于回溯

---

## ✨ 最终成果

成功实现了 Bridge 合约的 Permit2 集成，支持：
- ✅ 用户一次签名授权多个代币（vToken + LINK）
- ✅ 两种 CCIP 费用支付方式（LINK 或原生 ETH）
- ✅ 安全的跨链转账（利用 Permit2 的签名验证）
- ✅ 避免传统的 approve + transferFrom 两步操作

---

## 📖 参考资料

- [Uniswap Permit2 文档](https://docs.uniswap.org/contracts/permit2/overview)
- [EIP-712 规范](https://eips.ethereum.org/EIPS/eip-712)
- [Chainlink CCIP 文档](https://docs.chain.link/ccip)
- Permit2 合约地址 (Sepolia): `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- Bridge 合约地址 (Sepolia): `0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7`

---

## 🔗 快速参考

### 关键地址（Sepolia 测试网）

| 合约 | 地址 |
|------|------|
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Bridge | `0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7` |
| vToken | `0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D` |
| LINK | `0x779877A7B0D9E8603169DdbD7836e478b4624789` |

### 链选择器

| 网络 | Chain Selector |
|------|----------------|
| Sepolia | `16015286601757825753` |
| Scroll | `2279865765895943307` |

### 常用命令模板

**生成签名（LINK 支付）**：
```bash
node tools/sign-permit2.js --network=sepolia --mode=2 --spender=0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7
```

**生成签名（ETH 支付）**：
```bash
node tools/sign-permit2.js --network=sepolia --mode=1 --spender=0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7
```

**查询费用**：
```bash
source .env.sepolia && cast call 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
  "quoteFee(address,uint64,address,uint256,bool)" \
  "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" "2279865765895943307" \
  "0xRECEIVER" "AMOUNT" "false" --rpc-url $RPC_URL
```

**查看 CCIP 消息状态**：
访问 [Chainlink CCIP Explorer](https://ccip.chain.link/) 并输入 Message ID

---

**调试完成时间**: 2025-11-20  
**总调试时长**: ~4 小时  
**失败交易数**: 15+  
**成功交易数**: 3  
**最大的坑**: Permit2 签名缺少 spender 字段  
**第二大坑**: Tuple/Array 参数编码规则混淆

---

## 🔗 快速参考

### 关键地址（Sepolia 测试网）

| 合约 | 地址 |
|------|------|
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Bridge | `0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7` |
| vToken | `0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D` |
| LINK | `0x779877A7B0D9E8603169DdbD7836e478b4624789` |

### 链选择器

| 网络 | Chain Selector |
|------|----------------|
| Sepolia | `16015286601757825753` |
| Scroll | `2279865765895943307` |

### 常用命令模板

**生成签名（LINK 支付）**：
```bash
node tools/sign-permit2.js --network=sepolia --mode=2 --spender=0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7
```

**生成签名（ETH 支付）**：
```bash
node tools/sign-permit2.js --network=sepolia --mode=1 --spender=0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7
```

**查询费用**：
```bash
source .env.sepolia && cast call 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7 \
  "quoteFee(address,uint64,address,uint256,bool)" \
  "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D" "2279865765895943307" \
  "0xRECEIVER" "AMOUNT" "false" --rpc-url $RPC_URL
```

**查看 CCIP 消息状态**：
访问 [Chainlink CCIP Explorer](https://ccip.chain.link/) 并输入 Message ID


## 🌏 自定义 CCIP 跨链配置全流程指南

本指南详细记录了配置 Chainlink CCIP BurnMint 跨链池所需的完整步骤。由于手动配置极易出错且流程繁琐，建议后续通过脚本实现自动化。

### 1. 核心角色与架构

配置涉及以下五个关键合约组件的交互：

1.  **BurnMintERC20**: 支持跨链的 Token（如 vETH, vUSDT）。需要将 `mint/burn` 权限授予 `BurnMintTokenPool`。
2.  **BurnMintTokenPool**: 负责锁定/销毁源链 Token 并通知 CCIP，或接收 CCIP 消息并解锁/铸造目标链 Token。
3.  **RegistryModuleOwnerCustom**: 用于向 TokenAdminRegistry 注册 Token 的管理权限。
4.  **TokenAdminRegistry**: Chainlink 官方维护的注册表，用于管理 Token 与 Pool 的绑定关系。
5.  **Bridge**: DripSwap 自建的桥接路由合约，负责前端交互和费用估算。

### 2. 环境配置与地址

#### Scroll Sepolia (Chain ID: 534351)
*   **Chain Selector**: `2279865765895943307`
*   **RMN Proxy**: `0x8f4413e02265F65eF89FB908dbA2915fF9f7F8cB`
*   **Router**: `0x6aF501292f2A33C81B9156203C9A66Ba0d8E3D21`
*   **TokenAdminRegistry**: `0xf49C561cf56149517c67793a3035D1877ffE2f04`
*   **RegistryModuleOwner**: `0x3325786a3eE3Aa488403A136CF9Ad3E764656C75`
*   **LINK Token**: `0x231d45b53C905c3d6201318156BDC725c9c3B9B1`

#### Sepolia (Chain ID: 11155111)
*   **Chain Selector**: `16015286601757825753`
*   **RMN Proxy**: `0xba3f6251de62dED61Ff98590cB2fDf6871FbB991`
*   **Router**: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59`
*   **TokenAdminRegistry**: `0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82`
*   **RegistryModuleOwner**: `0x62e731218d0D47305aba2BE3751E7EE9E5520790`
*   **LINK Token**: `0x779877A7B0D9E8603169DdbD7836e478b4624789`

### 3. 详细配置步骤 (针对每个 Token)

对于每个需要跨链的 Token（例如 vETH），需要在**每条链**上执行以下步骤：

#### 步骤 A: 权限注册 (TokenAdminRegistry)
1.  **获取 Admin 权限**：
    调用 `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(tokenAddress)`。
    *   *作用*：申明当前 EOA 是该 Token 的管理员（前提是 Token 合约实现了 `getCCIPAdmin()` 接口并指向该 EOA）。
2.  **接受 Admin 角色**：
    调用 `TokenAdminRegistry.acceptAdminRole(tokenAddress)`。
    *   *作用*：在注册表中正式接管 Token 的管理权。

#### 步骤 B: 绑定 Pool (TokenAdminRegistry)
1.  **设置 Pool**：
    调用 `TokenAdminRegistry.setPool(tokenAddress, poolAddress)`。
    *   *作用*：告诉 Chainlink 网络，该 Token 在本链上的跨链操作由哪个 Pool 合约负责。

#### 步骤 C: 配置远程链 (BurnMintTokenPool)
1.  **应用链更新 (Apply Chain Updates)**：
    调用 `BurnMintTokenPool.applyChainUpdates(remoteChainSelectorsToRemove, chainsToAdd)`。
    *   这是最复杂的一步，需要构造复杂的 Tuple 结构来指定：
        *   目标链的 Chain Selector。
        *   目标链上的 Token 地址（bytes 编码）。
        *   目标链上的 Pool 地址（bytes 编码）。
        *   出站/入站速率限制（Rate Limiter Config）。

    **`chainsToAdd` 参数结构示例**：
    ```solidity
    struct ChainUpdate {
        uint64 remoteChainSelector; // 目标链 Selector
        bool allowed;               // 是否允许通信 (虽然ABI中可能是 bytes[] remotePoolAddresses 等，具体看各版本实现，标准CCIP v1.5通常如下)
        bytes outboundToken;        // 目标链 Token 地址 (abi.encodePacked)
        bytes outboundPool;         // 目标链 Pool 地址 (abi.encodePacked)
        RateLimiterConfig outbound; // 出站限速
        RateLimiterConfig inbound;  // 入站限速
    }
    ```
    *(注：具体 ABI 请参考下文折叠部分)*

#### 步骤 D: DripSwap Bridge 配置
1.  **注册 Pool**：
    调用 DripSwap `Bridge.registerTokenPool(tokenAddress, poolAddress)`。
    *   *作用*：让 Bridge 合约知道通过哪个 Pool 去 burn/mint 该 Token。
2.  **设置 Allowlist (可选)**：
    如果 Pool 开启了 Allowlist，需要将 Bridge 合约地址加入 Pool 的允许列表。

---

### 4. 自动化脚本编写思路 (Scripting Plan)

为了避免重复的手工操作和潜在的人为错误，建议编写一个 Foundry Script (`ConfigureCCIP.s.sol`) 来自动化上述流程。

#### 设计思路
脚本应设计为幂等（Idempotent），即重复运行不会导致错误配置。

**脚本输入**：
*   `config.json`: 包含各链的 Router, Registry, Chain Selector 等基础设施地址。
*   `address_book.md`: 读取当前已部署的 Token 和 Pool 地址。

**脚本流程 (run 函数)**：
1.  **读取环境变量与配置**：确定当前网络（Sepolia 或 Scroll），加载对应的配置参数。
2.  **加载 Token 列表**：遍历所有已部署的 vToken（vETH, vUSDT 等）。
3.  **执行配置循环**：
    对于每个 Token：
    *   **Check**: 检查是否已在 `TokenAdminRegistry` 注册。
    *   **Action A**: 若未注册，执行 `registerAdminViaGetCCIPAdmin` 和 `acceptAdminRole`。
    *   **Check**: 检查 `TokenAdminRegistry` 中的 Pool 是否匹配当前部署的 Pool。
    *   **Action B**: 若不匹配，执行 `setPool`。
    *   **Action C**: 调用 `BurnMintTokenPool.applyChainUpdates`。
        *   *难点*：需要根据目标链（Remote Chain）的 `address_book` 获取对应的 Remote Token 和 Remote Pool 地址。
        *   *实现*：脚本需要同时读取本地和远程链的地址簿（或硬编码远程地址映射）。
        *   *参数构造*：使用 `abi.encodePacked(address)` 将地址转换为 bytes。
    *   **Action D**: 调用本地 Bridge 合约的 `registerTokenPool`。

**关键数据结构构造 (Solidity Script)**：
```solidity
// 构造 applyChainUpdates 的参数
TokenPool.ChainUpdate[] memory chainsToAdd = new TokenPool.ChainUpdate[](1);

// 速率限制配置 (默认不限制)
RateLimiter.Config memory noLimit = RateLimiter.Config({
    isEnabled: true,
    capacity: type(uint128).max,
    rate: type(uint128).max
});

chainsToAdd[0] = TokenPool.ChainUpdate({
    remoteChainSelector: remoteChainSelector,
    remotePoolAddresses: abi.encode(remotePoolAddress), // 注意：不同版本可能是 bytes[]
    remoteTokenAddress: abi.encode(remoteTokenAddress),
    outboundRateLimiterConfig: noLimit,
    inboundRateLimiterConfig: noLimit
});

pool.applyChainUpdates(new uint64[](0), chainsToAdd);
```

---

<details>
<summary>📂 点击展开：BurnMintTokenPool 完整 ABI 参考</summary>

```json
[
  {
    "inputs": [
      {
        "internalType": "contract IBurnMintERC20",
        "name": "token",
        "type": "address"
      },
      {
        "internalType": "uint8",
        "name": "localTokenDecimals",
        "type": "uint8"
      },
      {
        "internalType": "address[]",
        "name": "allowlist",
        "type": "address[]"
      },
      {
        "internalType": "address",
        "name": "rmnProxy",
        "type": "address"
      },
      {
        "internalType": "address",
        "name": "router",
        "type": "address"
      }
    ],
    "stateMutability": "nonpayable",
    "type": "constructor"
  },
  // ... (其余 ABI 内容保持不变)
  {
    "inputs": [
      {
        "internalType": "uint64[]",
        "name": "remoteChainSelectorsToRemove",
        "type": "uint64[]"
      },
      {
        "components": [
          {
            "internalType": "uint64",
            "name": "remoteChainSelector",
            "type": "uint64"
          },
          {
            "internalType": "bytes[]",
            "name": "remotePoolAddresses",
            "type": "bytes[]"
          },
          {
            "internalType": "bytes",
            "name": "remoteTokenAddress",
            "type": "bytes"
          },
          {
            "components": [
              {
                "internalType": "bool",
                "name": "isEnabled",
                "type": "bool"
              },
              {
                "internalType": "uint128",
                "name": "capacity",
                "type": "uint128"
              },
              {
                "internalType": "uint128",
                "name": "rate",
                "type": "uint128"
              }
            ],
            "internalType": "struct RateLimiter.Config",
            "name": "outboundRateLimiterConfig",
            "type": "tuple"
          },
          {
            "components": [
              {
                "internalType": "bool",
                "name": "isEnabled",
                "type": "bool"
              },
              {
                "internalType": "uint128",
                "name": "capacity",
                "type": "uint128"
              },
              {
                "internalType": "uint128",
                "name": "rate",
                "type": "uint128"
              }
            ],
            "internalType": "struct RateLimiter.Config",
            "name": "inboundRateLimiterConfig",
            "type": "tuple"
          }
        ],
        "internalType": "struct TokenPool.ChainUpdate[]",
        "name": "chainsToAdd",
        "type": "tuple[]"
      }
    ],
    "name": "applyChainUpdates",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  }
]
```
</details>

---

**调试统计**：
- ⏱️ 总调试时长: ~5 小时
- ❌ 失败交易数: 15+
- ✅ 成功交易数: 3
- 🎯 最大的坑: Permit2 签名缺少 spender 字段
- 🔧 第二大坑: Tuple/Array 参数编码规则混淆
