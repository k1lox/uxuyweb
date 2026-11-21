import 'package:flutter/widgets.dart';

/// V3 public contract: explicit general/scoped entry, never a signing method.
const businessSdkMajor = 3;

enum BusinessCapability {
  walletAddress,
  assetSelection,
  receive,
  transfer,
  navigation,
  dialogs,
}

enum BusinessErrorCode {
  scopeRevoked,
  unauthenticated,
  permissionDenied,
  unsupportedChain,
  walletUnavailable,
  invalidRequest,
  busy,
  unavailable,
  assetPrecisionUnavailable,
  amountPrecisionExceeded,
}

class BusinessException implements Exception {
  const BusinessException(this.code);
  final BusinessErrorCode code;
}

enum ConfirmOutcome { confirmed, cancelled, dismissed }

enum AlertOutcome { acknowledged, dismissed }

enum PageOutcome { closed }

enum AssetKind { native, contract }

enum HostPage { liveCenter }

class ModuleManifest {
  const ModuleManifest({
    required this.id,
    required this.sdkMajor,
    required this.capabilities,
  });
  final String id;
  final int sdkMajor;
  final Set<BusinessCapability> capabilities;
}

/// Public chain IDs use UXUY's existing integer chain_id catalog, not CAIP-2.
/// Public host chain metadata. IDs use the UXUY catalog: EVM network IDs and
/// host-assigned IDs for non-EVM networks (not interchangeable with SLIP-44).
class BusinessChain {
  const BusinessChain({required this.chainId, this.name});
  final int chainId;
  final String? name;
}

class BusinessContext {
  BusinessContext({
    required this.chainId,
    required Set<int> supportedChainIds,
    Set<int> evmChainIds = const {},
    List<BusinessChain> chains = const [],
  }) : supportedChainIds = Set.unmodifiable(supportedChainIds),
       evmChainIds = Set.unmodifiable(evmChainIds),
       chains = List.unmodifiable([
         for (final id in supportedChainIds)
           chains.where((chain) => chain.chainId == id).firstOrNull ??
               BusinessChain(chainId: id),
       ]) {
    if (!this.supportedChainIds.containsAll(this.evmChainIds)) {
      throw ArgumentError('EVM chains must belong to the host chain catalog');
    }
    if (chains.map((chain) => chain.chainId).toSet().length != chains.length ||
        chains.any((chain) => !supportedChainIds.contains(chain.chainId))) {
      throw ArgumentError(
        'Chain metadata must uniquely belong to the host catalog',
      );
    }
  }
  final int chainId;
  final Set<int> supportedChainIds;

  /// Immutable list for discovery; call readWallet with one of these chain IDs.
  /// Metadata is not an authentication or wallet-availability guarantee.
  final List<BusinessChain> chains;

  /// Host-owned classification, never inferred from chain number or address.
  /// Omitted chains keep case-sensitive identity. Hosts must declare EVM chains.
  final Set<int> evmChainIds;
  void validateChain(int id) {
    if (id <= 0) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    if (!supportedChainIds.contains(id)) {
      throw const BusinessException(BusinessErrorCode.unsupportedChain);
    }
  }

  AssetId normalizeAsset(AssetId id) {
    if (!id.isWellFormed) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    validateChain(id.chainId);
    return id.normalized(isEvm: evmChainIds.contains(id.chainId));
  }

  bool sameAsset(AssetId a, AssetId b) =>
      normalizeAsset(a) == normalizeAsset(b);
}

class WalletAddressRequest {
  const WalletAddressRequest({required this.chainId});
  final int chainId;
}

class WalletSnapshot {
  const WalletSnapshot({
    required this.label,
    required this.address,
    required this.chainId,
    required this.isMock,
  });
  final String label;
  final String address;
  final int chainId;
  final bool isMock;
}

abstract interface class BusinessScope {
  bool get isActive;
  Future<void> get revoked;
  void ensureActive();
}

abstract interface class IdentityHost {
  Future<WalletSnapshot> readWallet(WalletAddressRequest request);
}

/// Identity is chain + native/contract + contract address; symbol is display only.
/// Raw values retain their spelling. Use BusinessContext.normalizeAsset before
/// equality/hash-based collections; hosts normalize both requests and catalogs.
class AssetId {
  const AssetId.native(this.chainId) : kind = AssetKind.native, contract = '';
  const AssetId.contract(this.chainId, this.contract)
    : kind = AssetKind.contract;
  final int chainId;
  final AssetKind kind;
  final String contract;
  bool get isWellFormed =>
      chainId > 0 &&
      (kind == AssetKind.native
          ? contract.isEmpty
          : contract.isNotEmpty &&
                contract.length <= 256 &&
                !RegExp(r'\s').hasMatch(contract) &&
                !contract.codeUnits.any((c) => c < 32 || c == 127));

