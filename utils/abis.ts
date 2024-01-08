export const CCTPTokenMessengerInterface = [
  {
    inputs: [
      {
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
      {
        internalType: "uint32",
        name: "destinationDomain",
        type: "uint32",
      },
      {
        internalType: "bytes32",
        name: "mintRecipient",
        type: "bytes32",
      },
      {
        internalType: "address",
        name: "burnToken",
        type: "address",
      },
    ],
    name: "depositForBurn",
    outputs: [
      {
        internalType: "uint64",
        name: "_nonce",
        type: "uint64",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
];
