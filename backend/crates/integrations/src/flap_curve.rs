//! Flap's signed curve is read by creating a synthetic token inside eth_call only.
use crate::Integrations;
use alloy_primitives::{Address, B256, Bytes, U256, address, b256, keccak256};
use alloy_sol_types::{SolCall, sol};
use botai_core::{AppError, Chain, Result};
use botai_rpc::Call;
use serde_json::{Value, json};

pub const PORTAL: Address = address!("e2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0");
const READER: Address = address!("000000000000000000000000000000000000f1a7");
const TAX_IMPLEMENTATION: Address = address!("024f18294970b5c76c0691b87f138a0317156422");
const PLAIN_IMPLEMENTATION: Address = address!("88881b6f03090462a969ec7f48385744eeb63333");
const EXTENSION: B256 = b256!("0f1f338177d85790dd81a6e795b59ae3a205cb498e034240ce2261bf753f13a4");
const RUNTIME: &str = include_str!("../../routing/artifacts/readonly-batch.hex");
sol! {
    struct Configuration { uint8 enabled; uint8 defaultCurve; uint8 alternativeCurve; uint8 nativeToQuoteSwapType; uint8 dexId; }
    function getQuoteTokenConfiguration(address quote) view returns(Configuration);
    struct CreateV6 {
        string name; string symbol; string meta; uint8 dexThresh; bytes32 salt; uint8 migratorType;
        address quoteToken; uint256 quoteAmt; address beneficiary; bytes permitData; bytes32 extensionID;
        bytes extensionData; uint8 dexId; uint8 lpFeeProfile; uint16 buyTaxRate; uint16 sellTaxRate;
        uint64 taxDuration; uint64 antiFarmerDuration; uint16 mktBps; uint16 deflationBps; uint16 dividendBps;
        uint16 lpBps; uint256 minimumShareBalance; address dividendToken; address commissionReceiver; uint8 tokenVersion;
    }
    struct FeeConfig { uint8 feeType; uint16 bps; address marketingAddress; address dividendToken; uint256 minimumShareBalance; }
    struct CreateV7 {
        string name; string symbol; string meta; uint8 dexThresh; bytes32 salt; uint8 migratorType;
        address quoteToken; uint256 quoteAmt; bytes permitData; bytes32 extensionID; bytes extensionData;
        uint8 dexId; uint16 buyTaxRate; uint16 sellTaxRate; uint64 taxDuration; uint64 antiFarmerDuration;
        address commissionReceiver; uint8 tokenVersion; FeeConfig[4] feeConfigs;
    }
    function newTokenV6(CreateV6 params) payable returns(address);
    function newTokenV7(CreateV7 params) payable returns(address);
    struct TokenV9 {
        uint8 status; uint256 reserve; uint256 circulatingSupply; uint256 price; uint8 tokenVersion;
        uint256 r; uint256 h; uint256 k; uint256 dexSupplyThresh; address quoteTokenAddress;
        bool nativeToQuoteSwapEnabled; bytes32 extensionID; uint256 buyTaxRate; uint256 sellTaxRate;
        address pool; uint256 progress; uint8 lpFeeProfile; uint8 dexId; uint16 bondingCurveFeeRate;
    }
    function getTokenV9Safe(address token) view returns(TokenV9);
    struct CallValue { address target; bool allowFailure; uint256 value; bytes callData; }
    struct CallResult { bool success; bytes returnData; }
    function aggregate3Value(CallValue[] calls) payable returns(CallResult[]);
    function extensionData(uint256 price, uint256 deadline, bytes signature);
}
fn invalid() -> AppError {
    AppError::new("FLAP_CURVE_INVALID", "Flap 创建曲线读取未完成", 422, false)
}
fn payload(raw: Value) -> Result<Bytes> {
    raw.as_str().unwrap_or("").parse().map_err(|_| invalid())
}
fn candidate(version: u8, start: u64) -> Result<(B256, Address, u64)> {
    let implementation = if version == 7 {
        PLAIN_IMPLEMENTATION
    } else {
        TAX_IMPLEMENTATION
    };
    let init: Bytes = format!(
        "0x3d602d80600a3d3981f3363d3d373d3d3d363d73{:x}5af43d82803e903d91602b57fd5bf3",
        implementation
    )
    .parse()
    .map_err(|_| invalid())?;
    let hash = keccak256(init);
    for n in start..start + 1_000_000 {
        // This salt belongs to a discarded simulation, not to a user wallet or secret.
        let salt = keccak256(format!("botai-curve-{version}-{n}"));
        let mut bytes = Vec::with_capacity(85);
        bytes.push(0xff);
        bytes.extend_from_slice(PORTAL.as_slice());
        bytes.extend_from_slice(salt.as_slice());
        bytes.extend_from_slice(hash.as_slice());
        let full = keccak256(bytes);
        let address = Address::from_slice(&full[12..]);
        if address.as_slice()[18..]
            == if version == 7 {
                [0x88, 0x88]
            } else {
                [0x77, 0x77]
            }
        {
            return Ok((salt, address, n + 1));
        }
    }
    Err(invalid())
}
impl Integrations {
    pub async fn flap_native_swap_type(&self, quote: Address, block: &str) -> Result<u8> {
        let data = payload(self.rpc.read(Chain::Bsc,Call::new("eth_call",vec![json!({"to":PORTAL,"data":Bytes::from(getQuoteTokenConfigurationCall { quote }.abi_encode())}),json!(block)])).await?)?;
        Ok(getQuoteTokenConfigurationCall::abi_decode_returns(&data)
            .map_err(|_| invalid())?
            .nativeToQuoteSwapType)
    }
    pub async fn flap_creation_curve(
        &self,
        quote: Address,
        version: u8,
        block: Option<u64>,
    ) -> Result<Value> {
        if ![6, 7].contains(&version) {
            return Err(AppError::invalid("Flap 代币类型无效"));
        }
        let height = match block {
            Some(height) => height,
            None => {
                let raw = self
                    .rpc
                    .read(Chain::Bsc, Call::new("eth_blockNumber", vec![]))
                    .await?;
                u64::from_str_radix(raw.as_str().unwrap_or("").trim_start_matches("0x"), 16)
                    .map_err(|_| invalid())?
            }
        };
        // Exact-block key: never describe a curve from another block as this block's curve.
        self.cache.try_get_with(format!("flap-curve:{quote:#x}:{version}:{height}"),async {
            let tag = format!("{height:#x}");
            let mut start = 0; let mut selected = None;
            for _ in 0..8 {
                let (salt,address,next) = tokio::task::spawn_blocking(move || candidate(version,start)).await.map_err(|_| invalid())??;
                let code = self.rpc.read(Chain::Bsc,Call::new("eth_getCode",vec![json!(address),json!(tag)])).await?;
                if code == "0x" { selected = Some((salt,address)); break; } start = next;
            }
            let (salt,address) = selected.ok_or_else(invalid)?;
            let config = payload(self.rpc.read(Chain::Bsc,Call::new("eth_call",vec![json!({"to":PORTAL,"data":Bytes::from(getQuoteTokenConfigurationCall { quote }.abi_encode())}),json!(tag)])).await?)?;
            let config = getQuoteTokenConfigurationCall::abi_decode_returns(&config).map_err(|_| invalid())?;
            let (extension_id, extension_data) = if !quote.is_zero() && config.enabled != 1 {
                let signature = self.flap_signature(&format!("{quote:#x}"),&format!("{salt:#x}"),version).await?;
                if signature["allowed"] != true { return Err(AppError::new("FLAP_QUOTE_NOT_APPROVED","Flap 尚未批准该自定义底池代币",422,false)); }
                let encoded = extensionDataCall { price:signature["price"].as_str().unwrap_or("").parse().map_err(|_| invalid())?,deadline:U256::from(signature["deadline"].as_u64().ok_or_else(invalid)?),signature:signature["signature"].as_str().unwrap_or("").parse().map_err(|_| invalid())? };
                let mut raw = Vec::new(); encoded.abi_encode_raw(&mut raw); (EXTENSION,Bytes::from(raw))
            } else { (B256::ZERO,Bytes::new()) };
            let data = creation(version,quote,salt,extension_id,extension_data);
            let calls = vec![CallValue { target:PORTAL,allowFailure:false,value:U256::ZERO,callData:data.into() },CallValue { target:PORTAL,allowFailure:false,value:U256::ZERO,callData:getTokenV9SafeCall { token:address }.abi_encode().into() }];
            let raw = payload(self.rpc.read(Chain::Bsc,Call::new("eth_call",vec![json!({"from":READER,"to":READER,"gas":"0x2625a00","data":Bytes::from(aggregate3ValueCall { calls }.abi_encode())}),json!(tag),json!({format!("{READER:#x}"):{"code":RUNTIME.trim(),"balance":"0xde0b6b3a7640000"}})])).await?)?;
            let rows = aggregate3ValueCall::abi_decode_returns(&raw).map_err(|_| invalid())?;
            if rows.len() != 2 || rows.iter().any(|r| !r.success) || newTokenV6Call::abi_decode_returns(&rows[0].returnData).map_err(|_| invalid())? != address { return Err(invalid()); }
            let state = getTokenV9SafeCall::abi_decode_returns(&rows[1].returnData).map_err(|_| invalid())?;
            if state.status != 1 || state.tokenVersion != version || state.quoteTokenAddress != quote || state.extensionID != extension_id
                || state.r.is_zero() || state.k.is_zero() || state.dexSupplyThresh.is_zero() || state.bondingCurveFeeRate >= 10000 { return Err(invalid()); }
            Ok(json!({"r":state.r.to_string(),"h":state.h.to_string(),"k":state.k.to_string(),"dexSupplyThresh":state.dexSupplyThresh.to_string(),"blockNumber":height,"tokenVersion":version,"bondingCurveFeeRate":state.bondingCurveFeeRate.to_string()}))
        }).await.map_err(|e| (*e).clone())
    }
}
fn creation(version: u8, quote: Address, salt: B256, extension: B256, data: Bytes) -> Vec<u8> {
    let minimum = U256::from(10000) * U256::from(10u64).pow(U256::from(18));
    if version == 7 {
        let mut fees = std::array::from_fn(|_| FeeConfig {
            feeType: 0,
            bps: 0,
            marketingAddress: Address::ZERO,
            dividendToken: Address::ZERO,
            minimumShareBalance: U256::ZERO,
        });
        fees[0] = FeeConfig {
            feeType: 2,
            bps: 10000,
            marketingAddress: Address::ZERO,
            dividendToken: quote,
            minimumShareBalance: minimum,
        };
        newTokenV7Call {
            params: CreateV7 {
                name: "Curve Read".into(),
                symbol: "READ".into(),
                meta: format!("bafkreif{}", "a".repeat(52)),
                dexThresh: 1,
                salt,
                migratorType: 3,
                quoteToken: quote,
                quoteAmt: U256::ZERO,
                permitData: Bytes::new(),
                extensionID: extension,
                extensionData: data,
                dexId: 0,
                buyTaxRate: 0,
                sellTaxRate: 0,
                taxDuration: 0,
                antiFarmerDuration: 0,
                commissionReceiver: Address::ZERO,
                tokenVersion: 7,
                feeConfigs: fees,
            },
        }
        .abi_encode()
    } else {
        newTokenV6Call {
            params: CreateV6 {
                name: "Curve Read".into(),
                symbol: "READ".into(),
                meta: format!("bafkreif{}", "a".repeat(52)),
                dexThresh: 1,
                salt,
                migratorType: 1,
                quoteToken: quote,
                quoteAmt: U256::ZERO,
                beneficiary: READER,
                permitData: Bytes::new(),
                extensionID: extension,
                extensionData: data,
                dexId: 0,
                lpFeeProfile: 0,
                buyTaxRate: 0,
                sellTaxRate: 100,
                taxDuration: 3153600000,
                antiFarmerDuration: 0,
                mktBps: 0,
                deflationBps: 0,
                dividendBps: 10000,
                lpBps: 0,
                minimumShareBalance: minimum,
                dividendToken: quote,
                commissionReceiver: Address::ZERO,
                tokenVersion: 6,
            },
        }
        .abi_encode()
    }
}
