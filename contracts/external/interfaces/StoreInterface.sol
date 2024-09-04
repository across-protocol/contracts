// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Library for fixed point arithmetic on uints
 * @notice This library is deprecated now that Solidity supports fixed point arithmetic natively, however its included
 * because contracts like the UMA Store contract, which the HubPool calls, uses this interface. Specifically,
 * the HubPool needs to pull the rawValue from a FixedPoint type returned by the Store.computeFinalFee() function.
 */
library FixedPoint {
    struct Unsigned {
        uint256 rawValue;
    }
}

/**
 * @title Interface that allows financial contracts to pay oracle fees for their use of the system.
 */
interface StoreInterface {
    /**
     * @notice Computes the final oracle fees that a contract should pay at settlement.
     * @param currency token used to pay the final fee.
     * @return finalFee amount due.
     */
    function computeFinalFee(address currency) external view returns (FixedPoint.Unsigned memory);
}
