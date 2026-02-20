// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SpokePoolInterface } from "./SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "./V3SpokePoolInterface.sol";

/**
 * @notice Consolidated interface for SpokePool consumers.
 * @dev Combines active V3 deposit/fill API with legacy/admin/root functions.
 */
interface ISpokePool is SpokePoolInterface, V3SpokePoolInterface {}
