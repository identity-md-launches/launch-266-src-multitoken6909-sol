// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MultiToken6909} from "../src/MultiToken6909.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// Call through an independently declared ABI to check the EIP's exact signatures.
interface IERC6909 is IERC165 {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function allowance(address owner, address spender, uint256 id) external view returns (uint256);
    function isOperator(address owner, address spender) external view returns (bool);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);
    function approve(address spender, uint256 id, uint256 amount) external returns (bool);
    function setOperator(address spender, bool approved) external returns (bool);
}

contract RejectsCallbacks {
    fallback() external {
        revert("ERC-6909 receivers need no callbacks");
    }
}

abstract contract MultiToken6909TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant OPERATOR = address(0x0BEE);
    uint256 internal constant MAX = type(uint256).max;
    MultiToken6909 internal token;

    function setUp() public {
        token = new MultiToken6909();
        vm.prank(ALICE);
        require(token.create() == 1, "first id must be one");
        vm.prank(BOB);
        require(token.create() == 2, "ids must increase globally");
        vm.prank(ALICE);
        token.mint(1, ALICE, 100);
        vm.prank(BOB);
        token.mint(2, ALICE, 200);
    }

    function _approve(address owner, address spender, uint256 id, uint256 amount) internal {
        vm.prank(owner);
        require(token.approve(spender, id, amount), "approve return value");
    }

    function _operator(address owner, address spender, bool approved) internal {
        vm.prank(owner);
        require(token.setOperator(spender, approved), "setOperator return value");
    }

    function _transferFrom(address caller, address sender, address receiver, uint256 id, uint256 amount) internal {
        vm.prank(caller);
        require(token.transferFrom(sender, receiver, id, amount), "transferFrom return value");
    }

    function _revertsAs(address caller, bytes memory callData) internal {
        vm.prank(caller);
        (bool ok,) = address(token).call(callData);
        require(!ok, "call should revert");
    }

    function _balances(uint256 id, uint256 alice, uint256 bob, uint256 supply) internal view {
        require(token.balanceOf(ALICE, id) == alice, "Alice balance");
        require(token.balanceOf(BOB, id) == bob, "Bob balance");
        require(token.totalSupply(id) == supply, "total supply");
    }

    function _topic(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _singleLog(bytes32 signature, uint256 topicCount) internal returns (Vm.Log memory entry) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        require(entries.length == 1, "expected one event");
        entry = entries[0];
        require(entry.emitter == address(token), "event emitter");
        require(entry.topics.length == topicCount, "event indexed field count");
        require(entry.topics[0] == signature, "event signature");
    }

    function _transferLog(address caller, address sender, address receiver, uint256 id, uint256 amount) internal {
        Vm.Log memory entry = _singleLog(keccak256("Transfer(address,address,address,uint256,uint256)"), 4);
        require(entry.topics[1] == _topic(sender), "Transfer sender topic");
        require(entry.topics[2] == _topic(receiver), "Transfer receiver topic");
        require(entry.topics[3] == bytes32(id), "Transfer id topic");
        require(keccak256(entry.data) == keccak256(abi.encode(caller, amount)), "Transfer caller/amount data");
    }

    function _minterLog(uint256 id, address minter) internal {
        Vm.Log memory entry = _singleLog(keccak256("MinterSet(uint256,address)"), 3);
        require(entry.topics[1] == bytes32(id), "MinterSet id topic");
        require(entry.topics[2] == _topic(minter), "MinterSet minter topic");
        require(entry.data.length == 0, "MinterSet data");
    }
}

