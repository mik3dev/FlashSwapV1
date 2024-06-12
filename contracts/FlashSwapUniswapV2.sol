// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IFlashLoanRecipient} from "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "hardhat/console.sol";

contract FlashSwapUniswapV2 is Ownable, IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    IVault private constant vault =
        IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 private constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    struct ExchangeInfo {
        address router;
        address factory;
    }

    mapping(string => ExchangeInfo) public exchangesInfo;
    string[] public exchanges;

    event ReceivedETH(address indexed sender, uint amount);
    event WithdrawETH(address indexed recipient, uint amount);
    event ReceivedTokens(
        address indexed sender,
        address indexed token,
        uint amount
    );
    event WithdrawnTokens(
        address indexed recipient,
        address indexed token,
        uint amount
    );
    event FlashSwapFinished(uint256 profitAmount);

    constructor(address initialAddress) Ownable(initialAddress) {}

    function getExchanges() public view returns (string[] memory) {
        return exchanges;
    }

    function addExchangeRouter(
        string memory _name,
        address _routerAddress,
        address _factoryAddress
    ) public onlyOwner {
        require(
            exchangesInfo[_name].router == address(0),
            "Aready registered exchange router"
        );
        exchangesInfo[_name] = ExchangeInfo({
            router: _routerAddress,
            factory: _factoryAddress
        });
        exchanges.push(_name);
    }

    function _findExchangeName(
        string memory _name
    ) private view returns (uint, bool) {
        for (uint i = 0; i < exchanges.length; i++) {
            if (
                keccak256(abi.encodePacked(exchanges[i])) ==
                keccak256(abi.encodePacked(_name))
            ) {
                return (i, true);
            }
        }
        return (0, false);
    }

    function _removeExchangeName(string memory _name) private {
        (uint index, bool found) = _findExchangeName(_name);
        require(found, "Element not found");

        for (uint i = index; i < exchanges.length - 1; i++) {
            exchanges[i] = exchanges[i + 1];
        }
        exchanges.pop();
    }

    function removeExchangeRouter(string memory _name) public onlyOwner {
        delete exchangesInfo[_name];
        _removeExchangeName(_name);
    }

    receive() external payable {
        emit ReceivedETH(msg.sender, msg.value);
    }

    function getBalance() external view returns (uint) {
        return address(this).balance;
    }

    function withdraw(uint256 _amount) public onlyOwner {
        payable(msg.sender).transfer(_amount);
        emit WithdrawETH(msg.sender, _amount);
    }

    function getTokenBalance(address token) public view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }

    function receiveTokens(address token, uint amount) public {
        require(
            IERC20(token).transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        emit ReceivedTokens(msg.sender, token, amount);
    }

    function withdrawTokens(address token, uint amount) public onlyOwner {
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
        emit WithdrawnTokens(msg.sender, token, amount);
    }

    function placeTrade(
        string memory _exchangeName,
        address _fromToken,
        address _toToken,
        uint256 _amountIn
    ) private returns (uint256) {
        ExchangeInfo memory _exchange = exchangesInfo[_exchangeName];
        require(_exchange.router != address(0), "Exchange not registered");

        address pair = IUniswapV2Factory(_exchange.factory).getPair(
            _fromToken,
            _toToken
        );
        require(pair != address(0), "Pool does not exist");

        IUniswapV2Router02 router = IUniswapV2Router02(_exchange.router);

        IERC20(_fromToken).approve(address(_exchange.router), MAX_INT);

        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        uint256 _amountOut = router.getAmountsOut(_amountIn, path)[1];

        uint256 deadline = block.timestamp + 1 hours;

        uint256 amountReceived = router.swapExactTokensForTokens(
            _amountIn,
            _amountOut,
            path,
            address(this),
            deadline
        )[1];

        require(amountReceived > 0, "Aborted TX: Trade returned zero");
        return amountReceived;
    }

    function startArbitrage(
        string[] memory _exchangeNames,
        address[] memory _tokens,
        uint256 _amount // amount of token[0] (borrowed amount)
    ) internal returns (uint256) {
        require(_exchangeNames.length >= 2, "Invalid exchange names length");
        require(_tokens.length >= 2, "Invalid tokens address length");
        require(
            _exchangeNames.length == _tokens.length,
            "Mismatch exchange and tokens lengths"
        );
        require(_amount > 0, "Invalid borrowed amount");

        uint256 lastReceivedAmount;

        for (uint256 i = 0; i < _exchangeNames.length; i++) {
            if (i == _exchangeNames.length - 1) {
                lastReceivedAmount = placeTrade(
                    _exchangeNames[i],
                    _tokens[i],
                    _tokens[0],
                    lastReceivedAmount
                );
            } else {
                lastReceivedAmount = lastReceivedAmount == 0
                    ? _amount
                    : lastReceivedAmount;
                lastReceivedAmount = placeTrade(
                    _exchangeNames[i],
                    _tokens[i],
                    _tokens[i + 1],
                    lastReceivedAmount
                );
            }
        }

        return lastReceivedAmount;
    }

    function executeflashSwap(
        string[] calldata _exchangeNames,
        address[] calldata _tokens,
        uint256 _amountToBorrow
    ) external onlyOwner {
        require(_exchangeNames.length >= 2, "Invalid exchange names length");
        require(_tokens.length >= 2, "Invalid tokens address length");
        require(_exchangeNames.length == _tokens.length, "Invalid lengths");
        require(_amountToBorrow > 0, "Invalid borrowed amount");

        IERC20 token = IERC20(_tokens[0]);

        bytes memory userData = abi.encode(
            _exchangeNames,
            _tokens,
            _amountToBorrow
        );

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _amountToBorrow;

        vault.flashLoan(this, tokens, amounts, userData);
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(vault), "Invalid vault address");

        (
            string[] memory _exchangeNames,
            address[] memory _tokens,
            uint256 _amountToBorrow
        ) = abi.decode(userData, (string[], address[], uint256));
        uint256 finalAmount = startArbitrage(
            _exchangeNames,
            _tokens,
            _amountToBorrow
        );

        uint256 amountToRepay = amounts[0] + feeAmounts[0];

        require(finalAmount > amountToRepay, "Arbitrage not profitable");
        uint256 profitAmount = finalAmount - amountToRepay;

        tokens[0].transfer(address(owner()), profitAmount);
        tokens[0].transfer(address(vault), amountToRepay);

        emit FlashSwapFinished(profitAmount);
    }
}