  /// Hex case is identity-insensitive only on an explicitly EVM chain.
  /// This checks 20-byte hex shape, not an EIP-55 checksum or token existence.
  AssetId normalized({required bool isEvm}) {
    if (!isWellFormed) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    if (kind == AssetKind.native || !isEvm) return this;
    if (!RegExp(r'^0[xX][0-9a-fA-F]{40}$').hasMatch(contract)) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    return AssetId.contract(chainId, contract.toLowerCase());
  }

  @override
  bool operator ==(Object other) =>
      other is AssetId &&
      chainId == other.chainId &&
      kind == other.kind &&
      contract == other.contract;
  @override
  int get hashCode => Object.hash(chainId, kind, contract);
}

class AssetSnapshot {
  const AssetSnapshot({
    required this.id,
    required this.symbol,
    this.decimals,
    this.name,
    this.icon,
    this.amount,
    this.value,
  });
  final AssetId id;
  final String symbol;

  /// Optional public display metadata; icon is a public URL, not an auth client.
  final String? name;
  final String? icon;

  /// Selected wallet holding in human token units, copied without rounding.
  /// A selection-time snapshot, not transferable funds or a live balance feed.
  /// Null means unavailable; the string '0' is a known zero.
  final String? amount;

  /// Host holding valuation in USD, copied without formatting or recomputation.
  /// Null means unavailable, not zero or a guaranteed execution quote.
  final String? value;
  String? get valueCurrency => value == null ? null : 'USD';

  /// Host-resolved precision; null means unknown, never a default 6/18.
  /// Hosts never trust metadata supplied back by the module.
  final int? decimals;
  int get chainId => id.chainId;

  /// Native assets have no contract. Never expose host native sentinel aliases.
  String? get contract => id.kind == AssetKind.native ? null : id.contract;
}

class AssetSelectionRequest {
  AssetSelectionRequest({required Set<int> chainIds, Set<AssetId>? assets})
    : chainIds = Set.unmodifiable(chainIds),
      assets = assets == null ? null : Set.unmodifiable(assets);
  final Set<int> chainIds;
  final Set<AssetId>? assets;
  bool accepts(AssetId id, {BusinessContext? context}) {
    final request = context == null ? this : normalized(context);
    if (!request.chainIds.contains(id.chainId)) return false;
    final candidate = context == null ? id : context.normalizeAsset(id);
    return request.chainIds.contains(candidate.chainId) &&
        (request.assets?.contains(candidate) ?? true);
  }

  /// Normalize once before filtering a host catalog; candidates must also use
  /// context.normalizeAsset (or pass context to accepts for a one-off check).
  AssetSelectionRequest normalized(BusinessContext context) {
    validate();
    for (final chain in chainIds) {
      context.validateChain(chain);
    }
    return AssetSelectionRequest(
      chainIds: chainIds,
      assets: assets?.map(context.normalizeAsset).toSet(),
    );
  }

  void validate() {
    if (chainIds.isEmpty ||
        chainIds.any((id) => id <= 0) ||
        (assets?.any(
              (id) => !id.isWellFormed || !chainIds.contains(id.chainId),
            ) ??
            false)) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
  }
}

class ReceiveRequest {
  const ReceiveRequest({required int this.chainId, this.asset});

  /// Original unrestricted host entry. The host/user chooses the network.
  const ReceiveRequest.general() : chainId = null, asset = null;

  /// Non-null restricts the complete flow to this chain. Asset is a preset.
  final int? chainId;
  final AssetId? asset;
  bool get isGeneral => chainId == null;
  ReceiveRequest normalized(BusinessContext context) {
    validate();
    if (isGeneral) return this;
    context.validateChain(chainId!);
    return ReceiveRequest(
      chainId: chainId!,
      asset: asset == null ? null : context.normalizeAsset(asset!),
    );
  }

  void validate() {
    if ((chainId != null && chainId! <= 0) ||
        (asset != null &&
            (!asset!.isWellFormed || asset!.chainId != chainId))) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
  }
}

