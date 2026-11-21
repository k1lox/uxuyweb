//! Bind signed swaps and ERC20 approvals to unexpired wallet-specific UXUY plans.
use crate::{
    error::{ApiError, Result},
    route::{RoutePlan, Side},
};
use alloy_primitives::{Address, B256, U256, keccak256};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
};

const MAX_ENTRIES: usize = 32_768;

#[derive(Hash, PartialEq, Eq)]
enum Action {
    Official(Vec<LegProof>),
    Grant {
        wallet: Address,
        market: Address,
        platform: String,
        asset: Address,
        spender: Address,
    },
    PrivateApproval {
        wallet: Address,
        target: Address,
        calldata: B256,
    },
    Swap {
        wallet: Address,
        to: Address,
        value: U256,
        calldata: B256,
    },
    Approval {
        wallet: Address,
        token: Address,
        spender: Address,
        amount: U256,
    },
}

#[derive(Clone, Hash, PartialEq, Eq)]
pub(crate) struct LegProof {
    wallet: Address,
    to: Address,
    value: U256,
    data: B256,
    gas_limit: u64,
}

impl LegProof {
    pub(crate) fn new(
        wallet: Address,
        to: Address,
        value: U256,
        data: &[u8],
        gas_limit: u64,
    ) -> Self {
        Self {
            wallet,
            to,
            value,
            data: keccak256(data),
            gas_limit,
        }
    }
}
#[derive(Default)]
struct Entry {
    until: u64,
    market: Option<(Address, String)>,
    limits: Vec<(U256, u64)>,
}
#[derive(Clone, Default)]
pub struct IssuedRoutes(Arc<RwLock<HashMap<Action, Entry>>>);

impl IssuedRoutes {
    pub fn record(&self, plan: &RoutePlan) -> Result<()> {
        self.record_inner_grants(plan)?;
        if !plan.executed || plan.quote_scope != Some("wallet") {
            return Ok(());
        }
        if plan.source == "official" {
            // A simulated grant establishes a budget, not an executable trading permission.
            if plan.simulation != "official" {
                return Ok(());
            }
            if plan.legs.is_empty() || plan.legs.len() > 3 {
                return Err(ApiError::invalid("内盘报价的交易步骤无效"));
            }
            let legs: Result<Vec<_>> = plan
                .legs
                .iter()
                .map(|leg| {
                    let value = U256::from_str_radix(&leg.value, 10)
                        .map_err(|_| ApiError::invalid("内盘金额无效"))?;
                    Ok(LegProof::new(
                        plan.wallet,
                        leg.to,
                        value,
                        &leg.data,
                        leg.gas_limit,
                    ))
                })
                .collect();
            let platform = plan
                .dexes
                .first()
                .ok_or_else(|| ApiError::invalid("内盘平台缺失"))?;
            return self.record_entries(
                vec![Action::Official(legs?)],
                plan.deadline,
                Some((plan.token, platform.clone())),
            );
        }
        let value =
            U256::from_str_radix(&plan.value, 10).map_err(|_| ApiError::invalid("路由金额无效"))?;
        let swap = Action::Swap {
            wallet: plan.wallet,
            to: plan.to,
            value,
            calldata: keccak256(&plan.data),
        };
        let approval = if plan.side == Side::Sell {
            Some(Action::Approval {
                wallet: plan.wallet,
                token: plan.token,
                spender: plan.spender,
                amount: crate::route::parse_amount(&plan.amount)?,
            })
        } else {
            None
        };
        self.record_actions(
            std::iter::once(swap).chain(approval).collect(),
            plan.deadline,
        )
    }

