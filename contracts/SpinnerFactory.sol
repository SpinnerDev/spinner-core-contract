// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, ILockerFactory, ExactInputSingleParams, ISwapRouter, ILocker} from "./interface.sol";
import {Bytes32AddressLib} from "./Bytes32AddressLib.sol";

///@dev SpinnerVerifiedToken is a verified ERC20 token, make sure it's safe to use
/// and not a scam token
contract SpinnerVerifiedToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_
    ) ERC20(name_, symbol_) {
        _mint(msg.sender, maxSupply_);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}


///@dev SpinnerFactory is a factory contract to create verified tokens
/// The factory will be triggered automatically by AI to create verified tokens
/// The liquidity NFT will be locked in a locker contract
contract SpinnerFactory is Ownable {
    using TickMath for int24;
    using Bytes32AddressLib for bytes32;
    uint64 public defaultLockingPeriod = 3 * 365 days;

    address public taxCollector;
    address public deadAddress = 0x000000000000000000000000000000000000dEaD;
    uint8 public taxRate = 25;
    uint8 public lpFeesCut = 50;
    uint8 public protocolCut = 30;
    ILockerFactory public liquidityLocker;
    mapping(address => uint256) public nonce;

    address public weth;
    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;

    address public swapRouter;

    event TokenCreated(
        address tokenAddress,
        uint256 lpNftId,
        address deployer,
        string name,
        string symbol,
        uint256 supply,
        uint256 _supply
    );

    event LockerCreated(
        address tokenAddress,
        uint256 lpNftId,
        address lockerAddress
    );

    constructor(
        address taxCollector_,
        address weth_,
        address locker_,
        address uniswapV3Factory_,
        address positionManager_,
        uint64 defaultLockingPeriod_,
        address swapRouter_
    ) Ownable(msg.sender) {
        taxCollector = taxCollector_;
        weth = weth_;
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        swapRouter = swapRouter_;
        liquidityLocker = ILockerFactory(locker_);
        defaultLockingPeriod = defaultLockingPeriod_;
    }

    function createToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _supply,
        int24 _initialTick,
        uint24 _fee,
        bytes32 _salt
    ) external payable returns (SpinnerVerifiedToken token, uint256 tokenId) {
        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_fee);

        require(
            tickSpacing != 0 && _initialTick % tickSpacing == 0,
            "SpinnerError: Invalid tick"
        );

        token = new SpinnerVerifiedToken{
            salt: keccak256(abi.encode(msg.sender, _salt))
        }(_name, _symbol, _supply);

        require(address(token) < weth, "SpinnerError: Invalid salt");

        uint160 sqrtPriceX96 = _initialTick.getSqrtRatioAtTick();
        address pool = uniswapV3Factory.createPool(address(token), weth, _fee);
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams(
                address(token),
                weth,
                _fee,
                _initialTick,
                maxUsableTick(tickSpacing),
                _supply,
                0,
                0,
                0,
                address(this),
                block.timestamp
            );

        token.approve(address(positionManager), _supply);
        (tokenId, , , ) = positionManager.mint(params);

        address lockerAddress = liquidityLocker.deploy(
            address(positionManager),
            msg.sender,
            defaultLockingPeriod,
            tokenId,
            lpFeesCut
        );

        positionManager.safeTransferFrom(address(this), lockerAddress, tokenId);

        ILocker(lockerAddress).initializer(tokenId);

        uint256 protocolFees = (msg.value * protocolCut) / 1000;
        uint256 remainingFundsToBuyTokens = msg.value - protocolFees;

        if (msg.value > 0) {
            ExactInputSingleParams memory swapParams = ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(token),
                fee: _fee,
                recipient: msg.sender,
                amountIn: remainingFundsToBuyTokens,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            ISwapRouter(swapRouter).exactInputSingle{
                value: remainingFundsToBuyTokens
            }(swapParams);
        }

        (bool success, ) = payable(taxCollector).call{value: protocolFees}("");

        if (!success) {
            revert("SpinnerError: Failed to send protocol fees");
        }
        nonce[msg.sender]++;

        emit TokenCreated(
            address(token),
            tokenId,
            msg.sender,
            _name,
            _symbol,
            _supply,
            _supply
        );

        emit LockerCreated(address(token), tokenId, lockerAddress);
    }

    function initialSwapTokens(address token, uint24 _fee) public payable {
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: address(token),
            fee: _fee,
            recipient: msg.sender,
            amountIn: msg.value,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        ISwapRouter(swapRouter).exactInputSingle{value: msg.value}(swapParams);
    }

    function updateLiquidityLocker(address newLocker) external onlyOwner {
        liquidityLocker = ILockerFactory(newLocker);
    }

    function updateDefaultLockingPeriod(uint64 newPeriod) external onlyOwner {
        defaultLockingPeriod = newPeriod;
    }

    function predictToken(
        address deployer,
        string calldata name,
        string calldata symbol,
        uint256 supply,
        bytes32 salt
    ) public view returns (address) {
        bytes32 create2Salt = keccak256(abi.encode(deployer, salt));
        return
            keccak256(
                abi.encodePacked(
                    bytes1(0xFF),
                    address(this),
                    create2Salt,
                    keccak256(
                        abi.encodePacked(
                            type(SpinnerVerifiedToken).creationCode,
                            abi.encode(name, symbol, supply)
                        )
                    )
                )
            ).fromLast20Bytes();
    }

    function generateSalt(
        address deployer,
        string calldata name,
        string calldata symbol,
        uint256 supply
    ) external view returns (bytes32 salt, address token) {
        uint256 deployerNonce = nonce[deployer];
        for (uint256 i; ; i++) {
            salt = keccak256(abi.encode(deployerNonce, i));
            token = predictToken(deployer, name, symbol, supply, salt);
            if (token < weth && token.code.length == 0) {
                break;
            }
        }
    }

    function updateTaxCollector(address newCollector) external onlyOwner {
        taxCollector = newCollector;
    }

    function updateProtocolFees(uint8 newFee) external onlyOwner {
        lpFeesCut = newFee;
    }

    function updateTaxRate(uint8 newRate) external onlyOwner {
        taxRate = newRate;
    }
}

function maxUsableTick(int24 tickSpacing) pure returns (int24) {
    unchecked {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }
}
