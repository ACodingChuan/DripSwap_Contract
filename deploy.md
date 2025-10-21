# DripSwap 合约部署指南

## 📋 概述

DripSwap使用**ERC-2470 Singleton Factory**实现确定性部署，确保在不同网络（Anvil、Sepolia、Scroll Sepolia）上部署的合约地址**完全一致**。

### 核心特性

- ✅ **跨链地址一致性**: 相同的合约在所有网络上地址相同
- ✅ **幂等性**: 可以重复运行部署脚本，已部署的合约会被跳过
- ✅ **标准化**: 使用EIP-2470标准工厂
- ✅ **可预测性**: 部署前可以计算合约地址

---

## 🎯 ERC-2470 Singleton Factory

### 什么是ERC-2470？

ERC-2470是一个标准的CREATE2工厂合约，部署在固定地址：

```
0xce0042B868300000d44A59004Da54A005ffdcf9f
```

### 为什么使用ERC-2470？

**传统部署方式的问题：**
```solidity
// 使用 new 部署
Factory factory = new Factory();
// 地址 = keccak256(deployer, nonce)
// 问题：不同网络的nonce可能不同 → 地址不同
```

**ERC-2470的优势：**
```solidity
// 使用 ERC-2470 部署
address factory = ERC2470.deploy(salt, bytecode);
// 地址 = keccak256(0xff, ERC2470, salt, keccak256(bytecode))
// 优势：只要salt和bytecode相同 → 地址相同
```

### 网络支持情况

| 网络 | ERC-2470状态 | 部署方式 |
|------|-------------|---------|
| **Anvil** | 需要部署 | 使用`vm.etch`自动部署 |
| **Sepolia** | ✅ 已存在 | 直接使用 |
| **Scroll Sepolia** | ✅ 已存在 | 直接使用 |

---

## 🚀 快速开始

### 前置要求

```bash
# 1. 安装Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. 安装Node.js依赖
npm install

# 3. 安装Forge依赖
make install
```

### 本地Anvil部署（最简单）

```bash
# 1. 启动Anvil（新终端）
anvil

# 2. 一键部署（另一个终端）
make deploy-local
```

就这么简单！所有合约会自动部署到Anvil。

---

## 📖 完整部署流程

### Step 0: 环境准备

```bash
# 设置环境变量
export RPC_URL=http://127.0.0.1:8545
export DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 编译V2合约
make build-v2
```

### Step 1: 设置ERC-2470工厂

```bash
make setup-erc2470
```

**这一步做什么？**
- Anvil: 使用`vm.etch`部署ERC-2470到固定地址
- Sepolia/Scroll Sepolia: 验证ERC-2470已存在

**输出示例：**
```
=== ERC-2470 Singleton Factory Setup ===
Standard address: 0xce0042B868300000d44A59004Da54A005ffdcf9f
Chain ID: 31337

Deploying ERC-2470 to Anvil using vm.etch...
✅ ERC-2470 deployed to Anvil

=== ERC-2470 Information ===
Address: 0xce0042B868300000d44A59004Da54A005ffdcf9f
Code size: 50 bytes
✅ Ready for deterministic deployments
```

### Step 2: 部署V2基础设施

```bash
make deploy-v2
```

**部署内容：**
- UniswapV2Factory
- UniswapV2Router01
- 计算INIT_CODE_PAIR_HASH

**输出示例：**
```
=== Deploying UniswapV2Factory ===
Deploying UniswapV2Factory...
✓ UniswapV2Factory deployed
  Address: 0x[确定性地址]

=== Deploying UniswapV2Router01 ===
Deploying UniswapV2Router01...
✓ UniswapV2Router01 deployed
  Address: 0x[确定性地址]
```

### Step 3: 部署测试代币

```bash
make deploy-tokens
```

**部署代币：**
- vETH (18 decimals)
- vUSDT (6 decimals)
- vUSDC (6 decimals)
- vDAI (18 decimals)
- vBTC (8 decimals)
- vLINK (18 decimals)

### Step 4: 部署预言机路由

```bash
make deploy-oracle
```

**部署内容：**
- ChainlinkOracle合约
- 配置价格源（从`configs/feeds.sepolia.jsonc`读取）

### Step 5: 部署交易保护

```bash
make deploy-guard
```

**部署内容：**
- GuardedRouter合约
- 配置软约束参数

### Step 6: 创建交易对并注入流动性

```bash
make deploy-pairs
```

**操作内容：**
- 创建交易对（从`configs/<network>/pairs.json`读取）
- 注入初始流动性

### 一键完整部署

```bash
make deploy-all
```

自动执行Step 1-6的所有步骤。

---

## 🌐 多网络部署

### Sepolia测试网

