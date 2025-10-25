// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBridge
 * @notice 统一的桥接接口（为未来扩展预留）
 * @dev 定义跨链桥接的标准功能，当前使用 Chainlink CCIP 实现
 */
interface IBridge {
    /**
     * @notice 发起跨链转移
     * @param token 源链 VToken 地址
     * @param amount 转移数量（最小单位）
     * @param receiver 目标链接收地址（address(0) 表示使用 msg.sender）
     * @param destinationChainSelector 目标链选择器
     * @return messageId CCIP 消息 ID
     * @return transferId 转移 ID（用于端到端追踪）
     */
    function sendToken(
        address token,
        uint256 amount,
        address receiver,
        uint64 destinationChainSelector
    ) external payable returns (bytes32 messageId, bytes32 transferId);
    
    /**
     * @notice 估算跨链费用
     * @param token 源链 VToken 地址
     * @param amount 转移数量
     * @param destinationChainSelector 目标链选择器
     * @return fee 预估费用（wei）
     */
    function estimateFee(
        address token,
        uint256 amount,
        uint64 destinationChainSelector
    ) external view returns (uint256 fee);
    
    /**
     * @notice 查询转移是否已处理
     * @param transferId 转移 ID
     * @return 是否已处理
     */
    function isTransferProcessed(bytes32 transferId) external view returns (bool);
}
