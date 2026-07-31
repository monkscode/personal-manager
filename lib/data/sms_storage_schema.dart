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
  /// in ascending order by [SmsDatabase]'s `onUpgrade`. Every schema-version
  /// bump adds an entry here and a case in `sms_migration_test.dart`.
  ///
  /// **v2** adds the additions made after the original v1 shipped: the A2
  /// `meta` table (per-install body-hash salt), the A5 `ref_number` index
  /// (indexed dedup), and the D4 `known_accounts` table + its indexes
  /// (self-transfer allow-list). All statements are idempotent (`IF NOT
  ///
  /// **v3** adds reserve progress tracking (`reserve_enabled`,
  /// `reserve_funded_paise`) to obligations and the `forecast_risk_decisions`
  /// table for user-driven confirmations and risk planning.
  static const migrations = <int, List<String>>{
    2: [
      createMetaTable,
      createKnownAccountsTable,
      'CREATE INDEX IF NOT EXISTS idx_transactions_ref ON transactions(ref_number);',
      'CREATE INDEX IF NOT EXISTS idx_known_accounts_last4 ON known_accounts(last4);',
      'CREATE INDEX IF NOT EXISTS idx_known_accounts_vpa_norm ON known_accounts(vpa_norm);',
    ],
    3: [
      'ALTER TABLE obligations ADD COLUMN reserve_enabled INTEGER NOT NULL DEFAULT 0;',
      'ALTER TABLE obligations ADD COLUMN reserve_funded_paise INTEGER NOT NULL DEFAULT 0;',
      createForecastRiskDecisionsTable,
      'CREATE INDEX IF NOT EXISTS idx_forecast_risk_target_month ON forecast_risk_decisions(target_month);',
    ],
  };
}
