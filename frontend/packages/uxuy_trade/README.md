# UXUY BSC 交易模块

独立网页和 Flutter 宿主共用这个模块。它提供 Four.meme、Flap 和 Genius 发币、批量交易、钱包生成、分发与归集。钱包在本机签名，普通外盘交易使用后端返回的 UXUY 报价。

## 独立网页

网页入口是 `frontend/web/lib/main.dart`，默认向网页所在域名的 `/api/` 发送请求。桌面 Chrome 负责请求本地文件夹权限。钱包备份与日志写入用户选择的目录，写入完成后重新读取并核对。

从项目根目录构建和运行网页的步骤见[项目说明](../../../README.md)。

## 嵌入 Flutter App

把 `uxuy_trade` 和 `uxuy_business_sdk` 放在宿主工程的 `packages/` 目录。在宿主的 `pubspec.yaml` 中声明两个包的位置。

```yaml
dependencies:
  uxuy_trade:
    path: packages/uxuy_trade
dependency_overrides:
  uxuy_business_sdk:
    path: packages/uxuy_business_sdk
```

宿主通过 `package:uxuy_trade/uxuy_trade.dart` 导入 `UxuyTradeModule`，按 SDK major 3 的业务模块接口注册，模块 ID 为 `uxuy.trade`。

| 构造参数 | 用途 |
| --- | --- |
| `endpoint` | 宿主模式的后端地址，可用 `--dart-define=UXUY_BACKEND=…` 设置默认值，未配置时连接本机 `http://127.0.0.1:3291/` |
| `imagePicker` | 调用宿主图片选择器，返回 `LaunchImage`；用户取消时返回 `null` |
| `keyStoreFactory` | 提供宿主的钱包存储实现，默认使用 `MemoryKeyStore` |
| `clientFactory` | 提供后端 HTTP 客户端，默认使用 `http.Client.new` |

## 测试与翻译

在本目录运行 `flutter pub get --enforce-lockfile`、`flutter analyze --no-pub` 和 `flutter test --no-pub --exclude-tags fork`。离线测试使用模拟钱包和节点；标有 `fork` 的用例需要单独准备相应的测试环境。Flap 金库的只读集成测试接收 `UXUY_FLAP_READONLY_RPC` 指定的 BSC RPC，可用 `UXUY_FLAP_VAULT_REPORT` 指定结果文件。`interop` 用例使用仓库内 Rust 后端的签名样本进行对照。

中英文来自 `translations/l10n.tsv`。在项目根目录运行 `python3 frontend/tool/generate_strings.py` 更新 Dart 翻译表；加上 `--check` 可检查当前生成结果。生成器使用当前 Flutter SDK 配套的 `dart format`。
