#!/bin/bash

# 批量修复所有 token 的 CCIP 配置
# 顺序：vDAI, vBTC, vLINK, vSCR (vUSDC 已经完成)

cd /Users/guohaochuan/Documents/web3project/DripSwap/DripSwap_Contract

echo "=========================================="
echo "开始批量修复 CCIP 配置"
echo "=========================================="

TOKENS=("vDAI" "vBTC" "vLINK" "vSCR")

for TOKEN in "${TOKENS[@]}"; do
    echo ""
    echo "=========================================="
    echo "正在修复: $TOKEN"
    echo "=========================================="
    
    # Sepolia
    echo ""
    echo "--- Sepolia ---"
    source .env.sepolia
    forge script script/FixCCIP_$TOKEN.s.sol:FixCCIP_$TOKEN --rpc-url $RPC_URL --broadcast
    
    if [ $? -eq 0 ]; then
        echo "✅ $TOKEN Sepolia 修复成功"
    else
        echo "❌ $TOKEN Sepolia 修复失败"
        exit 1
    fi
    
    # Scroll
    echo ""
    echo "--- Scroll ---"
    source .env.scroll
    forge script script/FixCCIP_$TOKEN.s.sol:FixCCIP_$TOKEN --rpc-url $RPC_URL --broadcast
    
    if [ $? -eq 0 ]; then
        echo "✅ $TOKEN Scroll 修复成功"
    else
        echo "❌ $TOKEN Scroll 修复失败"
        exit 1
    fi
    
    echo ""
    echo "✅ $TOKEN 修复完成！"
    echo ""
done

echo "=========================================="
echo "🎉 所有 token 修复完成！"
echo "=========================================="
