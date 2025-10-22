use anchor_lang::{prelude::*, solana_program::keccak};

use crate::error::{DataDecodingError, SvmError};

// Macro to define the SponsoredCCTPQuote fields as an enum with associated constants for ordinal, start, count, and
// minimum total bytes.
macro_rules! define_quote_fields {
    ($($V:ident),+ $(,)?) => {
        #[derive(Copy, Clone)]
        pub enum SponsoredCCTPQuoteFields { $($V),+ }

        impl SponsoredCCTPQuoteFields {
            pub const fn ordinal(self) -> usize { self as usize }

            pub const fn start(self) -> usize { self.ordinal() * Self::WORD_SIZE }

            pub const fn end(self) -> usize {
                self.start() + Self::WORD_SIZE
            }

            pub const WORD_SIZE: usize = 32;

            pub const COUNT: usize = [$(SponsoredCCTPQuoteFields::$V),+].len();

            pub const MIN_TOTAL_BYTES: usize = Self::COUNT * Self::WORD_SIZE;
        }
    };
}

// Define the SponsoredCCTPQuote fields using the macro. Each field corresponds to a 32-byte word in the ABI encoded
// SponsoredCCTPQuote struct, except for the last actionData field which is variable length bytes and would be encoded
// to the multiple of 32 bytes (minimum is 64 bytes for the offset and length) on EVM.
define_quote_fields!(
    SourceDomain,
    DestinationDomain,
    MintRecipient,
    Amount,
    BurnToken,
    DestinationCaller,
    MaxFee,
    MinFinalityThreshold,
    Nonce,
    Deadline,
    MaxBpsToSponsor,
    MaxUserSlippageBps,
    FinalRecipient,
    FinalToken,
    ExecutionMode,
    ActionDataOffset,
    ActionDataLength
);

// Compile-time guarantees that below fields passed in hookData are contiguous, ordered and actionData is the last.
const _: () = {
    assert!((SponsoredCCTPQuoteFields::Deadline as usize) == (SponsoredCCTPQuoteFields::Nonce as usize) + 1);
    assert!((SponsoredCCTPQuoteFields::MaxBpsToSponsor as usize) == (SponsoredCCTPQuoteFields::Deadline as usize) + 1);
    assert!(
        (SponsoredCCTPQuoteFields::MaxUserSlippageBps as usize)
            == (SponsoredCCTPQuoteFields::MaxBpsToSponsor as usize) + 1
    );
    assert!(
        (SponsoredCCTPQuoteFields::FinalRecipient as usize)
            == (SponsoredCCTPQuoteFields::MaxUserSlippageBps as usize) + 1
    );
    assert!((SponsoredCCTPQuoteFields::FinalToken as usize) == (SponsoredCCTPQuoteFields::FinalRecipient as usize) + 1);
    assert!((SponsoredCCTPQuoteFields::ExecutionMode as usize) == (SponsoredCCTPQuoteFields::FinalToken as usize) + 1);
    assert!(
        (SponsoredCCTPQuoteFields::ActionDataOffset as usize) == (SponsoredCCTPQuoteFields::ExecutionMode as usize) + 1
    );
    assert!(
        (SponsoredCCTPQuoteFields::ActionDataLength as usize)
            == (SponsoredCCTPQuoteFields::ActionDataOffset as usize) + 1
    );
    assert!((SponsoredCCTPQuoteFields::ActionDataLength as usize) == SponsoredCCTPQuoteFields::COUNT - 1);
};

pub const MIN_QUOTE_DATA_LENGTH: usize = SponsoredCCTPQuoteFields::MIN_TOTAL_BYTES;

pub const HOOK_DATA_START: usize = SponsoredCCTPQuoteFields::Nonce.start();

pub const NONCE_START: usize = SponsoredCCTPQuoteFields::Nonce.start();
pub const NONCE_END: usize = SponsoredCCTPQuoteFields::Nonce.end();

pub struct SponsoredCCTPQuote<'a> {
    data: &'a [u8],
}

impl<'a> SponsoredCCTPQuote<'a> {
    pub fn new(quote_bytes: &'a [u8]) -> Result<Self> {
        // Encoded quote data must be at least MIN_QUOTE_DATA_LENGTH bytes long and must be a multiple of 32 bytes.
        let quote_bytes_len = quote_bytes.len();
        if quote_bytes_len < MIN_QUOTE_DATA_LENGTH || quote_bytes_len % SponsoredCCTPQuoteFields::WORD_SIZE != 0 {
            return err!(SvmError::InvalidQuoteDataLength);
        }

        Ok(Self { data: quote_bytes })
    }

