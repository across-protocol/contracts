import {
  Rpc,
  RpcSubscriptions,
  RpcTransport,
  SignatureNotificationsApi,
  SlotNotificationsApi,
  SolanaRpcApiFromTransport,
} from "@solana/kit";

/**
 * A client for the Solana RPC.
 */
export type RpcClient = {
  rpc: Rpc<SolanaRpcApiFromTransport<RpcTransport>>;
  rpcSubscriptions: RpcSubscriptions<SignatureNotificationsApi & SlotNotificationsApi>;
};
