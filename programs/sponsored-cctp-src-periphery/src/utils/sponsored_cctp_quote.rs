use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SponsoredCCTPQuote {
    pub source_domain: u32,
    pub destination_domain: u32,
    pub mint_recipient: Pubkey,
    pub amount: u64,
    pub burn_token: Pubkey,
    pub destination_caller: Pubkey,
    pub max_fee: u64,
    pub min_finality_threshold: u32,
    pub nonce: [u8; 32],
    pub deadline: u64,
    pub max_bps_to_sponsor: u64,
    pub max_user_slippage_bps: u64,
    pub final_recipient: Pubkey,
    pub final_token: Pubkey,
    pub execution_mode: u8,
    pub action_data: Vec<u8>,
}

impl SponsoredCCTPQuote {
    /// EVM-compatible typed hash used for signature verification.
    ///
    /// Mirrors the Solidity implementation:
    /// - The full quote hash is split into two parts to avoid the EVM stack too deep issue in the contract.
    /// - The dynamic `actionData` is hashed separately (`keccak256(actionData)`) and that 32-byte digest is included as
    ///   the last field of `hash2`.
    /// - Finally, `typedDataHash = keccak256(abi.encode(hash1, hash2))`.
    ///
    /// Rust implementation detail:
    /// - We use `keccak::hashv(&[...])` to hash the bytewise concatenation of slices without building intermediate
    ///   buffers (no memcopy).
    pub fn evm_typed_hash(&self) -> [u8; 32] {
        keccak::hashv(&[&self.hash1(), &self.hash2()]).to_bytes()
    }

    /// `hash1` (EVM: first part) = keccak256(abi.encode(sourceDomain, destinationDomain, mintRecipient, amount,
    ///   burnToken, destinationCaller, maxFee, minFinalityThreshold))
    ///
    /// These are all static ABI fields, so `abi.encode(...)` is exactly the concatenation of their 32-byte words
    /// already present in the head.
    fn hash1(&self) -> [u8; 32] {
        // Encode the first 8 static quote data fields.
        let mut encoded = Vec::with_capacity(8 * 32);

        Self::encode_u32(&mut encoded, self.source_domain);
        Self::encode_u32(&mut encoded, self.destination_domain);
        Self::encode_pubkey(&mut encoded, &self.mint_recipient);
        Self::encode_u64(&mut encoded, self.amount);
        Self::encode_pubkey(&mut encoded, &self.burn_token);
        Self::encode_pubkey(&mut encoded, &self.destination_caller);
        Self::encode_u64(&mut encoded, self.max_fee);
        Self::encode_u32(&mut encoded, self.min_finality_threshold);

        keccak::hash(&encoded).to_bytes()
    }

    /// `hash2` (EVM: second part) = keccak256(abi.encode(nonce, deadline, maxBpsToSponsor, maxUserSlippageBps,
    ///   finalRecipient, finalToken, executionMode, keccak256(actionData)))
    ///
    /// We hash the static words (`nonce..executionMode`) directly from the head with appended `keccak(actionData)` as a
    /// `bytes32` (static) value.
    fn hash2(&self) -> [u8; 32] {
        // Encode the following 7 static quote data fields + action_data hash.
        let mut encoded = Vec::with_capacity(8 * 32);

        Self::encode_bytes32(&mut encoded, &self.nonce);
        Self::encode_u64(&mut encoded, self.deadline);
        Self::encode_u64(&mut encoded, self.max_bps_to_sponsor);
        Self::encode_u64(&mut encoded, self.max_user_slippage_bps);
        Self::encode_pubkey(&mut encoded, &self.final_recipient);
        Self::encode_pubkey(&mut encoded, &self.final_token);
        Self::encode_u8(&mut encoded, self.execution_mode);
        Self::encode_bytes32(&mut encoded, &keccak::hash(&self.action_data).to_bytes());

        keccak::hash(&encoded).to_bytes()
    }

    pub fn encode_hook_data(&self) -> Vec<u8> {
        // ABI encoded hookData on EVM holds 7 static 32-byte words followed by the actionData offset that points to the
        // length-prefixed actionData bytes. The actionData bytes are padded to 32-byte word length.
        let action_data_offset = 8 * 32;
        let min_hook_data_len = action_data_offset + 32;
        let mut hook_data = Vec::with_capacity(min_hook_data_len);

        Self::encode_bytes32(&mut hook_data, &self.nonce);
        Self::encode_u64(&mut hook_data, self.deadline);
        Self::encode_u64(&mut hook_data, self.max_bps_to_sponsor);
        Self::encode_u64(&mut hook_data, self.max_user_slippage_bps);
        Self::encode_pubkey(&mut hook_data, &self.final_recipient);
        Self::encode_pubkey(&mut hook_data, &self.final_token);
        Self::encode_u8(&mut hook_data, self.execution_mode);
        Self::encode_bytes(&mut hook_data, &self.action_data, action_data_offset as u64);

        hook_data
    }

    fn pad32_left(output: &mut Vec<u8>, input: &[u8]) {
        let pad_len = (32usize).saturating_sub(input.len());
        output.extend_from_slice(&[0u8; 32][..pad_len]);
        output.extend_from_slice(input);
    }

    fn encode_u8(output: &mut Vec<u8>, input: u8) {
        Self::pad32_left(output, &[input]);
    }

    fn encode_u32(output: &mut Vec<u8>, input: u32) {
        Self::pad32_left(output, &input.to_be_bytes());
    }

    fn encode_u64(output: &mut Vec<u8>, input: u64) {
        Self::pad32_left(output, &input.to_be_bytes());
    }

    fn encode_bytes32(output: &mut Vec<u8>, input: &[u8; 32]) {
        output.extend_from_slice(input);
    }

    fn encode_pubkey(output: &mut Vec<u8>, input: &Pubkey) {
        output.extend_from_slice(input.as_ref());
    }

    fn encode_bytes(output: &mut Vec<u8>, input: &[u8], offset: u64) {
        Self::encode_u64(output, offset);
        Self::encode_u64(output, input.len() as u64);
        output.extend_from_slice(input);

        // Pad to 32 byte word length.
        let remainder = input.len() % 32;
        if remainder != 0 {
            output.extend_from_slice(&[0u8; 32][..32 - remainder]);
        }
    }
}
