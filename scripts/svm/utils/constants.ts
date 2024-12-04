import { TOKEN_SYMBOLS_MAP } from "@across-protocol/constants";
import BN from "bn.js";

export const CIRCLE_IRIS_API_URL_DEVNET = "https://iris-api-sandbox.circle.com";
export const CIRCLE_IRIS_API_URL_MAINNET = "https://iris-api.circle.com";
export const SOLANA_USDC_MAINNET = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
export const SOLANA_USDC_DEVNET = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU";
export const SEPOLIA_CCTP_MESSAGE_TRANSMITTER_ADDRESS = "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD";
export const MAINNET_CCTP_MESSAGE_TRANSMITTER_ADDRESS = "0x0a992d191deec32afe36203ad87d7d289a738f81";
export const SEPOLIA_USDC_ADDRESS = TOKEN_SYMBOLS_MAP.USDC.addresses[5];
export const MAINNET_USDC_ADDRESS = TOKEN_SYMBOLS_MAP.USDC.addresses[1];

export const SOLANA_SPOKE_STATE_SEED = new BN(0);
