// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice The functions of the Merkl Distributor (AngleProtocol/merkl-contracts, contracts/Distributor.sol) that the
///         adapters call. Merkl publishes no interface file, and its contract doesn't compile against OpenZeppelin v5.
interface IMerklDistributor {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external;
    function claimed(address user, address token) external view returns (uint208 amount, uint48 timestamp, bytes32 merkleRoot);
}
