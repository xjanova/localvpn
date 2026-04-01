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

# Keep native methods (JNI)
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep JSON models
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses

# Google Play Core (referenced by Flutter deferred components)
-dontwarn com.google.android.play.core.**
