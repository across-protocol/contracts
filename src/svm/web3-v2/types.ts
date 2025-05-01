import {
  Rpc,
  RpcSubscriptions,
  RpcTransport,
  SignatureNotificationsApi,
  SlotNotificationsApi,
  SolanaRpcApiFromTransport,
} from "@solana/kit";

export type RpcClient = {
  rpc: Rpc<SolanaRpcApiFromTransport<RpcTransport>>;
  rpcSubscriptions: RpcSubscriptions<SignatureNotificationsApi & SlotNotificationsApi>;
};
