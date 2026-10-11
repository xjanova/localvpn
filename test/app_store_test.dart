import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/database/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  setUp(() async {
    AppStore.resetForTests();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
  });
  tearDown(() async {
    AppStore.resetForTests();
    await db.close();
  });

  test('the first run copies everything SharedPreferences held, once',
      () async {
    SharedPreferences.setMockInitialValues({
      'm3_theme': 'sky',
      'p2p_last_session_id': 1234567,
      'sfx_enabled': false,
      'ratio': 0.5,
      'recent': ['a', 'b'],
    });
    final store = await AppStore.openForTests(db);
    expect(store.backend, 'sqlite');
    expect(store.getString('m3_theme'), 'sky');
    expect(store.getInt('p2p_last_session_id'), 1234567);
    expect(store.getBool('sfx_enabled'), isFalse);
    expect(store.getDouble('ratio'), 0.5);
    expect(store.getStringList('recent'), ['a', 'b']);
    expect(store.getKeys(),
        {'m3_theme', 'p2p_last_session_id', 'sfx_enabled', 'ratio', 'recent'});

    // A later change in SharedPreferences is not imported again.
    SharedPreferences.setMockInitialValues({'m3_theme': 'night'});
    AppStore.resetForTests();
    final again = await AppStore.openForTests(db);
    expect(again.getString('m3_theme'), 'sky');
  });

  test('writes reach SQLite in order and survive a reopen', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.openForTests(db);
    // Reads see a write at once, before it is stored.
    store.setString('license_type', 'trial');
    expect(store.getString('license_type'), 'trial');
    store.setString('license_type', 'pro');
    await store.setInt('count', 3);
    await store.setBool('wifi_tweak', true);
    await store.remove('count');
    await store.flush();

    final rows = {
      for (final r in await db.query('kv')) r['key']: r['value'],
    };
    expect(rows['license_type'], '"pro"');
    expect(rows.containsKey('count'), isFalse);

    AppStore.resetForTests();
    final reopened = await AppStore.openForTests(db);
    expect(reopened.getString('license_type'), 'pro');
    expect(reopened.getBool('wifi_tweak'), isTrue);
    expect(reopened.getInt('count'), isNull);
    // Wrong type reads as missing instead of throwing.
    expect(reopened.getInt('license_type'), isNull);
  });

  test('without a database it falls back to SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({'m3_theme': 'sky'});
    // No sqflite plugin and no path provider in unit tests: open fails.
    final store = await AppStore.instance();
    expect(store.backend, 'shared_preferences');
    expect(store.getString('m3_theme'), 'sky');
    await store.setString('m3_theme', 'night');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('m3_theme'), 'night');
  });
}
