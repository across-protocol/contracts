// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";
import { UpdateVkey } from "./UpdateVkey.s.sol";

/**
 * @title CheckHeliosVkey
 * @notice Reports, per chain, whether the SP1Helios contract already holds the expected vkey. Intended for
 * monitoring the rollout of a HubPool vkey update (see UpdateVkey.s.sol) as the relayed admin messages land.
 * @dev Reuses UpdateVkey's chain parsing and Tron-aware address lookup. Uses raw `eth_call` via `vm.rpc` instead
 * of forking so that it also works against Tron's `latest`-only JSON-RPC. RPC URLs are read from .env using the
 * NODE_URL_<CHAIN_ID> convention. Read-only; never broadcasts.
 *
 * Examples:
 *   # Per-chain vkey status
 *   forge script script/tasks/CheckHeliosVkey.s.sol:CheckHeliosVkey \
 *     --sig "check(bytes32,string)" \
 *     0x009677367b726fbff9493b3cb72e5d6d218cf4e453f92b7ca1bfce64fe005f1b "56,143,999,4217,4663,5042,9745,43114,728126428"
 *
 *   # Per-chain timestamp of the last successful SP1Helios.update() (latest HeadUpdate event)
 *   forge script script/tasks/CheckHeliosVkey.s.sol:CheckHeliosVkey \
 *     --sig "lastUpdate(string)" "56,143,999,4217,4663,5042,9745,43114,728126428"
 */
