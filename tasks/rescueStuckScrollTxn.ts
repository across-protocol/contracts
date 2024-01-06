/* eslint-disable camelcase */
import axios from "axios";
import { task } from "hardhat/config";
import { Contract, Signer, ethers } from "ethers";
import { L1_ADDRESS_MAP } from "../deploy/consts";
import { ZERO_ADDRESS } from "@uma/common";

require("dotenv").config();

const relayMessengerAbi = [
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "sender",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "target",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "value",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "messageNonce",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "gasLimit",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "bytes",
        name: "message",
        type: "bytes",
      },
    ],
    name: "SentMessage",
    type: "event",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "_from",
        type: "address",
      },
      {
        internalType: "address",
        name: "_to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "_value",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "_messageNonce",
        type: "uint256",
      },
      {
        internalType: "bytes",
        name: "_message",
        type: "bytes",
      },
      {
        internalType: "uint32",
        name: "_newGasLimit",
        type: "uint32",
      },
      {
        internalType: "address",
        name: "_refundAddress",
        type: "address",
      },
    ],
    name: "replayMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

task("rescue-stuck-scroll-txn", "Rescue a failed Scroll transaction")
  .addParam("l1Hash", "Txn of the L1 message to rescue")
  .addParam("gasLimit", "Gas limit to use for the rescue transaction")
  .setAction(async function (taskArguments, hre_: any) {
    const chainId = await hre_.getChainId();
    if (!["1", "11155111"].includes(String(chainId))) {
      throw new Error("This script can only be run on Sepolia or Ethereum mainnet");
    }
    const signer = (await (hre_ as any).ethers.getSigners())[0] as unknown as Signer;
    const messengerContract = new Contract(L1_ADDRESS_MAP[chainId].scrollMessengerRelay, relayMessengerAbi, signer);

    const txn = await signer.provider?.getTransactionReceipt(taskArguments.l1Hash);
    const eventSignature = ethers.utils.id("SentMessage(address,address,uint256,uint256,uint256,bytes)");
    const relevantEvent = txn?.logs?.find((log) => log.topics[0] === eventSignature);
    if (!relevantEvent) {
      throw new Error("No relevant event found. Is this a Scroll bridge transaction?");
    }
    const decodedEvent = messengerContract.interface.parseLog(relevantEvent);
    const { sender, target, value, messageNonce, message } = decodedEvent.args;
    console.log("Decoded event:", {
      sender,
      target,
      value: value.toString(),
      messageNonce: messageNonce.toString(),
      message: message.toString(),
    });

    console.log("Replaying message...");
    const resultingTxn = await messengerContract.replayMessage(
      sender, // _from
      target, // _to
      value, // _value
      messageNonce, // _messageNonce
      message, // _message
      ethers.BigNumber.from(taskArguments.gasLimit), // _newGasLimit
      await signer.getAddress(), // _refundAddress
      {
        // 0.00001 ETH to be sent to the Scroll relayer (to cover L1 gas costs)
        // Using recommended value default as described here: https://docs.scroll.io/en/developers/l1-and-l2-bridging/eth-and-erc20-token-bridge/
        // *Any* leftover ETH will be immediately refunded to the signer - this is just the L1 gas cost
        value: ethers.utils.parseEther("0.00001"),
      }
    );
    console.log("Replay transaction hash:", resultingTxn.hash);
  });
