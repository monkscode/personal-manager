import 'package:expense_insight/data/sms_storage_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmsStorageSchema', () {
    test(
      'transactions table includes production audit, review, money, and privacy columns',
      () {
        final sql = SmsStorageSchema.createTransactionsTable;

        for (final column in [
          'sms_id TEXT NOT NULL UNIQUE',
          'amount_paise INTEGER NOT NULL',
          'txn_local_date TEXT NOT NULL',
          'txn_month TEXT NOT NULL',
          'needs_review INTEGER NOT NULL',
          'review_status TEXT NOT NULL',
          "CHECK ((review_status = 'needs_review' AND needs_review = 1) OR (review_status != 'needs_review' AND needs_review = 0))",
          'review_reason TEXT',
          'auto_added_at INTEGER',
          'scan_batch_id TEXT NOT NULL',
          'collision_set_id TEXT',
          'raw_body_redacted TEXT NOT NULL',
          'body_hash TEXT NOT NULL',
        ]) {
          expect(sql, contains(column));
        }
      },
    );

    test(
      'obligations table captures durable identity and reviewable missing amount state',
      () {
        final sql = SmsStorageSchema.createObligationsTable;

        for (final column in [
          'source_type TEXT NOT NULL',
          'source_id TEXT',
          'dedupe_key TEXT NOT NULL',
          'amount_paise INTEGER',
          'amount_status TEXT NOT NULL',
          'due_month INTEGER',
          'payment_status TEXT NOT NULL',
          'review_status TEXT NOT NULL',
        ]) {
          expect(sql, contains(column));
        }
      },
    );

    test(
      'indexes include month, date, category, review status, and scan batch lookups',
      () {
        expect(
          SmsStorageSchema.indexStatements,
          contains(
            'CREATE INDEX IF NOT EXISTS idx_transactions_txn_month ON transactions(txn_month);',
          ),
        );
        expect(
          SmsStorageSchema.indexStatements,
          contains(
            'CREATE INDEX IF NOT EXISTS idx_transactions_txn_local_date ON transactions(txn_local_date);',
          ),
        );
        expect(
          SmsStorageSchema.indexStatements,
          contains(
            'CREATE INDEX IF NOT EXISTS idx_transactions_category_key ON transactions(category_key);',
          ),
        );
        expect(
          SmsStorageSchema.indexStatements,
          contains(
            'CREATE INDEX IF NOT EXISTS idx_transactions_review_status ON transactions(review_status);',
          ),
        );
        expect(
          SmsStorageSchema.indexStatements,
          contains(
            'CREATE INDEX IF NOT EXISTS idx_transactions_scan_batch_id ON transactions(scan_batch_id);',
          ),
        );
      },
    );
  });
}
