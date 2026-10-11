enum LicenseStatus {
  checking,
  free,
  trial,
  active,
  expired,
  none,
}

class LicenseState {
  final LicenseStatus status;
  final String? licenseKey;
  final String? licenseType;
  final DateTime? expiresAt;
  final String? deviceId;
  final String? errorMessage;

  /// Server error code of the last failed action (e.g.
  /// ALREADY_ACTIVATED_OTHER_DEVICE), for the UI to offer the right fix.
  final String? errorCode;

  /// Whole days left on a trial or a paid term (null = no end).
  final int? daysLeft;

  /// This device may still start its one free Pro trial.
  final bool trialAvailable;

  /// Last answer came from the cache because the server was unreachable.
  final bool offline;

  const LicenseState({
    required this.status,
    this.licenseKey,
    this.licenseType,
    this.expiresAt,
    this.deviceId,
    this.errorMessage,
    this.errorCode,
    this.daysLeft,
    this.trialAvailable = false,
    this.offline = false,
  });

  const LicenseState.initial()
      : status = LicenseStatus.checking,
        licenseKey = null,
        licenseType = null,
        expiresAt = null,
        deviceId = null,
        errorMessage = null,
        errorCode = null,
        daysLeft = null,
        trialAvailable = false,
        offline = false;

  LicenseState copyWith({
    LicenseStatus? status,
    String? licenseKey,
    String? licenseType,
    DateTime? expiresAt,
    String? deviceId,
    String? errorMessage,
    String? errorCode,
    int? daysLeft,
    bool? trialAvailable,
    bool? offline,
  }) {
    return LicenseState(
      status: status ?? this.status,
      licenseKey: licenseKey ?? this.licenseKey,
      licenseType: licenseType ?? this.licenseType,
      expiresAt: expiresAt ?? this.expiresAt,
      deviceId: deviceId ?? this.deviceId,
      errorMessage: errorMessage ?? this.errorMessage,
      errorCode: errorCode ?? this.errorCode,
      daysLeft: daysLeft ?? this.daysLeft,
      trialAvailable: trialAvailable ?? this.trialAvailable,
      offline: offline ?? this.offline,
    );
  }

  /// The same state without the error of the last action.
  LicenseState withoutError() => LicenseState(
        status: status,
        licenseKey: licenseKey,
        licenseType: licenseType,
        expiresAt: expiresAt,
        deviceId: deviceId,
        daysLeft: daysLeft,
        trialAvailable: trialAvailable,
        offline: offline,
      );

  bool get isValid =>
      status == LicenseStatus.active ||
      status == LicenseStatus.trial ||
      status == LicenseStatus.free;

  /// Pro features: a paid key or the trial.
  bool get isPaid =>
      status == LicenseStatus.active || status == LicenseStatus.trial;

  bool get isFree =>
      status == LicenseStatus.free || status == LicenseStatus.none;

  int get maxNetworkMembers => isPaid ? 50 : 5;

  String get statusDisplayName {
    switch (status) {
      case LicenseStatus.checking:
        return 'กำลังตรวจสอบ...';
      case LicenseStatus.free:
        return 'ฟรี';
      case LicenseStatus.trial:
        return 'ทดลองใช้งาน';
      case LicenseStatus.active:
        return 'Premium';
      case LicenseStatus.expired:
        return 'หมดอายุ';
      case LicenseStatus.none:
        return 'ฟรี';
    }
  }

  String get typeDisplayName {
    switch (licenseType) {
      case 'free':
        return 'ฟรี (จำกัด 5 คน/ห้อง)';
      case 'demo':
        return 'ทดลองใช้ PRO';
      case 'monthly':
        return 'Premium รายเดือน';
      case 'yearly':
        return 'Premium รายปี';
      case 'lifetime':
        return 'Premium ตลอดชีพ';
      default:
        return licenseType ?? 'ฟรี';
    }
  }
}
