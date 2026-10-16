// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSubscriptionService — thin wrapper around purchases_flutter (RevenueCat).
//
// Responsibilities:
//   - Configure Purchases SDK once at app startup with the platform SDK key
//     and Wearable's devId as the app user ID (one-device-one-user model).
//   - Expose ChangeNotifier-backed `hasPro` / `customerInfo` state so widgets
//     can reactively gate behind the Wearable Pro entitlement.
//   - Surface current offering (lifetime / yearly / monthly) for custom UIs
//     that don't use the pre-built PaywallView.
//   - Handle purchase / restore / identity rotation with PlatformException
//     normalisation into WearableSubscriptionError.
//
// The paywall UI and customer center UI are presented via
// `purchases_ui_flutter` helpers — see WearableSubscriptionSheet / the
// pro-gate widget for the user-facing entry points.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

/// Public identifier for the Pro entitlement. Must match the `lookup_key`
/// configured for the entitlement in RevenueCat's project dashboard.
const String kWearableProEntitlement = 'Wearable Pro';

/// Package identifiers emitted by the dashboard's current offering. Kept as
/// const strings so lookups are compile-time safe and typos fail loudly.
class WearablePackageIds {
  WearablePackageIds._();
  static const lifetime = 'lifetime';
  static const yearly = 'yearly';
  static const monthly = 'monthly';
}

/// RevenueCat SDK keys — platform-specific. The `test_*` key from the
/// dashboard is usable for both iOS and Android in sandbox mode. For
/// production, replace with the `appl_*` (iOS) and `goog_*` (Android)
/// keys from RC dashboard → Project Settings → API Keys → Public SDK Keys.
///
/// Future move: host these in `lib/env/dev_env.g.dart` via Envied so the
/// key never lands in git. For the current sandbox-only build, inlining
/// is fine.
class _WearableRcKeys {
  _WearableRcKeys._();

  // Sandbox / dev — shared between iOS and Android (test_ prefix).
  static const _sandboxTest = 'test_GNXhXstncgHNaHTgHjqbuWINXjI';

  // Production placeholders — replace before shipping prod builds.
  static const _prodIos = 'appl_REPLACE_ME_BEFORE_PROD';
  static const _prodAndroid = 'goog_REPLACE_ME_BEFORE_PROD';

  static String resolve({required bool isRelease}) {
    if (!isRelease) return _sandboxTest;
    if (Platform.isIOS || Platform.isMacOS) return _prodIos;
    if (Platform.isAndroid) return _prodAndroid;
    throw UnsupportedError('RevenueCat only supports iOS, macOS and Android');
  }
}

/// Wraps PlatformException from Purchases calls into a typed, user-facing
/// error with a stable `code` and a human-readable `message`.
class WearableSubscriptionError implements Exception {
  WearableSubscriptionError(this.code, this.message, [this.cause]);
  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WearableSubscriptionError($code): $message';

  /// Convert from a raw PlatformException. See
  /// <https://www.revenuecat.com/docs/errors> for the error-code table.
  factory WearableSubscriptionError.fromPlatform(PlatformException e) {
    final rcCode = PurchasesErrorHelper.getErrorCode(e);
    return WearableSubscriptionError(
      rcCode.name,
      _friendlyMessage(rcCode, e.message ?? 'Unknown error'),
      e,
    );
  }

  static String _friendlyMessage(PurchasesErrorCode code, String fallback) {
    switch (code) {
      case PurchasesErrorCode.purchaseCancelledError:
        return 'Purchase cancelled.';
      case PurchasesErrorCode.purchaseNotAllowedError:
        return 'Purchases are not allowed on this device.';
      case PurchasesErrorCode.paymentPendingError:
        return 'Payment is pending — will complete in the background.';
      case PurchasesErrorCode.storeProblemError:
        return 'There was a problem with the App Store / Play Store. Please try again.';
      case PurchasesErrorCode.networkError:
        return 'Network error — check your connection and retry.';
      case PurchasesErrorCode.receiptAlreadyInUseError:
        return 'This purchase is already attached to a different account.';
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return 'You already own this product — restore purchases to activate.';
      case PurchasesErrorCode.productNotAvailableForPurchaseError:
        return 'This product is not available right now.';
      default:
        return fallback;
    }
  }
}

class WearableSubscriptionService extends ChangeNotifier {
  WearableSubscriptionService._();
  static final WearableSubscriptionService instance = WearableSubscriptionService._();

  bool _configured = false;
  CustomerInfo? _customerInfo;
  Offerings? _offerings;
  Object? _lastError;

  /// Convenience — true once [configure] finished.
  bool get isConfigured => _configured;

  /// Latest cached CustomerInfo snapshot. Null before first fetch.
  CustomerInfo? get customerInfo => _customerInfo;

  /// All offerings returned from the dashboard. Typically you want
  /// [currentOffering] unless you're doing A/B testing across offerings.
  Offerings? get offerings => _offerings;

  /// The dashboard-designated "current" offering, null if none configured.
  Offering? get currentOffering => _offerings?.current;

  /// Last error (non-cancel) observed from a purchase/restore attempt, for
  /// UI inspection. Cleared on next successful operation.
  Object? get lastError => _lastError;

  /// True when the Wearable Pro entitlement is active and not expired.
  bool get hasPro {
    final ent = _customerInfo?.entitlements.active[kWearableProEntitlement];
    if (ent == null) return false;
    return ent.isActive;
  }