```bash
# 1. 设置环境变量
export RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
export DEPLOYER_PK=你的私钥

# 2. 编译V2合约
make build-v2

# 3. 完整部署
make deploy-all
```

### Scroll Sepolia测试网

```bash
# 1. 设置环境变量
export RPC_URL=https://sepolia-rpc.scroll.io
export DEPLOYER_PK=你的私钥

# 2. 编译V2合约
make build-v2

# 3. 完整部署
make deploy-all
```

### 跨链地址验证

部署到多个网络后，验证地址一致性：

```bash
# Sepolia
cast call 0x[Factory地址] "allPairsLength()(uint256)" --rpc-url $SEPOLIA_RPC

# Scroll Sepolia
cast call 0x[Factory地址] "allPairsLength()(uint256)" --rpc-url $SCROLL_RPC

# 地址应该完全相同！
```

---

## 🔄 幂等性说明

所有部署脚本都支持幂等性，可以安全地重复运行：

```bash
# 第一次运行 - 部署所有合约
make deploy-all

# 第二次运行 - 跳过已部署的合约
make deploy-all
```

**输出示例：**
```
=== Deploying UniswapV2Factory ===
✓ UniswapV2Factory already deployed
  Address: 0x...

=== Deploying UniswapV2Router01 ===
✓ UniswapV2Router01 already deployed
  Address: 0x...
```

---

## 📁 配置文件

### deployments/local.m1.json

部署后的合约地址记录：

```json
{
  "chainId": 31337,
  "factoryDeployer": "0xce0042B868300000d44A59004Da54A005ffdcf9f",
  "v2": {
    "factory": "0x...",
    "router": "0x...",
    "weth": "0x0000000000000000000000000000000000000001",
    "initCodeHash": "0x..."
  },
  "tokens": {
    "vETH": { "address": "0x...", "decimals": 18 },
    "vUSDT": { "address": "0x...", "decimals": 6 }
  },
  "oracle": {
    "router": "0x..."
  },
  "guard": {
    "address": "0x..."
  }
}
```

### configs/feeds.sepolia.jsonc

价格源配置（支持注释）：

```jsonc
{
  "network": "sepolia",
  "symbols": ["vETH","vBTC","vLINK","vUSDT","vUSDC","vDAI"],
  "feeds": {
    // ETH/USD Price Feed
    "vETH": { 
      "type": "chainlink", 
      "aggregator": "0x694AA1769357215DE4FAC081bf1f309aDC325306",  
      "aggDecimals": 8 
    },
    // USDT - 固定价格
    "vUSDT": { 
      "type": "fixed", 
      "priceE18": "1000000000000000000", 
      "aggDecimals": 8 
    }
  }
}
```

### configs/<network>/pairs.json

交易对配置：

```json
{
  "pairs": [
    { "base": "vETH", "quote": "vUSDT" },
    { "base": "vBTC", "quote": "vUSDT" }
  ],
  "seedPolicy": {
    "minQuoteUsdE18": "100000000000000000000",
    "slippageBpsTarget": 20
  }
}
```

---

## 🛠️ 故障排除

### 问题1: ERC-2470 not found

**错误信息：**
```
Error: ERC-2470 not found. Run 'make setup-erc2470' first
```

**解决方案：**
```bash
make setup-erc2470
```

### 问题2: 地址不一致

**原因：**
- 使用了不同的salt
- 使用了不同的bytecode
- 使用了不同的构造参数

**解决方案：**
- 确保所有网络使用相同的代码版本
- 确保编译器版本一致
- 检查`foundry.toml`配置

### 问题3: Nonce问题

**错误信息：**
```
Error: nonce too low
```

**解决方案：**
```bash
# 检查当前nonce
cast nonce $DEPLOYER_ADDR --rpc-url $RPC_URL

# 等待pending交易确认
```

### 问题4: Gas不足

**错误信息：**
```
Error: insufficient funds for gas
```

**解决方案：**
```bash
# 检查余额
cast balance $DEPLOYER_ADDR --rpc-url $RPC_URL

# 转账ETH到部署地址
cast send $DEPLOYER_ADDR --value 1ether --rpc-url $RPC_URL
```

---

## 📊 Gas成本估算

| 操作 | Gas消耗 | 估算费用 (50 gwei) |
|------|---------|-------------------|
| ERC-2470部署 | 0 (已存在) | 0 ETH |
| Factory部署 | ~2,500,000 | ~0.125 ETH |
| Router部署 | ~3,000,000 | ~0.150 ETH |
| Token部署 (6个) | ~1,200,000 | ~0.060 ETH |
| Oracle部署 | ~800,000 | ~0.040 ETH |
| Guard部署 | ~1,500,000 | ~0.075 ETH |
| **总计** | **~9,000,000** | **~0.45 ETH** |

