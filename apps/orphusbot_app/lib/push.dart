// Push notifications on Android through UnifiedPush (DESIGN §12, D-041): the
// ntfy app is the distributor, connected to OrphusBot's own ntfy server. It
// hands us an endpoint, which the server posts every push to as JSON; we
// show it as our own notification, and a tap opens that bot.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'api.dart';

final _notes = FlutterLocalNotificationsPlugin();
var _ready = false;

const _channel = AndroidNotificationDetails(
  'bots',
  'Bots',
  channelDescription: 'When a bot needs you, finishes or fails',
  importance: Importance.high,
  priority: Priority.high,
);

Future<void> _init(void Function(String bot)? open) async {
  if (_ready) return;
  _ready = true;
  await _notes.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (r) {
      final bot = r.payload;
      if (bot != null && bot.isNotEmpty) open?.call(bot);
    },
  );
}

/// Shows one push from the server: `{title, body, bot, priority}`.
Future<void> _show(PushMessage m) async {
  // ponytail: the payload isn't Web Push encrypted; it only crosses our own
  // ntfy over TLS. Encrypt with the endpoint's pubKeySet if a public distributor is used.
  final msg = jsonDecode(utf8.decode(m.content)) as Map<String, dynamic>;
  await _init(null);
  await _notes.show(
    id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
    title: msg['title'] as String?,
    body: msg['body'] as String?,
    notificationDetails: const NotificationDetails(android: _channel),
    payload: msg['bot'] as String?,
  );
}

/// Starts push on Android. Returns a note for the owner when it can't (no
/// distributor installed), else null. [open] is called with a bot's slug
/// when a notification is tapped, including the one that launched the app.
Future<String?> startPush(Api api, void Function(String bot) open) async {
  if (!Platform.isAndroid) return null;
  await _init(open);
  await _notes
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
  final launch = await _notes.getNotificationAppLaunchDetails();
  final bot = launch?.notificationResponse?.payload;
  if ((launch?.didNotificationLaunchApp ?? false) && bot != null) open(bot);

  await UnifiedPush.initialize(
    onNewEndpoint: (e, _) => api.post('/api/push', {'endpoint': e.url}),
    onMessage: (m, _) => _show(m),
  );
  if (!await UnifiedPush.tryUseCurrentOrDefaultDistributor()) {
    final found = await UnifiedPush.getDistributors();
    if (found.isEmpty) {
      return 'For notifications on this phone, install the ntfy app, '
          'then open OrphusBot again.';
    }
    await UnifiedPush.saveDistributor(found.first);
  }
  await UnifiedPush.register();
  return null;
}
