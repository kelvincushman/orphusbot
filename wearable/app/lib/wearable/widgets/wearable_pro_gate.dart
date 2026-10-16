// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableProGate — declarative widget that gates child content behind the
// Wearable Pro entitlement. On unentitled users, presents the RevenueCat
// paywall UI; on entitled users, renders the child.
//
// Usage:
//   WearableProGate(
//     child: ProFeatureScreen(),
//     lockedChild: BasicFeatureScreen(), // optional — defaults to a CTA card
//   )
//
// Pairs with showWearablePaywall() / presentWearablePaywallIfNeeded() for imperative
// flows (e.g. "Buy" button on a dedicated page).

import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:provider/provider.dart';

import '../wearable_theme.dart';
import '../services/wearable_subscription_service.dart';

/// Imperative helper: present the RevenueCat paywall modally. Returns when
/// the user dismisses, purchases, restores, or hits an error. The SDK handles
/// customer info refresh automatically — `WearableSubscriptionService.hasPro`
/// will be up-to-date on resolve.
Future<PaywallResult> showWearablePaywall({
  Offering? offering,
  String? displayCloseButton,
}) async {
  return RevenueCatUI.presentPaywall(
    offering: offering ?? WearableSubscriptionService.instance.currentOffering,
    displayCloseButton: true,
  );
}

/// Present paywall *only* if the user doesn't already have the entitlement.
/// Returns [PaywallResult.notPresented] when the user is already entitled —
/// useful at screen-open time ("if this feature requires Pro, show paywall
/// now, otherwise skip and render content").
Future<PaywallResult> presentWearablePaywallIfNeeded({
  String entitlement = kWearableProEntitlement,
  Offering? offering,
}) async {
  return RevenueCatUI.presentPaywallIfNeeded(
    entitlement,
    offering: offering ?? WearableSubscriptionService.instance.currentOffering,
    displayCloseButton: true,
  );
}

/// Present the Customer Center — subscription management, restore purchases,
/// cancellation flow, receipt inspection, etc. RC renders this entirely from
/// the dashboard config.
Future<void> showWearableCustomerCenter() async {
  return RevenueCatUI.presentCustomerCenter();
}

class WearableProGate extends StatelessWidget {
  const WearableProGate({
    super.key,
    required this.child,
    this.lockedChild,
    this.lockedCta = 'Unlock Wearable Pro',
    this.lockedMessage = 'This feature requires a Wearable Pro subscription.',
  });

  /// Rendered when the user has the Pro entitlement.
  final Widget child;

  /// Optional: widget to render for unentitled users. Defaults to a card
  /// with the paywall-launching button.
  final Widget? lockedChild;

  /// CTA label for the default locked-state card.
  final String lockedCta;

  /// Description shown above the CTA.
  final String lockedMessage;

  @override
  Widget build(BuildContext context) {
    return Consumer<WearableSubscriptionService>(
      builder: (context, svc, _) {
        if (!svc.isConfigured) {
          // SDK still initialising — show a small loader rather than
          // flashing the paywall briefly.
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (svc.hasPro) return child;
        return lockedChild ?? _DefaultLockedCard(
          message: lockedMessage,
          ctaLabel: lockedCta,
        );
      },
    );
  }
}

class _DefaultLockedCard extends StatelessWidget {
  const _DefaultLockedCard({required this.message, required this.ctaLabel});
  final String message;
  final String ctaLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 36, color: WearableColors.primary),
                const SizedBox(height: 12),
                Text('Wearable Pro required',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () async {
                    await showWearablePaywall();
                  },
                  icon: const Icon(Icons.star_outline),
                  label: Text(ctaLabel),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await WearableSubscriptionService.instance.restorePurchases();
                      if (!context.mounted) return;
                      if (WearableSubscriptionService.instance.hasPro) {
                        messenger.showSnackBar(const SnackBar(
                          content: Text('Purchases restored.'),
                        ));
                      } else {
                        messenger.showSnackBar(const SnackBar(
                          content: Text('No previous Pro purchases found.'),
                        ));
                      }
                    } on WearableSubscriptionError catch (e) {
                      if (!context.mounted) return;
                      messenger.showSnackBar(SnackBar(content: Text(e.message)));
                    }
                  },
                  child: const Text('Restore purchases'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
