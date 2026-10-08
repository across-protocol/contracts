import { AnchorProvider, setProvider } from "@anchor-lang/core";

const url = process.env.ANCHOR_PROVIDER_URL;
if (!url) throw new Error("ANCHOR_PROVIDER_URL is not defined");

// Set both connection and Anchor defaults so SPL-token setup and dependent preflights see confirmed state.
export const provider = AnchorProvider.local(url, {
  commitment: "confirmed",
  preflightCommitment: "confirmed",
});
setProvider(provider);
