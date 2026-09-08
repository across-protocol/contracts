import { AnchorProvider, setProvider } from "@coral-xyz/anchor";

// Set this before SvmSpoke.common constructs anchor.workspace.SvmSpoke; its
// default provider otherwise points at port 8899, not our isolated validator.
setProvider(AnchorProvider.env());
