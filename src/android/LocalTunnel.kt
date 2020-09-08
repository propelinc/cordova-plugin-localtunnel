package com.propel.localtunnel

import android.app.Activity
import android.R
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Browser
import android.text.InputType
import android.util.TypedValue
import android.view.*
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.*
import android.webkit.WebChromeClient.FileChooserParams
import android.widget.*
import com.propel.localtunnel.LocalTunnel
import org.apache.cordova.CallbackContext
import org.apache.cordova.Config
import org.apache.cordova.CordovaArgs
import org.apache.cordova.CordovaHttpAuthHandler
import org.apache.cordova.CordovaPlugin
import org.apache.cordova.CordovaWebView
import org.apache.cordova.LOG
import org.apache.cordova.PluginManager
import org.apache.cordova.PluginResult
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.UnsupportedEncodingException
import java.lang.reflect.Field
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.net.URLEncoder
import java.util.*

@SuppressLint("SetJavaScriptEnabled")
class LocalTunnel : CordovaPlugin() {
    private var dialog: LocalTunnelDialog? = null
    private var localTunnelWebView: WebView? = null
    private var edittext: EditText? = null
    private var callbackContext: CallbackContext? = null

    /**
     * Should we show the location bar?
     *
     * @return boolean
     */
    private var showLocationBar = true
    private var showZoomControls = true
    private var openWindowHidden = false
    private var clearAllCache = false
    private var clearSessionCache = false
    private var hadwareBackButton = true
    private var mediaPlaybackRequiresUserGesture = false
    private var shouldPauseLocalTunnel = false
    private var useWideViewPort = true
    private var mUploadCallback: ValueCallback<Uri?>? = null
    private var mUploadCallbackLollipop: ValueCallback<Array<Uri>>? = null
    private var closeButtonCaption = ""
    private var closeButtonColor = ""
    private var toolbarColor = Color.LTGRAY
    private var hideNavigationButtons = false
    private var navigationButtonColor = ""
    private var hideUrlBar = false
    private var showFooter = false
    private var footerColor = ""
    var captchaUrl: String? = null
    var requestUrl: String? = null
    var lastRequestUrl: String? = null
    var enableRequestBlocking = false

    /**
     * Executes the request and returns PluginResult.
     *
     * @param action the action to execute.
     * @param args JSONArry of arguments for the plugin.
     * @param callbackContext the callbackContext used when calling back into JavaScript.
     * @return A PluginResult object with a status and message.
     */
    @Throws(JSONException::class)
    override fun execute(action: String, args: CordovaArgs, callbackContext: CallbackContext): Boolean {
        if (action == "open") {
            this.callbackContext = callbackContext
            val url: String = args.getString(0)
            var t: String = args.optString(1)
            if (t == null || t == "" || t == NULL) {
                t = SELF
            }
            val target = t
            val features = parseFeature(args.optString(2))
            LOG.d(LOG_TAG, "target = $target")
            this.cordova.getActivity().runOnUiThread(Runnable {
                var result = ""
                // SELF
                if (SELF == target) {
                    LOG.d(LOG_TAG, "in self")
                    /* This code exists for compatibility between 3.x and 4.x versions of Cordova.
                             * Previously the Config class had a static method, isUrlWhitelisted(). That
                             * responsibility has been moved to the plugins, with an aggregating method in
                             * PluginManager.
                             */
                    var shouldAllowNavigation: Boolean? = null
                    if (url.startsWith("javascript:")) {
                        shouldAllowNavigation = true
                    }
                    if (shouldAllowNavigation == null) {
                        try {
                            val iuw: Method = Config::class.java.getMethod("isUrlWhiteListed", String::class.java)
                            shouldAllowNavigation = iuw.invoke(null, url) as Boolean
                        } catch (e: NoSuchMethodException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        } catch (e: IllegalAccessException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        } catch (e: InvocationTargetException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        }
                    }
                    if (shouldAllowNavigation == null) {
                        try {
                            val gpm: Method = webView.javaClass.getMethod("getPluginManager")
                            val pm: PluginManager = gpm.invoke(webView) as PluginManager
                            val san: Method = pm.javaClass.getMethod("shouldAllowNavigation", String::class.java)
                            shouldAllowNavigation = san.invoke(pm, url) as Boolean
                        } catch (e: NoSuchMethodException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        } catch (e: IllegalAccessException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        } catch (e: InvocationTargetException) {
                            LOG.d(LOG_TAG, e.localizedMessage)
                        }
                    }
                    // load in webview
                    if (java.lang.Boolean.TRUE == shouldAllowNavigation) {
                        LOG.d(LOG_TAG, "loading in webview")
                        val webView = localTunnelWebView
                        if (webView != null) {
                            webView.loadUrl(url)
                        }
                    } else if (url.startsWith(WebView.SCHEME_TEL)) {
                        try {
                            LOG.d(LOG_TAG, "loading in dialer")
                            val intent = Intent(Intent.ACTION_DIAL)
                            intent.data = Uri.parse(url)
                            cordova.getActivity().startActivity(intent)
                        } catch (e: ActivityNotFoundException) {
                            LOG.e(LOG_TAG, "Error dialing $url: $e")
                        }
                    } else {
                        LOG.d(LOG_TAG, "loading in LocalTunnel")
                        result = showWebPage(url, features)
                    }
                } else if (SYSTEM == target) {
                    LOG.d(LOG_TAG, "in system")
                    result = openExternal(url)
                } else if (CAPTCHA == target) {
                    LOG.d(LOG_TAG, "loading captcha in LocalTunnel")
                    try {
                        result = showCaptchaPage(url, features, args)
                    } catch (ex: JSONException) {
                        LOG.e(LOG_TAG, "Should never happen", ex)
                    }
                } else if (HTTP_REQUEST == target) {
                    LOG.d(LOG_TAG, "Making http request in LocalTunnel")
                    try {
                        result = makeHttpRequest(url, features, args)
                    } catch (ex: JSONException) {
                        LOG.e(LOG_TAG, "Should never happen", ex)
                    }
                } else if (CLEAR_COOKIES == target) {
                    LOG.d(LOG_TAG, "Clearing cookies")
                    CookieManager.getInstance().removeAllCookie()
                    result = "success"
                } else {
                    LOG.d(LOG_TAG, "in blank")
                    result = showWebPage(url, features)
                }
                val pluginResult = PluginResult(PluginResult.Status.OK, result)
                pluginResult.setKeepCallback(true)
                callbackContext.sendPluginResult(pluginResult)
            })
        } else if (action == "close") {
            closeDialog()
        } else if (action == "injectScriptCode") {
            var jsWrapper: String? = null
            if (args.getBoolean(1)) {
                jsWrapper = java.lang.String.format("(function(){prompt(JSON.stringify([eval(%%s)]), 'gap-iab://%s')})()", callbackContext.getCallbackId())
            }
            injectDeferredObject(args.getString(0), jsWrapper)
        } else if (action == "injectScriptFile") {
            val jsWrapper: String
            jsWrapper = if (args.getBoolean(1)) {
                java.lang.String.format("(function(d) { var c = d.createElement('script'); c.src = %%s; c.onload = function() { prompt('', 'gap-iab://%s'); }; d.body.appendChild(c); })(document)", callbackContext.getCallbackId())
            } else {
                "(function(d) { var c = d.createElement('script'); c.src = %s; d.body.appendChild(c); })(document)"
            }
            injectDeferredObject(args.getString(0), jsWrapper)
        } else if (action == "injectStyleCode") {
            val jsWrapper: String
            jsWrapper = if (args.getBoolean(1)) {
                java.lang.String.format("(function(d) { var c = d.createElement('style'); c.innerHTML = %%s; d.body.appendChild(c); prompt('', 'gap-iab://%s');})(document)", callbackContext.getCallbackId())
            } else {
                "(function(d) { var c = d.createElement('style'); c.innerHTML = %s; d.body.appendChild(c); })(document)"
            }
            injectDeferredObject(args.getString(0), jsWrapper)
        } else if (action == "injectStyleFile") {
            val jsWrapper: String
            jsWrapper = if (args.getBoolean(1)) {
                java.lang.String.format("(function(d) { var c = d.createElement('link'); c.rel='stylesheet'; c.type='text/css'; c.href = %%s; d.head.appendChild(c); prompt('', 'gap-iab://%s');})(document)", callbackContext.getCallbackId())
            } else {
                "(function(d) { var c = d.createElement('link'); c.rel='stylesheet'; c.type='text/css'; c.href = %s; d.head.appendChild(c); })(document)"
            }
            injectDeferredObject(args.getString(0), jsWrapper)
        } else if (action == "show") {
            this.cordova.getActivity().runOnUiThread(Runnable { dialog!!.show() })
            val pluginResult = PluginResult(PluginResult.Status.OK)
            pluginResult.setKeepCallback(true)
            val ctx = this.callbackContext;
            if (ctx != null) {
                ctx.sendPluginResult(pluginResult)
            }
        } else if (action == "hide") {
            this.cordova.getActivity().runOnUiThread(Runnable { dialog!!.hide() })
            val pluginResult = PluginResult(PluginResult.Status.OK)
            pluginResult.setKeepCallback(true)
            val ctx = this.callbackContext;
            if (ctx != null) {
                ctx.sendPluginResult(pluginResult)
            }
        } else {
            return false
        }
        return true
    }

