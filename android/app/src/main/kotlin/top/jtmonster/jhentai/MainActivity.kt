package top.jtmonster.jhentai

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private var interceptVolumeEvent = false
    private lateinit var volumeMethodChannel: MethodChannel
    private lateinit var xrayMethodChannel: MethodChannel
    private val xrayExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        xrayMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.jtmonster.jhentai.xray"
        )
        xrayMethodChannel.setMethodCallHandler { call, result ->
            // ProxyController must be called on the main thread, and the
            // method call handler already runs there: handle it inline.
            if (call.method == "setWebViewProxy") {
                XrayBridge.setWebViewProxy(
                    call.argument<String>("mode") ?: "direct",
                    call.argument<String>("address"),
                    call.argument<Int>("mainPort") ?: XrayBridge.mainPort
                )
                result.success(null)
                return@setMethodCallHandler
            }
            // libXray invoke calls are blocking JNI into Go: run them on a
            // background thread and post the result back to the main thread.
            xrayExecutor.execute {
                val knownMethods = setOf("start", "stop", "isRunning", "version", "convertLinks", "decodeSubscription")
                if (call.method !in knownMethods) {
                    mainHandler.post { result.notImplemented() }
                    return@execute
                }
                try {
                    val value: Any? = when (call.method) {
                        "start" -> {
                            XrayBridge.start(
                                call.argument<String>("mainLink"),
                                call.argument<Int>("mainPort") ?: 23366
                            )
                            null
                        }
                        "stop" -> {
                            XrayBridge.stop()
                            null
                        }
                        "isRunning" -> XrayBridge.isRunning()
                        "version" -> XrayBridge.version()
                        "convertLinks" -> XrayBridge.convertLinks(call.arguments as? String ?: "")
                        "decodeSubscription" -> XrayBridge.decodeSubscriptionText(call.arguments as? String ?: "")
                        else -> null
                    }
                    mainHandler.post { result.success(value) }
                } catch (e: Exception) {
                    mainHandler.post { result.error("XRAY_ERROR", e.message, null) }
                }
            }
        }

        volumeMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.jtmonster.jhentai.volume.event.intercept"
        )

        volumeMethodChannel.setMethodCallHandler { call, result ->
            if (call.method == "set") {
                val value = call.arguments<Boolean>()
                if (value != null) {
                    interceptVolumeEvent = value
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Disable the Android splash screen fade out animation to avoid
            // a flicker before the similar frame is drawn in Flutter.
            splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
        }

        super.onCreate(savedInstanceState)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (interceptVolumeEvent && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            volumeMethodChannel.invokeMethod(
                "event",
                if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) 1 else -1
            )
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (interceptVolumeEvent && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onDestroy() {
        volumeMethodChannel.setMethodCallHandler(null)
        xrayMethodChannel.setMethodCallHandler(null)
        xrayExecutor.shutdown()
        super.onDestroy()
    }
}
