// GPL-3.0 License

pragma solidity ^0.8.0;

import "./utils/ContractGuard.sol";
import "./utils/SafeERC20Upgradeable.sol";
import "./utils/SafeMathUpgradeable.sol";

contract SafePOKT is ContractGuard {
    //Libraries
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    //Start contract
    /* ========== DATA STRUCTURES ========== */
    // All uint256 has 6 decimals unless other is specified
    struct Poktseat {
        bool exists;
        // Investment
        uint256 poktShareCount;
        // Rewards
        uint256 PoktReward;// Holder $POKT accumulated rewards (amount is being hold in pocket network reward wallet)
        uint256 rewardClaimable; // Holder $USDC accumulated rewards (amount that is in smart contract in ftm network)
        uint256 PoktUnHold; // POKT holdings from the holder that will be released
        uint256 PoktUnHoldEpoch; // Epoch that POKT released holdings will be claimable
        uint256 willingToClaim; // 0-100 range
        // reward_updated & reward_claimed controllers
        uint256 lastSnapshotIndex; //integer - to know last time your reward was updated
        uint256 lastEpoch; //integer - For lockups and claiming

        // reserved vars for sell share implementation (just memory allocated btw)
        uint256 sellShareAmount; //reserved but not used
        uint256 sellEpoch;  //reserved but not used
        // stat
        uint256 totalClaimedUSDC; //Holder total claimed (stat)
    }

    struct SafePoktSnapshot {
        uint256 time; //integer - block number
        uint256 rewardPerPokt; // Reward per POKT Share in $POKT
        uint256 poktSellPrice; // $POKT-$USDC epoch price rate

        // reserved vars for future implementations (just memory allocated btw)
        uint256 feature1; //USED from Jan/23 - maps each epoch duration in ms
        uint256 feature2;
        // Epoch stats
        uint256 rewardDeposit; // Total $USDC claimable deposited in the contract
        uint256 rewardReceived; //Total $POKT reward from epoch's reward distribution
    }

    /* ========== STATE VARIABLES ========== */
    // Governance
    address public operator;
    address public treasury;
    address public protToken; //USDC

    // Protocol global state
    uint256 public totalPoktShares;
    uint256 public totalInvestedShares;

    uint256 public totalClaimableRewards;
    uint256 public newInvestments;
    uint256 public accumulatedFees;
    uint256 public fee; // 10%

    uint256 public poktBuyPrice;

    //Holders & Epochs
    mapping(address => Poktseat) public holders;
    SafePoktSnapshot[] public safePoktHistory;

    uint256 public holderCount; //integer - Pocket Network Holders
    // Node management - UNUSED
    address[] private holdersEnum; //Set to private to avoid user enumeration
    uint256 public totalNodeCount; //integer
    address[] public nodeHolders;

    //Stats
    uint256 public totalInvestmentsInUSDC; //integer - Total $USDC invested
    uint256 public totalRewardsUSDC; //integer - Total $USDC converted rewards
    uint256 public totalPOKTwithdraw; // Total $POKT claimed as $USDC
    uint256 public totalPOKTRewards; // Total $POKT earned as reward

    // flag
    bool public holderActionsEnabled;
    bool public initialized;

    uint256 public tokenDecimals; //integer (=10^6)
    uint256 public sharePoktNum; // 1share price = 10 * poktBuyPrice - UNUSED since Jan/23

    uint256 public totalEpochPoktCompound;
    uint256 public totalPOKTStake;

    uint256 public nodeDiscount; // (%) max discount from share price
    //uint256 public maxDiscountShares; UNUSED ONLY FOR TESTING

    uint256 public nextEpochDate; // Millisecond date
    uint256 public epochDuration; // ms increment (1 week = 604800000)

    uint256 nextDistributionPoktRPS;

    struct BuyOnDemand {
        address holder;
        uint256 amountUSDC;
        uint256 time;
    }
    BuyOnDemand[] public BuyDemandOrders;
    uint256 public BuyDemandMinAmount; //no decimals USDC


    /* ========== EVENTS ========== */
    // Operator
    event Initialized(address operator, uint256 at);
    event WidthdrawToOperator(uint256 amount);
    event ClaimTreasuryFee(address treasury, uint256 fee_amount);
    event RewardAdded(uint256 snapshotIndex, uint256 poktDistribution, uint256 usdDistribution, uint256 epochSellPrice, uint256 poktUnhold, uint256 poktCompound);
    event BuyPriceUpdate(uint256 newPrice);
    event NodeAdded(uint256 newNodes, uint256 numNodes, uint256 addPOKT, uint256 subPOKT, uint256 stakedPOKT);
    event HolderActionsToggled(bool enabled);
    event DemandPoktStaked(uint256 poktAmount, uint256 poktPrice);

    //Holder
    event Deposited(address indexed holder, uint256 amountPokt, uint256 amountusd, uint256 holderCount);
    event RewardPaid(address indexed holder, uint256 rewardUSDT);
    event ClaimRateUpdated(address indexed holder, uint256 percent);
    event UnHold(address indexed holder, uint256 poktUnhold, uint256 poktUnHoldEpoch);
    event Compounded(address indexed holder, uint256 poktStaked);
    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "caller is not the operator");
        _;
    }

    modifier onlyManager() {
        require(treasury == msg.sender || operator == msg.sender, "not a Manager");
        _;
    }

    modifier onlyHolder() {
        require(holders[msg.sender].exists == true, "not a holder");
        _;
    }

    modifier onlyHolderActionsEnabled() {
        require(holderActionsEnabled == true, "holder actions disabled");
        _;
    }

    modifier notInitialized {
        require(!initialized, "already initialized");
        _;
    }

    modifier updateReward(address holder) {
        updateRewardHolder(holder);
        _;
    }

    //INIT
    function initialize(
        address _treasury,
        uint256 _fee,
        address _protToken
    ) public notInitialized {

        operator = msg.sender;
        treasury = _treasury;
        fee = _fee;
        protToken = _protToken;

        tokenDecimals = 10 ** 6; //Hardcoded for simplicity: 10**uint256(IERC20Upgradeable(protToken).decimals())
        //sharePoktNum = 10;

        SafePoktSnapshot memory genesisSnapshot = SafePoktSnapshot({time: block.number, rewardPerPokt: 0, poktSellPrice: 0, feature1: 0, feature2: 0, rewardDeposit: 0, rewardReceived: 0});
        safePoktHistory.push(genesisSnapshot);

        totalPoktShares = 0;
        totalInvestedShares = 1;
        holderCount = 0;
        newInvestments = 0;
        poktBuyPrice = tokenDecimals; //start at 1USDC
        totalClaimableRewards = 0;
        totalPOKTwithdraw = 0;
        totalPOKTRewards = 0;
        accumulatedFees = 0;
        totalNodeCount = 0;

        totalInvestmentsInUSDC = 0;
        totalRewardsUSDC = 0;

        holderActionsEnabled = false;
        initialized = true;

        emit Initialized(msg.sender, block.number);
    }


    /* ========== Compute reward method (private) ========== */
    function updateRewardHolder(address holder) private {
        if (holder != address(0)) {
            Poktseat memory seat = holders[holder];
            if (seat.exists && seat.lastEpoch <= latestSnapshotIndex()) { // "Lockup: Still investing your money"
                if (seat.lastSnapshotIndex < latestSnapshotIndex() && seat.willingToClaim <= 100) // "Reward already updated to last index"
                    ( seat.PoktReward , seat.rewardClaimable ) = RewardEarned(seat);
                seat.lastSnapshotIndex = latestSnapshotIndex(); // reward added, reset claim index
                if (seat.PoktUnHold > 0 && seat.PoktUnHoldEpoch > 0 && latestSnapshotIndex() >= seat.PoktUnHoldEpoch) {
                    uint256 unholdvalue = seat.PoktUnHold.mul(safePoktHistory[seat.PoktUnHoldEpoch].poktSellPrice).div(tokenDecimals);
                    seat.PoktUnHold = 0;
                    seat.PoktUnHoldEpoch = 0;
                    seat.rewardClaimable = seat.rewardClaimable.add(unholdvalue);
                }
                holders[holder] = seat;
            }
        }
    }

    function RewardEarned(Poktseat memory holder_seat) private view returns (uint256, uint256) {
        uint256 c = (holder_seat.lastSnapshotIndex).add(1);
        uint256 last_claim = latestSnapshotIndex();

        uint256 pokt_amount = holder_seat.poktShareCount;
        uint256 will2claim = holder_seat.willingToClaim;

        uint256 poktEarned = 0;
        uint256 poktClaimableValue = 0;

        uint256 c_poktEarned;
        uint256 c_poktClaim;
        for (c; c <= last_claim; ++c) {
            c_poktEarned = (safePoktHistory[c].rewardPerPokt).mul(pokt_amount);
            c_poktClaim = c_poktEarned.mul(will2claim).div(100);
            c_poktEarned = (c_poktEarned.sub(c_poktClaim)).div(tokenDecimals);
            c_poktClaim = c_poktClaim.mul(safePoktHistory[c].poktSellPrice).div(tokenDecimals).div(tokenDecimals);
            poktEarned = poktEarned.add(c_poktEarned);
            poktClaimableValue = poktClaimableValue.add(c_poktClaim);
        }
        return (poktEarned.add(holder_seat.PoktReward), poktClaimableValue.add(holder_seat.rewardClaimable));
    }

    /* ========== VIEW FUNCTIONS ========== */

    function latestSnapshotIndex() public view returns (uint256) {
        return safePoktHistory.length.sub(1);
    }

    function canClaimReward(address holder) public view returns (bool) {
        return (holders[holder].lastEpoch < latestSnapshotIndex());
    }

    function checkTokenDecimals() public view returns (bool) {
        return ( tokenDecimals == 10**uint256(IERC20Upgradeable(protToken).decimals()) );
    }

    function holderReward(address holder) public view returns (uint256, uint256) {
        if (holder != address(0)) {
            Poktseat memory seat = holders[holder];
            if (seat.exists)
                return RewardEarned(seat);
        }
        return (0,0);
    }

    function holderUnHoldValue(address holder) public view returns (uint256) {
        if (holder != address(0)) {
            Poktseat memory seat = holders[holder];
            if (seat.exists && seat.PoktUnHoldEpoch != 0 && latestSnapshotIndex() >= seat.PoktUnHoldEpoch)
                return seat.PoktUnHold.mul(safePoktHistory[seat.PoktUnHoldEpoch].poktSellPrice).div(tokenDecimals);
        }
        return 0;
    }

    function getAllHolders() public view returns (address[] memory) {
        if (msg.sender == operator || msg.sender == treasury) return holdersEnum;
        address[] memory ret = new address[](1);
        ret[0] = address(msg.sender);
        return ret;
    }
    
    function getNetAPR() public view returns (uint256) {
	    return (nextDistributionPoktRPS.mul( 31556900000.div(epochDuration) ).div( getPoktPerShare().div(100) ));  //(RPS(pokt)*TimesIn1Year/PoktPerShare)*100 = NET EPOCH APR (%)
    }

    function checkPendingBuys() public view returns (uint256, uint256) {
        uint256 totalUSDC = 0;
        uint256 totalBuys = 0;
        for (uint256 i = 0; i < BuyDemandOrders.length; ++i) {
            if (BuyDemandOrders[i].holder == msg.sender) {
                totalUSDC = totalUSDC.add(BuyDemandOrders[i].amountUSDC);
                totalBuys++;
            }
        }
        return (totalUSDC,totalBuys);
    }

    function BuyDemandOrdersLen() public view returns (uint256) {
        if (msg.sender == operator || msg.sender == treasury) return BuyDemandOrders.length;
        return 0;
    }

    //Get Pokt Amount Per Share (in decimals)
    function getPoktPerShare() public view returns (uint256) {
        return ( totalPOKTStake.mul(tokenDecimals).div(totalInvestedShares) );
    }

    /* ========== OPERATOR SETTERS ========== */

    function toggleHolderActionsEnabled() external onlyOperator {
        holderActionsEnabled = !holderActionsEnabled;
        emit HolderActionsToggled(holderActionsEnabled);
    }

    function setProtocolToken(address _tokenAddress) external onlyOperator {
        require(tokenDecimals == 10**uint256(IERC20Upgradeable(_tokenAddress).decimals()), "not same decimals");
        protToken = _tokenAddress;
    }

    function addNodeCount(uint256 _count, uint256 _poktbuy, uint256 _poktsell) external onlyOperator {
        totalNodeCount = totalNodeCount.add(_count);
        totalPOKTStake = totalPOKTStake.add(_poktbuy);
        totalPOKTStake = totalPOKTStake.sub(_poktsell);
        emit NodeAdded(_count, totalNodeCount, _poktbuy, _poktsell, totalPOKTStake);
    }

    function setOperator(address _address) external onlyOperator {
        operator = _address;
    }

    function setTreasury(address _address) external onlyOperator {
        treasury = _address;
    }

    function setFee(uint256 _fee) external onlyOperator {
        fee = _fee;
    }

    function setBuyDiscount(uint256 _discount, uint256 _maxDiscountAmount) external onlyOperator {
        if ( _discount < 100 ) nodeDiscount = _discount;
        if ( _maxDiscountAmount != 0 ) BuyDemandMinAmount = _maxDiscountAmount;
    }

    function setNextEpochDateTime(uint256 _nextDate, uint256 _epochDuration) external onlyManager {
        if ( _nextDate != 0 && _nextDate > nextEpochDate )
            nextEpochDate = _nextDate;
        if ( _epochDuration != 0)
            epochDuration = _epochDuration;
    }

    function setNextDistributionPoktRPS(uint256 _poktRewardEst) external onlyManager {
        nextDistributionPoktRPS = _poktRewardEst;
    }

    /*
     @param _price: Buy $POKT price in tokendecimals
    */
    function setBuyPoktPrice(uint256 _price) external onlyManager {
        poktBuyPrice = _price;
        emit BuyPriceUpdate(_price);
    }

    /*
    @param _amount: Transfer to operator amount (in tokendecimals)
    */
    function withdrawToOperator(uint256 _amount) external onlyOperator {
        require(newInvestments >= _amount, "not enough investment");
        newInvestments = newInvestments.sub(_amount);
        IERC20Upgradeable(protToken).safeTransfer(operator, _amount);
        emit WidthdrawToOperator(_amount);
    }

    /*
    @require totalInvestedShares > 0, _epochSellPoktPrice > 0, _amountPoktUnhold > 0 | OR TX will be reverted
    @param _amountPokt: Number of $POKT rewards from current epoch distribution node rewards(in tokendecimals)
    @param _amountProtToken: $USDC amount obtained for swapping all/part of $POKT from _amountPokt (in tokendecimals)
    @param _epochSellPrice: $POKT sell price in the epoch (in tokendecimals)
    @param _amountPoktUnhold: $POKT amount (from rewards) to be unholded/released on this new epoch (in tokendecimals)

    THIS FUNCTION STARTS A NEW PROTOCOL EPOCH

    */
    function depositEpochRewards(uint256 _amountPokt, uint256 _amountProtToken, uint256 _epochSellPrice, uint256 _amountPoktUnhold) external onlyOneBlock onlyOperator {
        require(_epochSellPrice > 0, "sell price cannot be 0");
        uint256 totalPoktReward = _amountPokt.add(_amountPoktUnhold);
        uint256 totalTokenReward = _amountProtToken.add( _amountPoktUnhold.mul(_epochSellPrice).div(tokenDecimals) ); //Add $USDC return from selling _amountPoktUnhold
        require(totalTokenReward >= tokenDecimals, "cannot allocate 0");

        uint256 feepokt = _amountPokt.mul(fee).div(100);
        // Create & add new snapshot
        SafePoktSnapshot memory newSnapshot = SafePoktSnapshot({
        time: block.number,
        rewardPerPokt: (_amountPokt.sub(feepokt) ).mul(tokenDecimals).div(totalInvestedShares), // Current epoch Node rewards per pokt share (in pokt)
        poktSellPrice: _epochSellPrice,   // = totalTokenReward/(_amountPokt*GLOBAL_SHARES_CLAIM_RATE + _amountPoktUnhold)
        feature1: epochDuration,
        feature2: 0,
        rewardDeposit: totalTokenReward, //Total $USDC
        rewardReceived: totalPoktReward //Total $POKT
        });
        safePoktHistory.push(newSnapshot);

        uint256 feevalue = _amountProtToken.mul(fee).div(100);
        accumulatedFees = accumulatedFees.add(feevalue);

        totalClaimableRewards = totalClaimableRewards.add( totalTokenReward.sub(feevalue) );
        if (totalPoktShares > totalInvestedShares) totalPOKTStake = totalPOKTStake.add( totalPoktShares.sub(totalInvestedShares).mul(getPoktPerShare()).div(tokenDecimals) );
        totalInvestedShares = totalPoktShares;


        IERC20Upgradeable( protToken ).safeTransferFrom(
            msg.sender,
            address(this),
            totalTokenReward
        );
        emit RewardAdded( latestSnapshotIndex(), _amountPokt, _amountProtToken, _epochSellPrice, _amountPoktUnhold, totalEpochPoktCompound );
        totalEpochPoktCompound = 0;
        //stats
        nextEpochDate = nextEpochDate.add( epochDuration );
        nextDistributionPoktRPS = newSnapshot.rewardPerPokt;
        totalPOKTRewards = totalPOKTRewards.add( _amountPokt );
        totalPOKTwithdraw = totalPOKTwithdraw.add( _amountPoktUnhold.add( _amountPokt.mul(tokenDecimals).div(_epochSellPrice) ) );
        totalRewardsUSDC = totalRewardsUSDC.add(totalTokenReward.div(tokenDecimals));
    }

    /*
    @param: Amount of protToken to be transfered
    */
    function addPoktFee(uint256 amountToken) external onlyOperator {

        IERC20Upgradeable( protToken ).safeTransferFrom(
            msg.sender,
            address(this),
            amountToken
        );
        accumulatedFees = accumulatedFees.add(amountToken);
    }


    /* ========== TREASURY METHODS ========== */

    function claimFees() external onlyManager {
        uint256 _amount = accumulatedFees;
        accumulatedFees = 0;
        IERC20Upgradeable(protToken).safeTransfer(treasury, _amount);
        emit ClaimTreasuryFee(treasury, _amount);
    }


    /* ========== HOLDER METHODS ========== */

    function claimReward() external onlyHolderActionsEnabled onlyHolder onlyOneBlock updateReward(msg.sender) {
        uint256 reward = holders[msg.sender].rewardClaimable;
        if (reward > 0) {
            require(holders[msg.sender].lastEpoch < latestSnapshotIndex(), "already claimed");
            holders[msg.sender].lastEpoch = latestSnapshotIndex(); // reset claim timer
            holders[msg.sender].rewardClaimable = 0;

            holders[msg.sender].totalClaimedUSDC = holders[msg.sender].totalClaimedUSDC.add(reward);
            totalClaimableRewards = totalClaimableRewards.sub(reward);

            IERC20Upgradeable(protToken).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function changeClaimPercent(uint256 _newPercent) external onlyHolderActionsEnabled onlyHolder onlyOneBlock updateReward(msg.sender) {
        require(_newPercent <= 100, "not valid percentage");
        //Update Holder Claim Rate for the following Epoch Reward Distributions
        holders[msg.sender].willingToClaim = _newPercent;
        emit ClaimRateUpdated(msg.sender, _newPercent);

    }

    function unHoldPoktOrder(uint256 _poktUnhold) external onlyHolderActionsEnabled onlyHolder onlyOneBlock updateReward(msg.sender) {
        require(_poktUnhold <= holders[msg.sender].PoktReward, "not enough $POKT holdings");

        if (holders[msg.sender].PoktReward > 0) {

            holders[msg.sender].PoktReward = holders[msg.sender].PoktReward.sub(_poktUnhold);
            holders[msg.sender].PoktUnHold = holders[msg.sender].PoktUnHold.add(_poktUnhold);
            holders[msg.sender].PoktUnHoldEpoch = latestSnapshotIndex().add(1);

            emit UnHold(msg.sender, _poktUnhold, holders[msg.sender].PoktUnHoldEpoch);
        }
    }

    function compoundPoktReward() external onlyHolderActionsEnabled onlyHolder onlyOneBlock updateReward(msg.sender) {
        uint256 poktReward = holders[msg.sender].PoktReward;
        if (poktReward > 0) {
            holders[msg.sender].PoktReward = 0;
            uint256 compoundShares = poktReward.mul(tokenDecimals).div( getPoktPerShare() );
            holders[msg.sender].poktShareCount = holders[msg.sender].poktShareCount.add(compoundShares);
            totalEpochPoktCompound = totalEpochPoktCompound.add(poktReward);

            totalPOKTStake = totalPOKTStake.add(poktReward);
            totalInvestedShares = totalInvestedShares.add(compoundShares);
            totalPoktShares = totalPoktShares.add(compoundShares);

            emit Compounded(msg.sender, poktReward);
        }
    }

    function addNewHolder(address newMember) internal returns (Poktseat memory) {

        holderCount = holderCount.add(1);
        holdersEnum.push(newMember);

        Poktseat memory seat = holders[newMember];
        seat.exists = true;
        seat.poktShareCount = 0;
        seat.willingToClaim = 100;
        seat.PoktReward = 0;
        seat.rewardClaimable = 0;
        seat.PoktUnHold = 0;
        seat.PoktUnHoldEpoch = 0;
        seat.lastSnapshotIndex = latestSnapshotIndex().add(1);
        seat.lastEpoch = latestSnapshotIndex().add(1);

        return seat;
    }

    function compute_discount(uint256 _amountShares) public view returns (uint256) {

        uint256 maxDiscountShares = BuyDemandMinAmount.mul(tokenDecimals).div( poktBuyPrice.mul(getPoktPerShare()).div(tokenDecimals) );
        if (_amountShares > maxDiscountShares) _amountShares = maxDiscountShares;

        uint256 discount = ( tokenDecimals.mul(_amountShares).div(maxDiscountShares) ).mul(nodeDiscount).div(100);

        return ( discount.mul( poktBuyPrice.mul( getPoktPerShare() ).mul(_amountShares).div(tokenDecimals) ).div(tokenDecimals) );

    }

    function buyPoktShares(address _token, uint256 _amountShares) external onlyHolderActionsEnabled onlyOneBlock updateReward(msg.sender) {
        require(protToken == _token, "not protocol token");
        require(_amountShares >= 1, "min purchase is 1 share");

        uint256 _amountWei = poktBuyPrice.mul( getPoktPerShare() ).mul(_amountShares).div(tokenDecimals).sub(compute_discount(_amountShares));
        IERC20Upgradeable(protToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amountWei
        );
        uint256 _sharesDecimal = _amountShares.mul(tokenDecimals);

        Poktseat memory seat = holders[msg.sender];
        if (!seat.exists) { //new holder
            seat = addNewHolder(msg.sender);
        }
        else if (seat.lastSnapshotIndex <= latestSnapshotIndex()) { // Dont add if you are in investing period
            totalPOKTStake = totalPOKTStake.add( getPoktPerShare().mul(_amountShares) );
            totalInvestedShares = totalInvestedShares.add(_sharesDecimal);
        }

        seat.poktShareCount = seat.poktShareCount.add(_sharesDecimal);
        holders[msg.sender] = seat;

        totalPoktShares = totalPoktShares.add(_sharesDecimal);
        newInvestments = newInvestments.add(_amountWei);

        emit Deposited(msg.sender, _amountShares, _amountWei, holderCount);

        totalInvestmentsInUSDC = totalInvestmentsInUSDC.add(_amountWei.div(tokenDecimals));
    }

    function buyPoktOnDemand(address _token, uint256 _amount) external onlyHolderActionsEnabled onlyOneBlock updateReward(msg.sender) {
        require(protToken == _token, "not protocol token");
        require(_amount >= BuyDemandMinAmount, "insufficient amount");

        uint256 _amountWei = _amount.mul(tokenDecimals);
        IERC20Upgradeable(protToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amountWei
        );

        Poktseat memory seat = holders[msg.sender];
        if (!seat.exists) //new holder
            holders[msg.sender] = addNewHolder(msg.sender);

        BuyDemandOrders.push( BuyOnDemand({ //New buy by demand
        holder: msg.sender,
        amountUSDC: _amountWei,
        time: block.timestamp
        }) );
        newInvestments = newInvestments.add(_amountWei);

        emit Deposited(msg.sender, 0, _amountWei, holderCount);

        totalInvestmentsInUSDC = totalInvestmentsInUSDC.add(_amountWei.div(tokenDecimals));
    }

    // Method input is the BuyByDemand confirmation of X1 POKT for X2 USDC
    // @_amountPokt -> integer NO decimals
    // @_buyUSDC -> 6 decimals integer
    function confirmDemandBuys(uint256 _amountPokt, uint256 _buyUSDC) external onlyManager {
        require(BuyDemandOrders.length > 0, "no orders");
        require(_buyUSDC > tokenDecimals, "no decimals");

        uint256 buyPrice = _buyUSDC.div(_amountPokt);
        bool end = false;
        uint256 confirmUSDC = _buyUSDC;
        do {
            BuyOnDemand memory order = BuyDemandOrders[0];
            uint256 usdc;
            if (order.amountUSDC > confirmUSDC) {
                usdc = confirmUSDC;
                BuyDemandOrders[0].amountUSDC = BuyDemandOrders[0].amountUSDC.sub(usdc);
                end = true;
            } else {
                usdc = order.amountUSDC;
                BuyDemandOrders[0] = BuyDemandOrders[BuyDemandOrders.length - 1];
                BuyDemandOrders.pop();
            }

            updateRewardHolder(order.holder);
            uint256 poktDecimal = usdc.mul(tokenDecimals).div(buyPrice);
            uint256 sharesDecimal = poktDecimal.mul(tokenDecimals).div( getPoktPerShare() );
            holders[order.holder].poktShareCount = holders[order.holder].poktShareCount.add(sharesDecimal);
            if (holders[order.holder].lastSnapshotIndex <= latestSnapshotIndex()) {
                totalInvestedShares = totalInvestedShares.add(sharesDecimal);
                totalPOKTStake = totalPOKTStake.add(poktDecimal);
            }
            totalPoktShares = totalPoktShares.add(sharesDecimal);
            confirmUSDC = confirmUSDC.sub(usdc);
            if (BuyDemandOrders.length == 0) require(confirmUSDC == 0, "extra funds");

        } while ( BuyDemandOrders.length > 0 && !end);

        emit DemandPoktStaked(_amountPokt, buyPrice);
    }

    //Util Giveaway
    function transferSharesTreasury(uint256 amount, address receiver) external onlyManager updateReward(msg.sender) updateReward(receiver) {

        uint256 transferShares = amount.mul(tokenDecimals);
        require(holders[treasury].poktShareCount >= transferShares, "not enough shares");

        Poktseat memory seat = holders[receiver];
        if (!seat.exists) seat = addNewHolder(receiver);
        if (seat.lastSnapshotIndex > latestSnapshotIndex()) {
            totalPOKTStake = totalPOKTStake.sub( getPoktPerShare().mul(transferShares).div(tokenDecimals) );
            totalInvestedShares = totalInvestedShares.sub(transferShares);
        }

        holders[msg.sender].poktShareCount = holders[msg.sender].poktShareCount.sub(transferShares);
        seat.poktShareCount = seat.poktShareCount.add(transferShares);
        holders[receiver] = seat;

    }
    //End contract
}
