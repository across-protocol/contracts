// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title MockSpokePool
 * @notice Logic is 100% copied from "@uma/core/contracts/common/implementation/MultiCaller.sol" but one
 * comment is added to clarify why we allow delegatecall() in this contract, which is typically unsafe for use in
 * upgradeable implementation contracts.
 * @dev See https://docs.openzeppelin.com/upgrades-plugins/1.x/faq#delegatecall-selfdestruct for more details.
 */
contract MultiCallerUpgradeable {
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        //slither-disable-start calls-loop
        for (uint256 i = 0; i < data.length; i++) {
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
                // Next 5 lines from https://ethereum.stackexchange.com/a/83577
                if (result.length < 68) revert();
                //slither-disable-next-line assembly
                assembly {
                    result := add(result, 0x04)
                }
                revert(abi.decode(result, (string)));
            }

            results[i] = result;
        }
        //slither-disable-end calls-loop
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[1000] private __gap;
}
