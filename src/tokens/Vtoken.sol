// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VToken - 简单可铸造的 ERC20（自定义小数位）
/// @dev 仅 owner 可铸造；用于本地/测试网络模拟 vUSDT/vETH 等。
contract VToken is ERC20, Ownable {
    uint8 private immutable _dec;

    /// @param name_  代币名（如 "vUSDT"）
    /// @param symbol_ 代币符号（如 "vUSDT"）
    /// @param decimals_ 小数位（USDT/USDC=6，WBTC=8，其余=18）
    /// @param initialOwner 初始所有者（将拥有 mint 权限）
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address initialOwner)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    /// @notice 仅 owner 可铸造
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
