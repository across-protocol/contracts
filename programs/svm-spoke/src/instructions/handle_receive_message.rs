use anchor_lang::{
    prelude::*,
    solana_program::{instruction::Instruction, program},
};

use crate::{
    constants::MESSAGE_TRANSMITTER_PROGRAM_ID,
    error::CalldataError,
    error::CustomError,
    program::SvmSpoke,
    utils::{self, EncodeInstructionData},
    State,
};

#[derive(Accounts)]
#[instruction(params: HandleReceiveMessageParams)]
pub struct HandleReceiveMessage<'info> {
    // authority_pda is a Signer to ensure that this instruction
    // can only be called by Message Transmitter
    #[account(
        seeds = [b"message_transmitter_authority", SvmSpoke::id().as_ref()],
        bump = params.authority_bump,
        seeds::program = MESSAGE_TRANSMITTER_PROGRAM_ID
    )]
    pub authority_pda: Signer<'info>,
    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = params.remote_domain == state.remote_domain @ CustomError::InvalidRemoteDomain,
        constraint = params.sender == state.cross_domain_admin @ CustomError::InvalidRemoteSender,
    )]
    pub state: Account<'info, State>,
    /// CHECK: empty PDA, used in authenticating self-CPI invoked by the received message.
    #[account(
        seeds = [b"self_authority"],
        bump,
    )]
    pub self_authority: UncheckedAccount<'info>,
    pub program: Program<'info, SvmSpoke>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct HandleReceiveMessageParams {
    pub remote_domain: u32,
    pub sender: Pubkey,
    pub message_body: Vec<u8>,
    pub authority_bump: u8,
}

impl<'info> HandleReceiveMessage<'info> {
    pub fn handle_receive_message(&self, params: &HandleReceiveMessageParams) -> Result<Vec<u8>> {
        // Return instruction data for the self invoked CPI based on the received message body.
        translate_message(&params.message_body)
    }
}

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
            let new_cross_domain_admin =
                utils::decode_solidity_address(&utils::get_solidity_arg(data, 0)?)?;

            new_cross_domain_admin.encode_instruction_data("global:set_cross_domain_admin")
        }
        // TODO: Make sure to change EVM SpokePool interface using bytes32 for token addresses and uint64 for chain IDs.
        s if s == utils::encode_solidity_selector("setEnableRoute(bytes32,uint64,bool)") => {
            let origin_token = Pubkey::new_from_array(utils::get_solidity_arg(data, 0)?);
            let destination_chain_id =
                utils::decode_solidity_uint64(&utils::get_solidity_arg(data, 1)?)?;
            let enabled = utils::decode_solidity_bool(&utils::get_solidity_arg(data, 2)?)?;

            (origin_token, destination_chain_id, enabled)
                .encode_instruction_data("global:set_enable_route")
        }
        s if s == utils::encode_solidity_selector("relayRootBundle(bytes32,bytes32)") => {
            let relayer_refund_root = utils::get_solidity_arg(data, 0)?;
            let slow_relay_root = utils::get_solidity_arg(data, 1)?;

            (relayer_refund_root, slow_relay_root)
                .encode_instruction_data("global:relay_root_bundle")
        }
        s if s == utils::encode_solidity_selector("emergencyDeleteRootBundle(uint256)") => {
            let root_id = utils::decode_solidity_uint32(&utils::get_solidity_arg(data, 0)?)?;

            root_id.encode_instruction_data("global:emergency_delete_root_bundle")
        }
        _ => Err(CalldataError::UnsupportedSelector.into()),
    }
}

// Invokes self CPI for remote domain invoked message calls. We use low level invoke_signed with seeds corresponding to
// the self_authority account and passing all remaining accounts from the context. Instruction data is obtained within
// handle_receive_message by translating the received message body into a valid instruction data for the invoked CPI.
pub fn invoke_self<'info>(
    ctx: &Context<'_, '_, '_, 'info, HandleReceiveMessage<'info>>,
    data: &Vec<u8>,
) -> Result<()> {
    let self_authority_seeds: &[&[&[u8]]] = &[&[b"self_authority", &[ctx.bumps.self_authority]]];

    let mut accounts = Vec::with_capacity(1 + ctx.remaining_accounts.len());

    accounts.push(AccountMeta::new_readonly(
        ctx.accounts.self_authority.key(),
        true,
    ));

    for acc in ctx.remaining_accounts {
        if acc.is_writable {
            accounts.push(AccountMeta::new(acc.key(), acc.is_signer));
        } else {
            accounts.push(AccountMeta::new_readonly(acc.key(), acc.is_signer));
        }
    }

    let instruction = Instruction {
        program_id: crate::ID,
        accounts,
        data: data.to_owned(),
    };

    program::invoke_signed(
        &instruction,
        &[
            &[ctx.accounts.self_authority.to_account_info()],
            ctx.remaining_accounts,
        ]
        .concat(),
        self_authority_seeds,
    )?;

    Ok(())
}
