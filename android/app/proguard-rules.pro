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

# Keep JSON models
-keepattributes *Annotation*
-keepattributes Signature

# Remove debug logging in release
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}
