use alloy_sol_types::sol;
sol! {
    function symbol() view returns(string);
    function decimals() view returns(uint8);
    function feeRate() view returns(uint256);
    function feeRateBuy() view returns(uint256);
    function feeRateSell() view returns(uint256);
    function mainPool() view returns(address);
    function pair() view returns(address);
    function getPair(address a,address b) view returns(address);
    function token0() view returns(address);
    function token1() view returns(address);
    function factory() view returns(address);
    function getReserves() view returns(uint112 reserve0,uint112 reserve1,uint32 timestamp);
    struct FlapState {uint8 status;uint256 reserve;uint256 circulatingSupply;uint256 price;uint8 tokenVersion;uint256 r;uint256 h;uint256 k;uint256 dexSupplyThresh;address quoteTokenAddress;bool nativeToQuoteSwapEnabled;bytes32 extensionID;uint256 buyTaxRate;uint256 sellTaxRate;address pool;uint256 progress;uint8 lpFeeProfile;uint8 dexId;}
    function getTokenV8Safe(address token) view returns(FlapState);
    error TokenNotFound(address token);
    function getTokenInfo(address token) view returns(uint256 version,address tokenManager,address quote,uint256 lastPrice,uint256 tradingFeeRate,uint256 minTradingFee,uint256 launchTime,uint256 offers,uint256 maxOffers,uint256 funds,uint256 maxFunds,bool liquidityAdded);
    function _tokenInfos(address token) view returns(address base,address quote,uint256 template,uint256 totalSupply,uint256 maxOffers,uint256 maxRaising,uint256 launchTime,uint256 offers,uint256 funds,uint256 lastPrice,uint256 K,uint256 T,uint256 status);
    struct LaunchRecord {address token;address curve;address deployer;address creatorFeeRecipient;address pairToken;uint256 graduationThreshold;uint24 poolFee;int24 tickSpacing;uint16 creatorTaxBps;bool buybackEnabled;uint8 phase;uint256 sweptQuote;uint256 sweptTokens;uint256 sweptAt;bool exists;}
    function getLaunchedToken(address token) view returns(LaunchRecord);
    function pairTokenEconomics(address token) view returns(uint256 phantomQuote,uint256 graduationThreshold,uint8 decimals);
    struct InfinityKey {address currency0;address currency1;address hooks;address poolManager;uint24 fee;bytes32 parameters;}
    function poolKeyFor(address token) view returns(InfinityKey);
    interface Curve {
        function pairToken() view returns(address);
        function getReserves() view returns(uint256 quoteReserve,uint256 tokenReserve);
        function feeBps() view returns(uint256);
        function creatorRate(bool buy) view returns(uint16);
        function currentSnipeTaxBps(address recipient) view returns(uint256);
        function creatorTaxBps() view returns(uint256);
        function realQuoteReserve() view returns(uint256);
        function sellableTokens() view returns(uint256);
        function readyToGraduate() view returns(bool);
    }
    struct FeePolicy {address protocolFeeRecipient;uint16 protocolFeeShareBps;uint16 buybackBurnBps;uint16 hookFeeBps;uint16 maxInternalPriceImpactBps;}
    function getLaunchFeePolicy(address token) view returns(FeePolicy);
    function getTokenState(address token) view returns(uint256);
    function tokenCreator(address token) view returns(address);
    function virtualPools(address token) view returns(uint256 a,uint256 b,uint256 c,uint256 d,address quote);
    function taxConfig() view returns(uint16 a,uint16 b,uint16 c,uint16 d,address recipient,uint256 threshold);
    // OpenFour (Four's separate modular engine): Core runtime config and Vault phase.
    function tokens(address token) view returns(uint32 version,address creator,uint256 presetId,address token,string name,string symbol,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,address quoteAsset,address vault,address curveModule,address tradeModule,address migrateModule,address tokenModule,address customData,uint256 createBlock,bool exists,bool paused,bool antiSniperEnabled);
    function phase() view returns(uint8);
}
