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
  {
    inputs: [],
    name: "localMinter",
    outputs: [{ internalType: "contract ITokenMinter", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
];

export const CCTPTokenV2MessengerInterface = [
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
      {
        internalType: "bytes32",
        name: "destinationCaller",
        type: "bytes32",
      },
      {
        internalType: "uint256",
        name: "maxFee",
        type: "uint256",
      },
      {
        internalType: "uint32",
        name: "minFinalityThreshold",
        type: "uint32",
      },
    ],
    name: "depositForBurn",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "localMinter",
    outputs: [{ internalType: "contract ITokenMinterV2", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "feeRecipient",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
];

export const CCTPTokenMinterInterface = [
  {
    inputs: [{ internalType: "address", name: "", type: "address" }],
    name: "burnLimitsPerMessage",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
];

export const CCTPMessageTransmitterInterface = [
  {
    inputs: [
      { internalType: "uint32", name: "destinationDomain", type: "uint32" },
      { internalType: "bytes32", name: "recipient", type: "bytes32" },
      { internalType: "bytes", name: "messageBody", type: "bytes" },
    ],
    name: "sendMessage",
    outputs: [{ internalType: "uint64", name: "", type: "uint64" }],
    stateMutability: "nonpayable",
    type: "function",
  },
];
