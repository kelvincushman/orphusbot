// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSubscriptionPage — dedicated subscription management screen.
// Entry from Settings → Wearable Advanced → "Plan & Subscription".
//
// Shows current entitlement state, offering-driven package list, and wires
// the RevenueCat Customer Center for full subscription management
// (receipt lookup, cancel, change plan, restore).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../wearable_theme.dart';
import '../services/wearable_subscription_service.dart';
import '../widgets/wearable_pro_gate.dart';

class WearableSubscriptionPage extends StatelessWidget {
  const WearableSubscriptionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan & Subscription'),
      ),
      body: Consumer<WearableSubscriptionService>(
        builder: (context, svc, _) {
          if (!svc.isConfigured) {
            return const Center(child: CircularProgressIndicator());
          }

          final offering = svc.currentOffering;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _CurrentTierCard(info: svc.customerInfo, hasPro: svc.hasPro),
              const SizedBox(height: 24),
              if (!svc.hasPro) ...[
                Text('Upgrade to Wearable Pro',
                    style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 8),
                if (offering == null)
                  const _OfferingUnavailable()
                else
                  _PackageGrid(offering: offering),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => _restore(context),
                  icon: const Icon(Icons.history),
                  label: const Text('Restore previous purchases'),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: () => showWearableCustomerCenter(),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Manage subscription'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _restore(context),
                  icon: const Icon(Icons.history),
                  label: const Text('Restore purchases'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WearableSubscriptionService.instance.restorePurchases();
      if (!context.mounted) return;
      final hasPro = WearableSubscriptionService.instance.hasPro;
      messenger.showSnackBar(SnackBar(content: Text(
        hasPro ? 'Purchases restored — Wearable Pro active.'
               : 'No previous Pro purchases found.',
      )));
    } on WearableSubscriptionError catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _CurrentTierCard extends StatelessWidget {
  const _CurrentTierCard({required this.info, required this.hasPro});
  final CustomerInfo? info;
  final bool hasPro;

  @override
  Widget build(BuildContext context) {
    final activeEnt = info?.entitlements.active[kWearableProEntitlement];
    final expires = activeEnt?.expirationDate;
    final willRenew = activeEnt?.willRenew ?? false;
    final store = activeEnt?.store;

    return Card(
      child: ListTile(
        leading: Icon(
          hasPro ? Icons.verified : Icons.person_outline,
          color: hasPro ? WearableColors.primary : WearableColors.mutedFg,
          size: 32,
        ),
        title: Text(
          hasPro ? 'Wearable Pro' : 'Free tier',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        subtitle: hasPro
            ? Text(
                expires == null
                    ? 'Lifetime access · ${_storeName(store)}'
                    : '${willRenew ? "Renews" : "Ends"} $expires · ${_storeName(store)}',
              )
            : const Text('Upgrade to unlock all Wearable features.'),
      ),
    );
  }

  String _storeName(Store? store) {
    switch (store) {
      case Store.appStore: return 'App Store';
      case Store.macAppStore: return 'Mac App Store';
      case Store.playStore: return 'Play Store';
      case Store.stripe: return 'Stripe';
      case Store.promotional: return 'Promotional';
      case Store.amazon: return 'Amazon';
      case Store.rcBilling: return 'RC Billing';
      case Store.paddle: return 'Paddle';
      case Store.unknownStore: return 'Unknown';
      case Store.testStore: return 'Test Store';
      case Store.externalStore: return 'External';
      case Store.galaxy: return 'Galaxy Store';
      case null: return 'Unknown';
    }
  }
}

class _OfferingUnavailable extends StatelessWidget {
  const _OfferingUnavailable();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Offering not available',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'The subscription products could not be loaded right now. '
              'Check your network connection and try again.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                WearableSubscriptionService.instance.refreshOfferings();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackageGrid extends StatelessWidget {
  const _PackageGrid({required this.offering});
  final Offering offering;

  @override
  Widget build(BuildContext context) {
    // Order packages with lifetime first (biggest commitment), then yearly,
    // then monthly. Anything not in the known ID set appears after.
    final ordered = [...offering.availablePackages];
    const priority = {
      WearablePackageIds.lifetime: 0,
      WearablePackageIds.yearly: 1,
      WearablePackageIds.monthly: 2,
    };
    ordered.sort((a, b) {
      final ap = priority[a.identifier] ?? 99;
      final bp = priority[b.identifier] ?? 99;
      return ap.compareTo(bp);
    });

    return Column(
      children: [
        for (final p in ordered) ...[
          _PackageTile(package: p),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: () => showWearablePaywall(offering: offering),
          icon: const Icon(Icons.star),
          label: const Text('See full paywall'),
        ),
      ],
    );
  }
}

class _PackageTile extends StatefulWidget {
  const _PackageTile({required this.package});
  final Package package;

  @override
  State<_PackageTile> createState() => _PackageTileState();
}

class _PackageTileState extends State<_PackageTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final product = widget.package.storeProduct;
    final badge = _badgeFor(widget.package.identifier);
    return Card(
      child: ListTile(
        title: Row(
          children: [
            Expanded(
              child: Text(product.title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (badge != null) _BadgePill(text: badge),
          ],
        ),
        subtitle: Text(product.description,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: _busy
            ? const SizedBox(width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(product.priceString,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: WearableColors.primary,
                        fontWeight: FontWeight.w700)),
        onTap: _busy ? null : _purchase,
      ),
    );
  }

  String? _badgeFor(String id) {
    switch (id) {
      case WearablePackageIds.lifetime: return 'BEST VALUE';
      case WearablePackageIds.yearly: return 'SAVE';
      default: return null;
    }
  }

  Future<void> _purchase() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WearableSubscriptionService.instance.purchasePackage(widget.package);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Welcome to Wearable Pro 🎉'),
      ));
    } on WearableSubscriptionError catch (e) {
      if (!mounted) return;
      if (e.code == PurchasesErrorCode.purchaseCancelledError.name) {
        // User cancelled — don't bother them with a snackbar.
      } else {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: WearableColors.primary.withValues(alpha: 0.15),
        border: Border.all(color: WearableColors.primary),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(
            color: WearableColors.primary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          )),
    );
  }
}
