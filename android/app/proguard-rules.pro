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
# Must keep all classes including JNI native methods used by OpenVPN daemon
-keep class id.laskarmedia.openvpn_flutter.** { *; }
-keep class de.blinkt.openvpn.** { *; }
-keep class de.blinkt.openvpn.core.** { *; }
-keep class net.openvpn.ovpn3.** { *; }

# Keep native methods (JNI) — critical for OpenVPN native library
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep JSON models
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses

# Google Play Core (referenced by Flutter deferred components)
-dontwarn com.google.android.play.core.**
-dontwarn net.openvpn.ovpn3.**