    /// EVM-compatible typed hash used for signature verification.
    ///
    /// Mirrors the Solidity implementation:
    /// - The full quote hash is split into **two parts** to avoid the EVM stack too deep” issue in the contract.
    /// - The dynamic `actionData` is hashed separately (`keccak256(actionData)`) and that 32-byte digest is included as
    ///   the last field of `hash2`.
    /// - Finally, `typedDataHash = keccak256(abi.encode(hash1, hash2))`.
    ///
    /// Rust implementation detail:
    /// - We use `keccak::hashv(&[...])` to hash the bytewise concatenation of slices without building intermediate
    ///   buffers (no memcopy).
    pub fn evm_typed_hash(&self) -> Result<[u8; 32]> {
        Ok(keccak::hashv(&[&self.hash1(), &self.hash2()?]).to_bytes())
    }

    /// `hash1` (EVM: first part) = keccak256(abi.encode(sourceDomain, destinationDomain, mintRecipient, amount,
    ///   burnToken, destinationCaller, maxFee, minFinalityThreshold))
    ///
    /// These are all static ABI fields, so `abi.encode(...)` is exactly the concatenation of their 32-byte words
    /// already present in the head.
    fn hash1(&self) -> [u8; 32] {
        let start = SponsoredCCTPQuoteFields::SourceDomain.start();
        let end = SponsoredCCTPQuoteFields::MinFinalityThreshold.end();

        // Safe: start and end are derived from SponsoredCCTPQuoteFields, so this should always be in-bounds.
        keccak::hash(&self.data[start..end]).to_bytes()
    }

    /// `hash2` (EVM: second part) = keccak256(abi.encode(nonce, deadline, maxBpsToSponsor, maxUserSlippageBps,
    ///   finalRecipient, finalToken, executionMode, keccak256(actionData)))
    ///
    /// We hash the static words (`Nonce..ExecutionMode`) directly from the head with appended `keccak(actionData)` as a
    /// `bytes32` (static) value.
    fn hash2(&self) -> Result<[u8; 32]> {
        let start = SponsoredCCTPQuoteFields::Nonce.start();
        let end = SponsoredCCTPQuoteFields::ExecutionMode.end();

        // Safe: start and end are derived from SponsoredCCTPQuoteFields, so this should always be in-bounds.
        Ok(keccak::hashv(&[&self.data[start..end], &self.action_data_hash()?]).to_bytes())
    }

    /// `keccak256(actionData)` — hashes only the dynamic bytes content (not ABI-encoded), matching the Solidity side's
    /// `keccak256(quote.actionData)`.
    fn action_data_hash(&self) -> Result<[u8; 32]> {
        // actionData bytes start immediately after its length word.
        let start = SponsoredCCTPQuoteFields::ActionDataLength.end();
        let length = self.get_action_data_len_checked()?;

        // Safe: get_action_data_len_checked() ensures that the actionData bytes are within bounds.
        Ok(keccak::hash(&self.data[start..start + length]).to_bytes())
    }

    pub fn source_domain(&self) -> Result<u32> {
        Self::decode_to_u32(self.get_field_word(SponsoredCCTPQuoteFields::SourceDomain))
    }

    pub fn destination_domain(&self) -> Result<u32> {
        Self::decode_to_u32(self.get_field_word(SponsoredCCTPQuoteFields::DestinationDomain))
    }

