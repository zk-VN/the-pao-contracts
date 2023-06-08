// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract Queue {
    address public owner;
    mapping(uint256 => address) data;
    uint256 first = 1;
    uint256 last = 0;
    uint256 maxLength;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor(uint256 _maxLength) {
        maxLength = _maxLength;
        owner = msg.sender;
    }

    function enqueue(address _data) public onlyOwner {
        require(getLength() + 1 <= maxLength);
        for (uint256 i = first; i <= last; i++) {
            require(data[i] != _data);
        }
        last += 1;
        data[last] = _data;
    }

    function dequeue() public onlyOwner returns (address _data) {
        require(last >= first); // non-empty queue

        _data = data[first];

        delete data[first];
        first += 1;
    }

    function getLength() public view returns (uint256) {
        return last + 1 - first;
    }
}
