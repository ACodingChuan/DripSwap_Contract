# DripSwap Contract Makefile

.PHONY: all install build build-v2 build-all test test-coverage clean extract-abi fmt \
        setup-erc2470 deploy-v2 deploy-tokens deploy-oracle deploy-guard deploy-pairs \
        deploy-all deploy-local deploy-sepolia deploy-scroll help

SHELL := /bin/bash

# -------------------- 环境变量加载 --------------------
NETWORK ?= local

ifneq (,$(wildcard .env))
  include .env
  export
endif

ifneq (,$(wildcard .env.$(NETWORK)))
  include .env.$(NETWORK)
  export
endif

ifeq ($(NETWORK),local)
  DEFAULT_RPC := http://127.0.0.1:8545
  BOOK_PATH   := deployments/local.m1.json
else ifeq ($(NETWORK),sepolia)
  DEFAULT_RPC :=
  BOOK_PATH   := deployments/sepolia.m1.json
else ifeq ($(NETWORK),scroll)
  DEFAULT_RPC :=
  BOOK_PATH   := deployments/scroll-sepolia.m1.json
else
  $(error Unsupported NETWORK=$(NETWORK))
endif

RPC_URL ?= $(DEFAULT_RPC)

check-rpc = @if [ -z "$(RPC_URL)" ]; then \
  echo "Error: RPC_URL is required. Provide it via environment variable or .env.$(NETWORK)"; exit 1; \
fi

check-deployer = @if [ -z "$(DEPLOYER_PK)" ]; then \
  echo "Error: DEPLOYER_PK is required for broadcasting. Configure it in .env.$(NETWORK) or export it."; exit 1; \
fi


# 默认目标
all: build

# -------------------- 构建相关 --------------------

install:
	@echo "📦 安装Foundry依赖..."
	forge install

build:
	@echo "🔨 编译合约..."
	forge build
	@echo "📄 提取ABI文件..."
	npm run extract-abi

build-v2:
	@echo "🔨 编译V2合约..."
	./script/build-v2.sh

build-all: build-v2 build

test:
	@echo "🧪 运行测试..."
	forge test

test-coverage:
	@echo "📊 运行测试并生成覆盖率报告..."
	forge coverage --report lcov
	genhtml lcov.info --output-directory coverage-html

clean:
	@echo "🧹 清理构建文件..."
	forge clean
	rm -rf abi/*.json out-v2core/ out-v2router/

extract-abi:
	@echo "📄 提取ABI文件..."
	npm run extract-abi

fmt:
	@echo "✨ 格式化代码..."
	forge fmt


# -------------------- 部署相关 --------------------

setup-erc2470:
	$(call check-rpc)
	@echo "🏭 设置ERC-2470 Singleton Factory..."
	@rm -rf broadcast/DeployERC2470.s.sol cache/DeployERC2470.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/DeployERC2470.s.sol \
		--rpc-url $(RPC_URL) -vv

deploy-v2:
	$(call check-rpc)
	$(call check-deployer)
	@echo "🚀 部署UniswapV2 Factory和Router... (NETWORK=$(NETWORK))"
	@rm -rf broadcast/DeployV2Deterministic.s.sol cache/DeployV2Deterministic.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/DeployV2Deterministic.s.sol \
		--broadcast --force \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		-vv

deploy-tokens:
	$(call check-rpc)
	$(call check-deployer)
	@echo "🪙 部署测试代币... (NETWORK=$(NETWORK))"
	@rm -rf broadcast/DeployTokens.s.sol cache/DeployTokens.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/DeployTokens.s.sol \
		--tc DeployTokens \
		--broadcast --force \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		-vv

deploy-oracle:
	$(call check-rpc)
	$(call check-deployer)
	@echo "🔮 部署预言机路由... (NETWORK=$(NETWORK))"
	@rm -rf broadcast/DeployOracleRouter.s.sol cache/DeployOracleRouter.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/DeployOracleRouter.s.sol \
		--tc DeployOracleRouter \
		--broadcast --force \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		-vv

deploy-guard:
	$(call check-rpc)
	$(call check-deployer)
	@echo "🛡️  部署交易保护... (NETWORK=$(NETWORK))"
	@rm -rf broadcast/DeployGuard.s.sol cache/DeployGuard.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/DeployGuard.s.sol \
		--broadcast --force \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		-vv

deploy-pairs:
	$(call check-rpc)
	$(call check-deployer)
	@echo "💧 创建交易对并注入流动性... (NETWORK=$(NETWORK))"
	@rm -rf broadcast/CreatePairsAndSeed.s.sol cache/CreatePairsAndSeed.s.sol
	@FOUNDRY_DISABLE_TERMINAL_PROMPT=1 forge script script/CreatePairsAndSeed.s.sol \
		--broadcast --force \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		-vv

deploy-all: setup-erc2470 deploy-v2 deploy-tokens deploy-oracle deploy-guard deploy-pairs
	@echo ""
	@echo "✅ $(NETWORK) 部署完成！"
	@echo "📄 提取ABI文件..."
	@npm run extract-abi
	@echo ""
	@echo "📋 部署摘要:"
	@echo "  网络: $(NETWORK)"
	@echo "  地址簿: $(BOOK_PATH)"
	@echo "  ERC-2470 工厂: 0xce0042B868300000d44A59004Da54A005ffdcf9f"
	@echo ""
	@echo "🔍 查看详情: cat $(BOOK_PATH)"

deploy-local:
	@$(MAKE) NETWORK=local deploy-all

deploy-sepolia:
	@$(MAKE) NETWORK=sepolia deploy-all

deploy-scroll:
	@$(MAKE) NETWORK=scroll deploy-all


# -------------------- 帮助 --------------------

help:
	@echo "DripSwap Contract - 常用命令"
	@echo ""
	@echo "构建相关:"
	@echo "  make build           - 编译并更新 ABI"
	@echo "  make build-all       - 编译 V2 + 主体合约"
	@echo "  make test            - 运行测试"
	@echo "  make test-coverage   - 生成覆盖率报告"
	@echo "  make fmt             - 执行 forge fmt"
	@echo ""
	@echo "部署流程 (需设置 NETWORK / RPC_URL / DEPLOYER_PK):"
	@echo "  make deploy-all NETWORK=local"
	@echo "  make deploy-all NETWORK=sepolia"
	@echo "  make deploy-all NETWORK=scroll"
	@echo "  (或使用快捷命令 make deploy-local / deploy-sepolia / deploy-scroll)"
	@echo ""
	@echo "配置建议:"
	@echo "  1. 在 .env 和 .env.<network> 中设置 RPC_URL、DEPLOYER_PK"
	@echo "  2. 配置文件位于 configs/<network>/"
	@echo "  3. 部署结果写入 deployments/<network>.m1.json"
