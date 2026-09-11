import BN from "bn.js";

export const CIRCLE_IRIS_API_URL_DEVNET = "https://iris-api-sandbox.circle.com";
export const CIRCLE_IRIS_API_URL_MAINNET = "https://iris-api.circle.com";
export const SOLANA_USDC_MAINNET = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
export const SOLANA_USDC_DEVNET = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU";
export const SEPOLIA_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS = "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275";
export const MAINNET_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS = "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64";

// CCTP V2 finality threshold at which Circle attests only after hard finality on the source chain ("standard transfer").
export const CCTP_FINALITY_THRESHOLD_FINALIZED = 2000;
export const SOLANA_SPOKE_STATE_SEED = new BN(0);
