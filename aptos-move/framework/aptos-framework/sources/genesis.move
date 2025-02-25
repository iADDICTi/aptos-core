module aptos_framework::genesis {
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::aptos_governance;
    use aptos_framework::block;
    use aptos_framework::chain_id;
    use aptos_framework::coin::MintCapability;
    use aptos_framework::coins;
    use aptos_framework::consensus_config;
    use aptos_framework::gas_schedule;
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::timestamp;
    use aptos_framework::transaction_fee;
    use aptos_framework::staking_config;
    use aptos_framework::version;

    /// Invalid epoch duration.
    const EINVALID_EPOCH_DURATION: u64 = 1;
    const EINVALID_ADDRESSES: u64 = 2;

    struct ValidatorConfiguration has copy, drop {
        owner_address: address,
        operator_address: address,
        voter_address: address,
        stake_amount: u64,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        full_node_network_addresses: vector<u8>,
    }

    /// Genesis step 1: Initialize aptos framework account and core modules on chain.
    fun initialize(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        epoch_interval: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
    ) {
        // Initialize the aptos framework account. This is the account where system resources and modules will be
        // deployed to. This will be entirely managed by on-chain governance and no entities have the key or privileges
        // to use this account.
        let (aptos_framework_account, framework_signer_cap) = account::create_aptos_framework_account();

        // Initialize account configs on aptos framework account.
        account::initialize(
            &aptos_framework_account,
            @aptos_framework,
            b"account",
            b"script_prologue",
            b"module_prologue",
            b"writeset_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
            b"writeset_epilogue",
        );

        // Give the decentralized on-chain governance control over the core framework account.
        aptos_governance::store_signer_cap(&aptos_framework_account, @aptos_framework, framework_signer_cap);

        consensus_config::initialize(&aptos_framework_account, consensus_config);
        version::initialize(&aptos_framework_account, initial_version);
        stake::initialize(&aptos_framework_account);
        staking_config::initialize(
            &aptos_framework_account,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit,
        );
        gas_schedule::initialize(&aptos_framework_account, gas_schedule);

        // This needs to be called at the very end because earlier initializations might rely on timestamp not being
        // initialized yet.
        chain_id::initialize(&aptos_framework_account, chain_id);
        reconfiguration::initialize(&aptos_framework_account);
        block::initialize(&aptos_framework_account, epoch_interval);
        timestamp::set_time_has_started(&aptos_framework_account);
    }

    /// Genesis step 2: Initialize Aptos coin.
    fun initialize_aptos_coin(aptos_framework: &signer): MintCapability<AptosCoin> {
        let (burn_cap, mint_cap) = aptos_coin::initialize(aptos_framework);
        // Give stake module MintCapability<AptosCoin> so it can mint rewards.
        stake::store_aptos_coin_mint_cap(aptos_framework, mint_cap);

        // Give transaction_fee module BurnCapability<AptosCoin> so it can burn gas.
        transaction_fee::store_aptos_coin_burn_cap(aptos_framework, burn_cap);

        mint_cap
    }

    /// Only called for testnets and e2e tests.
    fun initialize_core_resources_and_aptos_coin(
        aptos_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        let core_resources = account::create_account_internal(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);
        let mint_cap = initialize_aptos_coin(aptos_framework);
        aptos_coin::configure_accounts_for_test(aptos_framework, &core_resources, mint_cap);
    }

    /// Sets up the initial validator set for the network.
    /// The validator "owner" accounts, and their authentication
    /// Addresses (and keys) are encoded in the `owners`
    /// Each validator signs consensus messages with the private key corresponding to the Ed25519
    /// public key in `consensus_pubkeys`.
    /// Finally, each validator must specify the network address
    /// (see types/src/network_address/mod.rs) for itself and its full nodes.
    ///
    /// Network address fields are a vector per account, where each entry is a vector of addresses
    /// encoded in a single BCS byte array.
    fun create_initialize_validators(aptos_framework: &signer, validators: vector<ValidatorConfiguration>) {
        let i = 0;
        let num_validators = vector::length(&validators);
        while (i < num_validators) {
            let validator = vector::borrow(&validators, i);
            let owner = &account::create_account_internal(validator.owner_address);
            let operator = owner;
            // Create the operator account if it's different from owner.
            if (validator.operator_address != validator.owner_address) {
                operator = &account::create_account_internal(validator.operator_address);
            };
            // Create the voter account if it's different from owner and operator.
            if (validator.voter_address != validator.owner_address &&
                validator.voter_address != validator.operator_address) {
                account::create_account_internal(validator.voter_address);
            };

            // Mint the initial staking amount to the validator.
            coins::register<AptosCoin>(owner);
            aptos_coin::mint(aptos_framework, validator.owner_address, validator.stake_amount);

            // Initialize the stake pool and join the validator set.
            stake::initialize_owner_only(
                owner,
                validator.stake_amount,
                validator.operator_address,
                validator.voter_address,
            );
            stake::rotate_consensus_key(
                operator,
                validator.owner_address,
                validator.consensus_pubkey,
                validator.proof_of_possession,
            );
            stake::update_network_and_fullnode_addresses(
                operator,
                validator.owner_address,
                validator.network_addresses,
                validator.full_node_network_addresses,
            );
            stake::join_validator_set_internal(operator, validator.owner_address);

            i = i + 1;
        };

        // Destroy the aptos framework account's ability to mint coins now that we're done with setting up the initial
        // validators.
        aptos_coin::destroy_mint_cap(aptos_framework);

        stake::on_new_epoch();
    }

    #[test_only]
    public fun setup() {
        initialize(
            x"00", // empty gas schedule
            4u8, // TESTING chain ID
            0,
            x"",
            1,
            0,
            1,
            1,
            true,
            1,
            1,
            30,
        )
    }

    #[test]
    fun test_setup() {
        use aptos_framework::account;

        setup();
        assert!(account::exists_at(@aptos_framework), 0);
    }
}
