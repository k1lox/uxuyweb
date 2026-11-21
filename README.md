# UXUY Web

BSC 桌面交易工作台，使用 Google Chrome。前端负责表单、钱包管理和本地签名。Rust 后端提供链上读取、报价、模拟及私有交易提交。

## 从源码启动

项目使用 Flutter 3.47.6（Dart 3.13.5）、Node.js 22.12 或更新版本、Python 3 和 Rust。后端使用 Rust 2024 edition，已用 Rust 1.94.1 验证。以下命令从项目根目录执行，使用支持 `sh` 的终端。将 Flutter 加入 `PATH` 后即可构建。

```sh
npm ci
npm run build
npm run dev
```

在 Chrome 打开 [本地工作台](http://127.0.0.1:3190/)。前端构建产物在 `frontend/web/build/web/`。预览服务将同源 `/api/` 请求转发到 `127.0.0.1:3291`，可用环境变量 `UXUY_PROXY_TARGET` 指定其他后端。

另开终端启动本地 API。首次启动时复制配置模板，在生成的 `config.local.toml` 中填写自己的部署参数。

```sh
cd backend
cp -n config.example.toml config.local.toml
cargo run --locked --release -p uxuy-backend -- config.local.toml
```

部署配置与 Rust 源码分开。`backend/app/src/config.rs` 定义配置格式和校验规则。`backend/config.example.toml` 是公开模板，实际配置由部署者保管。生产配置可以存放在仓库外，例如将启动命令最后的参数替换为 `/etc/uxuyweb/config.toml`。

在服务端配置文件的 `rpc_url` 中设置自己的 BSC 节点地址。后端默认使用本地 SQLite，可配置 MySQL。使用 UXUY 外盘报价时，需要在服务端设置自己的 App ID、RSA 签名密钥文件、BSC 执行合约与授权地址。私有交易提交需要相应的节点配置。生产部署将静态目录作为站点根目录，并把同源 `/api/` 反向代理给后端。[配置示例](backend/config.example.toml) · [后端说明](backend/README.md)

## 主要功能

- **发币**支持 Four.meme、Flap 和 Genius。官方合约处理创建、同块首买与迁移，操作前按顺序模拟。Dev 和参与首买的钱包可按平台支持的币种付款。
- **批量买卖**支持普通组、独立快速组和关联组。内盘使用官方合约，普通外盘使用 UXUY 的免平台费报价。交易检查处理所需授权。本轮清仓也会检查后续参与过该币批量交易的钱包余额。
- **钱包与工作台**包含生成私钥、命名分组、分发、归集、控盘率和操作日志。钱包签名在本机完成。授权本地文件夹后，钱包写入 `UAgent-wallets/wallets.json` 并回读核验，操作记录单独写入日志。钱包备份为明文，文件夹由使用者保管。编辑页面后刷新时，Chrome 会提示确认。

## 源码目录

| 目录 | 用途 |
| --- | --- |
| `frontend/web/` | 浏览器入口、文件夹接口、字体和静态页面 |
| `frontend/packages/uxuy_trade/` | 交易工作台、钱包、签名、执行及 Flutter 测试 |
| `frontend/packages/uxuy_business_sdk/` | 交易模块使用的宿主接口 |
| `frontend/local-log/` | 本地日志模块的 TypeScript 源码，构建时生成浏览器脚本 |
| `backend/app/`、`backend/crates/` | Rust 服务入口、路由、发射台、RPC、交易和存储 |
| `backend/dev/` | 开发用分叉节点工具、代币样本及样本维护脚本 |
| `scripts/`、`tests/` | 构建、预览、源码一致性校验及跨端回归 |
| `scripts/source-sha256.json` | 公开版核心源码的校验清单 |

## 验证

```sh
npm run verify
(cd backend && cargo test --locked --workspace)
(cd frontend/packages/uxuy_trade && ../../../scripts/flutter.sh pub get --enforce-lockfile && ../../../scripts/flutter.sh test --no-pub --exclude-tags fork)
```

运行 `npm run dev` 后，在另一终端运行 `npm run test:web`。该回归使用桌面 Chrome、模拟 API 和测试钱包。结果写入 `test-results/`。前后端互操作测试核对同一份签名样本。带 `fork` 标签的用例需要单独准备相应的链、分叉节点或服务。

`npm run verify` 核对本版核心源码的 SHA-256 指纹。

网站使用的 Noto Sans SC 字体及其 SIL Open Font License 随源码提供。[字体许可](frontend/web/assets/fonts/OFL.txt)
