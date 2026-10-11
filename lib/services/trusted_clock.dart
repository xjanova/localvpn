import 'dart:math';

import 'package:flutter/foundation.dart';

import '../database/app_store.dart';

/// Time the licence can trust while offline.
///
/// - The offset to the server's clock is learnt from every answer (HTTP
///   `Date`), so a wrong system clock is corrected while online.
/// - A watermark remembers the latest time seen and only moves forward: a
///   clock wound back doesn't bring back days of a trial. [rolledBack] says
///   the system clock is behind it by more than an hour; then only the
///   server can confirm a Pro licence.
class TrustedClock {
  TrustedClock._(this._store, this._systemNow, this._offsetMs, this._watermarkMs);

  static const String _prefOffset = 'clock_offset_ms';
  static const String _prefWatermark = 'clock_watermark_ms';
  static const Duration _rollbackTolerance = Duration(hours: 1);

  final AppStore _store;
  final DateTime Function() _systemNow;
  int _offsetMs;
  int _watermarkMs;

  static Future<TrustedClock> load({
    @visibleForTesting DateTime Function()? systemNow,
  }) async {
    final store = await AppStore.instance();
    final clock = TrustedClock._(
      store,
      systemNow ?? DateTime.now,
      store.getInt(_prefOffset) ?? 0,
      store.getInt(_prefWatermark) ?? 0,
    );
    clock._checkWatermark();
    return clock;
  }

  int get _adjustedMs => _systemNow().millisecondsSinceEpoch + _offsetMs;

  /// Now, by the server's clock as last learnt; never before the watermark.
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(max(_adjustedMs, _watermarkMs));

  /// The system clock was set back since the last time we looked.
  bool get rolledBack =>
      _adjustedMs < _watermarkMs - _rollbackTolerance.inMilliseconds;

  /// The server said it is [serverTime] now.
  void noteServerTime(DateTime serverTime) {
    _offsetMs = serverTime.millisecondsSinceEpoch -
        _systemNow().millisecondsSinceEpoch;
    // The server is the authority: a watermark from a clock that ran fast
    // must not stay in the future.
    _watermarkMs = serverTime.millisecondsSinceEpoch;
    _store.setInt(_prefOffset, _offsetMs);
    _store.setInt(_prefWatermark, _watermarkMs);
  }

  /// Moves the watermark up to now (called periodically).
  void mark() => _checkWatermark();

  void _checkWatermark() {
    if (rolledBack) return; // keep the evidence until the server answers
    final t = _adjustedMs;
    if (t > _watermarkMs) {
      _watermarkMs = t;
      _store.setInt(_prefWatermark, t);
    }
  }
}