    pub(crate) fn record_inner_grants(&self, plan: &RoutePlan) -> Result<()> {
        if plan.source != "official"
            || plan.quote_scope != Some("wallet")
            || plan.approvals.is_empty()
        {
            return Ok(());
        }
        let platform = plan
            .dexes
            .first()
            .ok_or_else(|| ApiError::invalid("内盘授权依据缺少平台"))?;
        let grants: Result<Vec<_>> = plan
            .approvals
            .iter()
            .map(|a| {
                Ok((
                    Action::Grant {
                        wallet: plan.wallet,
                        market: plan.token,
                        platform: platform.clone(),
                        asset: a.token,
                        spender: a.spender,
                    },
                    crate::route::parse_amount(&a.amount)?,
                ))
            })
            .collect();
        let grants = grants?;
        let mut map = self
            .0
            .write()
            .map_err(|_| ApiError::unavailable("授权依据暂不可用"))?;
        let now = crate::now();
        if map.len() + grants.len() > MAX_ENTRIES {
            map.retain(|_, value| value.until > now);
            if map.len() + grants.len() > MAX_ENTRIES {
                return Err(ApiError::unavailable("授权依据已满，请稍后重试"));
            }
        }
        for (key, amount) in grants {
            let entry = map.entry(key).or_default();
            entry.until = entry.until.max(plan.deadline);
            // Keep independent expiries. Refreshing a smaller grant must not extend a larger one.
            entry
                .limits
                .retain(|(n, t)| *t > now && !(*n <= amount && *t <= plan.deadline));
            if !entry
                .limits
                .iter()
                .any(|(n, t)| *n >= amount && *t >= plan.deadline)
            {
                if entry.limits.len() >= 32 {
                    entry.limits.remove(0);
                }
                entry.limits.push((amount, plan.deadline));
            }
        }
        Ok(())
    }
    pub(crate) fn inner_budget(
        &self,
        wallet: Address,
        market: Address,
        platform: &str,
        asset: Address,
        spender: Address,
        amount: U256,
        orders: u32,
        now: u64,
    ) -> bool {
        if !(1..=10000).contains(&orders) {
            return false;
        }
        let order_count = U256::from(orders);
        let needed = amount / order_count + U256::from(!(amount % order_count).is_zero());
        let key = Action::Grant {
            wallet,
            market,
            platform: platform.to_owned(),
            asset,
            spender,
        };
        self.0.read().is_ok_and(|map| {
            map.get(&key).is_some_and(|entry| {
                entry
                    .limits
                    .iter()
                    .any(|(limit, until)| *until > now && *limit >= needed)
            })
        })
    }

    pub fn record_approvals(
        &self,
        token: Address,
        spender: Address,
        rows: &[(Address, U256)],
        deadline: u64,
    ) -> Result<()> {
        self.record_actions(
            rows.iter()
                .map(|&(wallet, amount)| Action::Approval {
                    wallet,
                    token,
                    spender,
                    amount,
                })
                .collect(),
            deadline,
        )
    }

    fn record_actions(&self, actions: Vec<Action>, deadline: u64) -> Result<()> {
        self.record_entries(actions, deadline, None)
    }
    fn record_entries(
        &self,
        actions: Vec<Action>,
        deadline: u64,
        market: Option<(Address, String)>,
    ) -> Result<()> {
        let mut issued = self
            .0
            .write()
            .map_err(|_| ApiError::unavailable("路由校验暂不可用"))?;
        if issued.len() + actions.len() > MAX_ENTRIES {
            let now = crate::now();
            issued.retain(|_, entry| entry.until > now);
            if issued.len() + actions.len() > MAX_ENTRIES {
                return Err(ApiError::new(
                    "ROUTE_CAPACITY",
                    "可执行报价已满，请稍后重试",
                    503,
                    true,
                ));
            }
        }
        for action in actions {
            let entry = issued.entry(action).or_default();
            entry.until = entry.until.max(deadline);
            entry.market = market.clone();
        }
        Ok(())
    }

    pub(crate) fn record_private_approvals(
        &self,
        proofs: &[(Address, Address, B256)],
        deadline: u64,
    ) -> Result<()> {
        self.record_actions(
            proofs
                .iter()
                .map(|&(wallet, target, calldata)| Action::PrivateApproval {
                    wallet,
                    target,
                    calldata,
                })
                .collect(),
            deadline,
        )
    }
    pub(crate) fn private_approval(
        &self,
        wallet: Address,
        target: Address,
        data: &[u8],
        now: u64,
    ) -> bool {
        self.valid(
            Action::PrivateApproval {
                wallet,
                target,
                calldata: keccak256(data),
            },
            now,
        )
    }

    pub(crate) fn official_order(&self, legs: &[LegProof], now: u64) -> Option<(Address, String)> {
        self.0
            .read()
            .ok()?
            .get(&Action::Official(legs.to_vec()))
            .filter(|entry| entry.until > now)?
            .market
            .clone()
    }
    fn valid(&self, action: Action, now: u64) -> bool {
        self.0
            .read()
            .is_ok_and(|issued| issued.get(&action).is_some_and(|entry| entry.until > now))
    }

    pub fn swap(&self, wallet: Address, to: Address, value: U256, data: &[u8], now: u64) -> bool {
        self.valid(
            Action::Swap {
                wallet,
                to,
                value,
                calldata: keccak256(data),
            },
            now,
        )
    }

    pub fn approval(
        &self,
        wallet: Address,
        token: Address,
        spender: Address,
        amount: U256,
        now: u64,
    ) -> bool {
        self.valid(
            Action::Approval {
                wallet,
                token,
                spender,
                amount,
            },
            now,
        )
    }
}