contract MultiToken6909Test is MultiToken6909TestBase {
    function testExactInterfaceAndERC165() public {
        IERC6909 asset = IERC6909(address(token));
        require(type(IERC6909).interfaceId == 0x0f632fb3, "ERC-6909 interface id");
        require(asset.supportsInterface(0x0f632fb3), "ERC-6909 support");
        require(asset.supportsInterface(0x01ffc9a7), "ERC-165 support");
        require(!asset.supportsInterface(0xffffffff), "invalid ERC-165 id");
        require(!asset.supportsInterface(0x00000000), "unknown interface");
        require(!asset.supportsInterface(0xd9b67a26), "not ERC-1155");
        require(asset.balanceOf(ALICE, 1) == 100, "balanceOf ABI");
        require(asset.allowance(ALICE, SPENDER, 1) == 0, "allowance ABI");
        require(!asset.isOperator(ALICE, SPENDER), "isOperator ABI");
        vm.prank(ALICE);
        require(asset.approve(SPENDER, 1, 2), "approve ABI");
        vm.prank(SPENDER);
        require(asset.transferFrom(ALICE, BOB, 1, 2), "transferFrom ABI");
        vm.prank(ALICE);
        require(asset.transfer(BOB, 1, 3), "transfer ABI");
        vm.prank(ALICE);
        require(asset.setOperator(OPERATOR, true), "setOperator ABI");
        _balances(1, 95, 5, 100);
        (bool ok, bytes memory data) =
            address(token).staticcall{gas: 30_000}(abi.encodeCall(IERC165.supportsInterface, (bytes4(0x01ffc9a7))));
        require(ok && abi.decode(data, (bool)), "ERC-165 gas limit");
    }

    function testUnknownIdsAndAccountsHaveZeroState() public view {
        uint256[3] memory ids = [uint256(0), 3, MAX];
        for (uint256 i; i < ids.length; ++i) {
            require(token.balanceOf(ALICE, ids[i]) == 0, "unknown balance");
            require(token.allowance(ALICE, SPENDER, ids[i]) == 0, "unknown allowance");
            require(token.totalSupply(ids[i]) == 0, "unknown supply");
            require(token.minter(ids[i]) == address(0), "unknown minter");
        }
        require(!token.isOperator(ALICE, SPENDER), "default operator");
        require(token.balanceOf(address(0), 1) == 0, "zero address balance");
    }

    function testCreateDoesNotReuseIdsAfterHandoverOrRenounce() public {
        vm.prank(ALICE);
        token.setMinter(1, address(0));
        vm.prank(BOB);
        token.setMinter(2, ALICE);
        vm.prank(ALICE);
        require(token.create() == 3, "renounced id reused");
        vm.prank(BOB);
        require(token.create() == 4, "creator-local counter");
        require(token.minter(1) == address(0), "renounce overwritten");
        require(token.minter(2) == ALICE, "handover overwritten");
        require(token.minter(3) == ALICE && token.minter(4) == BOB, "creator minters");
        _balances(1, 100, 0, 100);
        _balances(2, 200, 0, 200);
        require(token.totalSupply(3) == 0 && token.totalSupply(4) == 0, "new id supply");
    }

    function testDirectTransferPreservesSupplyAndOtherIds() public {
        vm.prank(ALICE);
        require(token.transfer(BOB, 1, 100), "transfer return value");
        _balances(1, 0, 100, 100);
        _balances(2, 200, 0, 200);
        _revertsAs(ALICE, abi.encodeCall(token.transfer, (BOB, 1, 1)));
        _balances(1, 0, 100, 100);
    }

    function testOwnerTransferFromNeedsNoAllowance() public {
        _transferFrom(ALICE, ALICE, BOB, 1, 20);
        require(token.allowance(ALICE, ALICE, 1) == 0, "owner allowance changed");
        _balances(1, 80, 20, 100);
    }

    function testOwnerTransferFromIgnoresFiniteSelfAllowance() public {
        _approve(ALICE, ALICE, 1, 1);
        _transferFrom(ALICE, ALICE, BOB, 1, 20);
        require(token.allowance(ALICE, ALICE, 1) == 1, "owner spent self allowance");
        _balances(1, 80, 20, 100);
    }

    function testOperatorWithoutAllowanceCanTransferEveryId() public {
        _operator(ALICE, OPERATOR, true);
        _transferFrom(OPERATOR, ALICE, BOB, 1, 20);
        _transferFrom(OPERATOR, ALICE, BOB, 2, 30);
        require(token.allowance(ALICE, OPERATOR, 1) == 0, "operator allowance id one");
        require(token.allowance(ALICE, OPERATOR, 2) == 0, "operator allowance id two");
        _balances(1, 80, 20, 100);
        _balances(2, 170, 30, 200);
    }

    function testOperatorLeavesInsufficientSufficientAndMaxAllowancesUntouched() public {
        _operator(ALICE, OPERATOR, true);
        uint256[3] memory amounts = [uint256(1), 40, MAX];
        for (uint256 i; i < amounts.length; ++i) {
            _approve(ALICE, OPERATOR, 1, amounts[i]);
            _transferFrom(OPERATOR, ALICE, BOB, 1, 10);
            require(token.allowance(ALICE, OPERATOR, 1) == amounts[i], "operator consumed allowance");
        }
        _balances(1, 70, 30, 100);
    }

    function testSpenderConsumesFiniteAllowanceAndCannotReuseIt() public {
        _approve(ALICE, SPENDER, 1, 30);
        _transferFrom(SPENDER, ALICE, BOB, 1, 11);
        require(token.allowance(ALICE, SPENDER, 1) == 19, "partial allowance consumption");
        _transferFrom(SPENDER, ALICE, BOB, 1, 19);
        require(token.allowance(ALICE, SPENDER, 1) == 0, "exact allowance consumption");
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        _balances(1, 70, 30, 100);
    }

    function testInfiniteAllowanceSurvivesRepeatedTransfers() public {
        _approve(ALICE, SPENDER, 1, MAX);
        _transferFrom(SPENDER, ALICE, BOB, 1, 30);
        _transferFrom(SPENDER, ALICE, BOB, 1, 70);
        require(token.allowance(ALICE, SPENDER, 1) == MAX, "infinite allowance decreased");
        _balances(1, 0, 100, 100);
    }

    function testInsufficientAllowanceRevertsWithoutChangingState() public {
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        _approve(ALICE, SPENDER, 1, 9);
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 10)));
        require(token.allowance(ALICE, SPENDER, 1) == 9, "failed call spent allowance");
        _balances(1, 100, 0, 100);
    }

    function testOperatorRevocationFallsBackToPreservedAllowance() public {
        _approve(ALICE, OPERATOR, 1, 7);
        _operator(ALICE, OPERATOR, true);
        _transferFrom(OPERATOR, ALICE, BOB, 1, 10);
        _operator(ALICE, OPERATOR, false);
        require(!token.isOperator(ALICE, OPERATOR), "operator not revoked");
        require(token.allowance(ALICE, OPERATOR, 1) == 7, "operator altered allowance");
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 8)));
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (ALICE, BOB, 2, 1)));
        _transferFrom(OPERATOR, ALICE, BOB, 1, 7);
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        _balances(1, 83, 17, 100);
        _balances(2, 200, 0, 200);
    }

    function testAllowanceIsScopedToOwnerSpenderAndId() public {
        vm.prank(ALICE);
        token.mint(1, BOB, 20);
        _approve(ALICE, SPENDER, 1, MAX);
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 2, 1)));
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (BOB, ALICE, 1, 1)));
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        _approve(ALICE, SPENDER, 2, 12);
        _transferFrom(SPENDER, ALICE, BOB, 2, 5);
        require(token.allowance(ALICE, SPENDER, 1) == MAX, "allowance leaked between ids");
        require(token.allowance(ALICE, SPENDER, 2) == 7, "wrong id allowance debited");
        _balances(1, 100, 20, 120);
        _balances(2, 195, 5, 200);
    }

    function testApproveReplacesAndZeroRevokesAllowance() public {
        _approve(ALICE, SPENDER, 1, 40);
        _approve(ALICE, SPENDER, 1, 3);
        require(token.allowance(ALICE, SPENDER, 1) == 3, "approve should replace");
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 4)));
        _approve(ALICE, SPENDER, 1, 0);
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        require(!token.isOperator(ALICE, SPENDER), "approve granted operator rights");
    }

    function testOperatorPermissionIsDirectionalAndOwnerScoped() public {
        _operator(OPERATOR, ALICE, true);
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 1)));
        _operator(ALICE, OPERATOR, true);
        vm.prank(ALICE);
        token.mint(1, BOB, 10);
        require(!token.isOperator(BOB, OPERATOR), "operator leaked to another owner");
        _revertsAs(OPERATOR, abi.encodeCall(token.transferFrom, (BOB, ALICE, 1, 1)));
        _operator(BOB, OPERATOR, false);
        require(token.isOperator(ALICE, OPERATOR), "another owner revoked permission");
        _balances(1, 100, 10, 110);
    }

    function testInsufficientBalanceRevertsForOwnerOperatorAndSpender() public {
        _operator(ALICE, OPERATOR, true);
        _approve(ALICE, SPENDER, 1, 150);
        address[3] memory callers = [ALICE, OPERATOR, SPENDER];
        for (uint256 i; i < callers.length; ++i) {
            _revertsAs(callers[i], abi.encodeCall(token.transferFrom, (ALICE, BOB, 1, 101)));
            _revertsAs(callers[i], abi.encodeCall(token.transferFrom, (ALICE, ALICE, 1, 101)));
        }
        _revertsAs(ALICE, abi.encodeCall(token.transfer, (BOB, 1, 101)));
        require(token.allowance(ALICE, SPENDER, 1) == 150, "balance failure spent allowance");
        _balances(1, 100, 0, 100);
    }

    function testZeroReceiverRevertsEvenForZeroAmountAndRollsBackAllowance() public {
        _operator(ALICE, OPERATOR, true);
        _approve(ALICE, SPENDER, 1, 100);
        address[3] memory callers = [ALICE, OPERATOR, SPENDER];
        for (uint256 amount; amount < 2; ++amount) {
            _revertsAs(ALICE, abi.encodeCall(token.transfer, (address(0), 1, amount)));
            for (uint256 i; i < callers.length; ++i) {
                _revertsAs(callers[i], abi.encodeCall(token.transferFrom, (ALICE, address(0), 1, amount)));
            }
        }
        require(token.allowance(ALICE, SPENDER, 1) == 100, "zero receiver spent allowance");
        require(token.balanceOf(address(0), 1) == 0, "zero address received tokens");
        _balances(1, 100, 0, 100);
    }

    function testZeroAmountTransfersNeedNeitherBalanceNorAllowance() public {
        vm.prank(BOB);
        require(token.transfer(ALICE, 1, 0), "zero transfer");
        _transferFrom(SPENDER, BOB, ALICE, 1, 0);
        _transferFrom(SPENDER, BOB, BOB, 1, 0);
        require(token.allowance(BOB, SPENDER, 1) == 0, "zero transfer allowance");
        _balances(1, 100, 0, 100);
    }

    function testSelfTransfersPreserveBalanceAndStillConsumeSpenderAllowance() public {
        vm.prank(ALICE);
        require(token.transfer(ALICE, 1, 100), "direct self transfer");
        _transferFrom(ALICE, ALICE, ALICE, 1, 100);
        _approve(ALICE, SPENDER, 1, 70);
        _transferFrom(SPENDER, ALICE, ALICE, 1, 30);
        require(token.allowance(ALICE, SPENDER, 1) == 40, "delegated self allowance");
        _operator(ALICE, SPENDER, true);
        _transferFrom(SPENDER, ALICE, ALICE, 1, 100);
        require(token.allowance(ALICE, SPENDER, 1) == 40, "operator self allowance");
        _balances(1, 100, 0, 100);
    }

    function testSelfTransferStillRequiresBalanceAndPermission() public {
        _revertsAs(ALICE, abi.encodeCall(token.transfer, (ALICE, 1, 101)));
        _revertsAs(SPENDER, abi.encodeCall(token.transferFrom, (ALICE, ALICE, 1, 1)));
        _balances(1, 100, 0, 100);
    }

    function testContractReceiverNeedsNoCallback() public {
        RejectsCallbacks receiver = new RejectsCallbacks();
        vm.prank(ALICE);
        token.mint(1, address(receiver), 3);
        vm.prank(ALICE);
        require(token.transfer(address(receiver), 1, 4), "contract transfer");
        _approve(ALICE, SPENDER, 1, 5);
        _transferFrom(SPENDER, ALICE, address(receiver), 1, 5);
        require(token.balanceOf(address(receiver), 1) == 12, "contract receiver balance");
        require(token.totalSupply(1) == 103, "contract receiver supply");
    }

    function testOnlyPerIdMinterMayMintEvenWhenCallerIsOperator() public {
        _operator(ALICE, OPERATOR, true);
        _approve(ALICE, SPENDER, 1, MAX);
        address[3] memory callers = [BOB, OPERATOR, SPENDER];
        for (uint256 i; i < callers.length; ++i) {
            _revertsAs(callers[i], abi.encodeCall(token.mint, (1, BOB, 1)));
            _revertsAs(callers[i], abi.encodeCall(token.mint, (1, BOB, 0)));
        }
        _revertsAs(ALICE, abi.encodeCall(token.mint, (2, BOB, 1)));
        _balances(1, 100, 0, 100);
        _balances(2, 200, 0, 200);
    }

    function testUncreatedIdsCannotBeMintedOrTakenOver() public {
        uint256[3] memory ids = [uint256(0), 3, MAX];
        for (uint256 i; i < ids.length; ++i) {
            _revertsAs(ALICE, abi.encodeCall(token.mint, (ids[i], BOB, 1)));
            _revertsAs(ALICE, abi.encodeCall(token.mint, (ids[i], BOB, 0)));
            _revertsAs(ALICE, abi.encodeCall(token.setMinter, (ids[i], ALICE)));
            require(token.minter(ids[i]) == address(0), "uncreated id claimed");
            require(token.totalSupply(ids[i]) == 0, "uncreated id supply");
        }
        vm.prank(BOB);
        require(token.create() == 3, "failed takeover advanced id counter");
        require(token.minter(3) == BOB, "future minter poisoned");
        vm.prank(BOB);
        token.mint(3, BOB, 1);
    }

    function testMinterCannotBeTakenOverByAnotherMinterOrOperator() public {
        _operator(ALICE, OPERATOR, true);
        _revertsAs(BOB, abi.encodeCall(token.setMinter, (1, BOB)));
        _revertsAs(OPERATOR, abi.encodeCall(token.setMinter, (1, OPERATOR)));
        _revertsAs(SPENDER, abi.encodeCall(token.setMinter, (1, address(0))));
        require(token.minter(1) == ALICE, "minter taken over");
    }

    function testMinterHandoverImmediatelyRevokesOldMinter() public {
        vm.prank(ALICE);
        token.setMinter(1, BOB);
        require(token.minter(1) == BOB, "handover minter");
        _balances(1, 100, 0, 100);
        _revertsAs(ALICE, abi.encodeCall(token.mint, (1, ALICE, 1)));
        _revertsAs(ALICE, abi.encodeCall(token.setMinter, (1, ALICE)));
        vm.prank(BOB);
        token.mint(1, BOB, 7);
        vm.prank(BOB);
        token.setMinter(1, SPENDER);
        _revertsAs(BOB, abi.encodeCall(token.mint, (1, BOB, 1)));
        vm.prank(SPENDER);
        token.mint(1, ALICE, 3);
        require(token.minter(2) == BOB, "handover affected another id");
        _balances(1, 103, 7, 110);
        _balances(2, 200, 0, 200);
    }

    function testRenounceIsPermanentButBalancesRemainTransferableAndBurnable() public {
        vm.prank(ALICE);
        token.setMinter(1, address(0));
        address[4] memory callers = [ALICE, BOB, SPENDER, address(0)];
        for (uint256 i; i < callers.length; ++i) {
            _revertsAs(callers[i], abi.encodeCall(token.mint, (1, ALICE, 1)));
            _revertsAs(callers[i], abi.encodeCall(token.setMinter, (1, callers[i])));
        }
        vm.prank(ALICE);
        require(token.transfer(BOB, 1, 20), "renounced token transfer");
        vm.prank(BOB);
        token.burn(1, 5);
        require(token.minter(1) == address(0), "renounce undone");
        require(token.minter(2) == BOB, "renounce affected another id");
        _balances(1, 80, 15, 95);
    }

    function testMintToZeroRevertsAndZeroMintDoesNotChangeSupply() public {
        _revertsAs(ALICE, abi.encodeCall(token.mint, (1, address(0), 1)));
        _revertsAs(ALICE, abi.encodeCall(token.mint, (1, address(0), 0)));
        vm.prank(ALICE);
        token.mint(1, BOB, 0);
        _balances(1, 100, 0, 100);
    }

    function testBurnUsesOnlyCallersBalanceRegardlessOfApprovals() public {
        _operator(ALICE, OPERATOR, true);
        _approve(ALICE, SPENDER, 1, MAX);
        _revertsAs(OPERATOR, abi.encodeCall(token.burn, (1, 1)));
        _revertsAs(SPENDER, abi.encodeCall(token.burn, (1, 1)));
        vm.prank(ALICE);
        token.mint(1, OPERATOR, 10);
        vm.prank(OPERATOR);
        token.burn(1, 4);
        require(token.balanceOf(OPERATOR, 1) == 6, "burn did not use caller balance");
        require(token.balanceOf(ALICE, 1) == 100, "burn used another owner balance");
        require(token.totalSupply(1) == 106, "burn supply");
    }

    function testBurnZeroPartialFullAndExcess() public {
        vm.prank(BOB);
        token.burn(1, 0);
        _revertsAs(ALICE, abi.encodeCall(token.burn, (1, 101)));
        _balances(1, 100, 0, 100);
        vm.prank(ALICE);
        token.burn(1, 40);
        _balances(1, 60, 0, 60);
        vm.prank(ALICE);
        token.burn(1, 60);
        _revertsAs(ALICE, abi.encodeCall(token.burn, (1, 1)));
        _balances(1, 0, 0, 0);
        _balances(2, 200, 0, 200);
        require(token.minter(1) == ALICE, "burn removed minter");
        vm.prank(ALICE);
        token.mint(1, BOB, 2);
        _balances(1, 0, 2, 2);
    }

    function testTotalSupplyOverflowAcrossHoldersRevertsAtomically() public {
        vm.prank(ALICE);
        token.mint(1, BOB, MAX - 100);
        _balances(1, 100, MAX - 100, MAX);
        // Neither recipient balance would overflow: only the aggregate supply does.
        _revertsAs(ALICE, abi.encodeCall(token.mint, (1, SPENDER, 1)));
        _revertsAs(ALICE, abi.encodeCall(token.mint, (1, ALICE, 1)));
        require(token.balanceOf(SPENDER, 1) == 0, "overflow partially minted");
        _balances(1, 100, MAX - 100, MAX);
        vm.prank(ALICE);
        token.burn(1, 1);
        vm.prank(ALICE);
        token.mint(1, SPENDER, 1);
        require(token.balanceOf(SPENDER, 1) == 1, "mint after freeing supply");
        _balances(1, 99, MAX - 100, MAX);
        _balances(2, 200, 0, 200);
    }

    function testMaxBalanceSelfTransferAndInfiniteAllowance() public {
        vm.prank(ALICE);
        token.mint(1, ALICE, MAX - 100);
        vm.prank(ALICE);
        require(token.transfer(ALICE, 1, MAX), "max self transfer");
        _approve(ALICE, SPENDER, 1, MAX);
        _transferFrom(SPENDER, ALICE, ALICE, 1, MAX);
        _transferFrom(SPENDER, ALICE, BOB, 1, MAX);
        require(token.allowance(ALICE, SPENDER, 1) == MAX, "max spend consumed infinite allowance");
        _balances(1, 0, MAX, MAX);
        vm.prank(BOB);
        token.burn(1, MAX);
        _balances(1, 0, 0, 0);
    }

    function testCreateHandoverAndRenounceEventTopics() public {
        vm.recordLogs();
        vm.prank(SPENDER);
        require(token.create() == 3, "create event id");
        _minterLog(3, SPENDER);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.setMinter(3, BOB);
        _minterLog(3, BOB);
        vm.recordLogs();
        vm.prank(BOB);
        token.setMinter(3, address(0));
        _minterLog(3, address(0));
    }

    function testTransferEventDistinguishesCallerFromSender() public {
        vm.recordLogs();
        vm.prank(ALICE);
        require(token.transfer(BOB, 1, 4), "event transfer");
        _transferLog(ALICE, ALICE, BOB, 1, 4);
        _approve(ALICE, SPENDER, 1, 6);
        vm.recordLogs();
        _transferFrom(SPENDER, ALICE, BOB, 1, 6);
        _transferLog(SPENDER, ALICE, BOB, 1, 6);
        _operator(ALICE, OPERATOR, true);
        vm.recordLogs();
        _transferFrom(OPERATOR, ALICE, BOB, 2, 7);
        _transferLog(OPERATOR, ALICE, BOB, 2, 7);
    }

    function testZeroAndSelfTransfersStillEmitEvents() public {
        vm.recordLogs();
        vm.prank(BOB);
        require(token.transfer(ALICE, 1, 0), "zero transfer event");
        _transferLog(BOB, BOB, ALICE, 1, 0);
        vm.recordLogs();
        _transferFrom(SPENDER, BOB, BOB, 1, 0);
        _transferLog(SPENDER, BOB, BOB, 1, 0);
        vm.recordLogs();
        vm.prank(ALICE);
        require(token.transfer(ALICE, 1, 100), "self transfer event");
        _transferLog(ALICE, ALICE, ALICE, 1, 100);
    }

    function testMintAndBurnEventsIncludeZeroEndpointsAndActualCaller() public {
        vm.recordLogs();
        vm.prank(ALICE);
        token.mint(1, BOB, 12);
        _transferLog(ALICE, address(0), BOB, 1, 12);
        vm.recordLogs();
        vm.prank(BOB);
        token.burn(1, 5);
        _transferLog(BOB, BOB, address(0), 1, 5);
        vm.recordLogs();
        vm.prank(ALICE);
        token.mint(1, BOB, 0);
        _transferLog(ALICE, address(0), BOB, 1, 0);
        vm.recordLogs();
        vm.prank(BOB);
        token.burn(1, 0);
        _transferLog(BOB, BOB, address(0), 1, 0);
    }

    function testApprovalEventTopicsForReplacementAndRevocation() public {
        uint256[3] memory amounts = [MAX, uint256(9), 0];
        for (uint256 i; i < amounts.length; ++i) {
            vm.recordLogs();
            _approve(ALICE, SPENDER, 2, amounts[i]);
            Vm.Log memory entry = _singleLog(keccak256("Approval(address,address,uint256,uint256)"), 4);
            require(entry.topics[1] == _topic(ALICE), "Approval owner topic");
            require(entry.topics[2] == _topic(SPENDER), "Approval spender topic");
            require(entry.topics[3] == bytes32(uint256(2)), "Approval id topic");
            require(keccak256(entry.data) == keccak256(abi.encode(amounts[i])), "Approval amount data");
        }
    }

    function testOperatorSetEventTopicsForGrantAndRevocation() public {
        for (uint256 i; i < 2; ++i) {
            bool approved = i == 0;
            vm.recordLogs();
            _operator(ALICE, OPERATOR, approved);
            Vm.Log memory entry = _singleLog(keccak256("OperatorSet(address,address,bool)"), 3);
            require(entry.topics[1] == _topic(ALICE), "OperatorSet owner topic");
            require(entry.topics[2] == _topic(OPERATOR), "OperatorSet spender topic");
            require(keccak256(entry.data) == keccak256(abi.encode(approved)), "OperatorSet approved data");
        }
    }
}

