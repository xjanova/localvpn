enum LicenseStatus {
  checking,
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
  final int? demoMinutesLeft;

  const LicenseState({
    required this.status,
    this.licenseKey,
    this.licenseType,
    this.expiresAt,
    this.deviceId,
    this.errorMessage,
    this.demoMinutesLeft,
  });

  const LicenseState.initial()
      : status = LicenseStatus.checking,
        licenseKey = null,
        licenseType = null,
        expiresAt = null,
        deviceId = null,
        errorMessage = null,
        demoMinutesLeft = null;

  LicenseState copyWith({
    LicenseStatus? status,
    String? licenseKey,
    String? licenseType,
    DateTime? expiresAt,
    String? deviceId,
    String? errorMessage,
    int? demoMinutesLeft,
  }) {
    return LicenseState(
      status: status ?? this.status,
      licenseKey: licenseKey ?? this.licenseKey,
      licenseType: licenseType ?? this.licenseType,
      expiresAt: expiresAt ?? this.expiresAt,
      deviceId: deviceId ?? this.deviceId,
      errorMessage: errorMessage ?? this.errorMessage,
      demoMinutesLeft: demoMinutesLeft ?? this.demoMinutesLeft,
    );
  }

  bool get isValid =>
      status == LicenseStatus.active || status == LicenseStatus.trial;

  String get statusDisplayName {
    switch (status) {
      case LicenseStatus.checking:
        return 'กำลังตรวจสอบ...';
      case LicenseStatus.trial:
        return 'ทดลองใช้งาน';
      case LicenseStatus.active:
        return 'ใช้งานอยู่';
      case LicenseStatus.expired:
        return 'หมดอายุ';
      case LicenseStatus.none:
        return 'ไม่มี License';
    }
  }

  String get typeDisplayName {
    switch (licenseType) {
      case 'demo':
        return 'ทดลองใช้';
      case 'monthly':
        return 'รายเดือน';
      case 'yearly':
        return 'รายปี';
      case 'lifetime':
        return 'ตลอดชีพ';
      default:
        return licenseType ?? 'ไม่ทราบ';
    }
  }
}
