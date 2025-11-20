// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

/// @title GuardedRouter（软约束版，仅视图预检，不代理交易/不托管资产）
/// @notice 提供对单跳 V2 交易的“价格偏离 / 预言机过期”检查，前端用 eth_call 调用；
///         通过后由前端/后端直接向 Router/Pair 下单。本合约不做转账、授权、路由调用。
/// @dev Gas 侧重点：
///      - factory immutable（部署期少一次 SSTORE）；
///      - 全局参数 Defaults 单槽打包（2B+2B+4B）；
///      - Pair 覆盖 PairCfg 单槽打包（2B+4B+1B）；
///      - 方向归一：_oriented() 统一对齐 base→quote 储备，后续无分支；
///      - 构造不 emit；仅 set* 事件（可按需删除进一步省字节码）。
contract GuardedRouter is Ownable2Step {
    // ===== 自定义错误（替代 require/字符串，节省部署与运行期 gas） =====
    error ZeroAddress();
    error PathLength(); // path.length != 2
    error PathArgs(); // 零地址或重复地址

    // ===== 常量（运行期不占存储） =====
    uint256 private constant FEE_NUM = 997; // Uniswap V2 0.3% 手续费的“有效系数”
    uint256 private constant FEE_DEN = 1000;

    // ===== 单槽全局默认参数 =====
    /// @param hardBps      正常价源下的价格偏离硬阈值（基点，10000=100%）
    /// @param hardBpsFixed 任一侧为 Fixed 价源时的放宽阈值（基点）
    /// @param staleSec     正常价源下的过期秒数
    struct Defaults {
        uint16 hardBps;
        uint16 hardBpsFixed;
        uint32 staleSec;
    }

    Defaults public defaults; // 1 槽

    struct PairCfg {
        uint16 hardBps;
        uint32 staleSec;
        uint8 enabled;
    }

    /// @notice 工厂地址（不可变，读便宜、部署不 SSTORE）
    IUniswapV2Factory public immutable FACTORY;

    /// @notice 预言机（可热切换）
    IOracleRouter public oracle; // 1 槽

    /// @dev 无序对 → 覆盖配置；键为排序后 (min, max) 的哈希
    mapping(bytes32 => PairCfg) public pairCfg;

    // ===== 事件（可按需删除以进一步省字节码） =====
    event DefaultsUpdated(uint16 hardBps, uint16 hardBpsFixed, uint32 staleSec);
    event PairCfgUpdated(address indexed tokenA, address indexed tokenB, PairCfg cfg);
    event OracleUpdated(address indexed newOracle);

    // ===== 构造（不 emit，减少部署成本） =====
    constructor(
        address _factory,
        address _oracle,
        uint16 _hardBps,
        uint16 _hardBpsFixed,
        uint32 _staleSec,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_factory == address(0) || _oracle == address(0)) revert ZeroAddress();
        FACTORY = IUniswapV2Factory(_factory); // immutable → 不写存储
        oracle = IOracleRouter(_oracle); // 1 槽
        defaults = Defaults(_hardBps, _hardBpsFixed, _staleSec); // 1 槽
    }

    // ===== 仅 owner 的管理入口 =====
    function setOracleRouter(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IOracleRouter(_oracle); // 非0→非0 ≈ 5k gas
        emit OracleUpdated(_oracle);
    }

    function setDefaults(uint16 _hardBps, uint16 _hardBpsFixed, uint32 _staleSec) external onlyOwner {
        defaults = Defaults(_hardBps, _hardBpsFixed, _staleSec); // 非0→非0 ≈ 5k gas
        emit DefaultsUpdated(_hardBps, _hardBpsFixed, _staleSec);
    }

    /// @notice 设置/关闭某对的覆盖（cfg.enabled=0 视为不用覆盖）
    function setPairCfg(address tokenA, address tokenB, PairCfg calldata cfg) external onlyOwner {
        (bytes32 key, address x, address y) = _pairKeySorted(tokenA, tokenB);
        pairCfg[key] = cfg; // 首次写入 ≈ 20k，更新 ≈ 5k
        emit PairCfgUpdated(x, y, cfg);
    }

    // ===== 只读：价格快照（前端展示用） =====
    /// @return dexMidE18   当前池子中价（quote/base，1e18）
    /// @return oraclePxE18 预言机价（1e18）
    /// @return updatedAt   预言机更新时间
    /// @return stale       是否过期（Fixed 不判过期）
    /// @return limitBps    本次检查使用的偏离阈值（Fixed 会放宽）
    /// @return srcFixed    是否涉及 Fixed 价源（用于 UI 提示）
    function checkPriceNow(address base, address quote)
        external
        view
        returns (uint256 dexMidE18, uint256 oraclePxE18, uint256 updatedAt, bool stale, uint16 limitBps, bool srcFixed)
    {
        Oriented memory o = _oriented(base, quote);
        if (o.pair == address(0) || o.reserveBase == 0) return (0, 0, 0, true, 0, false);
        dexMidE18 = (uint256(o.reserveQuote) * 1e18) / uint256(o.reserveBase);

        (oraclePxE18, updatedAt, limitBps, stale, srcFixed) = _oracleAndPolicy(base, quote);
    }

    // ===== 只读：单跳 Exact-In 预检（软约束） =====
    function checkSwapExactIn(address[] calldata path, uint256 amountIn)
        external
        view
        returns (bool ok, uint256 devBps, uint256 limitBps, bool stale, uint256 dexAfterE18, uint256 oracleE18)
    {
        _validatePath2(path);

        (oracleE18, limitBps, stale) = _oracleAndLimit(path[0], path[1]);
        if (stale) return (false, 0, limitBps, true, 0, oracleE18);

        (address pair, uint112 rBase, uint112 rQuote) = _orientedReserves(path[0], path[1]);
        if (pair == address(0) || rBase == 0) return (false, 0, limitBps, false, 0, oracleE18);

        // out = (in*997*resOut) / (resIn*1000 + in*997)
        uint256 inWithFee = amountIn * FEE_NUM;
        uint256 out = (inWithFee * rQuote) / (uint256(rBase) * FEE_DEN + inWithFee);

        // 仅为 dexAfter 计算新储备（不引入多余局部变量）
        dexAfterE18 = ((uint256(rQuote) - out) * 1e18) / (uint256(rBase) + amountIn);

        // 直接用实际成交均价 vs 预言机价计算偏离，避免 execPxE18 变量常驻
        uint256 pxExec = (amountIn == 0) ? 0 : (out * 1e18) / amountIn;
        devBps = _devBps(pxExec, oracleE18);
        ok = (devBps <= limitBps);
    }

    // ===== 只读：单跳 Exact-Out 预检（软约束） =====
    function checkSwapExactOut(address[] calldata path, uint256 amountOut)
        external
        view
        returns (
            bool ok,
            uint256 devBps,
            uint256 limitBps,
            bool stale,
            uint256 dexAfterE18,
            uint256 oracleE18,
            uint256 amountInNeeded
        )
    {
        _validatePath2(path);

        (oracleE18, limitBps, stale) = _oracleAndLimit(path[0], path[1]);
        if (stale) return (false, 0, limitBps, true, 0, oracleE18, 0);

        (address pair, uint112 rBase, uint112 rQuote) = _orientedReserves(path[0], path[1]);
        if (pair == address(0) || rBase == 0 || amountOut >= rQuote) {
            return (false, 0, limitBps, false, 0, oracleE18, 0);
        }

        // in = ceil(resIn*out*1000 / ((resOut - out)*997))
        uint256 num = uint256(rBase) * amountOut * FEE_DEN;
        uint256 den = (uint256(rQuote) - amountOut) * FEE_NUM;
        amountInNeeded = (num + den - 1) / den;

        // dexAfter
        dexAfterE18 = ((uint256(rQuote) - amountOut) * 1e18) / (uint256(rBase) + amountInNeeded);

        // 与 oracle 的偏离（使用实际成交均价，不保留中间变量）
        uint256 pxExec = (amountInNeeded == 0) ? 0 : (amountOut * 1e18) / amountInNeeded;
        devBps = _devBps(pxExec, oracleE18);
        ok = (devBps <= limitBps);
    }

    // ================= 内部：策略 / 方向归一 / 工具 =================

    /// @dev 读取公允价并计算“本次应使用的阈值/是否过期”
    ///      - src==Fixed：不过期；阈值取 max(pairHardBps, hardBpsFixed)
    ///      - UsdSplit  ：按 staleSec 判过期；阈值取 pairHardBps
    function _oracleAndPolicy(address base, address quote)
        internal
        view
        returns (uint256 oracleE18, uint256 updatedAt, uint16 limitBps, bool stale, bool srcFixed)
    {
        IOracleRouter.PriceSrc src;
        (oracleE18, updatedAt, src) = oracle.latestAnswer(base, quote);

        (uint16 hardBps, uint32 staleSec) = _pairPolicy(base, quote);

        if (src == IOracleRouter.PriceSrc.Fixed) {
            srcFixed = true;
            stale = false;
            limitBps = (hardBps >= defaults.hardBpsFixed) ? hardBps : defaults.hardBpsFixed;
        } else {
            srcFixed = false;
            stale = (block.timestamp - updatedAt) > staleSec;
            limitBps = hardBps;
        }
    }

    /// @dev 只拿交易需要的三项：公允价 / 偏离阈值 / 是否过期（减少一次多返回解构）
    function _oracleAndLimit(address base, address quote)
        internal
        view
        returns (uint256 oracleE18, uint16 limitBps, bool stale)
    {
        IOracleRouter.PriceSrc src;
        uint256 updatedAt;
        (oracleE18, updatedAt, src) = oracle.latestAnswer(base, quote);

        (uint16 hardBps, uint32 staleSec) = _pairPolicy(base, quote);

        if (src == IOracleRouter.PriceSrc.Fixed) {
            stale = false;
            limitBps = (hardBps >= defaults.hardBpsFixed) ? hardBps : defaults.hardBpsFixed;
        } else {
            stale = (block.timestamp - updatedAt) > staleSec;
            limitBps = hardBps;
        }
    }

    /// @dev 返回面向 base→quote 的储备，不再构造 struct，减少栈占用
    function _orientedReserves(address base, address quote)
        internal
        view
        returns (address pair, uint112 rBase, uint112 rQuote)
    {
        pair = FACTORY.getPair(base, quote);
        if (pair == address(0)) return (address(0), 0, 0);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        if (t0 == base) {
            rBase = r0;
            rQuote = r1;
        } else {
            rBase = r1;
            rQuote = r0;
        }
    }

    /// @dev 方向归一：把 pair 的 (r0,r1) 变成“面向 base→quote”的 (reserveBase,reserveQuote)
    struct Oriented {
        address pair;
        bool baseIsT0;
        uint112 reserveBase;
        uint112 reserveQuote;
    }

    function _oriented(address base, address quote) private view returns (Oriented memory o) {
        address p = FACTORY.getPair(base, quote);
        if (p == address(0)) return o; // o.pair=0 代表无池
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(p).getReserves();
        address t0 = IUniswapV2Pair(p).token0();
        o.pair = p;
        if (t0 == base) {
            o.baseIsT0 = true;
            o.reserveBase = r0;
            o.reserveQuote = r1;
        } else {
            o.baseIsT0 = false;
            o.reserveBase = r1;
            o.reserveQuote = r0;
        }
    }

    /// @dev 统一计算“本对使用的偏离阈值与过期阈值”（优先取覆盖；为 0 则回落到全局）
    function _pairPolicy(address a, address b) private view returns (uint16 hardBps, uint32 staleSec) {
        (bytes32 key,,) = _pairKeySorted(a, b);
        PairCfg memory cfg = pairCfg[key];
        if (cfg.enabled != 0) {
            hardBps = (cfg.hardBps == 0) ? defaults.hardBps : cfg.hardBps;
            staleSec = (cfg.staleSec == 0) ? defaults.staleSec : cfg.staleSec;
        } else {
            hardBps = defaults.hardBps;
            staleSec = defaults.staleSec;
        }
    }

    /// @dev 生成“无序对”的键：对 (a,b) 排序得到 (x=min, y=max)，并返回 key 与排序后的 x,y。
    function _pairKeySorted(address a, address b) private pure returns (bytes32 key, address x, address y) {
        (x, y) = a < b ? (a, b) : (b, a);
        key = keccak256(abi.encodePacked(x, y));
    }

    /// @dev 最小校验（软约束）：只保证 path 基本合理
    function _validatePath2(address[] calldata path) private pure {
        if (path.length != 2) revert PathLength();
        if (path[0] == address(0) || path[1] == address(0) || path[0] == path[1]) revert PathArgs();
    }

    /// @dev 偏离（基点）。若任一价格为 0，直接返回最大值用于标记“不可用/不通过”。
    function _devBps(uint256 dexPxE18, uint256 oraclePxE18) private pure returns (uint256) {
        if (dexPxE18 == 0 || oraclePxE18 == 0) return type(uint256).max;
        if (dexPxE18 > oraclePxE18) return ((dexPxE18 - oraclePxE18) * 10_000) / oraclePxE18;
        return ((oraclePxE18 - dexPxE18) * 10_000) / oraclePxE18;
    }
}
