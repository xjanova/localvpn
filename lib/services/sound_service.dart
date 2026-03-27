import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 16-bit chiptune sound engine for cyberpunk UI feedback.
/// Generates retro-style WAV sounds entirely in code — no asset files needed.
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  static const int _sampleRate = 22050;
  static const String _prefKey = 'sound_enabled';

  bool _enabled = true;
  bool get enabled => _enabled;

  bool _initialized = false;

  final Map<SfxType, Uint8List> _cache = {};
  final List<AudioPlayer> _pool = [];
  int _poolIndex = 0;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Load preference
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
    } catch (_) {}

    // Pre-generate all sounds
    for (final type in SfxType.values) {
      _cache[type] = _generate(type);
    }

    // Create a small pool of players for overlapping sounds
    for (var i = 0; i < 3; i++) {
      final p = AudioPlayer();
      await p.setVolume(0.35);
      await p.setPlayerMode(PlayerMode.lowLatency);
      _pool.add(p);
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
  }

  void dispose() {
    for (final p in _pool) {
      p.dispose();
    }
    _pool.clear();
  }

  /// Play a sound effect. Non-blocking, fire-and-forget.
  void play(SfxType type) {
    if (!_enabled || _pool.isEmpty) return;
    final data = _cache[type];
    if (data == null) return;

    // Round-robin through the pool
    final player = _pool[_poolIndex % _pool.length];
    _poolIndex++;

    player.play(BytesSource(data)).catchError((_) {
      // Silently ignore playback errors
    });
  }

  // ─── Sound Generators ─────────────────────────────────────

  Uint8List _generate(SfxType type) {
    final samples = switch (type) {
      SfxType.tap => _squarePing(1400, 0.025, 0.25),
      SfxType.tapHeavy => _squarePing(800, 0.04, 0.35),
      SfxType.success => _arpeggio([523, 659, 784, 1047], 0.07, 0.3),
      SfxType.error => _buzz(180, 0.2, 0.4),
      SfxType.connect => _powerUp(400, 1600, 0.35, 0.3),
      SfxType.disconnect => _powerDown(1200, 300, 0.25, 0.25),
      SfxType.notification => _arpeggio([880, 1100], 0.06, 0.2),
      SfxType.tabSwitch => _squarePing(2000, 0.015, 0.12),
      SfxType.swoosh => _swoosh(0.12, 0.2),
      SfxType.coin => _coin(),
      SfxType.boot => _bootSequence(),
      SfxType.toggle => _toggleClick(),
      SfxType.typing => _squarePing(3000, 0.01, 0.08),
    };
    return _createWav(samples);
  }

  /// Classic chiptune square wave ping
  List<int> _squarePing(double freq, double duration, double vol) {
    final n = (_sampleRate * duration).round();
    final out = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final env = 1.0 - (i / n); // linear decay
      final wave = sin(2 * pi * freq * t) > 0 ? 1.0 : -1.0; // square
      out[i] = (wave * vol * env * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  /// Ascending chiptune arpeggio
  List<int> _arpeggio(List<double> notes, double noteDur, double vol) {
    final out = <int>[];
    for (var ni = 0; ni < notes.length; ni++) {
      final freq = notes[ni];
      final n = (_sampleRate * noteDur).round();
      for (var i = 0; i < n; i++) {
        final t = i / _sampleRate;
        final env = 1.0 - (i / n) * 0.7;
        // Mix square + sine for richer chiptune tone
        final sq = sin(2 * pi * freq * t) > 0 ? 1.0 : -1.0;
        final sn = sin(2 * pi * freq * t);
        final wave = sq * 0.6 + sn * 0.4;
        out.add((wave * vol * env * 32767).round().clamp(-32767, 32767));
      }
    }
    return out;
  }

  /// Low buzz for errors
  List<int> _buzz(double freq, double duration, double vol) {
    final n = (_sampleRate * duration).round();
    final out = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final env = i < n ~/ 2 ? 1.0 : 1.0 - ((i - n ~/ 2) / (n ~/ 2));
      // Sawtooth wave for harsh buzzy tone
      final phase = (freq * t) % 1.0;
      final wave = 2.0 * phase - 1.0;
      out[i] = (wave * vol * env * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  /// Ascending frequency sweep — "power up" / connect
  List<int> _powerUp(
      double startF, double endF, double duration, double vol) {
    final n = (_sampleRate * duration).round();
    final out = List<int>.filled(n, 0);
    double phase = 0;
    for (var i = 0; i < n; i++) {
      final p = i / n;
      final freq = startF + (endF - startF) * p * p; // quadratic sweep
      final env = sin(p * pi); // bell envelope
      phase += 2 * pi * freq / _sampleRate;
      final wave = sin(phase) > 0 ? 1.0 : -1.0;
      out[i] = (wave * vol * env * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  /// Descending frequency sweep — "power down" / disconnect
  List<int> _powerDown(
      double startF, double endF, double duration, double vol) {
    final n = (_sampleRate * duration).round();
    final out = List<int>.filled(n, 0);
    double phase = 0;
    for (var i = 0; i < n; i++) {
      final p = i / n;
      final freq = startF + (endF - startF) * p;
      final env = 1.0 - p * 0.8;
      phase += 2 * pi * freq / _sampleRate;
      final wave = sin(phase) > 0 ? 0.7 : -0.7;
      out[i] = (wave * vol * env * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  /// Filtered noise swoosh — page transition
  List<int> _swoosh(double duration, double vol) {
    final n = (_sampleRate * duration).round();
    final out = List<int>.filled(n, 0);
    final rng = Random(7);
    double prev = 0;
    for (var i = 0; i < n; i++) {
      final p = i / n;
      final env = sin(p * pi); // bell
      // Simple low-pass filtered noise
      final raw = rng.nextDouble() * 2 - 1;
      prev = prev * 0.7 + raw * 0.3;
      out[i] = (prev * vol * env * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  /// Retro coin collect sound
  List<int> _coin() {
    final out = <int>[];
    // Two quick notes
    for (final freq in [987.0, 1319.0]) {
      final n = (_sampleRate * 0.06).round();
      for (var i = 0; i < n; i++) {
        final t = i / _sampleRate;
        final env = 1.0 - (i / n);
        final wave = sin(2 * pi * freq * t) > 0 ? 1.0 : -1.0;
        out.add((wave * 0.25 * env * 32767).round().clamp(-32767, 32767));
      }
    }
    return out;
  }

  /// Boot-up sequence: ascending bleeps
  List<int> _bootSequence() {
    final out = <int>[];
    final freqs = [220.0, 330.0, 440.0, 660.0, 880.0];
    for (var fi = 0; fi < freqs.length; fi++) {
      final freq = freqs[fi];
      final n = (_sampleRate * 0.05).round();
      for (var i = 0; i < n; i++) {
        final t = i / _sampleRate;
        final env = 1.0 - (i / n) * 0.5;
        final wave = sin(2 * pi * freq * t) > 0 ? 1.0 : -1.0;
        out.add((wave * 0.2 * env * 32767).round().clamp(-32767, 32767));
      }
      // Small silence gap between notes
      out.addAll(List.filled((_sampleRate * 0.02).round(), 0));
    }
    return out;
  }

  /// Toggle on/off click
  List<int> _toggleClick() {
    final n = (_sampleRate * 0.02).round();
    final out = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final env = 1.0 - (i / n);
      // Sharp attack with quick decay
      final wave = sin(2 * pi * 1800 * t) * env * env;
      out[i] = (wave * 0.2 * 32767).round().clamp(-32767, 32767);
    }
    return out;
  }

  // ─── WAV Encoder ──────────────────────────────────────────

  Uint8List _createWav(List<int> samples) {
    const bitsPerSample = 16;
    const numChannels = 1;
    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);

    // RIFF header
    _writeString(bytes, 0, 'RIFF');
    bytes.setUint32(4, fileSize, Endian.little);
    _writeString(bytes, 8, 'WAVE');

    // fmt chunk
    _writeString(bytes, 12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, numChannels, Endian.little);
    bytes.setUint32(24, _sampleRate, Endian.little);
    bytes.setUint32(
        28, _sampleRate * numChannels * bitsPerSample ~/ 8, Endian.little);
    bytes.setUint16(
        32, numChannels * bitsPerSample ~/ 8, Endian.little);
    bytes.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    _writeString(bytes, 36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    for (var i = 0; i < samples.length; i++) {
      bytes.setInt16(44 + i * 2, samples[i], Endian.little);
    }

    return bytes.buffer.asUint8List();
  }

  void _writeString(ByteData data, int offset, String str) {
    for (var i = 0; i < str.length; i++) {
      data.setUint8(offset + i, str.codeUnitAt(i));
    }
  }
}

/// All available 16-bit sound effects
enum SfxType {
  tap,        // Short UI tap
  tapHeavy,   // Heavier button press
  success,    // Ascending chime — creation, join, activation
  error,      // Low buzz — validation fail, API error
  connect,    // Power-up sweep — VPN connected
  disconnect, // Power-down sweep — VPN disconnected
  notification, // Short ping — member joined, file ready
  tabSwitch,  // Subtle click — bottom nav
  swoosh,     // Filtered noise — page transition
  coin,       // Retro coin collect — file shared
  boot,       // Boot sequence — splash screen
  toggle,     // Toggle click — switch on/off
  typing,     // Quick high click — text input
}
