// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOracleRouter
/// @notice 统一的“预言机路由”接口：
///         - 任意 base/quote 返回公允价（1e18精度）+ 更新时间 + 价源类型（src）
///         - 也可直接查询 token 的 USD 价格（1e18精度）
/// @dev    Guard 侧只依赖本接口；具体实现由 ChainlinkOracle 等提供
interface IOracleRouter {
    /// @dev 价源类型：
    ///      - UsdSplit: 由 base/USD 与 quote/USD 拼出 base/quote
    ///      - Fixed   : 固定锚价（用于测试网/无Feed场景），不参与 staleness 判定
    enum PriceSrc { UsdSplit, Fixed }

    /// @notice 查询 base/quote 的公允价（1e18）与更新时间与价源类型
    /// @param base   计价基准（分子）
    /// @param quote  计价标的（分母）
    /// @return priceE18  价格(1e18)，含义：1 base = priceE18 / 1e18 个 quote
    /// @return updatedAt 该价格的 on-chain 更新时间（两侧USD价的最小值；双Fixed时给当前块时间）
    /// @return src       价源类型（UsdSplit / Fixed）
    function latestAnswer(address base, address quote)
        external
        view
        returns (uint256 priceE18, uint256 updatedAt, PriceSrc src);

    /// @notice 查询 token 的 USD 价格（1e18）与更新时间
    /// @dev    为保持接口简洁，这里不返回 src；Guard 一般使用 latestAnswer()
    /// @param  token  资产地址
    /// @return priceE18  价格(1e18)，含义：1 token = priceE18 / 1e18 USD
    /// @return updatedAt 链上更新时间（Fixed 场景返回当前块时间）
    function getUSDPrice(address token)
        external
        view
        returns (uint256 priceE18, uint256 updatedAt);
}