---

## 🔐 安全注意事项

### 私钥管理

```bash
# ❌ 不要这样做
export DEPLOYER_PK=0x1234...  # 明文私钥

# ✅ 推荐做法
# 1. 使用.env文件（不要提交到git）
echo "DEPLOYER_PK=0x..." > .env
source .env

# 2. 使用硬件钱包
forge script ... --ledger

# 3. 使用Foundry keystore
cast wallet import deployer --interactive
forge script ... --account deployer
```

### 部署验证

```bash
# 部署后验证合约
forge verify-contract \
  --chain-id 11155111 \
  --compiler-version v0.8.24 \
  $CONTRACT_ADDRESS \
  src/Contract.sol:Contract \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

---

## 📚 参考资料

- [EIP-2470: Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470)
- [Foundry Book](https://book.getfoundry.sh/)
- [UniswapV2 Documentation](https://docs.uniswap.org/contracts/v2/overview)
- [CREATE2 详解](https://eips.ethereum.org/EIPS/eip-1014)

---

## 🎯 总结

DripSwap使用ERC-2470实现了真正的跨链确定性部署：

1. ✅ **统一工厂**: 所有网络使用相同的ERC-2470地址
2. ✅ **确定性地址**: 相同的合约在所有网络地址相同
3. ✅ **幂等性**: 可以安全地重复运行部署脚本
4. ✅ **简单易用**: 一条命令完成所有部署

**开始部署：**
```bash
# 本地测试
make deploy-local

