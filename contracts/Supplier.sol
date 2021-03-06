pragma solidity ^0.4.20;


import "./Withdrawable.sol";
import "./Base.sol";
import "./ERC20Interface.sol";
import "./ConversionAgentInterface.sol";
import "./SanityRatesInterface.sol";



contract Supplier is Withdrawable, Base{
	address public martletInstantlyTrader;
	bool public tradeEnabled;
    ConversionAgentInterface public conversionRatesContract;
    SanityRatesInterface public sanityRatesContract;
	mapping(bytes32=>bool) public approvedWithdrawAddresses; // sha3(token,address)=>bool

	constructor(address _martletInstantlyTrader, ConversionAgentInterface _ratesContract, address _admin) public{
		require (_admin != address(0));
        require(_ratesContract != address(0));
		require (_martletInstantlyTrader != address(0));
		
		martletInstantlyTrader = _martletInstantlyTrader;
        conversionRatesContract = _ratesContract;
		admin = _admin;
		tradeEnabled = true;
	}

	event DepositToken(ERC20 token, uint amount);

    function() public payable {
        emit DepositToken(ETH_TOKEN_ADDRESS, msg.value);
    }

    event TradeExecute(
        address indexed origin,
        address src,
        uint srcAmount,
        address destToken,
        uint destAmount,
        address destAddress
    );

    function trade(
        ERC20 srcToken,
        uint srcAmount,
        ERC20 destToken,
        address destAddress,
        uint conversionRate,
        bool validate
    )
        public
        payable
        returns(bool)
    {
        require(tradeEnabled);
        require(msg.sender == martletInstantlyTrader);

        require(doTrade(srcToken, srcAmount, destToken, destAddress, conversionRate, validate));

        return true;
    }

    event TradeEnabled(bool enable);

    function enableTrade() public onlyAdmin returns(bool) {
        tradeEnabled = true;
        emit TradeEnabled(true);

        return true;
    }

    function disableTrade() public onlyAdmin returns(bool) {
        tradeEnabled = false;
        emit TradeEnabled(false);

        return true;
    }

    event WithdrawAddressApproved(ERC20 token, address addr, bool approve);

    function approveWithdrawAddress(ERC20 token, address addr, bool approve) public onlyAdmin {
        approvedWithdrawAddresses[keccak256(token, addr)] = approve;
        emit WithdrawAddressApproved(token, addr, approve);

        setDecimals(token);
    }

    event WithdrawFunds(ERC20 token, uint amount, address destination);

    function withdraw(ERC20 token, uint amount, address destination) public onlyOperator returns(bool) {
        require(approvedWithdrawAddresses[keccak256(token, destination)]);

        if (token == ETH_TOKEN_ADDRESS) {
            destination.transfer(amount);
        } else {
            require(token.transfer(destination, amount));
        }

        emit WithdrawFunds(token, amount, destination);

        return true;
    }

    event SetContractAddresses(address martletInstantlyTrader, address rate, address sanity);

    function setContracts(address _martletInstantlyTrader, ConversionAgentInterface _conversionRates, SanityRatesInterface _sanityRates)
        public
        onlyAdmin
    {
        require(_martletInstantlyTrader != address(0));
        require(_conversionRates != address(0));

        martletInstantlyTrader = _martletInstantlyTrader;
        conversionRatesContract = _conversionRates;
        sanityRatesContract = _sanityRates;

        emit SetContractAddresses(martletInstantlyTrader, conversionRatesContract, sanityRatesContract);
    }

    ////////////////////////////////////////////////////////////////////////////
    /// status functions ///////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    function getBalance(ERC20 token) public view returns(uint) {
        if (token == ETH_TOKEN_ADDRESS)
            // return this.balance;
            return address(this).balance;
        else
            return token.balanceOf(this);
    }

    function getDestQty(ERC20 src, ERC20 dest, uint srcQty, uint rate) public view returns(uint) {
        uint dstDecimals = getDecimals(dest);
        uint srcDecimals = getDecimals(src);

        return calcDstQty(srcQty, srcDecimals, dstDecimals, rate);
    }

    function getSrcQty(ERC20 src, ERC20 dest, uint dstQty, uint rate) public view returns(uint) {
        uint dstDecimals = getDecimals(dest);
        uint srcDecimals = getDecimals(src);

        return calcSrcQty(dstQty, srcDecimals, dstDecimals, rate);
    }

    function getConversionRate(ERC20 src, ERC20 dest, uint srcQty, uint blockNumber) public view returns(uint) {
        ERC20 token;
        bool  buy;

        if (!tradeEnabled) return 0;

        if (ETH_TOKEN_ADDRESS == src) {
            buy = true;
            token = dest;
        } else if (ETH_TOKEN_ADDRESS == dest) {
            buy = false;
            token = src;
        } else {
            return 0; // pair is not listed
        }

        uint rate = conversionRatesContract.getRate(token, blockNumber, buy, srcQty);
        uint destQty = getDestQty(src, dest, srcQty, rate);

        if (getBalance(dest) < destQty) return 0;

        if (sanityRatesContract != address(0)) {
            uint sanityRate = sanityRatesContract.getSanityRate(src, dest);
            if (rate > sanityRate) return 0;
        }

        return rate;
    }

    // event LogTrade(uint no, uint num1, uint num2, address addr);

        /// @dev do a trade
    /// @param srcToken Src token
    /// @param srcAmount Amount of src token
    /// @param destToken Destination token
    /// @param destAddress Destination address to send tokens to
    /// @param validate If true, additional validations are applicable
    /// @return true iff trade is successful
    function doTrade(
        ERC20 srcToken,
        uint srcAmount,
        ERC20 destToken,
        address destAddress,
        uint conversionRate,
        bool validate
    )
        internal
        returns(bool)
    {
        // can skip validation if done at coinrap network level
        if (validate) {
            // emit LogTrade(conversionRate, msg.value, srcAmount, destAddress);
            require(conversionRate > 0);
            if (srcToken == ETH_TOKEN_ADDRESS)
                require(msg.value == srcAmount);
            else
                require(msg.value == 0);
        }

        uint destAmount = getDestQty(srcToken, destToken, srcAmount, conversionRate);
        // sanity check
        require(destAmount > 0);
        // emit LogTrade(2, destAmount, srcAmount, destAddress);

        // // add to imbalance
        ERC20 token;
        int buy;
        if (srcToken == ETH_TOKEN_ADDRESS) {
            buy = int(destAmount);
            token = destToken;
        } else {
            buy = -1 * int(srcAmount);
            token = srcToken;
        }

        conversionRatesContract.logImbalance(
            token,
            buy,
            0,
            block.number
        );

        // // collect src tokens
        if (srcToken != ETH_TOKEN_ADDRESS) {
            require(srcToken.transferFrom(msg.sender, this, srcAmount));
        }

        // // send dest tokens
        if (destToken == ETH_TOKEN_ADDRESS) {
            destAddress.transfer(destAmount);
            // emit LogTrade(4, destAddress.balance, getBalance(ETH_TOKEN_ADDRESS), destAddress);
        } else {
            // emit LogTrade(5, destAddress.balance, getBalance(ETH_TOKEN_ADDRESS), destAddress);
            require(destToken.transfer(destAddress, destAmount));
        }

        emit TradeExecute(msg.sender, srcToken, srcAmount, destToken, destAmount, destAddress);

        return true;
    }

}