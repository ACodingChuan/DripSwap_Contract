// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

/*==============================*
 * 1) Oracle Router Mock (通用) *
 *==============================*/
contract MockOracleRouter is IOracleRouter {
    struct Rec {
        uint256 priceE18;
        uint256 updatedAt;
        PriceSrc src;
        bool set;
    }
    struct UsdRec {
        uint256 priceE18;
        uint256 updatedAt;
        bool set;
    }

    mapping(bytes32 => Rec) private _pair;   // (min,max) -> record
    mapping(address => UsdRec) private _usd; // token -> USD

    function _key(address a, address b) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(x, y));
    }

    // ---- test helpers ----
    function setPairPrice(address base, address quote, uint256 p, uint256 t, PriceSrc s) external {
        _pair[_key(base, quote)] = Rec({priceE18: p, updatedAt: t, src: s, set: true});
    }
    function setUSD(address token, uint256 p, uint256 t) external {
        _usd[token] = UsdRec({priceE18: p, updatedAt: t, set: true});
    }

    // ---- IOracleRouter ----
    function latestAnswer(address base, address quote)
        external
        view
        returns (uint256 priceE18, uint256 updatedAt, PriceSrc src)
    {
        Rec memory r = _pair[_key(base, quote)];
        require(r.set, "pair not set");
        return (r.priceE18, r.updatedAt, r.src);
    }

    function getUSDPrice(address token)
        external
        view
        returns (uint256 priceE18, uint256 updatedAt)
    {
        UsdRec memory r = _usd[token];
        require(r.set, "usd not set");
        return (r.priceE18, r.updatedAt);
    }
}

/*=============================*
 * 2) V2 Pair Mock (极简可调)  *
 *=============================*/
contract MockV2Pair is IUniswapV2Pair {
    address public  token0;
    address public  token1;
    uint112 private _r0;
    uint112 private _r1;
    uint32  private _ts;

    constructor(address _t0, address _t1, uint112 r0, uint112 r1) {
        token0 = _t0;
        token1 = _t1;
        _r0 = r0;
        _r1 = r1;
        _ts = 1;
    }

    // ---- test helpers ----
    function setReserves(uint112 r0, uint112 r1) external {
        _r0 = r0;
        _r1 = r1;
        _ts = _ts + 1;
    }

    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 blockTimestampLast) {
        return (_r0, _r1, _ts);
    }
}

/*==============================*
 * 3) V2 Factory Mock（可部署） *
 *==============================*/
contract MockV2Factory is IUniswapV2Factory {
    mapping(bytes32 => address) private _pair;

    function _key(address a, address b) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(x, y));
    }

    // A) 先部署好 pair，再注入
    function setPair(address a, address b, address p) external {
        _pair[_key(a, b)] = p;
    }

    // B) 直接由工厂创建一个带初始储备的 pair（测试里可再 setReserves）
    function createPair(address a, address b) external returns (address p) {
        require(a != b && a != address(0) && b != address(0), "bad args");
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        p = address(new MockV2Pair(t0, t1, 1_000_000 ether, 1_000_000 ether));
        _pair[_key(a, b)] = p;
    }

    // ---- IUniswapV2Factory ----
    function getPair(address a, address b) external view returns (address) {
        return _pair[_key(a, b)];
    }

    // 其余接口本测试用不到，返回默认值
    function feeTo() external pure returns (address) { return address(0); }
    function feeToSetter() external pure returns (address) { return address(0); }
    function allPairs(uint256) external pure returns (address) { return address(0); }
    function allPairsLength() external pure returns (uint256) { return 0; }
    function setFeeTo(address) external pure {}
    function setFeeToSetter(address) external pure {}
}

/*=====================================*
 * 4) Chainlink AggregatorV3 Mock (轻) *
 *=====================================*/
contract MockAggregatorV3 {
    int256 private _answer;
    uint8  private _decimals;
    uint256 private _updatedAt;

    constructor(uint8 d, int256 a, uint256 t) {
        _decimals = d;
        _answer   = a;
        _updatedAt = t;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // ---- test helpers ----
    function setAnswer(int256 a, uint256 t) external {
        _answer = a;
        _updatedAt = t;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }
}