  /// Configure the Purchases SDK. Idempotent — additional calls are a no-op.
  /// Call once in `main.dart::_init()` after `Firebase.initializeApp`.
  ///
  /// [appUserId] should be a stable per-user identifier; Wearable uses
  /// WearableClient's devId so a single device maps to a single RC user.
  Future<void> configure({
    required String? appUserId,
    LogLevel logLevel = LogLevel.warn,
  }) async {
    if (_configured) return;

    try {
      await Purchases.setLogLevel(logLevel);
      final key = _WearableRcKeys.resolve(isRelease: kReleaseMode);

      final config = PurchasesConfiguration(key);
      if (appUserId != null && appUserId.isNotEmpty) {
        config.appUserID = appUserId;
      }
      await Purchases.configure(config);

      // Listen for customer info updates (purchase completes, sync from
      // another device, renewals processed server-side, etc.) and push
      // into our ChangeNotifier stream so widgets rebuild automatically.
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfoUpdated);

      _configured = true;

      // Fire-and-forget initial fetches so the app has state on first
      // frame. Don't await — let the UI show unknown/loading until they
      // resolve.
      unawaited(_refresh());
    } on PlatformException catch (e) {
      _lastError = WearableSubscriptionError.fromPlatform(e);
      debugPrint('WearableSubscription configure failed: $_lastError');
      rethrow;
    }
  }

  void _onCustomerInfoUpdated(CustomerInfo info) {
    _customerInfo = info;
    _lastError = null;
    notifyListeners();
  }

  /// Refresh both customer info and offerings. Safe to call repeatedly.
  Future<void> _refresh() async {
    await Future.wait([
      _fetchCustomerInfo(),
      _fetchOfferings(),
    ]);
    notifyListeners();
  }

  Future<CustomerInfo?> _fetchCustomerInfo() async {
    try {
      _customerInfo = await Purchases.getCustomerInfo();
      return _customerInfo;
    } on PlatformException catch (e) {
      _lastError = WearableSubscriptionError.fromPlatform(e);
      return null;
    }
  }

  Future<Offerings?> _fetchOfferings() async {
    try {
      _offerings = await Purchases.getOfferings();
      return _offerings;
    } on PlatformException catch (e) {
      _lastError = WearableSubscriptionError.fromPlatform(e);
      return null;
    }
  }

  /// Manually refresh customer info from the server. Use after a purchase
  /// completes via a non-SDK path (receipt validation webhook, etc.).
  Future<void> refreshCustomerInfo() async {
    if (!_configured) return;
    await _fetchCustomerInfo();
    notifyListeners();
  }

  /// Manually refresh offerings (call when the dashboard config changes).
  Future<void> refreshOfferings() async {
    if (!_configured) return;
    await _fetchOfferings();
    notifyListeners();
  }

  /// Look up a package by its known identifier in the current offering.
  /// Returns null if the offering or package isn't configured yet.
  Package? packageById(String packageId) {
    final current = currentOffering;
    if (current == null) return null;
    for (final p in current.availablePackages) {
      if (p.identifier == packageId) return p;
    }
    return null;
  }

  Package? get lifetimePackage => packageById(WearablePackageIds.lifetime);
  Package? get yearlyPackage => packageById(WearablePackageIds.yearly);
  Package? get monthlyPackage => packageById(WearablePackageIds.monthly);

  /// Purchase the supplied package. On success, [hasPro] flips to true
  /// via the customer-info update listener. Throws WearableSubscriptionError
  /// on failure (caller should surface the message in a snackbar/dialog).
  Future<CustomerInfo> purchasePackage(Package package) async {
    _ensureConfigured();
    try {
      final result = await Purchases.purchasePackage(package);
      _customerInfo = result.customerInfo;
      _lastError = null;
      notifyListeners();
      return result.customerInfo;
    } on PlatformException catch (e) {
      final err = WearableSubscriptionError.fromPlatform(e);
      _lastError = err;
      notifyListeners();
      throw err;
    }
  }

  /// Restore previous purchases (e.g. after reinstall or new device login).
  Future<CustomerInfo> restorePurchases() async {
    _ensureConfigured();
    try {
      final result = await Purchases.restorePurchases();
      _customerInfo = result;
      _lastError = null;
      notifyListeners();
      return result;
    } on PlatformException catch (e) {
      final err = WearableSubscriptionError.fromPlatform(e);
      _lastError = err;
      notifyListeners();
      throw err;
    }
  }

  /// Swap the app user id (e.g. when the user signs into a different
  /// account). Merges or aliases server-side depending on RC project
  /// config. Anonymous-to-identified flows return mergeableSubscription
  /// aliased customer info.
  Future<CustomerInfo> identifyUser(String appUserId) async {
    _ensureConfigured();
    try {
      final result = await Purchases.logIn(appUserId);
      _customerInfo = result.customerInfo;
      _lastError = null;
      notifyListeners();
      return result.customerInfo;
    } on PlatformException catch (e) {
      final err = WearableSubscriptionError.fromPlatform(e);
      _lastError = err;
      notifyListeners();
      throw err;
    }
  }

  /// Sign the current user out. Resets to an anonymous RC user.
  Future<CustomerInfo> signOut() async {
    _ensureConfigured();
    try {
      final result = await Purchases.logOut();
      _customerInfo = result;
      _lastError = null;
      notifyListeners();
      return result;
    } on PlatformException catch (e) {
      final err = WearableSubscriptionError.fromPlatform(e);
      _lastError = err;
      notifyListeners();
      throw err;
    }
  }

  void _ensureConfigured() {
    if (!_configured) {
      throw WearableSubscriptionError(
        'NOT_CONFIGURED',
        'WearableSubscriptionService.configure() must be called before any purchase operation.',
      );
    }
  }

  @override
  void dispose() {
    // Service is a process-lifetime singleton; dispose is a no-op.
    // Keep the override to satisfy ChangeNotifier contract.
    super.dispose();
  }
}
