// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IVToken} from "src/interfaces/IVToken.sol";

/// @title VToken - 简单可铸造的 ERC20（自定义小数位）
/// @notice 对齐 Chainlink CCIP Burn-and-Mint Token 标准，供跨链桥接合约调用。
contract VToken is ERC20, Ownable, AccessControl, IVToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    uint8 private immutable _DEC;

    /// @param name_  代币名（如 "vUSDT"）
    /// @param symbol_ 代币符号（如 "vUSDT"）
    /// @param decimals_ 小数位（USDT/USDC=6，WBTC=8，其余=18）
    /// @param initialOwner 初始所有者（将拥有 mint 权限）
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address initialOwner)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        _DEC = decimals_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
        _grantRole(BURNER_ROLE, initialOwner);
    }

    function decimals() public view override(ERC20, IVToken) returns (uint8) {
        return _DEC;
    }

    function balanceOf(address account)
        public
        view
        override(ERC20, IVToken)
        returns (uint256)
    {
        return super.balanceOf(account);
    }

    function mint(address to, uint256 amount) external override(IVToken) onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(uint256 amount) external override(IVToken) {
        _burn(_msgSender(), amount);
    }

    function bridgeBurn(address from, uint256 amount) external override(IVToken) onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function getCCIPAdmin() external view override(IVToken) returns (address) {
        return owner();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return interfaceId == type(IVToken).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev 保持 Ownable owner 与 AccessControl 默认管理员同步，便于角色管理。
    function _transferOwnership(address newOwner) internal override {
        address previousOwner = owner();
        super._transferOwnership(newOwner);

        if (previousOwner != newOwner) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
            _revokeRole(DEFAULT_ADMIN_ROLE, previousOwner);
        }
    }
}
