//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./MockSpokePool.sol";

/**
 * @title MockSpokePoolV2
 * @notice Upgrades MockSpokePool for no practical reason other than to demonstrate
 * upgradeability options
 */
contract MockSpokePoolV2 is MockSpokePool {
    event NewEvent(bool value);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _wrappedNativeTokenAddress) MockSpokePool(_wrappedNativeTokenAddress) {} // solhint-disable-line no-empty-blocks

    // Demonstrative of how we could reset state variables in a V2 contract conveniently while initializing new
    // modules. The `reinitializer` modifier is required to create new Initializable contracts.
    function reinitialize(address _hubPool) public reinitializer(2) {
        _setHubPool(_hubPool);
    }

    // Demonstrative new function we could add in a V2 contract.
    function emitEvent() external {
        emit NewEvent(true);
    }
}
