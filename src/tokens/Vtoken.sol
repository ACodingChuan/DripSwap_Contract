// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title VToken - CCIP Burn-Mint Pool compatible ERC20 Token (upgradeable)
/// @notice Designed for deployment via ERC1167 minimal proxies. Only addresses granted
///         `BRIDGE_ROLE` may mint/burn. Pausing仅影响 mint/burn，转账不受限制。
contract VToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint8 private _tokenDecimals;

    event Minted(address indexed caller, address indexed to, uint256 amount);
    event Burned(address indexed caller, uint256 amount);

    /// @notice 初始化克隆实例
    function initialize(string memory name_, string memory symbol_, uint8 decimals_, address initialOwner)
        public
        initializer
    {
        require(initialOwner != address(0), "ZeroOwner");

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __AccessControl_init();
        __Ownable_init(initialOwner);
        __Pausable_init();

        _tokenDecimals = decimals_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);
    }

    /// @notice Mint tokens (only CCIP Pool)
    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        _mint(to, amount);
        emit Minted(msg.sender, to, amount);
    }

    /// @notice Burn tokens held by the caller (only CCIP Pool)
    function burn(uint256 amount) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @notice Optional helper for Chainlink CCIP pool admin discovery
    function getCCIPAdmin() external view returns (address) {
        return owner();
    }

    // --- Pause controls (only affect mint/burn) ---
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Ownership sync ---
    function _transferOwnership(address newOwner) internal override(OwnableUpgradeable) {
        address prev = owner();
        super._transferOwnership(newOwner);
        if (prev != newOwner) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
            _revokeRole(DEFAULT_ADMIN_ROLE, prev);
        }
    }

    // --- ERC165 / AccessControl ---
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @notice 便捷地授予/撤销 Bridge 角色
    function setBridgeRole(address pool) external onlyOwner {
        _grantRole(BRIDGE_ROLE, pool);
    }

    /// @dev 兼容 upgradeable 合约的存储 gap
    uint256[44] private __gap;
}
