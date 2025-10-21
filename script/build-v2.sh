#!/bin/bash
# 预编译UniswapV2合约（0.5.16和0.6.6版本）
# 用于CREATE2确定性部署

set -e

echo "🔨 Building UniswapV2 contracts..."

# 1. 编译 v2-core (0.5.16)
echo ""
echo "📦 Building v2-core (Solidity 0.5.16)..."
FOUNDRY_PROFILE=v2core forge build

# 检查输出
if [ ! -f "out-v2core/UniswapV2Factory.sol/UniswapV2Factory.json" ]; then
    echo "❌ Failed to build UniswapV2Factory"
    exit 1
fi

if [ ! -f "out-v2core/UniswapV2Pair.sol/UniswapV2Pair.json" ]; then
    echo "❌ Failed to build UniswapV2Pair"
    exit 1
fi

echo "✅ v2-core built successfully"
echo "   - UniswapV2Factory.json"
echo "   - UniswapV2Pair.json"

# 2. 编译 v2-router (0.6.6) - 自包含版本
echo ""
echo "📦 Building v2-router (Solidity 0.6.6)..."
FOUNDRY_PROFILE=v2router forge build

# 检查输出
if [ ! -f "out-v2router/UniswapV2Router01.sol/UniswapV2Router01.json" ]; then
    echo "❌ Failed to build UniswapV2Router01"
    exit 1
fi

echo "✅ v2-router built successfully"
echo "   - UniswapV2Router01.json"

echo ""
echo "🎉 All V2 contracts built successfully!"
echo ""
echo "📁 Output directories:"
echo "   - out-v2core/"
echo "   - out-v2router/"
