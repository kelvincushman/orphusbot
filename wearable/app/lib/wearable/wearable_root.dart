// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableRoot — the app shell.
//
// There is deliberately NO gate here. The app's job is to pair to the wearable
// over BLE and transcribe on-device with Gemma; none of that needs a server.
// Pairing to a Wearable server is optional enrichment — it pushes transcripts
// onward and backs the tasks/hive views — and it lives in Settings, where
// optional things belong.
//
// This used to boot into a page demanding a base URL and a bearer token before
// it would show anything at all, which put the BLE scan flow behind a server
// the wearer may not run. Its own comment claimed "with no server credentials
// there is nothing for the app to show"; that stopped being true when
// transcription moved on-device.

import 'package:flutter/material.dart';

import 'wearable_home_page.dart';

class WearableRoot extends StatelessWidget {
  const WearableRoot({super.key});

  @override
  Widget build(BuildContext context) => const WearableHomePage();
}
