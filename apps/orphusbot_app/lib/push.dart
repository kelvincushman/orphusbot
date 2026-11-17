// Push notifications on Android through UnifiedPush (DESIGN §12, D-041): the
// ntfy app is the distributor, connected to OrphusBot's own ntfy server. It
// hands us an endpoint, which the server posts every push to as JSON; we
// show it as our own notification, and a tap opens that bot.
//
// On Linux and macOS (D-079) the open app already holds the event stream, and
// the server sends each push on it too, as a live `push` event; the app shows
// it as a system notification (on Linux over D-Bus to the notification
// daemon), and a click opens that bot.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'api.dart';

final _notes = FlutterLocalNotificationsPlugin();
Future<void>? _ready;

const _channel = AndroidNotificationDetails(
  'bots',
  'Bots',
  channelDescription: 'When a bot needs you, finishes or fails',
  importance: Importance.high,
  priority: Priority.high,
);

// A new id each time, so one notification never replaces another.
var _id = DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000;

// Once; a notification shown meanwhile waits for it.
Future<void> _init(void Function(String bot)? open) =>
    _ready ??= _notes.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        // The `orphusbot` icon the app installs in the hicolor theme.
        linux: LinuxInitializationSettings(
          defaultActionName: 'Open',
          defaultIcon: ThemeLinuxIcon('orphusbot'),
        ),
        // Initialising asks the owner for permission, once.
        macOS: const DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (r) {
        final bot = r.payload;
        if (bot != null && bot.isNotEmpty) open?.call(bot);
      },
    );

/// Shows one push from the server: `{title, body, bot, priority}`.
Future<void> _show(PushMessage m) async {
  // ponytail: the payload isn't Web Push encrypted; it only crosses our own
  // ntfy over TLS. Encrypt with the endpoint's pubKeySet if a public distributor is used.
  final msg = jsonDecode(utf8.decode(m.content)) as Map<String, dynamic>;
  await _init(null);
  await _notes.show(
    id: _id++,
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
  if (_desktop) {
    await _init(open);
    return null;
  }
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

/// Where `push` events become notifications. Android has UnifiedPush, which
/// works with the app closed, so the event would only be a duplicate there.
final _desktop = Platform.isLinux || Platform.isMacOS;

/// Shows a notification; the plugin in the app, a fake in tests.
typedef ShowNote = Future<void> Function(
  String title,
  String body,
  String? bot,
  int priority,
);

/// Whether a `push` event about [bot] becomes a notification: on a desktop,
/// unless the window is focused with that bot's chat ([open]) showing.
bool shouldNotify({
  required bool desktop,
  required bool focused,
  required String? bot,
  required String open,
}) => desktop && !(focused && bot == open);

/// Shows a `push` event from the server (`{bot?, title, body, priority}`) as a
/// system notification, if [shouldNotify] says so. [open] is the bot whose
/// chat is showing.
Future<void> showPush(
  Map<String, dynamic> e, {
  required String open,
  bool? desktop,
  bool? focused,
  ShowNote? show,
}) async {
  final bot = e['bot'] as String?;
  final yes = shouldNotify(
    desktop: desktop ?? _desktop,
    focused:
        focused ??
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    bot: bot,
    open: open,
  );
  if (!yes) return;
  await (show ?? _showDesktop)(
    e['title'] as String? ?? '',
    e['body'] as String? ?? '',
    bot,
    e['priority'] as int? ?? 3,
  );
}

Future<void> _showDesktop(
  String title,
  String body,
  String? bot,
  int priority,
) async {
  await _init(null);
  await _notes.show(
    id: _id++,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      linux: LinuxNotificationDetails(
        // What needs the owner (4 and 5) stays until it is seen.
        urgency: priority >= 4
            ? LinuxNotificationUrgency.critical
            : priority <= 2
            ? LinuxNotificationUrgency.low
            : LinuxNotificationUrgency.normal,
      ),
    ),
    payload: bot,
  );
}
