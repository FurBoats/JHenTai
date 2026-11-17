package top.jtmonster.jhentai

import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLDecoder

/**
 * The door into the embedded Xray core (libXray AAR, JSON-envelope invoke API).
 *
 * Two loopback SOCKS inbounds are exposed:
 *  - [MAIN_PORT] routes to the "main" outbound (all normal traffic)
 *  - [IGNEOUS_PORT] routes to the "igneous" outbound (only the exhentai igneous
 *    cookie refresh uses it)
 *
 * Every invoke call is blocking JNI into Go: callers must stay off the main thread.
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

    /**
     * Parses pasted text (share links, one per line, or a base64 subscription body)
     * into a list of {"name", "link"} maps for the Dart side to store.
     */
    fun convertLinks(text: String): List<Map<String, String>> {
        var body = text.trim()
        if (!body.contains("://")) {
            val decoded = runCatching { decodeSubscriptionText(body) }.getOrNull()
            if (!decoded.isNullOrBlank()) {
                body = decoded.trim()
            }
        }
        val links = body.lineSequence().map { it.trim() }.filter { it.contains("://") }.toList()
        val result = mutableListOf<Map<String, String>>()
        for (link in links) {
            val outbounds = runCatching { convertOutbounds(link) }.getOrNull() ?: continue
            if (outbounds.length() == 0) continue
            val tag = outbounds.getJSONObject(0).optString("tag")
            result.add(mapOf("name" to (tag.ifBlank { fallbackName(link) }), "link" to link))
        }
        if (result.isEmpty()) {
            throw IllegalStateException("No valid node link found")
        }
        return result
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
        val outbounds = convertOutbounds(link)
        if (outbounds.length() == 0) {
            throw IllegalStateException("Cannot parse node link for $tag")
        }
        return outbounds.getJSONObject(0).put("tag", tag)
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
        invoke("testXray", JSONObject().put("xrayJson", configJson))
        if (isRunning()) {
            invoke("stopXray", JSONObject())
        }
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
}
