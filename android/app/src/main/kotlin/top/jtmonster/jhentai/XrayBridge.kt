package top.jtmonster.jhentai

import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLDecoder
import java.util.concurrent.Executor

/**
 * The door into the embedded Xray core (libXray AAR, JSON-envelope invoke API).
 *
 * Two loopback SOCKS inbounds are exposed:
 *  - [MAIN_PORT] routes to the "main" outbound (all normal traffic)
 *  - [IGNEOUS_PORT] routes to the "igneous" outbound (only the exhentai igneous
 *    cookie refresh uses it)
 *
 * Every invoke call is blocking JNI into Go: callers must stay off the main thread.
 * The only exception is [setWebViewProxy], which must run ON the main thread.
 */
object XrayBridge {
    private const val API_VERSION = 3
    const val MAIN_PORT = 28780
    const val IGNEOUS_PORT = 28781

    private fun invoke(method: String, payload: JSONObject): JSONObject? {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", method)
            .put("payload", payload)
        val raw = LibXray.invoke(request.toString())
        val response = JSONObject(raw)
        if (!response.optBoolean("success", false)) {
            val error = if (response.has("error") && !response.isNull("error")) {
                response.optString("error").ifBlank { "libXray $method failed" }
            } else {
                "libXray $method failed"
            }
            throw IllegalStateException(error)
        }
        return if (response.has("data") && !response.isNull("data")) response.optJSONObject("data") else null
    }

    /** Converts share links into Xray outbounds (one per link, tagged with the link's name). */
    fun convertOutbounds(text: String): JSONArray {
        val data = invoke("convertShareLinksToXrayJson", JSONObject().put("text", text))
        return data?.optJSONArray("outbounds") ?: JSONArray()
    }

    /** Decodes a base64 (or plain) subscription body into the share links it carries. */
    fun decodeSubscriptionText(text: String): String {
        val data = invoke("decodeSubscriptionText", JSONObject().put("text", text))
        return data?.optString("text", "") ?: ""
    }

    // ------------------------------------------------------------------
    // hysteria2 preprocessing
    //
    // LibXray's share parser deliberately rejects hysteria2 links carrying
    // pinSHA256 or insecure=true: the current Xray core removed
    // "allowInsecure" entirely and expresses pinning as the TLS setting
    // "pinnedPeerCertSha256" (comma-separated hex). Verified against
    // xray-core infra/conf with a Go test: injecting pinnedPeerCertSha256
    // (hex) into streamSettings.tlsSettings builds and the pin takes effect;
    // injecting allowInsecure makes Build() fail with a removed-feature
    // error. So: strip the pin from the link, convert, then inject it into
    // the outbound. insecure hy2 links cannot be honored at all and fail
    // with an explicit error instead of being silently dropped.
    // ------------------------------------------------------------------

    private class Hy2Fix(val strippedLink: String, val pinHex: String?)

    private fun isHy2(link: String): Boolean {
        val scheme = link.substringBefore("://", "").lowercase()
        return scheme == "hysteria2" || scheme == "hy2"
    }

    private fun preprocessHy2(link: String): Hy2Fix {
        val fragmentIndex = link.indexOf('#')
        val fragment = if (fragmentIndex >= 0) link.substring(fragmentIndex) else ""
        val noFragment = if (fragmentIndex >= 0) link.substring(0, fragmentIndex) else link
        val queryIndex = noFragment.indexOf('?')
        if (queryIndex < 0) {
            return Hy2Fix(link, null)
        }
        val base = noFragment.substring(0, queryIndex)
        val query = noFragment.substring(queryIndex + 1)
        var pinHex: String? = null
        val kept = mutableListOf<String>()
        for (param in query.split('&')) {
            if (param.isEmpty()) continue
            val key = param.substringBefore('=')
            val value = param.substringAfter('=', "")
            when (key) {
                "pinSHA256" -> {
                    val normalized = value.replace(":", "").lowercase()
                    if (normalized.length == 64 && normalized.all { it in '0'..'9' || it in 'a'..'f' }) {
                        pinHex = normalized
                    } else {
                        // Not a usable pin: keep the param so the core rejects
                        // the link with its own error instead of dropping the pin silently.
                        kept.add(param)
                    }
                }
                "insecure", "allowInsecure" -> {
                    if (value == "1" || value.equals("true", ignoreCase = true)) {
                        throw IllegalStateException("insecure hy2 not supported by core")
                    }
                    kept.add(param)
                }
                else -> kept.add(param)
            }
        }
        if (pinHex == null) {
            return Hy2Fix(link, null)
        }
        val rebuilt = buildString {
            append(base)
            if (kept.isNotEmpty()) {
                append('?')
                append(kept.joinToString("&"))
            }
            append(fragment)
        }
        return Hy2Fix(rebuilt, pinHex)
    }

