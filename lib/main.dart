import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'app.dart';
import 'data/app_controller.dart';
import 'data/sms_database.dart';
import 'data/transactions_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Best-effort open of the local transactions DB. On platforms without SMS
  // (iOS) or if the open fails, the snapshot stays empty and the app keeps its
  // existing manual/Gmail behavior — no crash.
  Database? db;
  try {
    db = await SmsDatabase.open();
  } catch (_) {
    db = null;
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        smsDatabaseProvider.overrideWithValue(db),
      ],
      child: const ExpenseInsightApp(),
    ),
  );
}
