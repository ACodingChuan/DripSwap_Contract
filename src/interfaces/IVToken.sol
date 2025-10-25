// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVToken
 * @notice VToken 接口，供 Bridge 合约调用
 * @dev 定义 VToken 跨链桥接所需的标准接口
 * 
 * 核心功能：
 * - mint: 铸造代币（仅 MINTER_ROLE 可调用）
 * - burn: 用户自己销毁代币
 * - bridgeBurn: 桥接合约销毁用户代币（仅 BURNER_ROLE 可调用）
 * - decimals: 获取小数位数（用于一致性校验）
 * - balanceOf: 查询余额
 * - getCCIPAdmin: 获取 CCIP 管理员地址（Chainlink 标准要求）
 */
interface IVToken {
    /**
     * @notice 铸造代币
     * @param to 接收地址
     * @param amount 铸造数量
     * @dev 仅具有 MINTER_ROLE 的地址可调用
     */
    function mint(address to, uint256 amount) external;
    
    /**
     * @notice 用户自己销毁代币
     * @param amount 销毁数量
     * @dev 任何用户都可以销毁自己的代币
     */
    function burn(uint256 amount) external;
    
    /**
     * @notice 桥接合约销毁用户代币
     * @param from 销毁地址
     * @param amount 销毁数量
     * @dev 仅具有 BURNER_ROLE 的地址可调用
     * @dev 桥接合约直接销毁，不需要 allowance
     */
    function bridgeBurn(address from, uint256 amount) external;
    
    /**
     * @notice 获取代币小数位数
     * @return 小数位数
     * @dev 用于跨链时验证源链和目标链代币的小数位一致性
     */
    function decimals() external view returns (uint8);
    
    /**
     * @notice 查询账户余额
     * @param account 账户地址
     * @return 余额
     */
    function balanceOf(address account) external view returns (uint256);
    
    /**
     * @notice 获取 CCIP 管理员地址
     * @return CCIP 管理员地址
     * @dev Chainlink CCIP 标准要求，用于 Token Admin Registry 兼容性
     */
    function getCCIPAdmin() external view returns (address);
}
