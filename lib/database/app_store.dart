import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// Settings and small app state, kept in SQLite (table `kv` of localvpn.db).
///
/// Same calls as SharedPreferences, so a service switches with one line.
/// Reads come from memory, loaded once; a write updates memory at once and
/// reaches the database in order, one after another. On the first run the
/// values saved by SharedPreferences are copied in (that file is left as it
/// was). If the database can't be opened the store falls back to
/// SharedPreferences, so nothing is lost either way.
class AppStore {
  AppStore._(this._db, this._prefs, this._values);

  static Future<AppStore>? _instance;

  /// The store, opened on first use.
  static Future<AppStore> instance() => _instance ??= _open();

  /// Tests: start again from [db] (or SharedPreferences' mock when null).
  @visibleForTesting
  static void resetForTests() => _instance = null;

  @visibleForTesting
  static Future<AppStore> openForTests(Database db) =>
      _instance = _openOn(db);

  static const String _importedKey = '__imported_shared_preferences';

  final Database? _db;
  final SharedPreferences? _prefs;
  final Map<String, Object> _values;
  Future<void> _writes = Future.value();

  /// Where values live: 'sqlite', or 'shared_preferences' after a fallback.
  String get backend => _db != null ? 'sqlite' : 'shared_preferences';

  static Future<AppStore> _open() async {
    try {
      return await _openOn(await DatabaseHelper().database);
    } catch (e) {
      debugPrint('AppStore: database unavailable, using SharedPreferences: $e');
      final prefs = await SharedPreferences.getInstance();
      final values = <String, Object>{};
      for (final key in prefs.getKeys()) {
        final v = _normalize(prefs.get(key));
        if (v != null) values[key] = v;
      }
      return AppStore._(null, prefs, values);
    }
  }

  static Future<AppStore> _openOn(Database db) async {
    await DatabaseHelper.ensureKvTable(db);
    final values = <String, Object>{};
    for (final row in await db.query('kv')) {
      final v = _decode(row['value'] as String?);
      if (v != null) values[row['key'] as String] = v;
    }
    if (!values.containsKey(_importedKey)) {
      await _importSharedPreferences(db, values);
    }
    return AppStore._(db, null, values);
  }

  /// One-time copy of everything SharedPreferences held.
  static Future<void> _importSharedPreferences(
      Database db, Map<String, Object> values) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        final v = _normalize(prefs.get(key));
        if (v == null || values.containsKey(key)) continue;
        values[key] = v;
        batch.insert('kv', {'key': key, 'value': jsonEncode(v), 'updated_at': now},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (e) {
      debugPrint('AppStore: SharedPreferences not readable, nothing imported: $e');
    }
    batch.insert(
        'kv', {'key': _importedKey, 'value': 'true', 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
    values[_importedKey] = true;
  }

  static Object? _normalize(Object? v) => switch (v) {
        final List<Object?> list => [for (final e in list) '$e'],
        final String s => s,
        final int i => i,
        final double d => d,
        final bool b => b,
        _ => null,
      };

  static Object? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return _normalize(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  // ── Reads ─────────────────────────────────────────────────────────────

  String? getString(String key) => _as<String>(key);
  int? getInt(String key) => _as<int>(key);
  bool? getBool(String key) => _as<bool>(key);
  List<String>? getStringList(String key) => _as<List<String>>(key);

  double? getDouble(String key) {
    final v = _values[key];
    return v is num ? v.toDouble() : null;
  }

  bool containsKey(String key) => _values.containsKey(key);

  Set<String> getKeys() =>
      _values.keys.where((k) => !k.startsWith('__')).toSet();

  T? _as<T>(String key) {
    final v = _values[key];
    return v is T ? v : null;
  }

  // ── Writes ────────────────────────────────────────────────────────────

  Future<bool> setString(String key, String value) => _put(key, value);
  Future<bool> setInt(String key, int value) => _put(key, value);
  Future<bool> setBool(String key, bool value) => _put(key, value);
  Future<bool> setDouble(String key, double value) => _put(key, value);
  Future<bool> setStringList(String key, List<String> value) =>
      _put(key, List<String>.unmodifiable(value));

  Future<bool> remove(String key) {
    _values.remove(key);
    return _enqueue(
      (db) => db.delete('kv', where: 'key = ?', whereArgs: [key]),
      (prefs) => prefs.remove(key),
    );
  }

  /// Resolves once every write so far has reached storage.
  Future<void> flush() => _writes;

  Future<bool> _put(String key, Object value) {
    _values[key] = value;
    return _enqueue(
      (db) => db.insert(
        'kv',
        {
          'key': key,
          'value': jsonEncode(value),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
      (prefs) => switch (value) {
        final String s => prefs.setString(key, s),
        final int i => prefs.setInt(key, i),
        final bool b => prefs.setBool(key, b),
        final double d => prefs.setDouble(key, d),
        final List<String> l => prefs.setStringList(key, l),
        _ => Future.value(false),
      },
    );
  }

  Future<bool> _enqueue(
    Future<Object?> Function(Database db) toDb,
    Future<Object?> Function(SharedPreferences prefs) toPrefs,
  ) {
    final done = Completer<bool>();
    _writes = _writes.then((_) async {
      try {
        final db = _db;
        if (db != null) {
          await toDb(db);
        } else {
          await toPrefs(_prefs!);
        }
        done.complete(true);
      } catch (e) {
        debugPrint('AppStore write failed: $e');
        done.complete(false);
      }
    });
    return done.future;
  }
}
