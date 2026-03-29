# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep VPN service
-keep class com.xjanova.localvpn.LocalVpnService { *; }
-keep class com.xjanova.localvpn.MainActivity { *; }

# Keep OpenVPN Flutter plugin and OpenVPN native library
-keep class id.laskarmedia.openvpn_flutter.** { *; }
-keep class de.blinkt.openvpn.** { *; }
-keep class de.blinkt.openvpn.core.** { *; }

# Keep JSON models
-keepattributes *Annotation*
-keepattributes Signature

# Google Play Core (referenced by Flutter deferred components)
-dontwarn com.google.android.play.core.**

# Remove debug logging in release
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}
