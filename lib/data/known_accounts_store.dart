import 'package:sqflite/sqflite.dart';

/// Allowed provenance values for a known own account (decision D12).
const Set<String> kKnownAccountOrigins = {
  'salary_anchor',
  'secondary_anchor',
  'manual_label',
  'user_marked',
};

/// A single user-owned account / VPA in the self-transfer allow-list.
class KnownAccount {
  const KnownAccount({
    required this.label,
    required this.origin,
    required this.createdAt,
    this.id,
    this.last4,
    this.vpaNorm,
  });

  final int? id;
  final String? last4;
  final String? vpaNorm;
  final String label;
  final String origin;
  final DateTime createdAt;
}

/// An immutable snapshot of the known-accounts allow-list with fast membership
/// checks used by the payee classifier.
class KnownAccounts {
  KnownAccounts(this.accounts)
    : _last4s = {
        for (final a in accounts)
          if (a.last4 != null) a.last4!,
      },
      _vpaNorms = {
        for (final a in accounts)
          if (a.vpaNorm != null) a.vpaNorm!,
      };

  final List<KnownAccount> accounts;
  final Set<String> _last4s;
  final Set<String> _vpaNorms;

  Set<String> get last4s => _last4s;
  Set<String> get vpaNorms => _vpaNorms;

  bool containsLast4(String? last4) => last4 != null && _last4s.contains(last4);

  bool containsVpa(String? vpaNorm) =>
      vpaNorm != null && _vpaNorms.contains(vpaNorm.toLowerCase());

  /// Whether either identifier belongs to a known own account.
  bool isOwn({String? last4, String? vpaNorm}) =>
      containsLast4(last4) || containsVpa(vpaNorm);
}

/// Local, user-editable persistence for the self-transfer allow-list (D12),
/// stored in the backup-excluded `transactions.db`.
class KnownAccountsStore {
  const KnownAccountsStore(this._db);

  final Database _db;

  Future<KnownAccounts> load() async {
    final rows = await _db.query('known_accounts', orderBy: 'id ASC');
    return KnownAccounts(rows.map(_fromRow).toList(growable: false));
  }

  /// Adds an own account, keyed by [last4] and/or [vpaNorm] (at least one is
  /// required). Idempotent: an account whose identifiers are all already
  /// recorded is not duplicated. [origin] must be one of
  /// [kKnownAccountOrigins].
  ///
  /// When only *some* of the identifiers are known, the missing ones are merged
  /// into the matching row rather than dropped. The match is an `OR`, so adding
  /// an account with both a last4 and a VPA used to match on the last4 alone and
  /// return, and the VPA was never stored — after which the classifier read the
  /// user's own transfers to that VPA as spend (TASK-27 M3).
  Future<void> addOwnAccount({
    String? last4,
    String? vpaNorm,
    required String label,
    required String origin,
    DateTime? now,
  }) async {
    if (!kKnownAccountOrigins.contains(origin)) {
      throw ArgumentError.value(origin, 'origin', 'unknown origin');
    }
    final normalizedVpa = vpaNorm?.toLowerCase();
    if ((last4 == null || last4.isEmpty) &&
        (normalizedVpa == null || normalizedVpa.isEmpty)) {
      throw ArgumentError('An own account needs a last4 or a VPA');
    }

    final newLast4 = (last4 != null && last4.isNotEmpty) ? last4 : null;
    final newVpa = (normalizedVpa != null && normalizedVpa.isNotEmpty)
        ? normalizedVpa
        : null;

    await _db.transaction((txn) async {
      final existing = await txn.query(
        'known_accounts',
        where: _matchWhere(last4, normalizedVpa),
        whereArgs: _matchArgs(last4, normalizedVpa),
      );

      // Every identifier this call carries that some matched row already holds.
      final last4Known =
          newLast4 == null || existing.any((r) => r['last4'] == newLast4);
      final vpaKnown =
          newVpa == null || existing.any((r) => r['vpa_norm'] == newVpa);
      if (last4Known && vpaKnown) return;

      // A matched row can absorb the missing identifier only if its own column
      // is empty. One that already names a different account keeps it, and the
      // new identifier gets its own row — overwriting would lose the first,
      // returning early would lose the second.
      Map<String, Object?>? absorber;
      for (final row in existing) {
        final canTakeLast4 = last4Known || row['last4'] == null;
        final canTakeVpa = vpaKnown || row['vpa_norm'] == null;
        if (canTakeLast4 && canTakeVpa) {
          absorber = row;
          break;
        }
      }

      if (absorber != null) {
        await txn.update(
          'known_accounts',
          {
            'last4': absorber['last4'] ?? newLast4,
            'vpa_norm': absorber['vpa_norm'] ?? newVpa,
          },
          where: 'id = ?',
          whereArgs: [absorber['id']],
        );
        return;
      }

      await txn.insert('known_accounts', {
        'last4': newLast4,
        'vpa_norm': newVpa,
        'label': label,
        'origin': origin,
        'created_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      });
    });
  }

  /// Removes any own account matching [last4] and/or [vpaNorm].
  Future<int> remove({String? last4, String? vpaNorm}) async {
    final normalizedVpa = vpaNorm?.toLowerCase();
    if ((last4 == null || last4.isEmpty) &&
        (normalizedVpa == null || normalizedVpa.isEmpty)) {
      throw ArgumentError('remove needs a last4 or a VPA');
    }
    return _db.delete(
      'known_accounts',
      where: _matchWhere(last4, normalizedVpa),
      whereArgs: _matchArgs(last4, normalizedVpa),
    );
  }

  String _matchWhere(String? last4, String? vpaNorm) {
    final clauses = <String>[];
    if (last4 != null && last4.isNotEmpty) clauses.add('last4 = ?');
    if (vpaNorm != null && vpaNorm.isNotEmpty) clauses.add('vpa_norm = ?');
    return clauses.join(' OR ');
  }

  List<Object?> _matchArgs(String? last4, String? vpaNorm) => [
    if (last4 != null && last4.isNotEmpty) last4,
    if (vpaNorm != null && vpaNorm.isNotEmpty) vpaNorm,
  ];

  KnownAccount _fromRow(Map<String, Object?> row) => KnownAccount(
    id: row['id'] as int?,
    last4: row['last4'] as String?,
    vpaNorm: row['vpa_norm'] as String?,
    label: row['label']! as String,
    origin: row['origin']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
  );
}
