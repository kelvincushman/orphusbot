# This is generated automatically by the Android Gradle plugin.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# Keep AutoSafeParcelables
-keep public class * extends org.microg.safeparcel.AutoSafeParcelable {
    @org.microg.safeparcel.SafeParcelable.Field *;
    @org.microg.safeparcel.SafeParceled *;
}

# Keep asInterface method cause it's accessed from SafeParcel
-keepattributes InnerClasses
-keepclassmembers interface * extends android.os.IInterface {
    public static class *;
}
-keep public class * extends android.os.Binder { public static *; }

# XML parser stuff
-dontwarn org.xmlpull.v1.**
-dontwarn org.kxml2.io.**
-dontwarn android.content.res.**
-dontwarn org.slf4j.impl.StaticLoggerBinder


-keep class org.xmlpull.** { *; }
-keepclassmembers class org.xmlpull.** { *; }

#Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# For Awesome Notification Plugin
-keep class com.google.common.reflect.TypeToken
-keep class * extends com.google.common.reflect.TypeToken

# You might not be using firebase
-keep class com.google.firebase.** { *; }
-keep class com.builttoroam.devicecalendar.** { *; }

-keep class com.pravera.flutter_foreground_task.service.** { *; }

# Lombok annotations
-dontwarn lombok.Generated
-dontwarn lombok.**
-keep class lombok.** { *; }

# Firebase: deprecated KTX shim references a class no longer on the classpath
# (firebase-common-ktx removed). Dead reference — safe to suppress.
-dontwarn com.google.firebase.ktx.Firebase

# flutter_gemma / MediaPipe LLM Inference (LiteRT-LM). Keep runtime classes and
# suppress the optional profiling/graph-template proto refs that tasks-genai
# references but does not bundle. Mirrors flutter_gemma's example app rules.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**
# okhttp optional TLS providers — referenced reflectively, absent at runtime.
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**