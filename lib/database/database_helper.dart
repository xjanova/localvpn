import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'localvpn.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE saved_networks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slug TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        password_hash TEXT,
        joined_at TEXT NOT NULL,
        last_connected TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE known_devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        machine_id TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        virtual_ip TEXT,
        first_seen TEXT NOT NULL,
        last_seen TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // Saved Networks CRUD
  Future<int> saveNetwork({
    required String slug,
    required String name,
    String? passwordHash,
  }) async {
    final db = await database;
    return await db.insert(
      'saved_networks',
      {
        'slug': slug,
        'name': name,
        'password_hash': passwordHash,
        'joined_at': DateTime.now().toIso8601String(),
        'last_connected': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getSavedNetworks() async {
    final db = await database;
    return await db.query('saved_networks', orderBy: 'last_connected DESC');
  }

  Future<Map<String, dynamic>?> getSavedNetwork(String slug) async {
    final db = await database;
    final results = await db.query(
      'saved_networks',
      where: 'slug = ?',
      whereArgs: [slug],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<int> updateLastConnected(String slug) async {
    final db = await database;
    return await db.update(
      'saved_networks',
      {'last_connected': DateTime.now().toIso8601String()},
      where: 'slug = ?',
      whereArgs: [slug],
    );
  }

  Future<int> deleteSavedNetwork(String slug) async {
    final db = await database;
    return await db.delete(
      'saved_networks',
      where: 'slug = ?',
      whereArgs: [slug],
    );
  }

  // Known Devices CRUD
  Future<int> saveDevice({
    required String machineId,
    required String displayName,
    String? virtualIp,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return await db.insert(
      'known_devices',
      {
        'machine_id': machineId,
        'display_name': displayName,
        'virtual_ip': virtualIp,
        'first_seen': now,
        'last_seen': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getKnownDevices() async {
    final db = await database;
    return await db.query('known_devices', orderBy: 'last_seen DESC');
  }

  Future<int> updateDeviceLastSeen(String machineId) async {
    final db = await database;
    return await db.update(
      'known_devices',
      {'last_seen': DateTime.now().toIso8601String()},
      where: 'machine_id = ?',
      whereArgs: [machineId],
    );
  }

  Future<int> deleteDevice(String machineId) async {
    final db = await database;
    return await db.delete(
      'known_devices',
      where: 'machine_id = ?',
      whereArgs: [machineId],
    );
  }

  // App Settings
  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final results = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return results.isNotEmpty ? results.first['value'] as String : null;
  }

  Future<int> deleteSetting(String key) async {
    final db = await database;
    return await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
