// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAccessController {
    function getCallValidator() external view returns (address);
    function isAdmin(address user) external view returns (bool);
}

contract YieldSeekerCallValidator {
    struct PatternKey {
        address contractAddress;
        bytes4 selector;
    }

    struct Rule {
        uint8 paramIndex; // which parameter in calldata
        string paramType; // "address", "uint256", "bool", "bytes32"
        string ruleType;  // "equal"
        string value;     // e.g. "any", "this", "owner", "0xabc...", "1", "true"
    }

    mapping(address => mapping(bytes4 => Rule)) public allowedPatterns;

    PatternKey[] public patternKeys;
    IAccessController public accessController;

    event PatternSet(address indexed contractAddress, bytes4 indexed selector, bytes paramRule);
    event PatternRemoved(address indexed contractAddress, bytes4 indexed selector);

    modifier onlyAdmin() {
        require(accessController.isAdmin(msg.sender), "Not admin");
        _;
    }

    constructor(address _accessController) {
        accessController = IAccessController(_accessController);
    }

    function setPattern(address contractAddress, bytes4 selector, string calldata ruleType, string calldata value, uint8 paramIndex, string calldata paramType) external onlyAdmin {
        Rule storage rule = allowedPatterns[contractAddress][selector];
        // Only add to patternKeys if not already present
        bool found = false;
        for (uint256 i = 0; i < patternKeys.length; i++) {
            if (patternKeys[i].contractAddress == contractAddress && patternKeys[i].selector == selector) {
                found = true;
                break;
            }
        }
        if (!found) {
            patternKeys.push(PatternKey(contractAddress, selector));
        }
        rule.ruleType = ruleType;
        rule.value = value;
        rule.paramIndex = paramIndex;
        rule.paramType = paramType;
        emit PatternSet(contractAddress, selector, bytes(ruleType));
    }

    function removePattern(address contractAddress, bytes4 selector) external onlyAdmin {
        delete allowedPatterns[contractAddress][selector];
        emit PatternRemoved(contractAddress, selector);
    }

    /**
     * @notice Get all (contract, selector) pairs with a rule defined (active only)
     */
    function getAllPatternKeys() external view returns (PatternKey[] memory) {
        // Count active (ruleType non-empty)
        uint256 count = 0;
        for (uint256 i = 0; i < patternKeys.length; i++) {
            PatternKey memory k = patternKeys[i];
            if (bytes(allowedPatterns[k.contractAddress][k.selector].ruleType).length != 0) count++;
        }
        PatternKey[] memory active = new PatternKey[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < patternKeys.length; i++) {
            PatternKey memory k = patternKeys[i];
            if (bytes(allowedPatterns[k.contractAddress][k.selector].ruleType).length != 0) {
                active[j] = k;
                j++;
            }
        }
        return active;
    }

    function isCallAllowed(address wallet, address target, bytes calldata data) external view returns (bool) {
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0xffffffff);
        // Try most specific to most general: [target][selector], [target][any]
        Rule storage rule = allowedPatterns[target][selector];
        if (bytes(rule.ruleType).length == 0) {
            rule = allowedPatterns[target][bytes4(0xffffffff)];
        }
        if (bytes(rule.ruleType).length == 0) {
            return false;
        }
        if (keccak256(bytes(rule.ruleType)) == keccak256(bytes("equal"))) {
            uint256 paramOffset = 4 + rule.paramIndex * 32;
            if (data.length >= paramOffset + 32) {
                if (keccak256(bytes(rule.paramType)) == keccak256(bytes("address"))) {
                    address paramAddr = abi.decode(data[paramOffset:paramOffset+32], (address));
                    if (keccak256(bytes(rule.value)) == keccak256(bytes("any"))) {
                        return true;
                    } else if (keccak256(bytes(rule.value)) == keccak256(bytes("this"))) {
                        if (paramAddr == wallet) return true;
                    } else {
                        // Compare to hex string
                        bytes memory addrBytes = abi.encodePacked(paramAddr);
                        bytes memory hexChars = "0123456789abcdef";
                        bytes memory addrStr = new bytes(42);
                        addrStr[0] = "0";
                        addrStr[1] = "x";
                        for (uint256 j = 0; j < 20; j++) {
                            addrStr[2 + j * 2] = hexChars[uint8(addrBytes[j] >> 4)];
                            addrStr[3 + j * 2] = hexChars[uint8(addrBytes[j] & 0x0f)];
                        }
                        if (keccak256(bytes(rule.value)) == keccak256(addrStr)) return true;
                    }
                } else if (keccak256(bytes(rule.paramType)) == keccak256(bytes("uint256"))) {
                    uint256 paramUint = abi.decode(data[paramOffset:paramOffset+32], (uint256));
                    if (keccak256(bytes(rule.value)) == keccak256(bytes("any"))) {
                        return true;
                    } else {
                        // Compare as string
                        uint256 temp = paramUint;
                        bytes memory reversed = new bytes(78);
                        uint256 i = 0;
                        if (temp == 0) {
                            reversed[i++] = bytes1(uint8(48));
                        } else {
                            while (temp != 0) {
                                reversed[i++] = bytes1(uint8(48 + temp % 10));
                                temp /= 10;
                            }
                        }
                        bytes memory str = new bytes(i);
                        for (uint256 k = 0; k < i; k++) {
                            str[k] = reversed[i - k - 1];
                        }
                        if (keccak256(bytes(rule.value)) == keccak256(str)) return true;
                    }
                } else if (keccak256(bytes(rule.paramType)) == keccak256(bytes("bool"))) {
                    bool paramBool = abi.decode(data[paramOffset:paramOffset+32], (bool));
                    if (keccak256(bytes(rule.value)) == keccak256(bytes("any"))) {
                        return true;
                    } else if ((paramBool && keccak256(bytes(rule.value)) == keccak256(bytes("true"))) ||
                               (!paramBool && keccak256(bytes(rule.value)) == keccak256(bytes("false")))) {
                        return true;
                    }
                } else if (keccak256(bytes(rule.paramType)) == keccak256(bytes("bytes32"))) {
                    bytes32 paramBytes = abi.decode(data[paramOffset:paramOffset+32], (bytes32));
                    if (keccak256(bytes(rule.value)) == keccak256(bytes("any"))) {
                        return true;
                    } else {
                        // Compare as hex string
                        bytes memory hexChars = "0123456789abcdef";
                        bytes memory paramStr = new bytes(66);
                        paramStr[0] = "0";
                        paramStr[1] = "x";
                        for (uint256 j = 0; j < 32; j++) {
                            paramStr[2 + j * 2] = hexChars[uint8(uint8(paramBytes[j]) >> 4)];
                            paramStr[3 + j * 2] = hexChars[uint8(uint8(paramBytes[j]) & 0x0f)];
                        }
                        if (keccak256(bytes(rule.value)) == keccak256(paramStr)) return true;
                    }
                }
            }
        }
        // Future: add more ruleTypes here
        return false;
    }
}
