# UXUY BSC 后端

Rust 服务为网页提供 BSC 的官方内盘交易、UXUY 外盘报价、钱包读取、官方发币接口和私有捆绑提交。钱包密钥仅在客户端签名。

## 启动

在 `backend/` 目录，将 `config.example.toml` 复制为自己的服务端配置，再运行下面的命令。

```sh
cargo run --locked --release -p uxuy-backend -- /path/to/config.toml
```

在服务端配置文件中以 `rpc_url` 设置自己的 BSC HTTPS 节点。示例使用本机 8545 端口，适合运行本地节点。

根据 UXUY 当前 BSC 部署填写 `[uxuy]` 的执行合约、ERC20 授权地址、原生 BNB 标识，并为服务账户配置可读的 App ID 文件和 RSA 私钥文件。网关固定为 UXUY 的 `gwapi.ourdex.com/bnbchain`。凭据仅由后端读取，每个请求通过五分钟 RS256 JWT 认证。启动时核对 chainId 56 并检查两个合约地址均有代码。旧配置可沿用监听、存储及 relay 设置。省略新的 UXUY 配置段时，钱包读取和官方发币接口可以启动。普通外盘和需要 UXUY 兑换底池币的交易依赖此配置。私有交易提交沿用原有 relay 配置。

App ID 用于网关 URL。JWT header 与 payload 的 `jti` 使用签名公钥的指纹。按 UXUY 的 Go 示例，将 RSA 公钥编码为 X.509 SubjectPublicKeyInfo DER，对 DER 求 SHA-256，将摘要转为标准 Base64，再对该字符串求 MD5 并取小写十六进制。后端直接从所配置的私钥导出对应公钥。生产请求与示例使用相同的 `iss=app`、`ts` 和五分钟 `exp`。

`GET /api/v1/config` 返回 `routeSource`、`routeEnabled`、`router` 和 `approvalSpender`。部署新前端和后端时保持版本一致。重新询价后才能提交服务重启前已准备的交易。多实例部署需要将询价和提交送到同一实例。

## 报价与执行

`POST /api/v1/routes` 为普通外盘按钱包和最小单位金额请求 UXUY。后端读取代币精度，向 `dex_offlineQuote` 发送人类可读的数量、百万分比滑点、相同的 sender/receiver 和 `noFee=true`。执行数据保留 UXUY 返回的目标、calldata 和 value。后端解码 trade 参数，核对交易方向、钱包、输入与链上最低到账，拒绝带跨链或额外收费参数的交易。签名前用同一次模拟检查钱包实际收支及 Traded 事件中的收费金额。预览没有可签名数据。网关无路径、低于最小到账或模拟失败时，准备阶段返回错误。

内盘请求携带 `innerPlatform`，服务回查 BSC 发射台登记。直接调用 Four Manager、Flap Portal 或登记的 Genius 曲线。Flap 支持 BNB 支付的底池可直接走 Portal。需要另行兑换时，前端逐笔核对输入资产、金额、最低到账和执行合约，按连续 nonce 提交同一钱包的整组交易。预览只返回只读步骤，执行返回经过顺序模拟的调用。中间币属于交易钱包。快速组的 `/api/v1/routes/rapid-check` 在同一份模拟状态里先买入，再按钱包实收验证首卖。

`/api/v1/routes/bundle` 按整组总额检查价格影响，各钱包单独取得原始 calldata。随后按实际发送顺序，在同一份链状态中模拟全部授权与兑换，逐钱包核对收支、最低到账及收费事件。任一笔不通过时，整组准备失败。外盘授权目标与配置一致。内盘依据单钱包报价、已核实的 spender 和计划笔数签发有限额度授权，单独捆绑提交，回查成功后才交易。执行节点需要支持 `eth_simulateV1`。提交时按签名恢复出的地址、交易目标、BNB 金额、calldata 和报价有效期重新核对。

BNB 买单的交易 value、合约输入和 Traded 事件必须等于请求金额。交易内可能退回 BNB，因此钱包的模拟净支出须大于零且不超过该金额，代币实际净到账须达到完整报价的最低值。卖单须实际扣除报价指定的全部代币。上游返回 HTTP 401 或 403 时，本地服务返回 `UXUY_AUTH_REJECTED` 并停止准备交易。

发币直接调用发射台的官方创建接口。发币同块的跟买和迁移按平台官方合约执行。后端在私有提交前模拟本次创建并绑定新币、内盘、底池与签名钱包，核对每次买入的净到账。日常买卖仍使用 UXUY。链上 Gas、协议规定的创建款和代币税按实际交易处理。网站不额外收取交易或发币服务费。

## BSC 工作台

卖出检查会单独调用 `POST /api/v1/approvals/check`。用户在页面发起检查后，客户端按缺少的额度准备授权，分组提交到私有节点，等回执确认，再从链上读取每个钱包的额度。卖出交易在用户确认交易金额后提交。普通组循环按该钱包启动时的持仓计算每轮额度，以当前余额封顶。
