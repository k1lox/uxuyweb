# 真实代币清单的来源（只读）

`../real_tokens.json` 是测试用的真实代币清单（BSC 主网已发出的代币，按 平台|内外盘|结算币|类型 分类）。
全部脚本只读：只调用 `eth_getLogs` / `eth_call` 和后端的平台识别接口，不发送任何交易。

| 脚本 | 找什么 |
|---|---|
| `scan_real_tokens.py` | 广泛扫描三个发射台的近期日志并分类（慢） |
| `find_gap_tokens.py` | 针对缺的类别，按新到旧分类，每类够 2 个即停 |
| `refresh_real_tokens.py` | 从最新发出的代币重建清单：Four 按创建类型（tax0 普通 / tax5/8/9 税币，内盘另标防狙击模式）、Flap 按版本（v6 税币 / v7 无税）、Genius 按版本，各类取最新 2 个 |
| `support_census.py` | 普查：各发射台最新创建的 N 个代币中，后端接受多少、拒绝原因是什么 |
| `recent_entrypoints.py` | 统计最近区块里大家调用发射台的入口函数，发现官方是否换了新接口 |

上游节点 `eth_getLogs` 每次最多 10,000 个区块。
