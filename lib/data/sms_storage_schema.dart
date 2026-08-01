import 'package:sqflite/sqflite.dart';

class SmsStorageSchema {
  const SmsStorageSchema._();

  static const createTransactionsTable = '''
CREATE TABLE IF NOT EXISTS transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sms_id TEXT NOT NULL UNIQUE,
  sender TEXT NOT NULL,
  direction TEXT NOT NULL,
  instrument TEXT NOT NULL,
  type TEXT NOT NULL,
  amount_paise INTEGER NOT NULL,
  txn_date INTEGER NOT NULL,
  txn_local_date TEXT NOT NULL,
  txn_month TEXT NOT NULL,
  effective_month TEXT,
  account_last4 TEXT,
  merchant TEXT,
  upi_vpa_norm TEXT,
  payee_type TEXT NOT NULL,
  category_key TEXT NOT NULL,
  confidence REAL NOT NULL,
  needs_review INTEGER NOT NULL,
  review_status TEXT NOT NULL,
  review_reason TEXT,
  auto_added_at INTEGER,
  scan_batch_id TEXT NOT NULL,
  collision_set_id TEXT,
  source TEXT NOT NULL,
  ref_number TEXT,
  balance_paise INTEGER,
  owner_key TEXT,
  coverage_bucket TEXT NOT NULL,
  raw_body_redacted TEXT NOT NULL,
  body_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  CHECK ((review_status = 'needs_review' AND needs_review = 1) OR (review_status != 'needs_review' AND needs_review = 0))
);
''';

  static const createObligationsTable = '''
CREATE TABLE IF NOT EXISTS obligations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type TEXT NOT NULL,
  source_id TEXT,
  dedupe_key TEXT NOT NULL,
  merchant TEXT NOT NULL,
  merchant_norm TEXT NOT NULL,
  category_key TEXT NOT NULL,
  amount_paise INTEGER,
  amount_status TEXT NOT NULL,
  recurrence TEXT NOT NULL,
  due_date INTEGER,
  due_day INTEGER,
  due_month INTEGER,
  payment_account_hint_last4 TEXT,
  payment_account_scope TEXT NOT NULL,
  amount_paid_paise INTEGER,
  outstanding_paise INTEGER,
  payment_status TEXT NOT NULL,
  next_expected_source TEXT NOT NULL,
  upi_vpa_norm TEXT,
  payee_type TEXT NOT NULL,
  user_cadence_status TEXT NOT NULL,
  confidence REAL NOT NULL,
  review_status TEXT NOT NULL,
  reserve_enabled INTEGER NOT NULL DEFAULT 0,
  reserve_funded_paise INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

  /// Small key/value store for per-install metadata (e.g. the body-hash salt).
  static const createMetaTable = '''
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

  /// Local, user-editable self-transfer allow-list (decision D12). Backup-
  /// excluded like the rest of `transactions.db`. Seeded from salary/secondary
  /// anchors and user "this is my account" decisions; survives across scans.
  static const createKnownAccountsTable = '''
CREATE TABLE IF NOT EXISTS known_accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  last4 TEXT,
  vpa_norm TEXT,
  label TEXT NOT NULL,
  origin TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
''';

  /// Risk and planning decision state for forecast obligations, keyed by owner
  /// and target month. Used by reserve planner and user-driven confirmations.
  static const createForecastRiskDecisionsTable = '''
CREATE TABLE IF NOT EXISTS forecast_risk_decisions (
  owner_key TEXT NOT NULL,
  target_month TEXT NOT NULL,
  status TEXT NOT NULL,
  amount_override_paise INTEGER,
  due_date_override INTEGER,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (owner_key, target_month)
);
''';

