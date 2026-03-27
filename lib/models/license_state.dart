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
      status == LicenseStatus.active ||
      status == LicenseStatus.trial ||
      status == LicenseStatus.free;

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
        return 'ทดลองใช้';
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
