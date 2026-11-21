use super::{abi::*, *};
use alloy_primitives::{B256, U256, address, b256};
use alloy_sol_types::SolError;
const FLAP: Address = address!("e2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0");
const FOUR_HELPER: Address = address!("f251f83e40a78868fcfa3fa4599dad6494e46034");
const FOUR: Address = address!("5c952063c7fc8610ffdb798152d69f0b9550762b");
const GENIUS: Address = address!("78eae9537c0ef90dfe9b7ae964682fe8138afe31");
const GENIUS_HOOK: Address = address!("ff17f41c5efd6cce944af0912f300097d62df5c9");
const GENIUS_V2: Address = address!("37ee8aee29c5efd3c1a7eda6df3f510779928a37");
const GENIUS_HOOK_V2: Address = address!("8e6f8ebbd62b60085b703c40b460dae802edc51b");
const GENIUS_M52: Address = address!("52609d5dc0f34b4d077dc6f568b17beb0878ab67");
const GENIUS_HOOK_M52: Address = address!("2c908012aba847735b6f43654265b02e3d37d74a");
const GENIUS_M52_START: u64 = 131_462_588;
const GENIUS_MANAGER: Address = address!("a0ffb9c1ce1fe56963b0321b32e7a0302114058b");
const WBNB: Address = address!("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c");
const FACTORY: Address = address!("ca143ce32fe78f1f7019d7d551a6402fc5350c73");
const OPENFOUR_CORE: Address = address!("ebe7b6c1089d9f72ad07f34e36d898e44e5e27f3");
const OPENFOUR_MIGRATED: u8 = 3;
impl Platforms {
    pub(crate) async fn bsc(&self, token: Address, block: u64) -> Result<Value> {
        if token == WBNB {
            return Err(unsupported("请输入需要买卖的目标代币地址"));
        }
        let tag = format!("{block:#x}");
        let results = self
            .rpc
            .multicall_results(
                Chain::Bsc,
                vec![
                    view(FLAP, getTokenV8SafeCall { token }, false),
                    view(FOUR_HELPER, getTokenInfoCall { token }, false),
                    view(FOUR, _tokenInfosCall { token }, false),
                    view(GENIUS, getLaunchedTokenCall { token }, false),
                    view(GENIUS_V2, getLaunchedTokenCall { token }, false),
                    view(GENIUS_M52, getLaunchedTokenCall { token }, false),
                ],
                &tag,
            )
            .await?;
        let flap_absent = !results[0].success
            && TokenNotFound::abi_decode(&results[0].returnData).is_ok_and(|e| e.token == token);
        let rows: Vec<_> = results
            .into_iter()
            .map(|r| r.success.then_some(r.returnData))
            .collect();
        let flap = decode::<getTokenV8SafeCall>(&rows[0]).ok();
        let four = decode::<getTokenInfoCall>(&rows[1]).ok();
        let registry = decode::<_tokenInfosCall>(&rows[2]).ok();
        let (platform, quote, external, tax_type, mut buy_tax, mut sell_tax, mut pool, extension) =
            // Flap token versions: 2 = standard (non-tax), 6 = tax V3, 7 = TokenV3 (non-tax); 4/5 are deprecated tax tokens.
            if let Some(s) = flap.as_ref().filter(|s| [2, 6, 7].contains(&s.tokenVersion)) {
                if ![1, 4].contains(&s.status) {
                    return Err(unsupported("这个 Flap 代币当前暂不可交易"));
                }
                if s.dexId != 0
                    || ![
                        B256::ZERO,
                        b256!("3526f6a0e790306d64c896eeda5ec66052ea17889e20632ff0cf512923153dad"),
                        b256!("0f1f338177d85790dd81a6e795b59ae3a205cb498e034240ce2261bf753f13a4"),
                    ]
                    .contains(&s.extensionID)
                {
                    return Err(unsupported("这个 Flap 代币的扩展配置暂不支持"));
                }
                (
                    "flap",
                    s.quoteTokenAddress,
                    s.status == 4,
                    s.tokenVersion,
                    s.buyTaxRate,
                    s.sellTaxRate,
                    if s.status == 4 { Some(s.pool) } else { None },
                    Some(s.extensionID),
                )
            } else if let Some((f, r)) = four.as_ref().zip(registry.as_ref()).filter(|(f, r)| {
                f.version == U256::from(2)
                    && f.tokenManager == FOUR
                    && r.base == token
                    && r.quote == f.quote
                    && !r.totalSupply.is_zero()
            }) {
                let tax = ((r.template >> 10usize) & U256::from(63)).to::<u8>();
                // 0 = ordinary (non-tax) token, 5/8/9 = tax templates; other templates are special modes.
                if ![0, 5, 8, 9].contains(&tax) {
                    return Err(unsupported("这里只支持 Four 普通币和税币，不支持特殊模式"));
                }
                (
                    "four",
                    f.quote,
                    f.liquidityAdded,
                    tax,
                    U256::ZERO,
                    U256::ZERO,
                    None,
                    None,
                )
            } else if let Some(record) = decode::<getLaunchedTokenCall>(&rows[5])
                .ok()
                .filter(|r| r.exists)
            {
                return self.genius(token, block, record, GENIUS_M52).await;
            } else if let Some(record) = decode::<getLaunchedTokenCall>(&rows[4])
                .ok()
                .filter(|r| r.exists)
            {
                return self.genius(token, block, record, GENIUS_V2).await;
            } else if let Some(record) = decode::<getLaunchedTokenCall>(&rows[3])
                .ok()
                .filter(|r| r.exists)
            {
                return self.genius(token, block, record, GENIUS).await;
            } else {
                // A failed/partial registry lookup is not proof of an ordinary
                // token. Keep registered but unsupported/malformed tokens closed.
                let r = decode::<_tokenInfosCall>(&rows[2])?;
                let g1 = decode::<getLaunchedTokenCall>(&rows[3])?;
                let g2 = decode::<getLaunchedTokenCall>(&rows[4])?;
                if !r.base.is_zero()
                    || !r.totalSupply.is_zero()
                    || g1.exists
                    || g2.exists
                    || (block >= GENIUS_M52_START && decode::<getLaunchedTokenCall>(&rows[5])?.exists)
                    || !(flap_absent
                        || flap
                            .as_ref()
                            .is_some_and(|f| f.tokenVersion == 0 && f.status == 0))
                    || four
                        .as_ref()
                        .is_some_and(|f| !f.tokenManager.is_zero() || !f.version.is_zero())
                {
                    return Err(unsupported("该发射台代币类型暂不支持"));
                }
                let meta = self
                    .rpc
                    .multicall(
                        Chain::Bsc,
                        vec![
                            view(token, symbolCall {}, true),
                            view(token, decimalsCall {}, true),
                            view(OPENFOUR_CORE, tokensCall { token }, false),
                        ],
                        &tag,
                    )
                    .await?;
                let (symbol, decimals) = metadata(&meta[0], &meta[1])?;
                // OpenFour tokens trade on Four's new modular engine until they migrate; only the
                // migrated (external DEX) phase can go through the ordinary external route.
                if let Some(cfg) = decode::<tokensCall>(&meta[2]).ok().filter(|c| c.exists && c.token == token) {
                    let phase = self.rpc.multicall(Chain::Bsc, vec![view(cfg.vault, phaseCall {}, true)], &tag).await?;
                    if decode::<phaseCall>(&phase[0])? != OPENFOUR_MIGRATED {
                        return Err(unsupported("这是 Four 新版 OpenFour 代币，内盘暂不支持，迁移到外盘后可交易"));
                    }
                }
                return Ok(
                    json!({"address":token.to_checksum(None),"symbol":symbol,"decimals":decimals,
                    "platform":"external","external":true,"quote":Address::ZERO,"taxType":0,
                    "buyTaxBps":"0","sellTaxBps":"0","pool":null,"reserveToken":"0","reserveQuote":"0",
                    "block":block,"route":null,"identity":format!("external:{token:#x}:uxuy")}),
                );
            };
        let mut reads = vec![
            view(token, symbolCall {}, true),
            view(token, decimalsCall {}, true),
        ];
        let four_tax = platform == "four" && tax_type != 0;
        if four_tax {
            reads.push(if tax_type == 5 {
                view(token, feeRateCall {}, true)
            } else {
                view(token, feeRateBuyCall {}, true)
            });
            reads.push(if tax_type == 5 {
                view(token, feeRateCall {}, true)
            } else {
                view(token, feeRateSellCall {}, true)
            });
        }
        // Factory discovery runs alongside metadata instead of another browser round trip.
        // Only Flap tax tokens (v6) are pinned to a V2 pair with mainPool(); other Flap versions trade through
        // the Portal on whatever pool it migrated to, so the pool comes from the Portal state.
        let pair_index = if external && !(platform == "flap" && tax_type != 6) {
            let i = reads.len();
            reads.push(view(
                FACTORY,
                getPairCall {
                    a: token,
                    b: if quote.is_zero() { WBNB } else { quote },
                },
                true,
            ));
            Some(i)
        } else {
            None
        };
        let meta = self.rpc.multicall(Chain::Bsc, reads, &tag).await?;
        let (symbol, decimals) = metadata(&meta[0], &meta[1])?;
        if four_tax {
            let factor = U256::from(if tax_type == 5 { 1 } else { 100 });
            buy_tax = decode::<feeRateCall>(&meta[2])?
                .checked_mul(factor)
                .ok_or_else(invalid)?;
            sell_tax = decode::<feeRateCall>(&meta[3])?
                .checked_mul(factor)
                .ok_or_else(invalid)?;
        }
        if buy_tax >= U256::from(10000) || sell_tax >= U256::from(10000) {
            return Err(unsupported("当前税率无法正常交易"));
        }
        let (mut reserve_token, mut reserve_quote) = (U256::ZERO, U256::ZERO);
        if let Some(index) = pair_index {
            let pair = decode::<getPairCall>(&meta[index])?;
            if pair.is_zero() || pool.is_some_and(|p| p != pair) {
                return Err(unsupported("官方外盘主池尚未就绪"));
            }
            pool = Some(pair);
            let rows = self
                .rpc
                .multicall(
                    Chain::Bsc,
                    vec![
                        view(pair, token0Call {}, true),
                        view(pair, token1Call {}, true),
                        view(pair, factoryCall {}, true),
                        view(pair, getReservesCall {}, true),
                        if platform == "flap" {
                            view(token, mainPoolCall {}, true)
                        } else {
                            view(token, pairCall {}, false)
                        },
                    ],
                    &tag,
                )
                .await?;
            let a = decode::<token0Call>(&rows[0])?;
            let b = decode::<token1Call>(&rows[1])?;
            let q = if quote.is_zero() { WBNB } else { quote };
            if decode::<factoryCall>(&rows[2])? != FACTORY
                || !((a == token && b == q) || (b == token && a == q))
            {
                return Err(invalid());
            }
            let declared = decode::<mainPoolCall>(&rows[4]).unwrap_or(Address::ZERO);
            if (platform == "flap" || !declared.is_zero()) && declared != pair {
                return Err(invalid());
            }
            let r = decode::<getReservesCall>(&rows[3])?;
            reserve_token = U256::from(if a == token { r.reserve0 } else { r.reserve1 });
            reserve_quote = U256::from(if a == token { r.reserve1 } else { r.reserve0 });
            if reserve_token.is_zero() || reserve_quote.is_zero() {
                return Err(unsupported("官方主池暂时没有可用流动性"));
            }
        }
        let mut result = json!({"address":token.to_checksum(None),"symbol":symbol,"decimals":decimals,"platform":platform,"external":external,"quote":quote.to_checksum(None),"taxType":tax_type,
            "buyTaxBps":buy_tax.to_string(),"sellTaxBps":sell_tax.to_string(),"pool":pool.map(|a|a.to_checksum(None)),"reserveToken":reserve_token.to_string(),"reserveQuote":reserve_quote.to_string(),"block":block,"route":null,
            "identity":format!("{platform}:{token:#x}:{quote:#x}:{tax_type}{}",extension.map(|e|format!(":{e:#x}")).unwrap_or_default())});
        if !external {
            let price = if platform == "four" {
                four.as_ref().map(|row| row.lastPrice)
            } else {
                flap.as_ref().map(|row| row.price)
            };
            if let Some(price) = price {
                result["innerPrice"] = json!(price.to_string());
            }
        }
        if let Some(extension) = extension {
            result["flapExtension"] = json!(extension);
            result["nativeToQuoteSwapEnabled"] = json!(flap.as_ref().is_some_and(|row| row.nativeToQuoteSwapEnabled));
            result["flapConversionRequired"] = json!(!quote.is_zero());
        }
        Ok(result)
    }
    async fn genius(
        &self,
        token: Address,
        block: u64,
        record: LaunchRecord,
        factory: Address,
    ) -> Result<Value> {
        let (version, hook) = match factory {
            GENIUS_M52 => ("m5.2", GENIUS_HOOK_M52),
            GENIUS_V2 => ("v2", GENIUS_HOOK_V2),
            _ => ("v1", GENIUS_HOOK),
        };
        if record.token != token || record.curve.is_zero() {
            return Err(invalid());
        }
        if record.phase == 1 {
            return Err(unsupported(
                "Genius 内盘已结束，外盘尚未开放，请等待平台建池后重试",
            ));
        }
        if ![0, 2].contains(&record.phase) {
            return Err(unsupported("Genius 代币当前不可交易"));
        }
        let quote = record.pairToken;
        let curve = record.curve;
        let inner = record.phase == 0;
        let mut reads = vec![
            view(token, symbolCall {}, true),
            view(token, decimalsCall {}, true),
            view(factory, pairTokenEconomicsCall { token: quote }, true),
        ];
        if !quote.is_zero() {
            reads.extend([
                view(quote, symbolCall {}, true),
                view(quote, decimalsCall {}, true),
            ]);
        }
        let offset = reads.len();
        if inner {
            reads.extend([
                view(curve, Curve::getReservesCall {}, true),
                view(curve, Curve::feeBpsCall {}, true),
                view(curve, Curve::realQuoteReserveCall {}, true),
            ]);
        } else {
            reads.push(view(factory, poolKeyForCall { token }, true));
        }
        let fees_offset = reads.len();
        if factory == GENIUS_M52 {
            // These getters return zero after expiry, for both curve and graduated markets.
            reads.extend([
                view(curve, Curve::creatorRateCall { buy: true }, true),
                view(curve, Curve::creatorRateCall { buy: false }, true),
            ]);
            if inner {
                reads.extend([
                    view(curve, Curve::sellableTokensCall {}, true),
                    view(curve, Curve::currentSnipeTaxBpsCall { recipient: Address::ZERO }, true),
                ]);
            }
        } else if inner {
            reads.push(view(curve, Curve::creatorTaxBpsCall {}, true));
        }
        let rows = self
            .rpc
            .multicall(Chain::Bsc, reads, &format!("{block:#x}"))
            .await?;
        let (symbol, decimals) = metadata(&rows[0], &rows[1])?;
        let (q_symbol, q_decimals) = if quote.is_zero() {
            ("BNB".into(), 18)
        } else {
            metadata(&rows[3], &rows[4])?
        };
        if !quote.is_zero() && decode::<pairTokenEconomicsCall>(&rows[2])?.decimals != q_decimals {
            return Err(invalid());
        }
        let (mut reserve_token, mut reserve_quote) = (U256::ZERO, U256::ZERO);
        let mut fee = U256::ZERO;
        let (buy_tax, sell_tax) = if factory == GENIUS_M52 {
            (
                U256::from(decode::<Curve::creatorRateCall>(&rows[fees_offset])?),
                U256::from(decode::<Curve::creatorRateCall>(&rows[fees_offset + 1])?),
            )
        } else {
            let tax = if inner {
                decode::<Curve::creatorTaxBpsCall>(&rows[fees_offset])?
            } else {
                U256::from(record.creatorTaxBps)
            };
            (tax, tax)
        };
        let mut real = U256::ZERO;
        let mut key = None;
        if inner {
            let r = decode::<Curve::getReservesCall>(&rows[offset])?;
            reserve_token = r.tokenReserve;
            reserve_quote = r.quoteReserve;
            fee = decode::<Curve::feeBpsCall>(&rows[offset + 1])?;
            real = decode::<Curve::realQuoteReserveCall>(&rows[offset + 2])?;
        } else {
            let k = decode::<poolKeyForCall>(&rows[offset])?;
            if k.hooks != hook
                || k.poolManager != GENIUS_MANAGER
                || !((k.currency0 == token && k.currency1 == quote)
                    || (k.currency1 == token && k.currency0 == quote))
            {
                return Err(invalid());
            }
            key = Some(
                json!({"currency0":k.currency0.to_checksum(None),"currency1":k.currency1.to_checksum(None),"hooks":k.hooks.to_checksum(None),"poolManager":k.poolManager.to_checksum(None),"fee":k.fee.to::<u32>(),"parameters":k.parameters}),
            );
        }
        if fee.checked_add(buy_tax.max(sell_tax)).is_none_or(|v| v >= U256::from(10000)) {
            return Err(unsupported("Genius 费率无法正常交易"));
        }
        let mut genius = json!({"version":version,"curve":curve.to_checksum(None),"phase":record.phase,"quoteSymbol":q_symbol,"quoteDecimals":q_decimals,"curveFeeBps":fee.to_string(),"realQuoteReserve":real.to_string()});
        if factory == GENIUS_M52 && inner {
            let sellable = decode::<Curve::sellableTokensCall>(&rows[fees_offset + 2])?;
            if sellable.is_zero() {
                return Err(unsupported("Genius 内盘已结束，外盘尚未开放，请等待平台建池后重试"));
            }
            genius["sellableTokens"] = json!(sellable.to_string());
            genius["openingBps"] = json!(decode::<Curve::currentSnipeTaxBpsCall>(&rows[fees_offset + 3])?.to_string());
        } else if factory != GENIUS_M52 {
            genius["creatorTaxBps"] = json!(buy_tax.to_string());
        }
        if let Some(key) = key {
            genius["poolKey"] = key;
        }
        Ok(
            json!({"address":token.to_checksum(None),"symbol":symbol,"decimals":decimals,"platform":"genius","external":!inner,"quote":quote.to_checksum(None),"taxType":0,"buyTaxBps":buy_tax.to_string(),"sellTaxBps":sell_tax.to_string(),"pool":null,"reserveToken":reserve_token.to_string(),"reserveQuote":reserve_quote.to_string(),"block":block,"route":null,"genius":genius,"identity":format!("genius:{token:#x}:{quote:#x}:{curve:#x}")}),
        )
    }
}
