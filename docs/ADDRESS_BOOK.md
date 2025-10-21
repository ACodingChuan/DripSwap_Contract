# 地址簿 (Address Book) 设计文档

## 问题分析

### 原问题

部署脚本使用 `vm.writeJson(data, file)` 会**覆盖整个文件**，导致之前部署的地址丢失。

### 解决方案

改用 `vm.writeJson(data, file, path)` 只更新特定字段，保留其他内容。

## 地址簿结构

```json
{
  "chainId": 31337,
  "factoryDeployer": "0xce0042B868300000d44A59004Da54A005ffdcf9f",
  "v2": {
    "factory": "0x...",
    "router": "0x...",
    "weth": "0x...",
    "initCodeHash": "0x...",
    "pairs": {
      "vBTC_vUSDT": "0x...",
      "vETH_vDAI": "0x..."
    }
  },
  "tokens": {
    "vETH": {
      "address": "0x...",
      "decimals": 18
    },
    "vUSDT": {
      "address": "0x...",
      "decimals": 6
    }
  },
  "oracle": {
    "router": "0x...",
    "feeds": {
      "vETH": {
        "feedType": "chainlink",
        "aggAddress": "0x...",
        "aggDecimals": 8,
        "fixedUsdE18": 0
      }
    }
  },
  "guard": {
    "router": "0x...",
    "defaults": {
      "hardBps": 250,
      "hardBpsFixed": 500,
      "staleSec": 600
    }
  }
}
```

## 修复的脚本

### 1. DeployV2Deterministic.s.sol

**修改前**：

```solidity
vm.writeJson(finalJson, BOOK);  // 覆盖整个文件
```

**修改后**：

```solidity
vm.writeJson(vm.toString(block.chainid), BOOK, ".chainId");
vm.writeJson(vm.toString(ERC2470), BOOK, ".factoryDeployer");
vm.writeJson(vm.toString(factory), BOOK, ".v2.factory");
vm.writeJson(vm.toString(router), BOOK, ".v2.router");
vm.writeJson(vm.toString(weth), BOOK, ".v2.weth");
vm.writeJson(vm.toString(pairHash), BOOK, ".v2.initCodeHash");
```

### 2. DeployTokens.s.sol

**修改前**：

```solidity
vm.writeJson(finalJson, BOOK);  // 覆盖整个文件
```

**修改后**：

```solidity
for (uint i = 0; i < infos.length; i++) {
    string memory basePath = string.concat(".tokens.", infos[i].sym);
    vm.writeJson(vm.toString(tokens[i]), BOOK, string.concat(basePath, ".address"));
    vm.writeJson(vm.toString(infos[i].dec), BOOK, string.concat(basePath, ".decimals"));
}
```

### 3. DeployOracleRouter.s.sol

**已经正确**：

```solidity
vm.writeJson(vm.toString(orc), BOOK, ".oracle.router");
vm.writeJson(feedJson, BOOK, string.concat(".oracle.feeds.", sym));
```

### 4. DeployGuard.s.sol

**修改前**：

```solidity
book = book.serialize("guard.address", guard);
book = book.serialize("guard.defaults.hardBps", hardBps);
vm.writeJson(book, BOOK);  // 覆盖整个文件
```

**修改后**：

```solidity
vm.writeJson(vm.toString(guard), BOOK, ".guard.router");
vm.writeJson(vm.toString(hardBps), BOOK, ".guard.defaults.hardBps");
vm.writeJson(vm.toString(hardBpsFixed), BOOK, ".guard.defaults.hardBpsFixed");
vm.writeJson(vm.toString(staleSec), BOOK, ".guard.defaults.staleSec");
```

### 5. CreatePairsAndSeed.s.sol

**修改前**：

```solidity
book = book.serialize(key, pair);
vm.writeJson(book, BOOK);  // 覆盖整个文件
```

**修改后**：

```solidity
string memory pairPath = string.concat(".v2.pairs.", baseSym, "_", quoteSym);
vm.writeJson(vm.toString(pair), BOOK, pairPath);
```

## 部署流程

1. **初始化地址簿**：创建包含所有字段的空模板
2. **deploy-v2**：写入 chainId, factoryDeployer, v2.\*
3. **deploy-tokens**：写入 tokens.\*
4. **deploy-oracle**：写入 oracle.router, oracle.feeds.\*
5. **deploy-guard**：写入 guard.router, guard.defaults.\*
6. **deploy-pairs**：写入 v2.pairs.\*

## 优势

1. **不会覆盖**：每个脚本只更新自己负责的字段
2. **幂等性**：重复运行不会丢失其他信息
3. **可追溯**：所有部署信息都保留在一个文件中
4. **易维护**：结构清晰，字段明确

## 测试验证

运行完整部署后，地址簿应包含：

- ✅ chainId
- ✅ factoryDeployer
- ✅ v2.factory, v2.router, v2.weth, v2.initCodeHash
- ✅ tokens (6 个 token 的 address 和 decimals)
- ✅ oracle.router
- ✅ oracle.feeds (6 个 token 的 feed 配置)
- ✅ guard.router
- ✅ guard.defaults (hardBps, hardBpsFixed, staleSec)
- ✅ v2.pairs (15 个交易对地址)