    pub fn mint_recipient(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::MintRecipient))
    }

    pub fn amount(&self) -> Result<u64> {
        Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::Amount))
    }

    pub fn burn_token(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::BurnToken))
    }

    pub fn destination_caller(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::DestinationCaller))
    }

    pub fn max_fee(&self) -> Result<u64> {
        Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::MaxFee))
    }

    pub fn min_finality_threshold(&self) -> Result<u32> {
        Self::decode_to_u32(self.get_field_word(SponsoredCCTPQuoteFields::MinFinalityThreshold))
    }

    pub fn nonce(&self) -> Result<[u8; 32]> {
        Self::decode_to_bytes32(self.get_field_word(SponsoredCCTPQuoteFields::Nonce))
    }

    pub fn deadline(&self) -> Result<i64> {
        Self::decode_to_i64(self.get_field_word(SponsoredCCTPQuoteFields::Deadline))
    }

    pub fn max_bps_to_sponsor(&self) -> Result<u64> {
        Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::MaxBpsToSponsor))
    }

    pub fn max_user_slippage_bps(&self) -> Result<u64> {
        Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::MaxUserSlippageBps))
    }

    pub fn final_recipient(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::FinalRecipient))
    }

    pub fn final_token(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::FinalToken))
    }

    pub fn hook_data(&self) -> Result<Vec<u8>> {
        // Safe: HOOK_DATA_START is derived from SponsoredCCTPQuoteFields, so this should always be in-bounds.
        let mut hook_data = self.data[HOOK_DATA_START..].to_vec();

        self.get_action_data_len_checked()?; // We only need the check, not the length here.

        // Patch the actionData offset relative to the HOOK_DATA_START.
        let hook_data_action_data_offset =
            (SponsoredCCTPQuoteFields::ActionDataLength.start() - HOOK_DATA_START) as u64;
        let offset_start = SponsoredCCTPQuoteFields::ActionDataOffset.start() - HOOK_DATA_START;
        hook_data[offset_start + 24..offset_start + 32].copy_from_slice(&hook_data_action_data_offset.to_be_bytes());

        Ok(hook_data)
    }

    fn get_action_data_len_checked(&self) -> Result<usize> {
        // Verify the actionData bytes offset points to its length field.
        let quote_action_data_offset =
            Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::ActionDataOffset))?;
        if quote_action_data_offset != (SponsoredCCTPQuoteFields::ActionDataLength.start() as u64) {
            return err!(DataDecodingError::CannotDecodeBytes);
        }

        // Verify the encoded quote data has sufficient length to hold the actionData bytes (constructor only checks the
        // minimum length to hold empty actionData bytes).
        let action_data_length =
            Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::ActionDataLength))? as usize;
        if action_data_length > self.data.len() - MIN_QUOTE_DATA_LENGTH {
            return err!(DataDecodingError::CannotDecodeBytes);
        }

        Ok(action_data_length)
    }

    fn get_field_word(&self, field: SponsoredCCTPQuoteFields) -> &[u8; 32] {
        let start = field.start();
        let end = field.end();
        // Safe: start and end are derived from SponsoredCCTPQuoteFields, so this should always be in-bounds.
        let data_slice = &self.data[start..end];
        // Safe: data_slice is exactly 32 bytes long, so we can convert it to [u8; 32].
        <&[u8; 32]>::try_from(data_slice).unwrap()
    }

    fn decode_to_u32(data: &[u8; 32]) -> Result<u32> {
        if data[..28].iter().any(|&b| b != 0) {
            return err!(DataDecodingError::CannotDecodeToU32);
        }
        // Safe: data[28..] is exactly 4 bytes long, so we can convert it to [u8; 4].
        Ok(u32::from_be_bytes(data[28..].try_into().unwrap()))
    }

    fn decode_to_u64(data: &[u8; 32]) -> Result<u64> {
        if data[..24].iter().any(|&b| b != 0) {
            return err!(DataDecodingError::CannotDecodeToU64);
        }
        // Safe: data[24..] is exactly 8 bytes long, so we can convert it to [u8; 8].
        Ok(u64::from_be_bytes(data[24..].try_into().unwrap()))
    }

    fn decode_to_i64(data: &[u8; 32]) -> Result<i64> {
        if data[..24].iter().any(|&b| b != 0) {
            return err!(DataDecodingError::CannotDecodeToI64);
        }
        // Safe: data[24..] is exactly 8 bytes long, so we can convert it to [u8; 8].
        let v_u64 = u64::from_be_bytes(data[24..].try_into().unwrap());
        match i64::try_from(v_u64) {
            Ok(v_i64) => Ok(v_i64),
            Err(_) => err!(DataDecodingError::CannotDecodeToI64),
        }
    }

    fn decode_to_pubkey(data: &[u8; 32]) -> Result<Pubkey> {
        // Wrap in Result just to have consistency with decoding other field types that might error.
        Ok(Pubkey::from(*data))
    }

    fn decode_to_bytes32(data: &[u8; 32]) -> Result<[u8; 32]> {
        // Wrap in Result just to have consistency with decoding other field types that might error.
        Ok(*data)
    }
}
