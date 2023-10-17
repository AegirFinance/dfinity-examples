import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import P "mo:base/Prelude";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import TrieMap "mo:base/TrieMap";

// Import our ICRC type definitions
import ICRC "./ICRC";

// The swap canister is the main backend canister for this example. To simplify
// this example we configure the swap canister with the two tokens it will be
// swapping.
shared(init_msg) actor class Swap(init_args: {
  token_a: Principal;
  token_b: Principal;
}) = this {

  // Track the deposited per-user balances for token A and token B
  private var balancesA = TrieMap.TrieMap<Principal, Nat>(Principal.equal, Principal.hash);
  private var balancesB = TrieMap.TrieMap<Principal, Nat>(Principal.equal, Principal.hash);

  // Because TrieMaps are not directly storeable in stable memory we need a
  // location to store the data during canister upgrades.
  private stable var stableBalancesA : ?[(Principal, Nat)] = null;
  private stable var stableBalancesB : ?[(Principal, Nat)] = null;

  public type DepositArgs = {
    spender_subaccount: ?Blob;
    token: Principal;
    from: ICRC.Account;
    amount: Nat;
    fee: ?Nat;
    memo: ?Blob;
    created_at_time: ?Nat64;
  };

  public type DepositError = {
    #TransferFromError: ICRC.TransferFromError;
  };

  // Accept deposits
  // - Accept TokenA, and TokenB
  // - user approves transfer: `token_a.icrc2_approve({ spender=swap_canister; amount=amount; ... })`
  // - user deposits their token: `swap_canister.deposit({ token=token_a; amount=amount; ... })`
  // - These deposit handlers show how to safely accept and register deposits of an ICRC-2 token. 
  public shared(msg) func deposit(args: DepositArgs): async Result.Result<Nat, DepositError> {
    let token: ICRC.Actor = actor(Principal.toText(args.token));
    let balances = which_balances(args.token);

    // Load the fee from the token here. The user can pass a null fee, which
    // means "use the default". So we need to look up the default in order to
    // correctly deduct it from their balance.
    let fee = switch (args.fee) {
      case (?f) { f };
      case (null) { await token.icrc1_fee() };
    };

    // Perform the transfer, to capture the tokens.
    let transfer_result = await token.icrc2_transfer_from({
      spender_subaccount = args.spender_subaccount;
      from = args.from;
      to = { owner = Principal.fromActor(this); subaccount = null };
      amount = args.amount;
      fee = ?fee;
      memo = args.memo;
      created_at_time = args.created_at_time;
    });

    // Check that the transfer was successful.
    let block_height = switch (transfer_result) {
      case (#Ok(block_height)) { block_height };
      case (#Err(err)) {
        // Transfer failed. There's no cleanup for us to do, so we can just
        // wrap and return the error to the frontend.
        return #err(#TransferFromError(err));
      };
    };

    // From here on out, we need to make sure that this function does *not*
    // fail. If it failed, the token transfer would be complete (meaning we
    // would have the user's tokens), but we would not have credited their
    // account yet, so this canister would not *know* that it had received the
    // user's tokens.
    // 
    // If the function *can* fail here after this point, we should either:
    // - Move that code to a separate action later
    // - Have failure-handling code which returns the user's tokens
    
    // Credit the sender's account
    let sender = args.from.owner;
    let old_balance = Option.get(balances.get(sender), 0 : Nat);
    balances.put(sender, old_balance + args.amount);

    // Return the "block height" of the transfer
    #ok(block_height)
  };

  public type SwapArgs = {
    user_a: Principal;
    user_b: Principal;
    token_a: Principal;
    token_b: Principal;
    amount_a: Nat;
    // amount_b is determined by the internal exchange rate
  };

  public type SwapError = {
    // TODO: Fill this in
  };

  // Swap TokenA for TokenB
  // - Exchange tokens between the two given users.
  // - For this example, there will be no AMM mechanism, simply a 1-1 swap. The exact
  //   swap pricing mechanism is left as an exercise for the reader.
  public shared(msg) func swap(args: SwapArgs): async Result.Result<Nat, SwapError> {
    // Because both tokens were deposited before calling swap, we can execute
    // this function atomically. To do that there must be no `await` calls in
    // this function. Additionally, we need to be careful with the order that
    // we update any internal state variables. If this function were to update
    // some state variables, then fail, before updating others, it could leave
    // this canister with inconsistent internal state.
    //
    // Making this function atomic makes it safer, because either the whole
    // function will execute or none of it will.
    P.nyi();
  };

  public type WithdrawArgs = {
    token: Principal;
    to: ICRC.Account;
    amount: Nat;
    fee: ?Nat;
    memo: ?Blob;
    created_at_time: ?Nat64;
  };

  public type WithdrawError = {
    // The caller doesn't not have sufficient funds deposited in this swap
    // contract to fulfil this withdrawal. Note, this is different from the
    // TransferError(InsufficientFunds), which would indicate that this
    // canister doesn't have enough funds to fulfil the withdrawal (a much more
    // serious error).
    #InsufficientFunds: { balance : ICRC.Tokens };
    // For other transfer errors, we can just wrap and return them.
    #TransferError: ICRC.TransferError;
  };

  // Allow withdrawals
  // - Allow UserA to withdraw TokenB, and UserB to withdraw TokenA
  // - These withdrawal handlers show how to safely send outbound transfers of an ICRC-1 token.
  public shared(msg) func withdraw(args: WithdrawArgs): async Result.Result<Nat, WithdrawError> {
    let token: ICRC.Actor = actor(Principal.toText(args.token));
    let balances = which_balances(args.token);

    // Load the fee from the token here. The user can pass a null fee, which
    // means "use the default". So we need to look up the default in order to
    // correctly deduct it from their balance.
    let fee = switch (args.fee) {
      case (?f) { f };
      case (null) { await token.icrc1_fee() };
    };

    // Check the user's balance is sufficient
    let old_balance = Option.get(balances.get(msg.caller), 0 : Nat);
    if (old_balance < args.amount + fee) {
      return #err(#InsufficientFunds{ balance = old_balance });
    };

    // Debit the sender's account
    //
    // We do this first, due to the asynchronous nature of the IC. By debitting
    // the account first, we ensure that the user cannot withdraw more than
    // they have.
    let new_balance = old_balance - args.amount - fee;
    if (new_balance == 0) {
      // Delete zero-balances to keep the balance table tidy.
      balances.delete(msg.caller);
    } else {
      balances.put(msg.caller, new_balance);
    };

    // Perform the transfer, to send the tokens.
    let transfer_result = await token.icrc1_transfer({
      from_subaccount = null;
      to = args.to;
      amount = args.amount;
      fee = ?fee;
      memo = args.memo;
      created_at_time = args.created_at_time;
    });

    // Check that the transfer was successful.
    let block_height = switch (transfer_result) {
      case (#Ok(block_height)) { block_height };
      case (#Err(err)) {
        // The transfer failed, we need to refund the user's account (less
        // fees), so that they do not completely lose their tokens, and can
        // retry the withdrawal.
        //
        // Refund the user's account. Note, we can't just put the old_balance
        // back, because their balance may have changed simultaneously while we
        // were waiting for the transaction.
        let old_balance = Option.get(balances.get(msg.caller), 0 : Nat);
        // TODO: Check if we can always refund the fee here, or if that gets charged
        // for any failed txns.
        balances.put(msg.caller, old_balance + args.amount + fee);

        return #err(#TransferError(err));
      };
    };

    // Return the "block height" of the transfer
    #ok(block_height)
  };

  // which_balances checks which token we are withdrawing, and configure the
  // rest of the transfer. This function will assert that the token specified
  // must be either token_a, or token_b.
  private func which_balances(t: Principal): TrieMap.TrieMap<Principal, Nat> {
    let balances = if (t == init_args.token_a) {
      balancesA
    } else if (t == init_args.token_b) {
      balancesB
    } else {
      Debug.trap("invalid token canister");
    };
  };

  // TrieMaps cannot be directly stored in stable memory, so we need a
  // preupgrade and postupgrade to store the balances into stable memory.
  system func preupgrade() {
    stableBalancesA := ?Iter.toArray(balancesA.entries());
    stableBalancesB := ?Iter.toArray(balancesB.entries());
  };

  system func postupgrade() {
    switch (stableBalancesA) {
      case (null) {};
      case (?entries) {
        balancesA := TrieMap.fromEntries<Principal, Nat>(entries.vals(), Principal.equal, Principal.hash);
        stableBalancesA := null;
      };
    };

    switch (stableBalancesB) {
      case (null) {};
      case (?entries) {
        balancesB := TrieMap.fromEntries<Principal, Nat>(entries.vals(), Principal.equal, Principal.hash);
        stableBalancesB := null;
      };
    };
  };

};