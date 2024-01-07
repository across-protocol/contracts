/* eslint-disable camelcase */
import axios from "axios";
import { task } from "hardhat/config";
import { Contract, Signer } from "ethers";
import { L1_ADDRESS_MAP } from "../deploy/consts";

require("dotenv").config();

const relayMessengerAbi = [
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
        name: "_nonce",
        type: "uint256",
      },
      {
        internalType: "bytes",
        name: "_message",
        type: "bytes",
      },
      {
        components: [
          {
            internalType: "uint256",
            name: "batchIndex",
            type: "uint256",
          },
          {
            internalType: "bytes",
            name: "merkleProof",
            type: "bytes",
          },
        ],
        internalType: "struct IL1ScrollMessenger.L2MessageProof",
        name: "_proof",
        type: "tuple",
      },
    ],
    name: "relayMessageWithProof",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
];

task("finalize-scroll-claims", "Finalize scroll claims")
  .addParam("l2Address", "Address that we'll attempt to claim")
  .setAction(async function (taskArguments, hre_: any) {
    const chainId = await hre_.getChainId();
    if (!["11155111", "1"].includes(String(chainId))) {
      throw new Error("This script can only be run on Sepolia or Ethereum mainnet");
    }
    const l2Operator = String(taskArguments.l2Address);
    if (!hre_.ethers.utils.isAddress(l2Operator)) {
      throw new Error("Invalid L2 operator address. Must pass as last argument to script");
    }

    const signer = (await (hre_ as any).ethers.getSigners())[0] as unknown as Signer;
    const apiUrl = `https://${String(chainId) === "1" ? "mainnet" : "sepolia"}-api-bridge.scroll.io/api/claimable`;
    const messengerContract = new Contract(L1_ADDRESS_MAP[chainId].scrollMessengerRelay, relayMessengerAbi, signer);
    const claimList = (
      await axios.get<{
        data: {
          result: {
            claimInfo: {
              from: string;
              to: string;
              value: string;
              nonce: string;
              message: string;
              proof: string;
              batch_index: string;
            };
          }[];
        };
      }>(apiUrl, {
        params: {
          page_size: 100,
          page: 1,
          address: l2Operator,
        },
      })
    ).data.data.result.map(({ claimInfo }) => claimInfo);
    console.log(`Attempting to finalize ${claimList.length} claims for ${l2Operator}`);
    const result = await Promise.allSettled(
      claimList.map(async (c) => {
        console.log(`Finalizing claim: (c.from -> c.to) = (${c.from}, ${c.to})`);
        await messengerContract.relayMessageWithProof(c.from, c.to, c.value, c.nonce, c.message, {
          batchIndex: c.batch_index,
          merkleProof: c.proof,
        });
      })
    );
    console.log(`Successfully finalized ${result.filter((r) => r.status === "fulfilled").length} claims`);
    if (result.filter((r) => r.status === "rejected").length > 0) {
      console.log(result.filter((r) => r.status === "rejected"));
      console.log(`Failed to finalize ${result.filter((r) => r.status === "rejected").length} claims`);
    }
  });