    private fun injectPinnedPeerCert(outbound: JSONObject, pinHex: String) {
        val stream = outbound.optJSONObject("streamSettings")
            ?: JSONObject().also { outbound.put("streamSettings", it) }
        if (stream.optString("security").isBlank()) {
            stream.put("security", "tls")
        }
        val tls = stream.optJSONObject("tlsSettings")
            ?: JSONObject().also { stream.put("tlsSettings", it) }
        tls.put("pinnedPeerCertSha256", pinHex)
    }

    /** Converts a single share link into its first outbound, applying hy2 fixes. */
    private fun convertSingleOutbound(link: String): JSONObject {
        var effectiveLink = link
        var pinHex: String? = null
        if (isHy2(link)) {
            val fix = preprocessHy2(link)
            effectiveLink = fix.strippedLink
            pinHex = fix.pinHex
        }
        val outbounds = convertOutbounds(effectiveLink)
        if (outbounds.length() == 0) {
            throw IllegalStateException("Cannot parse node link")
        }
        val outbound = outbounds.getJSONObject(0)
        if (pinHex != null) {
            injectPinnedPeerCert(outbound, pinHex)
        }
        return outbound
    }

    /** Short, credential-free summary of a link for failure reporting. */
    private fun linkSummary(link: String): String {
        val scheme = link.substringBefore("://", "")
        val afterScheme = link.substringAfter("://", "")
        val hostPort = afterScheme.substringBefore('/').substringBefore('?').substringAfter('@')
        return if (scheme.isBlank()) link.take(40) else "$scheme://$hostPort"
    }

    /**
     * Parses pasted text (share links, one per line, or a base64 subscription body)
     * into per-link results: {"nodes": [{name, link}], "failures": [{link, reason}]}.
     * Never throws for individual bad links; the caller decides what an empty
     * nodes list means.
     */
    fun convertLinks(text: String): Map<String, Any> {
        var body = text.trim()
        if (!body.contains("://")) {
            val decoded = runCatching { decodeSubscriptionText(body) }.getOrNull()
            if (!decoded.isNullOrBlank()) {
                body = decoded.trim()
            }
        }
        val links = body.lineSequence().map { it.trim() }.filter { it.contains("://") }.toList()
        val nodes = mutableListOf<Map<String, String>>()
        val failures = mutableListOf<Map<String, String>>()
        for (link in links) {
            try {
                val outbound = convertSingleOutbound(link)
                val tag = outbound.optString("tag")
                nodes.add(mapOf("name" to (tag.ifBlank { fallbackName(link) }), "link" to link))
            } catch (e: Exception) {
                failures.add(
                    mapOf(
                        "link" to linkSummary(link),
                        "reason" to (e.message?.takeIf { it.isNotBlank() } ?: "parse failed")
                    )
                )
            }
        }
        return mapOf("nodes" to nodes, "failures" to failures)
    }

    private fun fallbackName(link: String): String {
        val fragment = link.substringAfter('#', "")
        if (fragment.isNotBlank()) {
            return runCatching { URLDecoder.decode(fragment, "UTF-8") }.getOrDefault(fragment)
        }
        val host = runCatching {
            val afterScheme = link.substringAfter("://")
            afterScheme.substringBefore('/').substringBefore('?').substringAfter('@').substringBefore(':')
        }.getOrDefault("")
        return host.ifBlank { "node" }
    }

    private fun outboundFor(link: String?, tag: String): JSONObject {
        if (link.isNullOrBlank()) {
            return JSONObject().put("tag", tag).put("protocol", "freedom")
        }
        return convertSingleOutbound(link).put("tag", tag)
    }

