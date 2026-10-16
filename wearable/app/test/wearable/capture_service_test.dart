// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for CaptureService — the Dart half of the foreground service that keeps
// this process out of Android's "cached" state while the wearable streams.
//
// The properties worth pinning are all about not making things worse: the
// bridge must never be taken down because the service failed, start/stop must
// be idempotent so repeated attaches do not stack calls, and a platform without
// the native side must be a no-op rather than an exception.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wearable/capture_service');
  final calls = <String>[];

  void handle(Future<Object?>? Function(MethodCall)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    calls.clear();
    handle((call) async {
      calls.add(call.method);
      return true;
    });
  });

  tearDown(() async {
    handle(null);
    await CaptureService.instance.stop();
  });

  test('is a no-op off Android', () async {
    CaptureService.debugBypassPlatformCheck = false;
    addTearDown(() => CaptureService.debugBypassPlatformCheck = true);
    await CaptureService.instance.start();
    expect(calls, isEmpty, reason: 'touched the platform channel off Android');
    expect(CaptureService.instance.isRunning, isFalse);
  }, skip: Platform.isAndroid ? 'guard is a no-op on Android' : false);

  group('when enabled', () {
    setUp(() async {
      CaptureService.debugBypassPlatformCheck = true;
      await CaptureService.instance.stop();
      calls.clear();
    });
    tearDown(() => CaptureService.debugBypassPlatformCheck = false);

    test('start invokes the channel once and marks itself running', () async {
      await CaptureService.instance.start();
      expect(calls, ['start']);
      expect(CaptureService.instance.isRunning, isTrue);
    });

    test('start is idempotent — a second attach does not stack calls', () async {
      await CaptureService.instance.start();
      await CaptureService.instance.start();
      await CaptureService.instance.start();
      expect(calls, ['start']);
    });

    test('stop invokes the channel and clears running', () async {
      await CaptureService.instance.start();
      calls.clear();
      await CaptureService.instance.stop();
      expect(calls, ['stop']);
      expect(CaptureService.instance.isRunning, isFalse);
    });

    test('stop without start does nothing', () async {
      await CaptureService.instance.stop();
      expect(calls, isEmpty);
    });

    test('a native failure never throws — the bridge must survive it', () async {
      handle((call) async {
        calls.add(call.method);
        throw PlatformException(code: 'START_FAILED', message: 'denied');
      });
      await expectLater(CaptureService.instance.start(), completes);
      expect(calls, ['start']);
      // Left not-running, so a later attach retries rather than assuming
      // a service that never started is alive.
      expect(CaptureService.instance.isRunning, isFalse);
    });

    test('a missing native side is tolerated, not fatal', () async {
      handle((call) async {
        calls.add(call.method);
        throw MissingPluginException('no impl');
      });
      await expectLater(CaptureService.instance.start(), completes);
      expect(CaptureService.instance.isRunning, isFalse);
    });

    test('stop clears running even when the native call fails', () async {
      await CaptureService.instance.start();
      handle((call) async {
        throw PlatformException(code: 'STOP_FAILED', message: 'boom');
      });
      await expectLater(CaptureService.instance.stop(), completes);
      expect(CaptureService.instance.isRunning, isFalse,
          reason: 'a failed stop must not wedge the flag on');
    });
  });
}