/// Human token units, positive decimal string, at most six fractional digits:
/// matches the existing App amount keypad. This is not on-chain token decimals.
class TokenAmount {
  factory TokenAmount(String value) {
    if (value.length > 64 ||
        !RegExp(r'^\d{1,16}(\.\d+)?$').hasMatch(value) ||
        BigInt.parse(value.replaceAll('.', '')) <= BigInt.zero) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    if (_fractionDigits(value) > maxFractionDigits) {
      throw const BusinessException(BusinessErrorCode.amountPrecisionExceeded);
    }
    return TokenAmount._(value);
  }
  const TokenAmount._(this.value);
  final String value;

  /// SDK prefill limit, independent of on-chain or display precision.
  static const maxFractionDigits = 6;
  static int _fractionDigits(String value) =>
      value.contains('.') ? value.length - value.indexOf('.') - 1 : 0;

  /// Exact representation only. Fractional trailing zeros count. Never round
  /// or truncate the caller's amount. A known precision of zero is valid.
  void validateForDecimals(int? decimals) {
    if (decimals == null || decimals < 0 || decimals > 255) {
      throw const BusinessException(
        BusinessErrorCode.assetPrecisionUnavailable,
      );
    }
    if (_fractionDigits(value) > decimals ||
        _fractionDigits(value) > maxFractionDigits) {
      throw const BusinessException(BusinessErrorCode.amountPrecisionExceeded);
    }
  }
}

class TransferRequest {
  const TransferRequest({
    required int this.chainId,
    this.asset,
    this.recipient,
    this.amount,
  });

  /// Original host Send entry, with host-owned defaults and no prefills.
  const TransferRequest.general()
    : chainId = null,
      asset = null,
      recipient = null,
      amount = null;

  /// Restricts asset selection to this chain. Without asset, select before Send.
  final int? chainId;
  final AssetId? asset;
  final String? recipient;
  final TokenAmount? amount;
  bool get isGeneral => chainId == null;
  TransferRequest normalized(BusinessContext context) {
    validate();
    if (isGeneral) return this;
    context.validateChain(chainId!);
    return TransferRequest(
      chainId: chainId!,
      recipient: recipient,
      amount: amount,
      asset: asset == null ? null : context.normalizeAsset(asset!),
    );
  }

  void validate() {
    if (chainId != null) {
      ReceiveRequest(chainId: chainId!, asset: asset).validate();
    }
    // Money has a unit only when an explicit asset is supplied. Never guess it.
    if ((amount != null && asset == null) ||
        (isGeneral && (recipient != null || amount != null || asset != null))) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
    final text = recipient;
    if (text != null &&
        (text.isEmpty ||
            text.trim() != text ||
            text.length > 256 ||
            text.codeUnits.any((c) => c < 32 || c == 127))) {
      throw const BusinessException(BusinessErrorCode.invalidRequest);
    }
  }
}

class HostPageRequest {
  const HostPageRequest(this.page);
  final HostPage page;
}

class ConfirmRequest {
  const ConfirmRequest({required this.title, required this.message});
  final String title;
  final String message;
  void validate() => _validateText(title, message);
}

class AlertRequest {
  const AlertRequest({required this.title, required this.message});
  final String title;
  final String message;
  void validate() => _validateText(title, message);
}

class NoticeRequest {
  const NoticeRequest(this.message);
  final String message;
  void validate() => _validateText('Notice', message);
}

void _validateText(String title, String message) {
  if (title.trim().isEmpty ||
      title.length > 128 ||
      message.trim().isEmpty ||
      message.length > 2048) {
    throw const BusinessException(BusinessErrorCode.invalidRequest);
  }
}

abstract interface class DialogHost {
  Future<ConfirmOutcome> confirm(ConfirmRequest request);
  Future<AlertOutcome> alert(AlertRequest request);
  Future<void> notify(NoticeRequest request);
}

abstract interface class NavigationHost {
  Future<AssetSnapshot?> selectAsset(AssetSelectionRequest request);
  Future<PageOutcome> openReceive(ReceiveRequest request);

  /// Closed means UI ended, never transaction success.
  Future<PageOutcome> openTransfer(TransferRequest request);
  Future<PageOutcome> openPage(HostPageRequest request);
}

abstract interface class BusinessHost {
  BusinessContext get context;
  BusinessScope get scope;
  IdentityHost get identity;
  DialogHost get dialogs;
  NavigationHost get navigation;
}

abstract interface class BusinessModule {
  ModuleManifest get manifest;
  ModuleSession createSession(BusinessHost host);
}

abstract interface class ModuleSession {
  Widget buildEntry();
  void dispose();
}