    private fun socksInbound(tag: String, port: Int): JSONObject {
        return JSONObject()
            .put("tag", tag)
            .put("listen", "127.0.0.1")
            .put("port", port)
            .put("protocol", "socks")
            .put(
                "settings",
                JSONObject().put("auth", "noauth").put("udp", true)
            )
            .put(
                "sniffing",
                JSONObject()
                    .put("enabled", true)
                    .put("destOverride", JSONArray().put("http").put("tls"))
            )
    }

    private fun routingRule(inboundTag: String, outboundTag: String): JSONObject {
        return JSONObject()
            .put("type", "field")
            .put("inboundTag", JSONArray().put(inboundTag))
            .put("outboundTag", outboundTag)
    }

    /** Validates and (re)starts the core with the dual-node config. Empty link = direct (freedom). */
    fun start(mainLink: String?, igneousLink: String?) {
        val config = JSONObject()
            .put("log", JSONObject().put("loglevel", "warning"))
            .put(
                "inbounds",
                JSONArray()
                    .put(socksInbound("in-main", MAIN_PORT))
                    .put(socksInbound("in-igneous", IGNEOUS_PORT))
            )
            .put(
                "outbounds",
                JSONArray()
                    .put(outboundFor(mainLink, "out-main"))
                    .put(outboundFor(igneousLink, "out-igneous"))
                    .put(JSONObject().put("tag", "direct").put("protocol", "freedom"))
            )
            .put(
                "routing",
                JSONObject()
                    .put("domainStrategy", "AsIs")
                    .put(
                        "rules",
                        JSONArray()
                            .put(routingRule("in-main", "out-main"))
                            .put(routingRule("in-igneous", "out-igneous"))
                    )
            )
        val configJson = config.toString()
        // testXray refuses to run while a managed core instance exists
        // ("requires an isolated process"), so stop the running core first.
        if (isRunning()) {
            invoke("stopXray", JSONObject())
        }
        invoke("testXray", JSONObject().put("xrayJson", configJson))
        invoke("runXray", JSONObject().put("xrayJson", configJson))
    }

    fun stop() {
        if (isRunning()) {
            invoke("stopXray", JSONObject())
        }
    }

    fun isRunning(): Boolean {
        val data = invoke("getXrayState", JSONObject())
        return data?.optBoolean("running", false) == true
    }

    fun version(): String {
        val data = invoke("xrayVersion", JSONObject())
        return data?.optString("version", "") ?: ""
    }

    // ------------------------------------------------------------------
    // WebView proxy override (must be called on the main thread)
    //
    // Applies the app proxy setting to every WebView in the process via
    // androidx.webkit ProxyController. Proxy rules use the URL form
    // "[scheme://]host[:port]": the scheme selects the proxy protocol and
    // defaults to HTTP, so SOCKS proxies must carry the "socks://" scheme.
    // ------------------------------------------------------------------

    fun setWebViewProxy(mode: String, address: String?) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            return
        }
        val controller = ProxyController.getInstance()
        val executor = Executor { command -> command.run() }
        val target = address?.trim().orEmpty()
        try {
            when (mode) {
                "xray" -> controller.setProxyOverride(
                    ProxyConfig.Builder().addProxyRule("socks://127.0.0.1:$MAIN_PORT").build(),
                    executor
                ) {}
                "http" -> {
                    if (target.isEmpty()) {
                        controller.clearProxyOverride(executor) {}
                    } else {
                        controller.setProxyOverride(
                            ProxyConfig.Builder().addProxyRule(target).build(),
                            executor
                        ) {}
                    }
                }
                "socks5", "socks4" -> {
                    if (target.isEmpty()) {
                        controller.clearProxyOverride(executor) {}
                    } else {
                        controller.setProxyOverride(
                            ProxyConfig.Builder().addProxyRule("socks://$target").build(),
                            executor
                        ) {}
                    }
                }
                else -> controller.clearProxyOverride(executor) {}
            }
        } catch (e: Exception) {
            // Best effort only: a malformed user address must not crash the app.
        }
    }
}
