use anchor_lang::{
    prelude::*,
    solana_program::{instruction::Instruction, program},
};

use crate::{
    constants::MESSAGE_TRANSMITTER_PROGRAM_ID,
    error::{CallDataError, SvmError},
    program::SvmSpoke,
    state::State,
    utils::{self, EncodeInstructionData},
};

#[derive(Accounts)]
#[instruction(params: HandleReceiveMessageParams)]
pub struct HandleReceiveMessage<'info> {
    /// PDA authorized to handle messages from the Message Transmitter program.
    #[account(
        seeds = [b"message_transmitter_authority", SvmSpoke::id().as_ref()],
        bump = params.authority_bump,
        seeds::program = MESSAGE_TRANSMITTER_PROGRAM_ID
    )]
    pub authority_pda: Signer<'info>,

    /// State account storing configuration for the remote domain and cross-domain admin.
    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = params.remote_domain == state.remote_domain @ SvmError::InvalidRemoteDomain,
        constraint = params.sender == state.cross_domain_admin @ SvmError::InvalidRemoteSender,
    )]
    pub state: Account<'info, State>,

    /// CHECK: Unchecked account used for authenticating self-CPI invoked by the received message.
    #[account(seeds = [b"self_authority"], bump)]
    pub self_authority: UncheckedAccount<'info>,

    /// Program to invoke for self-CPI instructions.
    pub program: Program<'info, SvmSpoke>,
}

/// Parameters for the `HandleReceiveMessage` instruction.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct HandleReceiveMessageParams {
    pub remote_domain: u32,    // Domain from which the message originates.
    pub sender: Pubkey,        // Address of the message sender.
    pub message_body: Vec<u8>, // Encoded message body.
    pub authority_bump: u8,    // Bump seed for the authority PDA.
}

/// Handles a received message, translates it into an internal instruction, and invokes the instruction.
///
/// Parameters:
/// - `ctx`: The context for the handle receive message.
/// - `params`: Contains the message body and metadata for processing.
pub fn handle_receive_message<'info>(
    ctx: Context<'_, '_, '_, 'info, HandleReceiveMessage<'info>>,
    params: HandleReceiveMessageParams,
) -> Result<()> {
    let self_ix_data = translate_message(&params.message_body)?;

    invoke_self(&ctx, &self_ix_data)
}

/// Translates an incoming message body into Solana-compatible instruction data.
///
/// Parameters:
/// - `data`: The message body to translate.
fn translate_message(data: &Vec<u8>) -> Result<Vec<u8>> {
    match utils::get_solidity_selector(data)? {
        s if s == utils::encode_solidity_selector("pauseDeposits(bool)") => {
            let pause = utils::decode_solidity_bool(&utils::get_solidity_arg(data, 0)?)?;

            pause.encode_instruction_data("global:pause_deposits")
        }
        s if s == utils::encode_solidity_selector("pauseFills(bool)") => {
            let pause = utils::decode_solidity_bool(&utils::get_solidity_arg(data, 0)?)?;

            pause.encode_instruction_data("global:pause_fills")
        }
        s if s == utils::encode_solidity_selector("setCrossDomainAdmin(address)") => {
            let new_cross_domain_admin = utils::decode_solidity_address(&utils::get_solidity_arg(data, 0)?)?;

            new_cross_domain_admin.encode_instruction_data("global:set_cross_domain_admin")
        }
        s if s == utils::encode_solidity_selector("setEnableRoute(bytes32,uint64,bool)") => {
            let origin_token = Pubkey::new_from_array(utils::get_solidity_arg(data, 0)?);
            let destination_chain_id = utils::decode_solidity_uint64(&utils::get_solidity_arg(data, 1)?)?;
            let enabled = utils::decode_solidity_bool(&utils::get_solidity_arg(data, 2)?)?;

            (origin_token, destination_chain_id, enabled).encode_instruction_data("global:set_enable_route")
        }
        s if s == utils::encode_solidity_selector("relayRootBundle(bytes32,bytes32)") => {
            let relayer_refund_root = utils::get_solidity_arg(data, 0)?;
            let slow_relay_root = utils::get_solidity_arg(data, 1)?;

            (relayer_refund_root, slow_relay_root).encode_instruction_data("global:relay_root_bundle")
        }
        s if s == utils::encode_solidity_selector("emergencyDeleteRootBundle(uint256)") => {
            let root_id = utils::decode_solidity_uint32(&utils::get_solidity_arg(data, 0)?)?;

            root_id.encode_instruction_data("global:emergency_delete_root_bundle")
        }
        _ => Err(CallDataError::UnsupportedSelector.into()),
    }
}

/// Invokes self-CPI for message calls received from a remote domain.
///
/// Parameters:
/// - `ctx`: The context for the self-CPI.
/// - `data`: The instruction data to invoke.
fn invoke_self<'info>(ctx: &Context<'_, '_, '_, 'info, HandleReceiveMessage<'info>>, data: &Vec<u8>) -> Result<()> {
    let self_authority_seeds: &[&[&[u8]]] = &[&[b"self_authority", &[ctx.bumps.self_authority]]];

    let mut accounts = Vec::with_capacity(1 + ctx.remaining_accounts.len());

    // Add the self_authority account as a signer.
    accounts.push(AccountMeta::new_readonly(ctx.accounts.self_authority.key(), true));

    // Add remaining accounts with appropriate permissions.
    for acc in ctx.remaining_accounts {
        if acc.is_writable {
            accounts.push(AccountMeta::new(acc.key(), acc.is_signer));
        } else {
            accounts.push(AccountMeta::new_readonly(acc.key(), acc.is_signer));
        }
    }

    // Construct the instruction with translated data.
    let instruction = Instruction {
        program_id: crate::ID,
        accounts,
        data: data.to_owned(),
    };

    // Invoke the instruction with the appropriate signer seeds.
    program::invoke_signed(
        &instruction,
        &[&[ctx.accounts.self_authority.to_account_info()], ctx.remaining_accounts].concat(),
        self_authority_seeds,
    )?;

    Ok(())
}