# 测试网部署
make RPC_URL=$YOUR_RPC DEPLOYER_PK=$YOUR_KEY deploy-all
```

祝部署顺利！🚀

---

## 🛠️ 实战排障记录

> 以下内容整理自本地多轮调试，便于后续同学快速定位问题。

- **ERC‑2470 Runtime 注入**  
  - 仅 `vm.etch` 会让 Foundry 进程内看到代码，但对真实链状态无效。  
  - 解决：`_ensureERC2470` 中追加 `vm.rpc("anvil_setCode", …)`，确保在 Anvil 节点上也写入代码。  
  - 同时提前在 `vm.startBroadcast()` 之前调用 `_ensureERC2470()`，避免 broadcast 模式下复用旧代码。

- **调用工厂的 Calldata 格式**  
  - 官方 EIP‑2470 接收的 payload 是 `salt || init_code`。  
  - 早期使用 `abi.encodeWithSignature("deploy(bytes,bytes32)", …)` 或 `abi.encode(initCode, salt)` 会导致 `call to non-contract address` 或空返回。  
  - 现实现：`bytes memory payload = abi.encodePacked(salt, initCode);` + decode 20/32 字节两种返回格式，再校验与预测地址一致。

- **返回值解码**  
  - 某些环境下工厂直接返回 20 字节；若硬解 `abi.decode(result,(address))` 会 revert。  
  - 现逻辑：若 `result.length == 20`，读出 word 后右移 12 字节得到地址；否则按 32 字节解码。

- **大常量写入 `mstore` 触发 `Number literal too large`**  
  - 直接 `mstore(ptr, 0x7fff…` 写 69 字节 runtime 触发 Solc 检查。  
  - 解决：不再用 `mstore` 手填，改为常量 `bytes` 直接传入 `vm.etch / anvil_setCode`。

- **广播缓存导致交易冲突**  
  - 重复运行脚本会尝试重播 `broadcast/<script>/<run>.json` 中的旧交易，引起 `transaction already imported` 或 `replacement transaction underpriced`。  
  - 每次部署前清理对应 `broadcast/*` 与 `cache/*` 目录，并统一指定 `--with-gas-price`（默认 2 gwei）。

- **地址簿写入注意事项**  
  - `vm.writeJson` 期望输入是合法 JSON 片段，写字符串必须手动包上引号或使用 `stdJson.serialize*`。  
  - 针对 `deployments/local.m1.json`：首次执行前先写入 `{}`，随后脚本会逐步填充；写地址时通过 `serializeAddress/serializeUint` 组装对象再写入。  
  - 如果文件被清空，需重新执行 `deploy-v2`、`deploy-tokens` 等阶段，让脚本恢复所有节点。

- **Token 地址缺失触发 Oracle 报错**  
  - Oracle 脚本会读取 `.tokens.<symbol>.address`，若 `deploy-tokens` 未成功或地址簿被重置，会抛出 `Token address missing: vETH`。  
  - 处理：先跑 `make deploy-tokens`，确认地址簿中六个 Symbol 均写入地址+decimals，再继续 Oracle/Guard/Pairs。

- **feeds 配置缺少 aggregator**  
  - `configs/feeds.sepolia.json` 中某些条目只有 `priceE18` 无预言机地址。  
  - 现实现支持 `chainlink` 类型缺少 `aggregator` 的情况：自动用固定价格写入合同，并在日志中标记 “chainlink (no agg)”。  
  - 如果需要真实预言机，只需在配置中补上 `aggregator` 字段即可。

以上坑点都在当前脚本里落地处理，如果再次复现，可按照对应说明快速验证。欢迎继续补充新的排障经验。

### 当前进展与待办

**已完成：**
- ✅ 本地 `make deploy-v2` 成功，Factory/Router 部署并写入地址簿
- ✅ 本地 `make deploy-tokens` 成功，所有代币部署到链上
- ✅ 幂等性验证通过，重复运行会跳过已部署合约

**已知问题（TODO）：**
- ⚠️ **地址簿写入问题**：当所有合约已存在（幂等性跳过部署）时，Foundry的`--broadcast`模式会显示"No transactions to broadcast"，导致`vm.writeJson`不执行文件写入
  - **根本原因**：Foundry在没有交易时不会执行broadcast后的副作用操作
  - **临时方案**：首次部署时会正常写入；重复部署时需手动更新地址簿
  - **永久方案待定**：
    1. 使用单独的非broadcast脚本更新配置
    2. 在脚本中添加虚拟交易确保broadcast执行
    3. 使用`vm.writeFile`替代`vm.writeJson`
  - **影响范围**：`DeployTokens.s.sol`、`DeployOracleRouter.s.sol`、`DeployGuard.s.sol`

**下一步：**
- 继续完成 `deploy-oracle → deploy-guard → deploy-pairs` 的调试
- 全链路验证通过后，统一处理地址簿写入问题


可以不额外写脚本，直接利用 Foundry 生成的 broadcast/.../run-latest.json 来统计每一步的 gas。流程如下：

  ———

  1. 确认广播文件位置

  执行 make deploy-all NETWORK=<network> 后，Foundry 会把每个脚本的广播结果写到：

  broadcast/<脚本名>/<chainId>/run-latest.json

  例如：

  - broadcast/DeployV2Deterministic.s.sol/31337/run-latest.json
  - broadcast/DeployTokens.s.sol/11155111/run-latest.json
  - broadcast/CreatePairsAndSeed.s.sol/534351/run-latest.json

  ———

  2. 查看某个脚本本次用掉的所有 tx hash

  jq -r '.transactions[].hash' broadcast/DeployTokens.s.sol/31337/run-latest.json

  如需逐笔详情，可以把 hash 丢给 cast tx：

  cast tx <txhash> --rpc-url $RPC_URL

  ———

  3. 统计某个脚本本次总 gasUsed

  jq '[.receipts[].gasUsed | tonumber] | add' \
    broadcast/DeployTokens.s.sol/31337/run-latest.json

  返回的是 “gas 单位”的总和。

  若需要换算成 ETH（按每笔实际 effectiveGasPrice），可以：

  jq '[.receipts[] | ( ( .gasUsed | tonumber ) * ( .effectiveGasPrice | tonumber ))] | add
      | ./1e18
  ' broadcast/DeployTokens.s.sol/31337/run-latest.json

  这里 ./1e18 的写法适用于 jq >= 1.6；若版本较旧，可以在 shell 里除以 1e18：

  jq '[.receipts[] | ( ( .gasUsed | tonumber ) * ( .effectiveGasPrice | tonumber ))]
      | add' \
    broadcast/DeployTokens.s.sol/31337/run-latest.json \
  | awk '{printf "%.6f ETH\n", $1/1e18}'

  ———

  4. 按顺序统计一轮部署所有脚本

  可以一次循环目录里所有 run-latest：

  CHAIN_ID=31337   # sepolia: 11155111, scroll sepolia: 534351
  for f in broadcast/*/$CHAIN_ID/run-latest.json; do
    script=$(basename "$(dirname "$f")")
    gas=$(jq '[.receipts[].gasUsed | tonumber] | add' "$f")
    eth=$(jq '[.receipts[] | ( ( .gasUsed|tonumber ) * ( .effectiveGasPrice|tonumber ))] | add' "$f")
    printf "%-35s gasUsed=%-12s spent=%0.6f ETH\n" "$script" "$gas" "$(awk "BEGIN{print $eth/1e18}")"
  done

  把 CHAIN_ID 换成目标网络即可分别统计本地、Sepolia、Scroll 的数值。

  ———

  这样就能快速记录 deploy-local / deploy-sepolia / deploy-scroll 三套流程的 gas 消耗，而不需要额外写程序。