  static const indexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_transactions_txn_date ON transactions(txn_date);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_txn_local_date ON transactions(txn_local_date);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_txn_month ON transactions(txn_month);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_category_key ON transactions(category_key);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_review_status ON transactions(review_status);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_scan_batch_id ON transactions(scan_batch_id);',
    'CREATE INDEX IF NOT EXISTS idx_transactions_ref ON transactions(ref_number);',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_obligations_dedupe_key ON obligations(dedupe_key);',
    'CREATE INDEX IF NOT EXISTS idx_known_accounts_last4 ON known_accounts(last4);',
    'CREATE INDEX IF NOT EXISTS idx_known_accounts_vpa_norm ON known_accounts(vpa_norm);',
  ];

  /// Incremental schema migrations keyed by the version they upgrade *to*, run
  /// in ascending order by [SmsDatabase]'s `onUpgrade` via [applyMigration].
  /// Every schema-version bump adds an entry here and a case in
  /// `sms_migration_test.dart`.
  ///
  /// **v2** adds the additions made after the original v1 shipped: the A2
  /// `meta` table (per-install body-hash salt), the A5 `ref_number` index
  /// (indexed dedup), and the D4 `known_accounts` table + its indexes
  /// (self-transfer allow-list).
  ///
  /// **v3** adds reserve progress tracking (`reserve_enabled`,
  /// `reserve_funded_paise`) to obligations and the `forecast_risk_decisions`
  /// table for user-driven confirmations and risk planning.
  ///
  /// Every step is idempotent: plain statements all use `IF NOT EXISTS`, and
  /// the two column additions — which SQLite cannot express that way — go
  /// through [MigrationStep.addColumn] so [applyMigration] skips them when the
  /// column is already present. Re-running any migration is therefore safe,
  /// which is what lets a database whose version was written down by an older
  /// build heal itself on the next forward open.
  static const migrations = <int, List<MigrationStep>>{
    2: [
      MigrationStep(createMetaTable),
      MigrationStep(createKnownAccountsTable),
      MigrationStep(
        'CREATE INDEX IF NOT EXISTS idx_transactions_ref ON transactions(ref_number);',
      ),
      MigrationStep(
        'CREATE INDEX IF NOT EXISTS idx_known_accounts_last4 ON known_accounts(last4);',
      ),
      MigrationStep(
        'CREATE INDEX IF NOT EXISTS idx_known_accounts_vpa_norm ON known_accounts(vpa_norm);',
      ),
    ],
    3: [
      MigrationStep.addColumn(
        table: 'obligations',
        column: 'reserve_enabled',
        sql:
            'ALTER TABLE obligations ADD COLUMN reserve_enabled INTEGER NOT NULL DEFAULT 0;',
      ),
      MigrationStep.addColumn(
        table: 'obligations',
        column: 'reserve_funded_paise',
        sql:
            'ALTER TABLE obligations ADD COLUMN reserve_funded_paise INTEGER NOT NULL DEFAULT 0;',
      ),
      MigrationStep(createForecastRiskDecisionsTable),
      MigrationStep(
        'CREATE INDEX IF NOT EXISTS idx_forecast_risk_target_month ON forecast_risk_decisions(target_month);',
      ),
    ],
  };

  /// Runs every step registered for [version]. Missing versions fail loudly
  /// rather than leaving the schema half-migrated.
  static Future<void> applyMigration(DatabaseExecutor db, int version) async {
    final steps = migrations[version];
    if (steps == null) {
      throw StateError(
        'No SMS database migration is registered for schema version $version.',
      );
    }
    for (final step in steps) {
      await _applyStep(db, step);
    }
  }

  static Future<void> _applyStep(DatabaseExecutor db, MigrationStep step) async {
    final column = step.column;
    if (column != null && await _hasColumn(db, step.table!, column)) return;
    await db.execute(step.sql);
  }

  static Future<bool> _hasColumn(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    // `PRAGMA table_info` cannot take a `?` placeholder for the table name, so
    // it has to be interpolated. Safe here: every table name comes from a
    // compile-time literal in [migrations], never from user input.
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.any((row) => row['name'] == column);
  }
}

/// One statement in a schema migration.
///
/// Plain steps must be written idempotently (`CREATE ... IF NOT EXISTS`) so a
/// migration can be re-applied safely. SQLite has no
/// `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so column additions instead
/// declare the [table] and [column] they add and are skipped by
/// `SmsStorageSchema.applyMigration` when that column already exists.
class MigrationStep {
  const MigrationStep(this.sql) : table = null, column = null;

  const MigrationStep.addColumn({
    required String this.table,
    required String this.column,
    required this.sql,
  });

  final String sql;
  final String? table;
  final String? column;
}
