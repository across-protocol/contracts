use anchor_lang::{prelude::*, solana_program::keccak};

use crate::error::{DataDecodingError, QuoteSignatureError};

// Macro to define the SponsoredCCTPQuote fields as an enum with associated constants for ordinal, start, end, count,
// and total bytes.
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

            pub const TOTAL_BYTES: usize = Self::COUNT * Self::WORD_SIZE;
        }
    };
}

// Define the SponsoredCCTPQuote fields using the macro. Each field corresponds to a 32-byte word in the ABI encoded
// SponsoredCCTPQuote struct.
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
    FinalRecipient,
    FinalToken
);

// Compile-time guarantees that these 5 fields passed in hookData are contiguous and ordered.
const _: () = {
    assert!((SponsoredCCTPQuoteFields::Deadline as usize) == (SponsoredCCTPQuoteFields::Nonce as usize) + 1);
    assert!((SponsoredCCTPQuoteFields::MaxBpsToSponsor as usize) == (SponsoredCCTPQuoteFields::Deadline as usize) + 1);
    assert!(
        (SponsoredCCTPQuoteFields::FinalRecipient as usize) == (SponsoredCCTPQuoteFields::MaxBpsToSponsor as usize) + 1
    );
    assert!((SponsoredCCTPQuoteFields::FinalToken as usize) == (SponsoredCCTPQuoteFields::FinalRecipient as usize) + 1);
};

pub const QUOTE_DATA_LENGTH: usize = SponsoredCCTPQuoteFields::TOTAL_BYTES;

pub const HOOK_DATA_START: usize = SponsoredCCTPQuoteFields::Nonce.start();
pub const HOOK_DATA_END: usize = SponsoredCCTPQuoteFields::FinalToken.end();
pub const HOOK_DATA_LENGTH: usize = HOOK_DATA_END - HOOK_DATA_START;

pub const NONCE_START: usize = SponsoredCCTPQuoteFields::Nonce.start();
pub const NONCE_END: usize = SponsoredCCTPQuoteFields::Nonce.end();

pub struct SponsoredCCTPQuote<'a> {
    data: &'a [u8],
}

impl<'a> SponsoredCCTPQuote<'a> {
    pub fn new(quote_bytes: &'a [u8]) -> Result<Self> {
        if quote_bytes.len() != QUOTE_DATA_LENGTH {
            return err!(QuoteSignatureError::InvalidQuoteDataLength);
        }

        Ok(Self { data: quote_bytes })
    }

    /// Returns Keccak hash of the encoded quote data.
    pub fn hash(&self) -> [u8; 32] {
        keccak::hash(self.data).to_bytes()
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

    pub fn deadline(&self) -> Result<u32> {
        Self::decode_to_u32(self.get_field_word(SponsoredCCTPQuoteFields::Deadline))
    }

    pub fn max_bps_to_sponsor(&self) -> Result<u64> {
        Self::decode_to_u64(self.get_field_word(SponsoredCCTPQuoteFields::MaxBpsToSponsor))
    }

    pub fn final_recipient(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::FinalRecipient))
    }

    pub fn final_token(&self) -> Result<Pubkey> {
        Self::decode_to_pubkey(self.get_field_word(SponsoredCCTPQuoteFields::FinalToken))
    }

    pub fn hook_data(&self) -> Vec<u8> {
        // Safe: HOOK_DATA_START and HOOK_DATA_END are derived from SponsoredCCTPQuoteFields, so this should always be
        // in-bounds.
        let data_slice = &self.data[HOOK_DATA_START..HOOK_DATA_END];
        // Safe: data_slice is exactly HOOK_DATA_LENGTH bytes long, so we can convert it to &[u8; HOOK_DATA_LENGTH].
        let hook_data_bytes = <&[u8; HOOK_DATA_LENGTH]>::try_from(data_slice).unwrap();
        hook_data_bytes.to_vec()
    }

    fn get_field_word(&self, field: SponsoredCCTPQuoteFields) -> &[u8; 32] {
        let start = field.start();
        let end = field.end();
        // Safe: start and end are derived from SponsoredCCTPQuoteFields, so this should always be in-bounds.
        let data_slice = &self.data[start..end];
        // Safe: data_slice is exactly 32 bytes long, so we can convert it to &[u8; 32].
        <&[u8; 32]>::try_from(data_slice).unwrap()
    }

    fn decode_to_u32(data: &[u8; 32]) -> Result<u32> {
        let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
        let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
        if h_value > 0 || l_value > (u32::MAX as u128) {
            return err!(DataDecodingError::CannotDecodeToU32);
        }
        Ok(l_value as u32)
    }

    fn decode_to_u64(data: &[u8; 32]) -> Result<u64> {
        let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
        let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
        if h_value > 0 || l_value > (u64::MAX as u128) {
            return err!(DataDecodingError::CannotDecodeToU64);
        }
        Ok(l_value as u64)
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
