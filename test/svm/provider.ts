import { AnchorProvider, setProvider } from "@anchor-lang/core";

const url = process.env.ANCHOR_PROVIDER_URL;
if (!url) throw new Error("ANCHOR_PROVIDER_URL is not defined");

// Set both connection and Anchor defaults so SPL-token setup and dependent preflights see confirmed state.
export const provider = AnchorProvider.local(url, {
  commitment: "confirmed",
  preflightCommitment: "confirmed",
});
setProvider(provider);

// Failed transactions can make web3.js confirmation either reject or return an error, depending on RPC timing.
// Read the confirmed receipt so negative tests assert the actual runtime result in either case.
export async function getConfirmedTransaction(signature: string) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const receipt = await provider.connection.getTransaction(signature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (receipt) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Confirmed transaction receipt unavailable: ${signature}`);
}