    /**
     * Called when the view navigates.
     */
    override fun onReset() {
        closeDialog()
    }

    /**
     * Called when the system is about to start resuming a previous activity.
     */
    override fun onPause(multitasking: Boolean) {
        if (shouldPauseLocalTunnel) {
            localTunnelWebView!!.onPause()
        }
    }

    /**
     * Called when the activity will start interacting with the user.
     */
    override fun onResume(multitasking: Boolean) {
        if (shouldPauseLocalTunnel) {
            localTunnelWebView!!.onResume()
        }
    }

    /**
     * Called by AccelBroker when listener is to be shut down.
     * Stop listener.
     */
    override fun onDestroy() {
        closeDialog()
    }

    /**
     * Inject an object (script or style) into the LocalTunnel WebView.
     *
     * This is a helper method for the inject{Script|Style}{Code|File} API calls, which
     * provides a consistent method for injecting JavaScript code into the document.
     *
     * If a wrapper string is supplied, then the source string will be JSON-encoded (adding
     * quotes) and wrapped using string formatting. (The wrapper string should have a single
     * '%s' marker)
     *
     * @param source      The source object (filename or script/style text) to inject into
     * the document.
     * @param jsWrapper   A JavaScript string to wrap the source string in, so that the object
     * is properly injected, or null if the source string is JavaScript text
     * which should be executed directly.
     */
    private fun injectDeferredObject(source: String, jsWrapper: String?) {
        if (localTunnelWebView != null) {
            val scriptToInject: String
            scriptToInject = if (jsWrapper != null) {
                val jsonEsc = JSONArray()
                jsonEsc.put(source)
                val jsonRepr = jsonEsc.toString()
                val jsonSourceString = jsonRepr.substring(1, jsonRepr.length - 1)
                String.format(jsWrapper, jsonSourceString)
            } else {
                source
            }
            this.cordova.getActivity().runOnUiThread(Runnable {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
                    // This action will have the side-effect of blurring the currently focused element
                    localTunnelWebView!!.loadUrl("javascript:$scriptToInject")
                } else {
                    localTunnelWebView!!.evaluateJavascript(scriptToInject, null)
                }
            })
        } else {
            LOG.d(LOG_TAG, "Can't inject code into the system browser")
        }
    }

    /**
     * Put the list of features into a hash map
     *
     * @param optString
     * @return
     */
    private fun parseFeature(optString: String): HashMap<String, String>? {
        return if (optString == NULL) {
            null
        } else {
            val map = HashMap<String, String>()
            val features = StringTokenizer(optString, ",")
            var option: StringTokenizer
            while (features.hasMoreElements()) {
                option = StringTokenizer(features.nextToken(), "=")
                if (option.hasMoreElements()) {
                    val key = option.nextToken()
                    var value = option.nextToken()
                    if (!customizableOptions.contains(key)) {
                        value = if (value == "yes" || value == "no") value else "yes"
                    }
                    map[key] = value
                }
            }
            map
        }
    }

    /**
     * Display a new browser with the specified URL.
     *
     * @param url the url to load.
     * @return "" if ok, or error message.
     */
    fun openExternal(url: String): String {
        return try {
            var intent: Intent? = null
            intent = Intent(Intent.ACTION_VIEW)
            // Omitting the MIME type for file: URLs causes "No Activity found to handle Intent".
            // Adding the MIME type to http: URLs causes them to not be handled by the downloader.
            val uri = Uri.parse(url)
            if ("file" == uri.scheme) {
                intent.setDataAndType(uri, webView.getResourceApi().getMimeType(uri))
            } else {
                intent.data = uri
            }
            intent.putExtra(Browser.EXTRA_APPLICATION_ID, cordova.getActivity().getPackageName())
            this.cordova.getActivity().startActivity(intent)
            ""
            // not catching FileUriExposedException explicitly because buildtools<24 doesn't know about it
        } catch (e: RuntimeException) {
            LOG.d(LOG_TAG, "LocalTunnel: Error loading url $url:$e")
            e.toString()
        }
    }

    /**
     * Closes the dialog
     */
    fun closeDialog() {
        this.cordova.getActivity().runOnUiThread(Runnable {
            val childView = localTunnelWebView ?: return@Runnable
            // The JS protects against multiple calls, so this should happen only when
            // closeDialog() is called by other native code.
            childView.webViewClient = object : WebViewClient() {
                // NB: wait for about:blank before dismissing
                override fun onPageFinished(view: WebView, url: String) {
                    if (dialog != null) {
                        // https://stackoverflow.com/questions/22924825/view-not-attached-to-window-manager-crash
                        if (Build.VERSION.SDK_INT < 17 && !cordova.getActivity().isFinishing()) {
                            dialog!!.dismiss()
                        } else if (Build.VERSION.SDK_INT >= 17 && !cordova.getActivity().isDestroyed()) {
                            dialog!!.dismiss()
                        }
                        dialog = null
                    }
                    // NOTE(Alex) This used to be outside of this onPageFinished callback but it led to race conditions.
                    // Specifically, we would await an exit event but that event would occur before dialog had been set
                    // to null (which happens above). If you then called open again quickly enough, it became possible
                    // for the dialog of the new instance to be set to null by the above call. These leads to tons of
                    // wonkiness for the new dialog. The fix is to only say that we have exited after dialog is set to
                    // null
                    try {
                        val obj = JSONObject()
                        obj.put("type", EXIT_EVENT)
                        sendUpdate(obj, false)
                    } catch (ex: JSONException) {
                        LOG.d(LOG_TAG, "Should never happen")
                    }
                }
            }
            // NB: From SDK 19: "If you call methods on WebView from any thread
            // other than your app's UI thread, it can cause unexpected results."
            // http://developer.android.com/guide/webapps/migrating.html#Threads
            childView.loadUrl("about:blank")
        })
    }

    /**
     * Checks to see if it is possible to go back one page in history, then does so.
     */
    fun goBack() {
        if (localTunnelWebView!!.canGoBack()) {
            localTunnelWebView!!.goBack()
        }
    }

    /**
     * Can the web browser go back?
     * @return boolean
     */
    fun canGoBack(): Boolean {
        return localTunnelWebView!!.canGoBack()
    }

    /**
     * Has the user set the hardware back button to go back
     * @return boolean
     */
    fun hardwareBack(): Boolean {
        return hadwareBackButton
    }

    /**
     * Checks to see if it is possible to go forward one page in history, then does so.
     */
    private fun goForward() {
        if (localTunnelWebView!!.canGoForward()) {
            localTunnelWebView!!.goForward()
        }
    }

    /**
     * Navigate to the new page
     *
     * @param url to load
     */
    private fun navigate(url: String) {
        val imm = this.cordova.getActivity().getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(edittext!!.windowToken, 0)
        if (!url.startsWith("http") && !url.startsWith("file:")) {
            localTunnelWebView!!.loadUrl("http://$url")
        } else {
            localTunnelWebView!!.loadUrl(url)
        }
        localTunnelWebView!!.requestFocus()
    }

    private val localTunnel: LocalTunnel
        private get() = this

    /**
     * Display a new browser with the specified URL.
     *
     * @param url the url to load.
     * @param features jsonObject
     */
    fun showWebPage(url: String?, features: HashMap<String, String>?): String {
        // Determine if we should hide the location bar.
        showLocationBar = true
        showZoomControls = true
        openWindowHidden = false
        mediaPlaybackRequiresUserGesture = false
        captchaUrl = null
        requestUrl = null
        lastRequestUrl = null
        enableRequestBlocking = false
        if (features != null) {
            val show = features[LOCATION]
            if (show != null) {
                showLocationBar = if (show == "yes") true else false
            }
            if (showLocationBar) {
                val hideNavigation = features[HIDE_NAVIGATION]
                val hideUrl = features[HIDE_URL]
                if (hideNavigation != null) hideNavigationButtons = if (hideNavigation == "yes") true else false
                if (hideUrl != null) hideUrlBar = if (hideUrl == "yes") true else false
            }
            val zoom = features[ZOOM]
            if (zoom != null) {
                showZoomControls = if (zoom == "yes") true else false
            }
            val hidden = features[HIDDEN]
            if (hidden != null) {
                openWindowHidden = if (hidden == "yes") true else false
            }
            val hardwareBack = features[HARDWARE_BACK_BUTTON]
            hadwareBackButton = if (hardwareBack != null) {
                if (hardwareBack == "yes") true else false
            } else {
                DEFAULT_HARDWARE_BACK
            }
            val mediaPlayback = features[MEDIA_PLAYBACK_REQUIRES_USER_ACTION]
            if (mediaPlayback != null) {
                mediaPlaybackRequiresUserGesture = if (mediaPlayback == "yes") true else false
            }
            var cache = features[CLEAR_ALL_CACHE]
            if (cache != null) {
                clearAllCache = if (cache == "yes") true else false
            } else {
                cache = features[CLEAR_SESSION_CACHE]
                if (cache != null) {
                    clearSessionCache = if (cache == "yes") true else false
                }
            }
            val shouldPause = features[SHOULD_PAUSE]
            if (shouldPause != null) {
                shouldPauseLocalTunnel = if (shouldPause == "yes") true else false
            }
            val wideViewPort = features[USER_WIDE_VIEW_PORT]
            if (wideViewPort != null) {
                useWideViewPort = if (wideViewPort == "yes") true else false
            }
            val closeButtonCaptionSet = features[CLOSE_BUTTON_CAPTION]
            if (closeButtonCaptionSet != null) {
                closeButtonCaption = closeButtonCaptionSet
            }
            val closeButtonColorSet = features[CLOSE_BUTTON_COLOR]
            if (closeButtonColorSet != null) {
                closeButtonColor = closeButtonColorSet
            }
            val toolbarColorSet = features[TOOLBAR_COLOR]
            if (toolbarColorSet != null) {
                toolbarColor = Color.parseColor(toolbarColorSet)
            }
            val navigationButtonColorSet = features[NAVIGATION_COLOR]
            if (navigationButtonColorSet != null) {
                navigationButtonColor = navigationButtonColorSet
            }
            val showFooterSet = features[FOOTER]
            if (showFooterSet != null) {
                showFooter = if (showFooterSet == "yes") true else false
            }
            val footerColorSet = features[FOOTER_COLOR]
            if (footerColorSet != null) {
                footerColor = footerColorSet
            }
        }
        val thatWebView: CordovaWebView = this.webView
        val thatIAB = this

        // Create dialog in new thread
        val runnable: Runnable = object : Runnable {
            /**
             * Convert our DIP units to Pixels
             *
             * @return int
             */
            private fun dpToPixels(dipValue: Int): Int {
                return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP,
                        dipValue.toFloat(),
                        cordova.getActivity().getResources().getDisplayMetrics()
                ).toInt()
            }

            private fun createCloseButton(id: Int): View {
                val _close: View
                val activityRes: Resources = cordova.getActivity().getResources()
                if (closeButtonCaption !== "") {
                    // Use TextView for text
                    val close = TextView(cordova.getActivity())
                    close.text = closeButtonCaption
                    close.textSize = 20f
                    if (closeButtonColor !== "") close.setTextColor(Color.parseColor(closeButtonColor))
                    close.gravity = Gravity.CENTER_VERTICAL
                    close.setPadding(dpToPixels(10), 0, dpToPixels(10), 0)
                    _close = close
                } else {
                    val close = ImageButton(cordova.getActivity())
                    val closeResId = activityRes.getIdentifier("ic_action_remove", "drawable", cordova.getActivity().getPackageName())
                    val closeIcon = activityRes.getDrawable(closeResId)
                    if (closeButtonColor !== "") close.setColorFilter(Color.parseColor(closeButtonColor))
                    close.setImageDrawable(closeIcon)
                    close.scaleType = ImageView.ScaleType.FIT_CENTER
                    if (Build.VERSION.SDK_INT >= 16) close.adjustViewBounds
                    _close = close
                }
                val closeLayoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.MATCH_PARENT)
                closeLayoutParams.addRule(RelativeLayout.ALIGN_PARENT_RIGHT)
                _close.layoutParams = closeLayoutParams
                if (Build.VERSION.SDK_INT >= 16) _close.background = null else _close.setBackgroundDrawable(null)
                _close.contentDescription = "Close Button"
                _close.id = Integer.valueOf(id)
                _close.setOnClickListener { closeDialog() }
                return _close
            }

            @SuppressLint("NewApi")
            override fun run() {

                // CB-6702 LocalTunnel hangs when opening more than one instance
                if (dialog != null) {
                    dialog!!.dismiss()
                }

                // Let's create the main dialog
                dialog = LocalTunnelDialog(cordova.getActivity(), R.style.Theme_NoTitleBar)
                dialog!!.window.attributes.windowAnimations = R.style.Animation_Dialog
                dialog!!.requestWindowFeature(Window.FEATURE_NO_TITLE)
                dialog!!.setCancelable(true)
                dialog!!.setLocalTunnel(localTunnel)

                // Main container layout
                val main = LinearLayout(cordova.getActivity())
                main.orientation = LinearLayout.VERTICAL

                // Toolbar layout
                val toolbar = RelativeLayout(cordova.getActivity())
                //Please, no more black!
                toolbar.setBackgroundColor(toolbarColor)
                toolbar.layoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, dpToPixels(44))
                toolbar.setPadding(dpToPixels(2), dpToPixels(2), dpToPixels(2), dpToPixels(2))
                toolbar.setHorizontalGravity(Gravity.LEFT)
                toolbar.setVerticalGravity(Gravity.TOP)

                // Action Button Container layout
                val actionButtonContainer = RelativeLayout(cordova.getActivity())
                actionButtonContainer.layoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT)
                actionButtonContainer.setHorizontalGravity(Gravity.LEFT)
                actionButtonContainer.setVerticalGravity(Gravity.CENTER_VERTICAL)
                actionButtonContainer.id = Integer.valueOf(1)

                // Back button
                val back = ImageButton(cordova.getActivity())
                val backLayoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.MATCH_PARENT)
                backLayoutParams.addRule(RelativeLayout.ALIGN_LEFT)
                back.layoutParams = backLayoutParams
                back.contentDescription = "Back Button"
                back.id = Integer.valueOf(2)
                val activityRes: Resources = cordova.getActivity().getResources()
                val backResId = activityRes.getIdentifier("ic_action_previous_item", "drawable", cordova.getActivity().getPackageName())
                val backIcon = activityRes.getDrawable(backResId)
                if (navigationButtonColor !== "") back.setColorFilter(Color.parseColor(navigationButtonColor))
                if (Build.VERSION.SDK_INT >= 16) back.background = null else back.setBackgroundDrawable(null)
                back.setImageDrawable(backIcon)
                back.scaleType = ImageView.ScaleType.FIT_CENTER
                back.setPadding(0, dpToPixels(10), 0, dpToPixels(10))
                if (Build.VERSION.SDK_INT >= 16) back.adjustViewBounds
                back.setOnClickListener { goBack() }

                // Forward button
                val forward = ImageButton(cordova.getActivity())
                val forwardLayoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.MATCH_PARENT)
                forwardLayoutParams.addRule(RelativeLayout.RIGHT_OF, 2)
                forward.layoutParams = forwardLayoutParams
                forward.contentDescription = "Forward Button"
                forward.id = Integer.valueOf(3)
                val fwdResId = activityRes.getIdentifier("ic_action_next_item", "drawable", cordova.getActivity().getPackageName())
                val fwdIcon = activityRes.getDrawable(fwdResId)
                if (navigationButtonColor !== "") forward.setColorFilter(Color.parseColor(navigationButtonColor))
                if (Build.VERSION.SDK_INT >= 16) forward.background = null else forward.setBackgroundDrawable(null)
                forward.setImageDrawable(fwdIcon)
                forward.scaleType = ImageView.ScaleType.FIT_CENTER
                forward.setPadding(0, dpToPixels(10), 0, dpToPixels(10))
                if (Build.VERSION.SDK_INT >= 16) forward.adjustViewBounds
                forward.setOnClickListener { goForward() }

                // Edit Text Box
                edittext = EditText(cordova.getActivity())
                val textLayoutParams = RelativeLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                textLayoutParams.addRule(RelativeLayout.RIGHT_OF, 1)
                textLayoutParams.addRule(RelativeLayout.LEFT_OF, 5)
                edittext!!.layoutParams = textLayoutParams
                edittext!!.id = Integer.valueOf(4)
                edittext!!.setSingleLine(true)
                edittext!!.setText(url)
                edittext!!.inputType = InputType.TYPE_TEXT_VARIATION_URI
                edittext!!.imeOptions = EditorInfo.IME_ACTION_GO
                edittext!!.inputType = InputType.TYPE_NULL // Will not except input... Makes the text NON-EDITABLE
                edittext!!.setOnKeyListener(View.OnKeyListener { v, keyCode, event -> // If the event is a key-down event on the "enter" button
                    if (event.action == KeyEvent.ACTION_DOWN && keyCode == KeyEvent.KEYCODE_ENTER) {
                        navigate(edittext!!.text.toString())
                        return@OnKeyListener true
                    }
                    false
                })


                // Header Close/Done button
                val close = createCloseButton(5)
                toolbar.addView(close)

                // Footer
                val footer = RelativeLayout(cordova.getActivity())
                val _footerColor: Int
                _footerColor = if (footerColor !== "") {
                    Color.parseColor(footerColor)
                } else {
                    Color.LTGRAY
                }
                footer.setBackgroundColor(_footerColor)
                val footerLayout = RelativeLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, dpToPixels(44))
                footerLayout.addRule(RelativeLayout.ALIGN_PARENT_BOTTOM, RelativeLayout.TRUE)
                footer.layoutParams = footerLayout
                if (closeButtonCaption !== "") footer.setPadding(dpToPixels(8), dpToPixels(8), dpToPixels(8), dpToPixels(8))
                footer.setHorizontalGravity(Gravity.LEFT)
                footer.setVerticalGravity(Gravity.BOTTOM)
                val footerClose = createCloseButton(7)
                footer.addView(footerClose)


                // WebView
                localTunnelWebView = WebView(cordova.getActivity())
                // By default navigator.onLine is false.
                localTunnelWebView!!.setNetworkAvailable(true)
                localTunnelWebView!!.layoutParams = LinearLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                localTunnelWebView!!.id = Integer.valueOf(6)
                // File Chooser Implemented ChromeClient
                localTunnelWebView!!.webChromeClient = object : LocalTunnelChromeClient(thatWebView, localTunnel) {
                    // For Android 5.0+
                    override fun onShowFileChooser(webView: WebView, filePathCallback: ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean {
                        LOG.d(LOG_TAG, "File Chooser 5.0+")
                        // If callback exists, finish it.
                        if (mUploadCallbackLollipop != null) {
                            mUploadCallbackLollipop!!.onReceiveValue(null)
                        }
                        mUploadCallbackLollipop = filePathCallback

                        // Create File Chooser Intent
                        val content = Intent(Intent.ACTION_GET_CONTENT)
                        content.addCategory(Intent.CATEGORY_OPENABLE)
                        content.type = "*/*"

                        // Run cordova startActivityForResult
                        cordova.startActivityForResult(this@LocalTunnel, Intent.createChooser(content, "Select File"), FILECHOOSER_REQUESTCODE_LOLLIPOP)
                        return true
                    }

                    // For Android 4.1+
                    fun openFileChooser(uploadMsg: ValueCallback<Uri?>?, acceptType: String?, capture: String?) {
                        LOG.d(LOG_TAG, "File Chooser 4.1+")
                        // Call file chooser for Android 3.0+
                        openFileChooser(uploadMsg, acceptType)
                    }

                    // For Android 3.0+
                    fun openFileChooser(uploadMsg: ValueCallback<Uri?>?, acceptType: String?) {
                        LOG.d(LOG_TAG, "File Chooser 3.0+")
                        mUploadCallback = uploadMsg
                        val content = Intent(Intent.ACTION_GET_CONTENT)
                        content.addCategory(Intent.CATEGORY_OPENABLE)

                        // run startActivityForResult
                        cordova.startActivityForResult(this@LocalTunnel, Intent.createChooser(content, "Select File"), FILECHOOSER_REQUESTCODE)
                    }
                }
                val client: WebViewClient = LocalTunnelClient(thatWebView, edittext!!)
                localTunnelWebView!!.webViewClient = client
                val settings = localTunnelWebView!!.settings
                settings.javaScriptEnabled = true
                settings.javaScriptCanOpenWindowsAutomatically = true
                settings.builtInZoomControls = showZoomControls
                settings.pluginState = WebSettings.PluginState.ON
                // localTunnelWebView.addJavascriptInterface(new HTMLViewerJavaScriptInterface(thatIAB), "HtmlViewer");
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                    settings.mediaPlaybackRequiresUserGesture = mediaPlaybackRequiresUserGesture
                }
                val overrideUserAgent: String = preferences.getString("OverrideUserAgent", null)
                val appendUserAgent: String = preferences.getString("AppendUserAgent", null)
                if (overrideUserAgent != null) {
                    settings.userAgentString = overrideUserAgent
                }
                if (appendUserAgent != null) {
                    settings.userAgentString = settings.userAgentString + appendUserAgent
                }

                //Toggle whether this is enabled or not!
                val appSettings: Bundle = cordova.getActivity().getIntent().getExtras()
                val enableDatabase = appSettings?.getBoolean("LocalTunnelStorageEnabled", true)
                        ?: true
                if (enableDatabase) {
                    val databasePath: String = cordova.getActivity().getApplicationContext().getDir("localTunnelDB", Context.MODE_PRIVATE).getPath()
                    settings.databasePath = databasePath
                    settings.databaseEnabled = true
                }
                settings.domStorageEnabled = true
                if (clearAllCache) {
                    CookieManager.getInstance().removeAllCookie()
                } else if (clearSessionCache) {
                    CookieManager.getInstance().removeSessionCookie()
                }

                // Enable Thirdparty Cookies on >=Android 5.0 device
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    CookieManager.getInstance().setAcceptThirdPartyCookies(localTunnelWebView, true)
                }
                localTunnelWebView!!.loadUrl(url)
                localTunnelWebView!!.id = Integer.valueOf(6)
                localTunnelWebView!!.settings.loadWithOverviewMode = true
                localTunnelWebView!!.settings.useWideViewPort = useWideViewPort
                localTunnelWebView!!.requestFocus()
                localTunnelWebView!!.requestFocusFromTouch()

                // Add the back and forward buttons to our action button container layout
                actionButtonContainer.addView(back)
                actionButtonContainer.addView(forward)

                // Add the views to our toolbar if they haven't been disabled
                if (!hideNavigationButtons) toolbar.addView(actionButtonContainer)
                if (!hideUrlBar) toolbar.addView(edittext)

                // Don't add the toolbar if its been disabled
                if (showLocationBar) {
                    // Add our toolbar to our main view/layout
                    main.addView(toolbar)
                }

                // Add our webview to our main view/layout
                val webViewLayout = RelativeLayout(cordova.getActivity())
                webViewLayout.addView(localTunnelWebView)
                main.addView(webViewLayout)

                // Don't add the footer unless it's been enabled
                if (showFooter) {
                    webViewLayout.addView(footer)
                }
                val lp = WindowManager.LayoutParams()
                lp.copyFrom(dialog!!.window.attributes)
                lp.width = WindowManager.LayoutParams.MATCH_PARENT
                lp.height = WindowManager.LayoutParams.MATCH_PARENT
                dialog!!.setContentView(main)
                dialog!!.show()
                dialog!!.window.attributes = lp
                // the goal of openhidden is to load the url and not display it
                // Show() needs to be called to cause the URL to be loaded
                if (openWindowHidden) {
                    dialog!!.hide()
                }
            }
        }
        this.cordova.getActivity().runOnUiThread(runnable)
        return ""
    }

    fun clearCookiesForDomain(domain: String?) {
        val cookieManager = CookieManager.getInstance()
        val cookiestring = cookieManager.getCookie(domain)
        if (cookiestring != null) {
            val cookies = cookiestring.split(";".toRegex()).toTypedArray()
            for (i in cookies.indices) {
                val cookieparts = cookies[i].split("=".toRegex()).toTypedArray()
                cookieManager.setCookie(domain, cookieparts[0].trim { it <= ' ' } + "=; Expires=Wed, 31 Dec 2025 23:59:59 GMT")
            }
        }
    }

    /**
     * Display a new browser with the specified URL.
     *
     * @param url the url to load.
     * @param features jsonObject
     */
    @Throws(JSONException::class)
    fun showCaptchaPage(url: String?, features: HashMap<String, String>?, args: CordovaArgs): String {
        val captchaOptionsJson: String = args.optString(3)
        val captchaOptions = JSONObject(captchaOptionsJson)
        val captchaCookies = captchaOptions.getJSONObject("cookies")
        val content = captchaOptions.getString("content")
        val userAgent = captchaOptions.getString("useragent")
        val captchaHidden = captchaOptions.getBoolean("hidden")
        val thatWebView: CordovaWebView = this.webView
        val thatIAB = this
        captchaUrl = url

        // Create dialog in new thread
        val runnable: Runnable = object : Runnable {
            private fun dpToPixels(dipValue: Int): Int {
                return TypedValue.applyDimension(
                        TypedValue.COMPLEX_UNIT_DIP,
                        dipValue.toFloat(),
                        cordova.getActivity().getResources().getDisplayMetrics()).toInt()
            }

            @SuppressLint("NewApi")
            override fun run() {
                val cookieManager = CookieManager.getInstance()

                // CB-6702 LocalTunnel hangs when opening more than one instance
                if (dialog != null) {
                    dialog!!.dismiss()
                    dialog = null
                }
                if (dialog == null) {
                    // Edit Text Box
                    edittext = EditText(cordova.getActivity())

                    // Let's create the main dialog
                    dialog = LocalTunnelDialog(cordova.getActivity(), R.style.Theme_NoTitleBar)
                    dialog!!.window.attributes.windowAnimations = R.style.Animation_Dialog
                    dialog!!.requestWindowFeature(Window.FEATURE_NO_TITLE)
                    dialog!!.setCancelable(true)
                    dialog!!.setLocalTunnel(localTunnel)

                    // Main container layout
                    val main = LinearLayout(cordova.getActivity())
                    main.orientation = LinearLayout.VERTICAL

                    // WebView
                    localTunnelWebView = WebView(cordova.getActivity())
                    localTunnelWebView!!.layoutParams = LinearLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                    localTunnelWebView!!.id = Integer.valueOf(6)
                    localTunnelWebView!!.webChromeClient = LocalTunnelChromeClient(thatWebView, localTunnel)
                    val client: WebViewClient = LocalTunnelClient(thatWebView, edittext!!)
                    localTunnelWebView!!.webViewClient = client
                    val settings = localTunnelWebView!!.settings
                    settings.javaScriptEnabled = true
                    settings.javaScriptCanOpenWindowsAutomatically = true
                    settings.builtInZoomControls = false
                    settings.pluginState = WebSettings.PluginState.ON
                    settings.userAgentString = userAgent
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                        settings.mediaPlaybackRequiresUserGesture = mediaPlaybackRequiresUserGesture
                    }

                    //Toggle whether this is enabled or not!
                    val appSettings: Bundle = cordova.getActivity().getIntent().getExtras()
                    val enableDatabase = appSettings?.getBoolean("LocalTunnelStorageEnabled", true)
                            ?: true
                    if (enableDatabase) {
                        val databasePath: String = cordova.getActivity().getApplicationContext().getDir("localTunnelDB", Context.MODE_PRIVATE).getPath()
                        settings.databasePath = databasePath
                        settings.databaseEnabled = true
                    }
                    settings.domStorageEnabled = true
                    captchaUrl = "about:blank"
                    localTunnelWebView!!.loadDataWithBaseURL(url, content, "text/html", "UTF-8", null)
                    localTunnelWebView!!.id = Integer.valueOf(6)
                    localTunnelWebView!!.settings.loadWithOverviewMode = true
                    localTunnelWebView!!.settings.useWideViewPort = useWideViewPort
                    localTunnelWebView!!.requestFocus()
                    localTunnelWebView!!.requestFocusFromTouch()

                    // Add our webview to our main view/layout
                    val webViewLayout = RelativeLayout(cordova.getActivity())
                    webViewLayout.addView(localTunnelWebView)
                    main.addView(webViewLayout)
                    val lp = WindowManager.LayoutParams()
                    lp.copyFrom(dialog!!.window.attributes)
                    lp.width = WindowManager.LayoutParams.MATCH_PARENT
                    lp.height = WindowManager.LayoutParams.MATCH_PARENT
                    dialog!!.setContentView(main)
                    dialog!!.window.attributes = lp
                }
                if (!captchaHidden) {
                    dialog!!.show()
                }
            }
        }
        this.cordova.getActivity().runOnUiThread(runnable)
        return ""
    }

    /**
     * Display a new browser with the specified URL.
     *
     * @param url the url to load.
     * @param features jsonObject
     */
    @Throws(JSONException::class)
    fun makeHttpRequest(url: String?, features: HashMap<String, String>?, args: CordovaArgs): String {
        val requestOptionsJson: String = args.optString(3)
        val requestOptions = JSONObject(requestOptionsJson)
        val requestParams = requestOptions.getJSONObject("params")
        val requestHeaders = requestOptions.getJSONObject("headers")
        val requestCookies = requestOptions.getString("cookies")
        val method = requestOptions.getString("method")
        val userAgent = requestOptions.getString("useragent")
        val thatWebView: CordovaWebView = this.webView
        val thatIAB = this
        requestUrl = url
        lastRequestUrl = url
        openWindowHidden = true
        enableRequestBlocking = requestOptions.getBoolean("enable_request_blocking")
        if (features != null) {
            val hidden = features[HIDDEN]
            if (hidden != null && hidden == "no") {
                openWindowHidden = false
            }
        }

        // Create dialog in new thread
        val runnable: Runnable = object : Runnable {
            private fun dpToPixels(dipValue: Int): Int {
                return TypedValue.applyDimension(
                        TypedValue.COMPLEX_UNIT_DIP,
                        dipValue.toFloat(),
                        cordova.getActivity().getResources().getDisplayMetrics()).toInt()
            }

            @SuppressLint("NewApi")
            override fun run() {
                val cookieManager = CookieManager.getInstance()

                // CB-6702 LocalTunnel hangs when opening more than one instance
                // ram: Create a new thing called tunnel dialog.
                if (dialog == null) {
                    // Edit Text Box
                    edittext = EditText(cordova.getActivity())

                    // Let's create the main dialog
                    dialog = LocalTunnelDialog(cordova.getActivity(), R.style.Theme_NoTitleBar)
                    dialog!!.window.attributes.windowAnimations = R.style.Animation_Dialog
                    dialog!!.requestWindowFeature(Window.FEATURE_NO_TITLE)
                    dialog!!.setCancelable(true)
                    dialog!!.setLocalTunnel(localTunnel)

                    // Main container layout
                    val main = LinearLayout(cordova.getActivity())
                    main.orientation = LinearLayout.VERTICAL

                    // WebView
                    localTunnelWebView = WebView(cordova.getActivity())
                    localTunnelWebView!!.layoutParams = LinearLayout.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                    localTunnelWebView!!.id = Integer.valueOf(6)
                    localTunnelWebView!!.webChromeClient = LocalTunnelChromeClient(thatWebView, localTunnel)
                    val client: WebViewClient = LocalTunnelClient(thatWebView, edittext!!)
                    localTunnelWebView!!.webViewClient = client
                    val settings = localTunnelWebView!!.settings
                    settings.javaScriptEnabled = true
                    // localTunnelWebView.addJavascriptInterface(new HTMLViewerJavaScriptInterface(), "HtmlViewer");
                    settings.javaScriptCanOpenWindowsAutomatically = true
                    settings.builtInZoomControls = false
                    settings.pluginState = WebSettings.PluginState.ON
                    settings.userAgentString = userAgent
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                        settings.mediaPlaybackRequiresUserGesture = mediaPlaybackRequiresUserGesture
                    }

                    //Toggle whether this is enabled or not!
                    val appSettings: Bundle = cordova.getActivity().getIntent().getExtras()
                    val enableDatabase = appSettings?.getBoolean("LocalTunnelStorageEnabled", true)
                            ?: true
                    if (enableDatabase) {
                        val databasePath: String = cordova.getActivity().getApplicationContext().getDir("localTunnelDB", Context.MODE_PRIVATE).getPath()
                        settings.databasePath = databasePath
                        settings.databaseEnabled = true
                    }
                    settings.domStorageEnabled = true
                    localTunnelWebView!!.id = Integer.valueOf(6)
                    localTunnelWebView!!.settings.loadWithOverviewMode = true
                    localTunnelWebView!!.settings.useWideViewPort = useWideViewPort
                    localTunnelWebView!!.requestFocus()
                    localTunnelWebView!!.requestFocusFromTouch()

                    // Add our webview to our main view/layout
                    val webViewLayout = RelativeLayout(cordova.getActivity())
                    webViewLayout.addView(localTunnelWebView)
                    main.addView(webViewLayout)
                    val lp = WindowManager.LayoutParams()
                    lp.copyFrom(dialog!!.window.attributes)
                    lp.width = WindowManager.LayoutParams.MATCH_PARENT
                    lp.height = WindowManager.LayoutParams.MATCH_PARENT

                    // Enable Thirdparty Cookies on >=Android 5.0 device
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        cookieManager.setAcceptThirdPartyCookies(localTunnelWebView, true)
                    }
                    dialog!!.setContentView(main)
                    dialog!!.show()
                    dialog!!.window.attributes = lp
                }
                var isContentJSON: Boolean? = null
                isContentJSON = try {
                    requestHeaders.getString("Content-Type") == "application/json"
                } catch (ex: JSONException) {
                    false
                }
                if (method == "get") {
                    localTunnelWebView!!.loadUrl(url)
                } else if (method == "post" && isContentJSON!!) {
                    val jsCode = String.format(
                            "var oReq = new XMLHttpRequest();" +
                                    "oReq.onload = function() {" +
                                    "    window._HTML = '<html><body>' + this.responseText + '</body></html>';" +
                                    "    prompt(JSON.stringify([this.status, this.statusText]), 'gap-iab://requestdone');" +
                                    "};" +
                                    "oReq.onerror = function() {" +
                                    "    window._HTML = '<html><body>' + this.responseText + '</body></html>';" +
                                    "    prompt(JSON.stringify([this.status, 'Load error']), 'gap-iab://requestdone');" +
                                    "};" +
                                    "oReq.open('post', '%s');" +
                                    "oReq.setRequestHeader('Content-Type', 'application/json;charset=UTF-8');" +
                                    "oReq.send(JSON.stringify(%s));",
                            url,
                            requestParams.toString()
                    )
                    cordova.getActivity().runOnUiThread(Runnable { localTunnelWebView!!.evaluateJavascript(jsCode, null) })
                } else if (method == "post") {
                    val postDataList: MutableList<String> = ArrayList()
                    val params = requestParams.keys()
                    while (params.hasNext()) {
                        try {
                            val param = params.next()
                            val paramValue = requestParams.getString(param)
                            postDataList.add(param + "=" + URLEncoder.encode(paramValue, "UTF-8"))
                        } catch (ex: JSONException) {
                            LOG.e(LOG_TAG, "Should never happen", ex)
                        } catch (ex: UnsupportedEncodingException) {
                            LOG.e(LOG_TAG, "Should never happen", ex)
                        }
                    }
                    var postData = ""
                    for (str in postDataList) {
                        if (postData !== "") {
                            postData += "&"
                        }
                        postData += str
                    }
                    localTunnelWebView!!.postUrl(url, postData.toByteArray())
                }
                if (openWindowHidden) {
                    dialog!!.hide()
                }
            }
        }
        this.cordova.getActivity().runOnUiThread(runnable)
        return ""
    }
    /**
     * Create a new plugin result and send it back to JavaScript
     *
     * @param obj a JSONObject contain event payload information
     * @param status the status code to return to the JavaScript environment
     */
    /**
     * Create a new plugin success result and send it back to JavaScript
     *
     * @param obj a JSONObject contain event payload information
     */
    private fun sendUpdate(obj: JSONObject, keepCallback: Boolean, status: PluginResult.Status = PluginResult.Status.OK) {
        val ctx = callbackContext;
        if (ctx != null) {
            val result = PluginResult(status, obj)
            result.setKeepCallback(keepCallback)
            ctx.sendPluginResult(result)
            if (!keepCallback) {
                callbackContext = null
            }
        }
    }

    /**
     * Create a new plugin result and send it back to JavaScript
     *
     * @param obj a JSONObject contain event payload information
     * @param status the status code to return to the JavaScript environment
     */
    fun sendRequestDone(status: Int, statusText: String?) {
        if (status >= 200 && status < 400) {
            try {
                val obj = JSONObject()
                obj.put("type", HTTP_REQUEST_DONE)
                val cookies = CookieManager.getInstance().getCookie(requestUrl)
                obj.put("cookies", cookies)
                obj.put("url", requestUrl)
                sendUpdate(obj, true)
            } catch (ex: JSONException) {
                LOG.e(LOG_TAG, "Should never happen", ex)
            }
        } else {
            try {
                val obj = JSONObject()
                obj.put("type", LOAD_ERROR_EVENT)
                obj.put("url", requestUrl)
                obj.put("code", status)
                obj.put("message", statusText)
                sendUpdate(obj, true)
            } catch (ex: JSONException) {
                LOG.e(LOG_TAG, "Should never happen", ex)
            }
        }
    }

    /**
     * Receive File Data from File Chooser
     *
     * @param requestCode the requested code from chromeclient
     * @param resultCode the result code returned from android system
     * @param intent the data from android file chooser
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, intent: Intent?) {
        // For Android >= 5.0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            LOG.d(LOG_TAG, "onActivityResult (For Android >= 5.0)")
            // If RequestCode or Callback is Invalid
            if (requestCode != FILECHOOSER_REQUESTCODE_LOLLIPOP || mUploadCallbackLollipop == null) {
                super.onActivityResult(requestCode, resultCode, intent)
                return
            }
            mUploadCallbackLollipop!!.onReceiveValue(FileChooserParams.parseResult(resultCode, intent))
            mUploadCallbackLollipop = null
        } else {
            LOG.d(LOG_TAG, "onActivityResult (For Android < 5.0)")
            // If RequestCode or Callback is Invalid
            if (requestCode != FILECHOOSER_REQUESTCODE || mUploadCallback == null) {
                super.onActivityResult(requestCode, resultCode, intent)
                return
            }
            val _uploadCallback = mUploadCallback
            if (_uploadCallback != null) {
                val result = if (intent == null || resultCode != Activity.RESULT_OK) null else intent.data
                _uploadCallback.onReceiveValue(result)
                mUploadCallback = null
            }
        }
    }

    /**
     * The webview client receives notifications about appView
     */
    inner class LocalTunnelClient(webView: CordovaWebView, mEditText: EditText) : WebViewClient() {
        var edittext: EditText
        var webView: CordovaWebView

        /**
         * Override the URL that should be loaded
         *
         * This handles a small subset of all the URIs that would be encountered.
         *
         * @param webView
         * @param url
         */
        override fun shouldInterceptRequest(webView: WebView, url: String): WebResourceResponse? {
            try {
                if (enableRequestBlocking && requestUrl != url) {
                    LOG.d(LOG_TAG, "REQUEST BLOCKED: $url")
                    val data: InputStream = ByteArrayInputStream("REQUEST BLOCKED".toByteArray(charset("UTF-8")))
                    return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
                        WebResourceResponse("text/html", "UTF-8", data)
                    } else {
                        val responseHeaders: Map<String, String> = HashMap()
                        WebResourceResponse(
                                "text/html", "UTF-8", 500, "Request blocked.",
                                responseHeaders, data)
                    }
                }
            } catch (ex: UnsupportedEncodingException) {
                LOG.e(LOG_TAG, "Should never happen", ex)
            }
            return super.shouldInterceptRequest(webView, url)
        }

        /**
         * Override the URL that should be loaded
         *
         * This handles a small subset of all the URIs that would be encountered.
         *
         * @param webView
         * @param url
         */
        override fun shouldOverrideUrlLoading(webView: WebView, url: String): Boolean {
            LOG.d(LOG_TAG, "shouldOverrideUrlLoading: $url")
            if (url.contains("chfs.non-pci.portmapper.vip")) {
                val actualUrl = url.replace("chfs.non-pci.portmapper.vip:[0-9]+".toRegex(), "www.connectebt.com")
                requestUrl = actualUrl
                lastRequestUrl = actualUrl
                webView.loadUrl(actualUrl)
                return true
            } else if (requestUrl != null && requestUrl != url) {
                LOG.d(LOG_TAG, "Handle page redirect from: $requestUrl")
                requestUrl = url
                lastRequestUrl = url
            } else if (captchaUrl != null) {
                LOG.d(LOG_TAG, "Closing the captcha loop")
                try {
                    val obj = JSONObject()
                    obj.put("type", CAPTCHA_DONE_EVENT)
                    val cookies = CookieManager.getInstance().getCookie(captchaUrl)
                    obj.put("cookies", cookies)
                    obj.put("url", captchaUrl)
                    sendUpdate(obj, true)
                } catch (ex: JSONException) {
                    LOG.e(LOG_TAG, "URI passed in has caused a JSON error.")
                }
                captchaUrl = null
                // closeDialog();
                return true
            } else if (url.startsWith(WebView.SCHEME_TEL)) {
                try {
                    val intent = Intent(Intent.ACTION_DIAL)
                    intent.data = Uri.parse(url)
                    cordova.getActivity().startActivity(intent)
                    return true
                } catch (e: ActivityNotFoundException) {
                    LOG.e(LOG_TAG, "Error dialing $url: $e")
                }
            } else if (url.startsWith("geo:") || url.startsWith(WebView.SCHEME_MAILTO) || url.startsWith("market:") || url.startsWith("intent:")) {
                try {
                    val intent = Intent(Intent.ACTION_VIEW)
                    intent.data = Uri.parse(url)
                    cordova.getActivity().startActivity(intent)
                    return true
                } catch (e: ActivityNotFoundException) {
                    LOG.e(LOG_TAG, "Error with $url: $e")
                }
            } else if (url.startsWith("sms:")) {
                try {
                    val intent = Intent(Intent.ACTION_VIEW)

                    // Get address
                    var address: String? = null
                    val parmIndex = url.indexOf('?')
                    if (parmIndex == -1) {
                        address = url.substring(4)
                    } else {
                        address = url.substring(4, parmIndex)

                        // If body, then set sms body
                        val uri = Uri.parse(url)
                        val query = uri.query
                        if (query != null) {
                            if (query.startsWith("body=")) {
                                intent.putExtra("sms_body", query.substring(5))
                            }
                        }
                    }
                    intent.data = Uri.parse("sms:$address")
                    intent.putExtra("address", address)
                    intent.type = "vnd.android-dir/mms-sms"
                    cordova.getActivity().startActivity(intent)
                    return true
                } catch (e: ActivityNotFoundException) {
                    LOG.e(LOG_TAG, "Error sending sms $url:$e")
                }
            }
            return false
        }

        /*
         * onPageStarted fires the LOAD_RESOURCE_EVENT
         *
         * @param view
         * @param url
         */
        override fun onLoadResource(view: WebView, url: String) {
            LOG.d(LOG_TAG, "LOADING RESOURCE: $url")
            try {
                val obj = JSONObject()
                obj.put("type", LOAD_RESOURCE_EVENT)
                obj.put("url", url)
                sendUpdate(obj, true)
            } catch (ex: JSONException) {
                LOG.e(LOG_TAG, "URI passed in has caused a JSON error.")
            }
            super.onLoadResource(view, url)
        }

        /*
         * onPageStarted fires the LOAD_START_EVENT
         *
         * @param view
         * @param url
         * @param favicon
         */
        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            super.onPageStarted(view, url, favicon)
            val newloc = if (url.startsWith("http:") || url.startsWith("https:") || url.startsWith("file:")) {
                url
            } else {
                // Assume that everything is HTTP at this point, because if we don't specify,
                // it really should be.  Complain loudly about this!!!
                LOG.e(LOG_TAG, "Possible Uncaught/Unknown URI")
                "http://$url"
            }

            // Update the UI if we haven't already
            if (newloc != edittext.text.toString()) {
                edittext.setText(newloc)
            }
            try {
                val obj = JSONObject()
                obj.put("type", LOAD_START_EVENT)
                obj.put("url", newloc)
                sendUpdate(obj, true)
            } catch (ex: JSONException) {
                LOG.e(LOG_TAG, "URI passed in has caused a JSON error.")
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            super.onPageFinished(view, url)

            // CB-10395 LocalTunnel's WebView not storing cookies reliable to local device storage
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                CookieManager.getInstance().flush()
            } else {
                CookieSyncManager.getInstance().sync()
            }
            LOG.d(LOG_TAG, "PAGE FINISHED: $url")
            if (url == requestUrl) {
                sendRequestDone(200, "")
                requestUrl = null
                enableRequestBlocking = false
            }

            // https://issues.apache.org/jira/browse/CB-11248
            view.clearFocus()
            view.requestFocus()
            try {
                val obj = JSONObject()
                obj.put("type", LOAD_STOP_EVENT)
                obj.put("url", url)
                sendUpdate(obj, true)
            } catch (ex: JSONException) {
                LOG.d(LOG_TAG, "Should never happen")
            }
        }

        override fun onReceivedError(view: WebView, errorCode: Int, description: String, failingUrl: String) {
            super.onReceivedError(view, errorCode, description, failingUrl)
            sendRequestDone(errorCode, description)
        }

        /**
         * On received http auth request.
         */
        override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) {

            // Check if there is some plugin which can resolve this auth challenge
            var pluginManager: PluginManager? = null
            try {
                val gpm: Method = webView.javaClass.getMethod("getPluginManager")
                pluginManager = gpm.invoke(webView) as PluginManager
            } catch (e: NoSuchMethodException) {
                LOG.d(LOG_TAG, e.localizedMessage)
            } catch (e: IllegalAccessException) {
                LOG.d(LOG_TAG, e.localizedMessage)
            } catch (e: InvocationTargetException) {
                LOG.d(LOG_TAG, e.localizedMessage)
            }
            if (pluginManager == null) {
                try {
                    val pmf: Field = webView.javaClass.getField("pluginManager")
                    pluginManager = pmf[webView] as PluginManager
                } catch (e: NoSuchFieldException) {
                    LOG.d(LOG_TAG, e.localizedMessage)
                } catch (e: IllegalAccessException) {
                    LOG.d(LOG_TAG, e.localizedMessage)
                }
            }
            if (pluginManager != null && pluginManager.onReceivedHttpAuthRequest(webView, CordovaHttpAuthHandler(handler), host, realm)) {
                return
            }

            // By default handle 401 like we'd normally do!
            super.onReceivedHttpAuthRequest(view, handler, host, realm)
        }

        /**
         * Constructor.
         *
         * @param webView
         * @param mEditText
         */
        init {
            this.webView = webView
            this.edittext = mEditText
        }
    }

    companion object {
        private const val NULL = "null"
        protected const val LOG_TAG = "LocalTunnel"
        private const val SELF = "_self"
        private const val SYSTEM = "_system"
        private const val CAPTCHA = "_captcha"
        private const val HTTP_REQUEST = "_httprequest"
        private const val CLEAR_COOKIES = "_clearcookies"
        private const val EXIT_EVENT = "exit"
        private const val LOCATION = "location"
        private const val ZOOM = "zoom"
        private const val HIDDEN = "hidden"
        private const val LOAD_START_EVENT = "loadstart"
        private const val LOAD_STOP_EVENT = "loadstop"
        private const val LOAD_ERROR_EVENT = "loaderror"
        private const val LOAD_RESOURCE_EVENT = "loadresource"
        private const val CAPTCHA_DONE_EVENT = "captchadone"
        private const val HTTP_REQUEST_DONE = "requestdone"
        private const val CLEAR_ALL_CACHE = "clearcache"
        private const val CLEAR_SESSION_CACHE = "clearsessioncache"
        private const val HARDWARE_BACK_BUTTON = "hardwareback"
        private const val MEDIA_PLAYBACK_REQUIRES_USER_ACTION = "mediaPlaybackRequiresUserAction"
        private const val SHOULD_PAUSE = "shouldPauseOnSuspend"
        private const val DEFAULT_HARDWARE_BACK = true
        private const val USER_WIDE_VIEW_PORT = "useWideViewPort"
        private const val TOOLBAR_COLOR = "toolbarcolor"
        private const val CLOSE_BUTTON_CAPTION = "closebuttoncaption"
        private const val CLOSE_BUTTON_COLOR = "closebuttoncolor"
        private const val HIDE_NAVIGATION = "hidenavigationbuttons"
        private const val NAVIGATION_COLOR = "navigationbuttoncolor"
        private const val HIDE_URL = "hideurlbar"
        private const val FOOTER = "footer"
        private const val FOOTER_COLOR = "footercolor"
        private val customizableOptions: List<*> = Arrays.asList(CLOSE_BUTTON_CAPTION, TOOLBAR_COLOR, NAVIGATION_COLOR, CLOSE_BUTTON_COLOR, FOOTER_COLOR)
        private const val FILECHOOSER_REQUESTCODE = 1
        private const val FILECHOOSER_REQUESTCODE_LOLLIPOP = 2
    }
}