methods {
    function balanceOf(address) external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function convertToShares(uint256) external returns (uint256) envfree;
    
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

/// @notice Rule 1: userBalance(A) + userBalance(B) <= totalPoolBalance()
/// Proves that the sum of the balances of any two distinct users cannot exceed the total supply.
rule solvency(address userA, address userB) {
    require userA != userB;
    
    mathint balanceA = balanceOf(userA);
    mathint balanceB = balanceOf(userB);
    mathint total = totalSupply();
    
    assert balanceA + balanceB <= total, "Sum of two user share balances exceeds total supply";
}

/// @notice Rule 2: withdraw(x) MUST decrease userBalance by exactly x.
/// Since this is an ERC4626 vault, withdraw(assets) burns a specific amount of shares.
/// We verify that the user's share balance decreases by exactly the shares returned by the withdraw function.
rule withdraw_accounting(uint256 assets, address receiver, address owner) {
    env e;
    require e.msg.sender == owner; // Assuming user withdraws their own funds
    
    mathint sharesBefore = balanceOf(owner);
    
    // Perform the withdrawal
    uint256 sharesBurned = withdraw(e, assets, receiver, owner);
    
    mathint sharesAfter = balanceOf(owner);
    
    assert sharesAfter == sharesBefore - sharesBurned, "Withdraw did not decrease share balance by exactly the burned shares";
}

/// @notice Rule 2b: redeem(shares) MUST decrease userBalance by exactly shares.
rule redeem_accounting(uint256 shares, address receiver, address owner) {
    env e;
    require e.msg.sender == owner; // Assuming user redeems their own funds
    
    mathint sharesBefore = balanceOf(owner);
    
    // Perform the redemption
    redeem(e, shares, receiver, owner);
    
    mathint sharesAfter = balanceOf(owner);
    
    assert sharesAfter == sharesBefore - shares, "Redeem did not decrease share balance by exactly shares";
}
