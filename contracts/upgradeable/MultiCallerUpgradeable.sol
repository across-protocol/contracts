// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title MultiCallerUpgradeable
 * @notice Logic is 100% copied from "@uma/core/contracts/common/implementation/MultiCaller.sol" but one
 * comment is added to clarify why we allow delegatecall() in this contract, which is typically unsafe for use in
 * upgradeable implementation contracts.
 * @dev See https://docs.openzeppelin.com/upgrades-plugins/1.x/faq#delegatecall-selfdestruct for more details.
 */
contract MultiCallerUpgradeable {
    struct Result {
        bool success;
        bytes returnData;
    }

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

    function _validateMulticallData(bytes[] calldata data) internal virtual {
        // no-op
    }

    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        _validateMulticallData(data);

        uint256 dataLength = data.length;
        results = new bytes[](dataLength);

        //slither-disable-start calls-loop
        for (uint256 i = 0; i < dataLength; i++) {
            // Typically, implementation contracts used in the upgradeable proxy pattern shouldn't call `delegatecall`
            // because it could allow a malicious actor to call this implementation contract directly (rather than
            // through a proxy contract) and then selfdestruct() the contract, thereby freezing the upgradeable
            // proxy. However, since we're only delegatecall-ing into this contract, then we can consider this
            // use of delegatecall() safe.

            //slither-disable-start low-level-calls
            /// @custom:oz-upgrades-unsafe-allow delegatecall
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            //slither-disable-end low-level-calls

            if (!success) {
                _revert(result);
            }

            results[i] = result;
        }
        //slither-disable-end calls-loop
    }

    function tryMulticall(bytes[] calldata data) external returns (Result[] memory results) {
        _validateMulticallData(data);

        uint256 dataLength = data.length;
        results = new Result[](dataLength);

        //slither-disable-start calls-loop
        for (uint256 i = 0; i < dataLength; i++) {
            // The delegatecall here is safe for the same reasons outlined in the first multicall function.
            Result memory result = results[i];
            //slither-disable-start low-level-calls
            /// @custom:oz-upgrades-unsafe-allow delegatecall
            (result.success, result.returnData) = address(this).delegatecall(data[i]);
            //slither-disable-end low-level-calls
        }
        //slither-disable-end calls-loop
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {Errors.FailedCall}.
     * @notice Copied from https://github.com/OpenZeppelin/openzeppelin-contracts/blob/dbb6104ce834628e473d2173bbc9d47f81a9eec3/contracts/utils/Address.sol#L146
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
        }
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure its always at the end of storage.
    uint256[1000] private __gap;
}
