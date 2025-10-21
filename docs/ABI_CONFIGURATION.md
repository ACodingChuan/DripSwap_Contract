# ABI 配置说明

本项目已配置为自动将所有合约编译生成的 ABI 文件统一放置到`./abi`目录下。

## 配置概述

### 1. Foundry 配置 (`foundry.toml`)

```toml
[profile.default]
# 启用额外输出以便提取ABI
extra_output = ["abi"]
# 构建完成后调用ABI提取脚本
post_compile = "npm run extract-abi"
```

### 2. 使用开源 ABI 导出工具

- 内置脚本 `tools/extract-abi.js` 会扫描 Foundry 编译输出的 `out/` 目录
- 自动读取每个合约 JSON 中的 `abi` 字段，生成 `{合约名}.json`
- 输出统一写入 `./abi` 目录，并在每次运行前清空旧文件

## 使用方法

### 方法 1: 使用 Forge 命令

```bash
# 编译合约（会自动触发ABI提取）
forge build

# 手动提取ABI
npm run extract-abi
```

### 方法 2: 使用 Makefile

```bash
# 编译并提取ABI
make build

# 仅提取ABI
make extract-abi

# 查看所有可用命令
make help
```

## 目录结构

```
项目根目录/
├── abi/                    # ABI文件目录（自动生成）
│   ├── UniswapV2Factory.json
│   ├── UniswapV2Pair.json
│   └── ...
├── out/                    # Foundry编译输出目录
├── src/                    # 合约源码目录
└── foundry.toml           # Foundry配置文件
```

## ABI 文件格式

提取的 ABI 文件为标准的 JSON 格式，包含合约的所有公共接口信息：

```json
[
  {
    "type": "constructor",
    "inputs": [...],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "functionName",
    "inputs": [...],
    "outputs": [...],
    "stateMutability": "view"
  },
  ...
]
```

## 注意事项

1. **自动触发**: 每次运行`forge build`时会通过`post_compile`钩子自动执行脚本生成 ABI
2. **命令统一**: 使用`npm run extract-abi`或`make extract-abi`时同样调用脚本手动生成
3. **自动清理**: 脚本会在写入新文件前清空`./abi`目录中的旧 ABI
4. **兼容 Foundry 结构**: 直接读取`out/`工件，无需 Hardhat 等额外依赖

## 故障排除

### 问题 1: ABI 文件未生成

**解决方案**: 确保先执行`forge build`成功产出`out/`目录，再运行脚本

### 问题 2: 脚本报错

**解决方案**: 使用`node tools/extract-abi.js`查看详细日志，或确认`out/`中的 JSON 文件格式正确

## 集成到 CI/CD

可以将 ABI 提取集成到 CI/CD 流程中：

```yaml
# GitHub Actions示例
- name: Build contracts and extract ABI
  run: |
    forge build
    # ABI文件已自动提取到./abi目录

- name: Upload ABI artifacts
  uses: actions/upload-artifact@v3
  with:
    name: contract-abi
    path: abi/
```
