// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-6909 tokens with a separate, transferable minter for each created id.
contract MultiToken6909 {
    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    event OperatorSet(address indexed owner, address indexed spender, bool approved);
    event MinterSet(uint256 indexed id, address indexed minter);

    error UncreatedId();
    error NotMinter();
    error ZeroReceiver();
    error InsufficientBalance();
    error InsufficientAllowance();

    mapping(address owner => mapping(uint256 id => uint256 amount)) public balanceOf;
    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;
    mapping(address owner => mapping(address spender => bool approved)) public isOperator;
    mapping(uint256 id => uint256 supply) public totalSupply;
    mapping(uint256 id => address) public minter;

    uint256 private _lastId;

    modifier onlyMinter(uint256 id) {
        if (id == 0 || id > _lastId) revert UncreatedId();
        if (minter[id] == address(0) || msg.sender != minter[id]) revert NotMinter();
        _;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x0f632fb3 || interfaceId == 0x01ffc9a7;
    }

    function create() public returns (uint256 id) {
        // Checked increment prevents wrapping to zero or reusing an existing id.
        id = ++_lastId;
        minter[id] = msg.sender;
        emit MinterSet(id, msg.sender);
    }

    /// @notice Setting the minter to zero permanently renounces minting for this id.
    function setMinter(uint256 id, address newMinter) public onlyMinter(id) {
        minter[id] = newMinter;
        emit MinterSet(id, newMinter);
    }

    function mint(uint256 id, address to, uint256 amount) public onlyMinter(id) {
        if (to == address(0)) revert ZeroReceiver();
        // Checked supply arithmetic keeps the sum of all balances representable.
        totalSupply[id] += amount;
        balanceOf[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    function burn(uint256 id, uint256 amount) public {
        if (balanceOf[msg.sender][id] < amount) revert InsufficientBalance();
        balanceOf[msg.sender][id] -= amount;
        totalSupply[id] -= amount;
        emit Transfer(msg.sender, msg.sender, address(0), id, amount);
    }

    function transfer(address receiver, uint256 id, uint256 amount) public returns (bool) {
        _transfer(msg.sender, receiver, id, amount);
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public returns (bool) {
        // Owners and operators bypass allowances entirely, including finite ones.
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 permitted = allowance[sender][msg.sender][id];
            if (permitted < amount) revert InsufficientAllowance();
            if (permitted != type(uint256).max) {
                allowance[sender][msg.sender][id] = permitted - amount;
            }
        }
        _transfer(sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address spender, bool approved) public returns (bool) {
        isOperator[msg.sender][spender] = approved;
        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }

    function _transfer(address sender, address receiver, uint256 id, uint256 amount) internal {
        if (receiver == address(0)) revert ZeroReceiver();
        if (balanceOf[sender][id] < amount) revert InsufficientBalance();
        // Read the receiver balance after debiting so self transfers preserve it.
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
    }
}
