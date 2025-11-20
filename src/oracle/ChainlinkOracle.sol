// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

/// @dev 轻量化的 Chainlink AggregatorV3 接口（只取用到的函数）
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title ChainlinkOracle
/// @notice IOracleRouter 的实现：
///         - 以“token→USD”为基准；无直连 base/quote 时用 USD 拆分（base/USD ÷ quote/USD）；
///         - 无喂价允许配置固定锚价（Fixed），常用于测试网；
///         - 统一输出 1e18 精度；stale 判定交由 Guard（全局/按 pair 阈值）处理。
/// @dev    Gas优化：
///         - FeedUSD 单槽布局（address + uint8 + uint88），初始化/配置 SSTORE 开销显著降低；
///         - 采用自定义错误，减少运行时代码；
///         - `aggDecimals` 作为可选缓存：非 0 则使用；为 0 时回退链上 `decimals()`（view，不上链）。
contract ChainlinkOracle is IOracleRouter, Ownable2Step {
    constructor(address initialOwner) Ownable(initialOwner) {}
    // ========= 自定义错误（替代长字符串，减少部署字节码） =========

    error OracleBadAnswer(address aggregator); // Chainlink 返回非正数
    error OracleQuoteZero(address quote); // 组合时除数为0（应当不发生）

    /// @notice token->USD 价源配置（单槽：20B + 1B + 11B = 32B）
    /// @param aggregator   Chainlink Aggregator 合约地址；为0表示无Feed，走 fixedUsdE18
    /// @param aggDecimals  （可选）缓存喂价小数位；为0表示运行时读取 aggregator.decimals()
    /// @param fixedUsdE18  固定USD价格（1e18表示1 USD）；仅 aggregator=0 时生效
    struct FeedUSD {
        address aggregator; // 20 bytes
        uint8 aggDecimals; // 1  byte（0 表示未缓存，运行时读取）
        uint88 fixedUsdE18; // 11 bytes（≈ 3.09e8 USD/枚上限；测试网兜底足够）
    }

    /// @dev token => USD 价源映射（每个条目仅 1 个存储槽）
    mapping(address => FeedUSD) public usdFeeds;

    /// @notice 当某个 token 的 USD 价源被设置/更新时触发（运维可观测）
    event USDFeedUpdated(address indexed token, address indexed aggregator, uint8 aggDecimals, uint88 fixedUsdE18);

    // ================ 管理方法（仅 owner，可2步交接） ================

    /// @notice 设置/更新某 token 的 USD 价源
    /// @dev    - aggregator=0 表示“无Feed”，此时使用 fixedUSDE18 作为固定锚价；
    ///         - 建议：稳定币在测试网可配 fixed=1e18；主网上尽量使用真实喂价；
    ///         - 本函数一次只写 1 槽（单槽结构），初始化更省 gas。
    function setUSDFeed(address token, FeedUSD calldata cfg) external onlyOwner {
        usdFeeds[token] = cfg;
        emit USDFeedUpdated(token, cfg.aggregator, cfg.aggDecimals, cfg.fixedUsdE18);
    }

    // ================ IOracleRouter 实现 ================

    /// @inheritdoc IOracleRouter
    function getUSDPrice(address token) public view override returns (uint256 pxE18, uint256 updatedAt) {
        FeedUSD memory f = usdFeeds[token];

        // 情况A：无Chainlink喂价 → 使用固定锚价（Fixed）
        if (f.aggregator == address(0)) {
            // 语义：1 token = fixedUSDE18 / 1e18 USD
            // 固定价理论上“不会过期”，updatedAt 返回当前块时间；Guard 会据此放宽硬阈值
            return (uint256(f.fixedUsdE18), block.timestamp);
        }

        // 情况B：有Chainlink喂价 → 从 aggregator 读取最新值
        (, int256 ans,, uint256 ts,) = AggregatorV3Interface(f.aggregator).latestRoundData();
        if (ans <= 0) revert OracleBadAnswer(f.aggregator);

        // 统一换算到1e18精度：
        // - 若 aggDecimals 缓存为非0，则直接使用；
        // - 否则读取 aggregator.decimals()（view，不上链）。
        uint8 d = f.aggDecimals == 0 ? AggregatorV3Interface(f.aggregator).decimals() : f.aggDecimals;

        uint256 u = uint256(ans);
        if (d < 18) pxE18 = u * 10 ** (18 - d);
        else if (d > 18) pxE18 = u / 10 ** (d - 18);
        else pxE18 = u;

        updatedAt = ts;
    }

    /// @inheritdoc IOracleRouter
    function latestAnswer(address base, address quote)
        external
        view
        override
        returns (uint256 priceE18, uint256 updatedAt, PriceSrc src)
    {
        // 取 base/USD 与 quote/USD
        (uint256 bPx, uint256 bTs) = getUSDPrice(base);
        (uint256 qPx, uint256 qTs) = getUSDPrice(quote);

        // 组合 base/quote： (bPx * 1e18) / qPx
        if (qPx == 0) revert OracleQuoteZero(quote);
        priceE18 = (bPx * 1e18) / qPx;

        // 判定是否 Fixed（检查映射中 aggregator 是否为0）
        FeedUSD memory bf = usdFeeds[base];
        FeedUSD memory qf = usdFeeds[quote];
        bool bFixed = (bf.aggregator == address(0));
        bool qFixed = (qf.aggregator == address(0));

        if (bFixed && qFixed) {
            src = PriceSrc.Fixed;
            updatedAt = block.timestamp; // 双Fixed情形：时间无意义，给当前块时间
        } else if (bFixed) {
            src = PriceSrc.Fixed;
            updatedAt = qTs; // 以非Fixed一侧时间为准
        } else if (qFixed) {
            src = PriceSrc.Fixed;
            updatedAt = bTs;
        } else {
            src = PriceSrc.UsdSplit;
            updatedAt = bTs < qTs ? bTs : qTs;
        }
    }
}
