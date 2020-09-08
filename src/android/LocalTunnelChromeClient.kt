package com.propel.localtunnel

import android.webkit.*
import android.webkit.WebStorage.QuotaUpdater
import org.apache.cordova.CordovaWebView
import org.apache.cordova.LOG
import org.apache.cordova.PluginResult
import org.json.JSONArray
import org.json.JSONException

open class LocalTunnelChromeClient(webView: CordovaWebView, lt: LocalTunnel) : WebChromeClient() {
    private val webView: CordovaWebView
    private val lt: LocalTunnel
    private val LOG_TAG = "LocalTunnelChromeClient"
    private val MAX_QUOTA = 100 * 1024 * 1024.toLong()

    init {
        this.webView = webView
        this.lt = lt
    }

    /**
     * Handle database quota exceeded notification.
     *
     * @param url
     * @param databaseIdentifier
     * @param currentQuota
     * @param estimatedSize
     * @param totalUsedQuota
     * @param quotaUpdater
     */
    override fun onExceededDatabaseQuota(url: String, databaseIdentifier: String, currentQuota: Long, estimatedSize: Long,
                                         totalUsedQuota: Long, quotaUpdater: QuotaUpdater) {
        LOG.d(LOG_TAG, "onExceededDatabaseQuota estimatedSize: %d  currentQuota: %d  totalUsedQuota: %d", estimatedSize, currentQuota, totalUsedQuota)
        quotaUpdater.updateQuota(MAX_QUOTA)
    }

    /**
     * Instructs the client to show a prompt to ask the user to set the Geolocation permission state for the specified origin.
     *
     * @param origin
     * @param callback
     */
    override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
        super.onGeolocationPermissionsShowPrompt(origin, callback)
        callback.invoke(origin, true, false)
    }

    /**
     * Tell the client to display a prompt dialog to the user.
     * If the client returns true, WebView will assume that the client will
     * handle the prompt dialog and call the appropriate JsPromptResult method.
     *
     * The prompt bridge provided for the LocalTunnel is capable of executing any
     * oustanding callback belonging to the LocalTunnel plugin. Care has been
     * taken that other callbacks cannot be triggered, and that no other code
     * execution is possible.
     *
     * To trigger the bridge, the prompt default value should be of the form:
     *
     * gap-iab://<callbackId>
     *
     * where <callbackId> is the string id of the callback to trigger (something
     * like "LocalTunnel0123456789")
     *
     * If present, the prompt message is expected to be a JSON-encoded value to
     * pass to the callback. A JSON_EXCEPTION is returned if the JSON is invalid.
     *
     * @param view
     * @param url
     * @param message
     * @param defaultValue
     * @param result
    </callbackId></callbackId> */
    override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String, result: JsPromptResult): Boolean {
        // See if the prompt string uses the 'gap-iab' protocol. If so, the remainder should be the id of a callback to execute.
        if (defaultValue != null && defaultValue.startsWith("gap")) {
            if (defaultValue.startsWith("gap-iab://")) {
                var scriptResult: PluginResult?
                val scriptCallbackId = defaultValue.substring(10)
                var jsonMessage: JSONArray
                if (message == null || message.length == 0) {
                    jsonMessage = JSONArray()
                    scriptResult = PluginResult(PluginResult.Status.OK, jsonMessage)
                } else {
                    try {
                        jsonMessage = JSONArray(message)
                        scriptResult = PluginResult(PluginResult.Status.OK, jsonMessage)
                    } catch (e: JSONException) {
                        jsonMessage = JSONArray()
                        scriptResult = PluginResult(PluginResult.Status.JSON_EXCEPTION, e.message)
                    }
                }
                if (scriptCallbackId.startsWith("LocalTunnel")) {
                    webView.sendPluginResult(scriptResult, scriptCallbackId)
                    result.confirm("")
                    return true
                } else if (scriptCallbackId.startsWith("requestdone")) {
                    try {
                        val status = jsonMessage.getInt(0)
                        val statusText = jsonMessage.getString(1)
                        lt.sendRequestDone(status, statusText)
                    } catch (e: JSONException) {
                        LOG.w(LOG_TAG, e.message)
                    }
                    result.confirm("")
                    return true
                }
            } else {
                // Anything else with a gap: prefix should get this message
                LOG.w(LOG_TAG, "LocalTunnel does not support Cordova API calls: $url $defaultValue")
                result.cancel()
                return true
            }
        }
        return false
    }

    /**
     * Tell the client to display a alert dialog to the user.
     * If the client returns true, WebView will assume that the client will
     * handle the alert dialog and call a JsResult method.
     *
     * @param view
     * @param url
     * @param message
     * @param result
     */
    override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
        LOG.d(LOG_TAG, "Alert received in LocalTunnel")
        if (lt.requestUrl != null || url == lt.lastRequestUrl) {
            LOG.d(LOG_TAG, "Suppressing alert in LocalTunnel")
            result.confirm()
            return true
        }
        return false
    }
}