contract MultiToken6909FuzzTest is MultiToken6909TestBase {
    struct Model {
        uint256[3] supplies;
        uint256[4][3] balances;
        uint256[4][4][3] allowances;
        bool[4][4] operators;
        address[3] minters;
    }

    function _actor(uint256 index) internal pure returns (address) {
        return [ALICE, BOB, SPENDER, OPERATOR][index];
    }

    function testFuzzSupplyOverflowCannotHideAcrossHolders(uint256 split) public {
        vm.prank(ALICE);
        uint256 id = token.create();
        vm.prank(ALICE);
        token.mint(id, ALICE, split);
        vm.prank(ALICE);
        token.mint(id, BOB, MAX - split);
        _revertsAs(ALICE, abi.encodeCall(token.mint, (id, SPENDER, 1)));
        _balances(id, split, MAX - split, MAX);
        require(token.balanceOf(SPENDER, id) == 0, "overflow gave recipient a balance");
    }

    function testFuzzSequentialIdsDoNotCollide(uint256 seed, uint8 countSeed) public {
        uint256 count = uint256(countSeed) % 32 + 1;
        for (uint256 i; i < count; ++i) {
            address creator = _actor(uint256(keccak256(abi.encode(seed, i))) % 4);
            vm.prank(creator);
            uint256 id = token.create();
            require(id == i + 3, "id collision or skipped id");
            require(token.minter(id) == creator, "wrong creator minter");
            vm.prank(creator);
            token.mint(id, creator, i + 1);
            require(token.balanceOf(creator, id) == i + 1, "new id inherited a balance");
            require(token.totalSupply(id) == i + 1, "new id inherited supply");
        }
        _balances(1, 100, 0, 100);
        _balances(2, 200, 0, 200);
        for (uint256 i; i < count; ++i) {
            require(token.totalSupply(i + 3) == i + 1, "later create overwrote earlier id");
            address creator = _actor(uint256(keccak256(abi.encode(seed, i))) % 4);
            require(token.minter(i + 3) == creator, "later create overwrote minter");
        }
    }

    // A closed universe of four holders and three ids makes the balance sum exhaustive.
    // Compare every step with a separate ledger, including operations expected to fail.
    function testFuzzPerIdSupplyInvariantAcrossOperationSequences(uint256 seed) public {
        vm.prank(SPENDER);
        require(token.create() == 3, "model third id");
        Model memory model;
        model.supplies[0] = 100;
        model.supplies[1] = 200;
        model.balances[0][0] = 100;
        model.balances[1][0] = 200;
        model.minters = [ALICE, BOB, SPENDER];
        _assertModel(model);
        for (uint256 step; step < 48; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _step(model, seed);
            _assertModel(model);
        }
    }

    function _step(Model memory model, uint256 random) internal {
        uint256 idIndex = (random >> 8) % 3;
        uint256 from = (random >> 16) % 4;
        uint256 to = (random >> 24) % 4;
        uint256 caller = (random >> 32) % 4;
        uint256 operation = random % 8;
        uint256 amount = (random >> 40) % 301;
        // Include zero, exact balance and one above balance independently of balance size.
        uint256 boundary = (random >> 56) % 4;
        if (boundary == 0) amount = 0;
        if (boundary == 1) amount = model.balances[idIndex][from];
        if (boundary == 2) amount = model.balances[idIndex][from] + 1;

        if (operation == 0) {
            bool allowed = model.minters[idIndex] == _actor(caller);
            _modelCall(_actor(caller), abi.encodeCall(token.mint, (idIndex + 1, _actor(to), amount)), allowed, false);
            if (allowed) {
                model.balances[idIndex][to] += amount;
                model.supplies[idIndex] += amount;
            }
        } else if (operation == 1) {
            bool allowed = model.balances[idIndex][caller] >= amount;
            _modelCall(_actor(caller), abi.encodeCall(token.burn, (idIndex + 1, amount)), allowed, false);
            if (allowed) {
                model.balances[idIndex][caller] -= amount;
                model.supplies[idIndex] -= amount;
            }
        } else if (operation == 2 || operation == 3) {
            _modelTransfer(model, idIndex, from, to, caller, amount, operation == 2);
        } else if (operation == 4) {
            if ((random >> 64) % 2 == 0) amount = MAX;
            _approve(_actor(from), _actor(to), idIndex + 1, amount);
            model.allowances[idIndex][from][to] = amount;
        } else if (operation == 5) {
            bool approved = (random >> 64) % 2 == 0;
            _operator(_actor(from), _actor(to), approved);
            model.operators[from][to] = approved;
        } else if (operation == 6) {
            address newMinter = (random >> 64) % 4 == 0 ? address(0) : _actor(to);
            bool allowed = model.minters[idIndex] == _actor(caller);
            _modelCall(_actor(caller), abi.encodeCall(token.setMinter, (idIndex + 1, newMinter)), allowed, false);
            if (allowed) model.minters[idIndex] = newMinter;
        } else {
            // Always invalid, even with amount zero and valid transfer authorization.
            _modelCall(
                _actor(caller),
                abi.encodeCall(token.transferFrom, (_actor(from), address(0), idIndex + 1, amount)),
                false,
                true
            );
        }
    }

    function _modelTransfer(
        Model memory model,
        uint256 idIndex,
        uint256 from,
        uint256 to,
        uint256 caller,
        uint256 amount,
        bool direct
    ) internal {
        if (direct) from = caller;
        bool usesAllowance = caller != from && !model.operators[from][caller];
        uint256 approved = model.allowances[idIndex][from][caller];
        bool allowed = model.balances[idIndex][from] >= amount && (!usesAllowance || approved >= amount);
        bytes memory callData = direct
            ? abi.encodeCall(token.transfer, (_actor(to), idIndex + 1, amount))
            : abi.encodeCall(token.transferFrom, (_actor(from), _actor(to), idIndex + 1, amount));
        _modelCall(_actor(caller), callData, allowed, true);
        if (allowed) {
            model.balances[idIndex][from] -= amount;
            model.balances[idIndex][to] += amount;
            if (usesAllowance && approved != MAX) model.allowances[idIndex][from][caller] -= amount;
        }
    }

    function _modelCall(address caller, bytes memory callData, bool shouldSucceed, bool returnsBool) internal {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(token).call(callData);
        require(ok == shouldSucceed, "model success/revert mismatch");
        if (ok && returnsBool) {
            require(result.length == 32 && abi.decode(result, (bool)), "model boolean return");
        }
    }

    function _assertModel(Model memory model) internal view {
        for (uint256 idIndex; idIndex < 3; ++idIndex) {
            uint256 sum;
            for (uint256 owner; owner < 4; ++owner) {
                uint256 balance = token.balanceOf(_actor(owner), idIndex + 1);
                require(balance == model.balances[idIndex][owner], "model balance mismatch");
                sum += balance;
                for (uint256 spender; spender < 4; ++spender) {
                    require(
                        token.allowance(_actor(owner), _actor(spender), idIndex + 1)
                            == model.allowances[idIndex][owner][spender],
                        "model allowance mismatch"
                    );
                }
            }
            require(sum == token.totalSupply(idIndex + 1), "per-id balance sum differs from supply");
            require(sum == model.supplies[idIndex], "model supply mismatch");
            require(token.minter(idIndex + 1) == model.minters[idIndex], "model minter mismatch");
            require(token.balanceOf(address(0), idIndex + 1) == 0, "zero address accumulated balance");
        }
        for (uint256 owner; owner < 4; ++owner) {
            for (uint256 spender; spender < 4; ++spender) {
                require(
                    token.isOperator(_actor(owner), _actor(spender)) == model.operators[owner][spender],
                    "model operator mismatch"
                );
            }
        }
    }
}