contract CheckHeliosVkey is UpdateVkey {
    /// @dev Block window per eth_getLogs query and how many windows to walk back before giving up.
    uint256 internal constant LOG_WINDOW = 5000;
    uint256 internal constant MAX_LOG_WINDOWS = 60;

    function check(bytes32 expectedVkey, string calldata chainsStr) external {
        uint256[] memory chainIds = parseChainIds(chainsStr);
        uint256 updated;
        uint256 pending;
        uint256 failed;

        console.log("");
        console.log("============ Check Helios Vkey ============");
        console.log("Expected Vkey:", vm.toString(expectedVkey));
        console.log("--------------------------------------------");

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            string memory rpcUrl = vm.envOr(string.concat("NODE_URL_", vm.toString(chainId)), string(""));
            if (bytes(rpcUrl).length == 0) {
                console.log("Chain %d: FAILED (no NODE_URL_%d in .env)", chainId, chainId);
                failed++;
                continue;
            }

            // Tron's Helios is read from deployed-addresses.json; EVM chains resolve it via SpokePool.helios().
            address helios = chainId == TRON_CHAIN_ID
                ? readAddressTronAware(chainId, "SP1Helios")
                : abi.decode(
                    ethCall(rpcUrl, readAddressTronAware(chainId, "SpokePool"), abi.encodeWithSignature("helios()")),
                    (address)
                );
            if (helios == address(0)) {
                console.log("Chain %d: FAILED (could not resolve Helios address)", chainId);
                failed++;
                continue;
            }

            bytes memory result = ethCall(rpcUrl, helios, abi.encodeWithSignature("heliosProgramVkey()"));
            if (result.length != 32) {
                console.log("Chain %d: FAILED (eth_call to Helios %s errored)", chainId, helios);
                failed++;
                continue;
            }
            bytes32 currentVkey = abi.decode(result, (bytes32));

            if (currentVkey == expectedVkey) {
                console.log("Chain %d: UPDATED  helios=%s", chainId, helios);
                updated++;
            } else {
                console.log("Chain %d: PENDING  helios=%s current=%s", chainId, helios, vm.toString(currentVkey));
                pending++;
            }
        }

        console.log("--------------------------------------------");
        console.log("Updated: %d  Pending: %d  Failed: %d", updated, pending, failed);
        console.log("============================================");
    }

    /// @notice Prints, per chain, when SP1Helios.update() last succeeded (block time of the latest HeadUpdate event)
    /// alongside the head slot it set. Forks each chain to use `vm.eth_getLogs`; chains that cannot be forked
    /// (Tron) fall back to the head slot time only.
    function lastUpdate(string calldata chainsStr) external {
        uint256[] memory chainIds = parseChainIds(chainsStr);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("HeadUpdate(uint256,bytes32)");

        console.log("");
        uint256 nowTs = vm.unixTime() / 1000;
        console.log("============ Last Helios Update ============");
        console.log("Now: %s", toDateString(nowTs));
        console.log("--------------------------------------------");

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            string memory rpcUrl = vm.envOr(string.concat("NODE_URL_", vm.toString(chainId)), string(""));
            if (bytes(rpcUrl).length == 0) {
                console.log("Chain %d: FAILED (no NODE_URL_%d in .env)", chainId, chainId);
                continue;
            }
            address helios = chainId == TRON_CHAIN_ID
                ? readAddressTronAware(chainId, "SP1Helios")
                : abi.decode(
                    ethCall(rpcUrl, readAddressTronAware(chainId, "SpokePool"), abi.encodeWithSignature("helios()")),
                    (address)
                );
            bytes memory headTs = ethCall(rpcUrl, helios, abi.encodeWithSignature("headTimestamp()"));
            bytes memory head = ethCall(rpcUrl, helios, abi.encodeWithSignature("head()"));
            if (helios == address(0) || headTs.length != 32 || head.length != 32) {
                console.log("Chain %d: FAILED (could not read Helios)", chainId);
                continue;
            }

            (bool found, uint256 updateBlock, uint256 updateTime, bytes32 txHash) = findLastHeadUpdate(
                rpcUrl,
                helios,
                topics
            );
            if (!found) {
                console.log(
                    "Chain %d: update tx not found (chain not forkable or no HeadUpdate in window); head slot %d, slot time %s",
                    chainId,
                    abi.decode(head, (uint256)),
                    toDateString(abi.decode(headTs, (uint256)))
                );
                continue;
            }
            console.log(
                "Chain %d: last update %s (%d min ago)",
                chainId,
                toDateString(updateTime),
                (nowTs - updateTime) / 60
            );
            console.log("  block %d  tx %s", updateBlock, vm.toString(txHash));
            console.log(
                "  head slot %d  slot time %s",
                abi.decode(head, (uint256)),
                toDateString(abi.decode(headTs, (uint256)))
            );
        }
        console.log("============================================");
    }

    /// @notice Walks back over `rpcUrl` in LOG_WINDOW-sized ranges for the newest HeadUpdate log on `helios`.
    function findLastHeadUpdate(
        string memory rpcUrl,
        address helios,
        bytes32[] memory topics
    ) internal returns (bool found, uint256 blockNumber, uint256 timestamp, bytes32 txHash) {
        try vm.createSelectFork(rpcUrl) {} catch {
            return (false, 0, 0, bytes32(0));
        }
        uint256 toBlock = block.number;
        for (uint256 w = 0; w < MAX_LOG_WINDOWS && toBlock > 0; w++) {
            uint256 fromBlock = toBlock > LOG_WINDOW ? toBlock - LOG_WINDOW : 0;
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, helios, topics);
            if (logs.length > 0) {
                Vm.EthGetLogs memory last = logs[logs.length - 1];
                vm.rollFork(last.blockNumber);
                return (true, last.blockNumber, block.timestamp, last.transactionHash);
            }
            toBlock = fromBlock;
        }
    }

    /// @notice Formats a unix timestamp as "YYYY-MM-DD HH:MM:SS UTC" (civil-from-days algorithm).
    function toDateString(uint256 ts) internal pure returns (string memory) {
        uint256 z = ts / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        uint256 secs = ts % 86400;
        return
            string.concat(
                vm.toString(year),
                "-",
                pad2(month),
                "-",
                pad2(day),
                " ",
                pad2(secs / 3600),
                ":",
                pad2((secs % 3600) / 60),
                ":",
                pad2(secs % 60),
                " UTC"
            );
    }

    function pad2(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    /// @notice Raw `eth_call` against `rpcUrl`; returns empty bytes on any RPC error.
    function ethCall(string memory rpcUrl, address to, bytes memory data) internal returns (bytes memory) {
        string memory obj = "ethCall";
        vm.serializeAddress(obj, "to", to);
        string memory callObject = vm.serializeBytes(obj, "data", data);
        // Append the quoted "latest" block tag without a mixed-quote literal (flagged by solhint).
        bytes1 quote = 0x22;
        string memory params = string(abi.encodePacked("[", callObject, ",", quote, "latest", quote, "]"));
        try vm.rpc(rpcUrl, "eth_call", params) returns (bytes memory result) {
            return result;
        } catch {
            return "";
        }
    }
}
