/*
Important resources for developing this plugin
* https://developer.apple.com/documentation/webkit/wkwebview
    * https://developer.apple.com/documentation/webkit/wkwebview/1415004-loadhtmlstring
* https://developer.apple.com/documentation/webkit/wkwebviewconfiguration
* https://developer.apple.com/documentation/webkit/wkpreferences
* https://developer.apple.com/documentation/webkit/wkusercontentcontroller

* https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
* https://developer.apple.com/documentation/webkit/wkuserscriptinjectiontime

* https://developer.apple.com/documentation/webkit/wkwebsitedatastore
* https://developer.apple.com/documentation/webkit/wkhttpcookiestore
* https://developer.apple.com/documentation/webkit/wkhttpcookiestoreobserver

* https://developer.apple.com/documentation/foundation/urlrequest
* https://developer.apple.com/documentation/foundation/urlauthenticationchallenge

* https://developer.apple.com/documentation/webkit/wknavigationaction
* https://developer.apple.com/documentation/webkit/wknavigationresponse
*/


import UIKit
import WebKit

let CLEAR_COOKIES_REQUEST = "_clearcookies"
let HTTP_REQUEST = "_httprequest"
let CAPTCHA_REQUEST = "_captcha"

struct RequestOptions {
    var blockNonEssentialRequests: Bool
    var fileExtensionsToBlock: [String]
    var displayWebview: Bool
    var isContentJSON: Bool
    var method: String
    var headers: [String: String]
    var requestType: String
    var url: String

    var captchaContentHtml: String?
    var cookies: String?
    var params: [String: Any]?
    var userAgent: String?
}

/*
    This protocol gives the WebViewController a simple interface to let the communicate
    with the CDVWKLocalTunnel class
*/
protocol WebViewPropagateDelegate {
    var requestStatus: Int? {get set}

    func requestDidSucceed(request: URLRequest?,  response: HTTPURLResponse?)
    func requestDidFail(request: URLRequest?,  error: URLError)
    func shouldStartLoadForURL(request: URLRequest) -> Bool
    func webViewControllerDidClose()
}

/*
    CDVWKLocalTunnel is the main cordova class. It is responsible for responding to all
    requests from the javascript layer. It is also responsible for communicating back to
    the javascript layer when important events occur.

    CDVWKLocalTunnel exposes three methods the javascript layer can call
        * open
        * close
        * injectScriptCode

    CDVWKLocalTunnel communicates back to the javascript layer using the `self.commandDelegate.send`
    call. This call expects a PluginResponse and a valid callback id
*/

@objc(CDVWKLocalTunnel) class CDVWKLocalTunnel : CDVPlugin, WebViewPropagateDelegate {
    var webViewController: WebViewViewController?
    var webViewIsVisible = false

    var requestStatus: Int?

    var requestOptions: RequestOptions?

    var captchaCount = 0

    var openCallbackId: String?

    var clearCookiesOnNextRequest = false

    var webDriverSession = false

    func resetState() {
        self.requestStatus = nil

        self.requestOptions = nil

        self.captchaCount = 0

        self.openCallbackId = nil
    }

    /*
        open is responsible for handling three different types of requests
            1. CLEAR_COOKIES_REQUEST - clears all cookies in the WKWebview
            2. HTTP_REQUEST - runs a request based off of the requestOptions passed in
            3. CAPTCHA_REQUEST - opens a WKWebview with the provided content and url.
            It explicitly does not make a request to a server. It expects that the
            content passed in will generate the next step
    */
    @objc(open:)
    func open(command: CDVInvokedUrlCommand) {
        self.resetState()
        self.requestOptions = self.createRequestOptions(command: command)
        self.openCallbackId = command.callbackId;

        print("Running open with \nrequest_options: \(self.requestOptions)")

        // The javascript client expects that calling open(..., "_clearcookies") should
        // clear the cookies synchronously. WKWebivew cannot clear cookies synchronously.
        // To properly handle this, we synchronously set a variable. On the next request, we clear the cookies and cleanup the variable
        if self.requestOptions?.requestType == CLEAR_COOKIES_REQUEST {
            self.clearCookiesOnNextRequest = true
            return
        }

        let runOpen = {
            if self.requestOptions?.displayWebview ?? false {
                self.showWebView()
            } else {
                self.hideWebView()
            }

            let makeRequestsBlock = {
                if self.requestOptions?.requestType == HTTP_REQUEST {
                    var request: URLRequest
                    if self.requestOptions?.method.lowercased() == "post" {
                        let postType = self.requestOptions!.isContentJSON ? "json" : "form"
                        request = createRequest(urlString: self.requestOptions!.url, method: self.requestOptions!.method, params: self.requestOptions!.params, headers: self.requestOptions!.headers, postType: postType)
                    } else {
                        request = createRequest(urlString: self.requestOptions?.url ?? "", method: self.requestOptions?.method ?? "GET", params: self.requestOptions?.params, headers: self.requestOptions!.headers)
                    }

                    // This implies we are webdriving code. We need to use normal loads
                    // for the totality of requests made after web driving in order to
                    // ensure that cookies are handled properly in the WKWebView
                    if (self.requestOptions?.blockNonEssentialRequests == false) {
                        self.webDriverSession = true
                    }

                    if self.webDriverSession {
                        self.webViewController?.load(request)
                    } else {
                        self.webViewController?.urlSessionLoad(request, requestOptions: self.requestOptions)
                    }
                } else if self.requestOptions?.requestType == CAPTCHA_REQUEST {
                    self.webViewController?.loadHTMLString(self.requestOptions?.captchaContentHtml ?? "", baseURL: createBaseURL(URL(string: self.requestOptions?.url ?? "")!))
                }
            }

            if self.clearCookiesOnNextRequest {
                self.clearCookiesOnNextRequest = false
                self.webViewController?.clearCookies {
                    makeRequestsBlock()
                }
            } else {
                makeRequestsBlock()
            }
        }

        if self.webViewController == nil  && self.requestOptions != nil{
            self.webViewController = WebViewViewController()
            self.webViewController?.propagateDelegate = self;
            self.webViewController?.createWebView(self.requestOptions!, completionHandler: runOpen)
        } else if self.requestOptions != nil {
            self.webViewController?.updateWebView(self.requestOptions!, completionHandler: runOpen)
        }
    }

    @objc(close:)
    func close(command: CDVInvokedUrlCommand) {
        print("Running close")
        self.destroyWebViewController()
    }

    func destroyWebViewController() {
        self.webDriverSession = false
        self.hideWebView()
        self.webViewController?.close()
    }

    @objc(getAllCookies:)
    func getAllCookies(command: CDVInvokedUrlCommand) {
        print("Running get all cookies")
        self.webViewController?.getCookies { cookies in
            print("Current Cookies in WKWebview \(cookies)")
            let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [
                    "type": "cookies",
                    "cookies": convertCookiesToString(cookies)
                ])
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
            }
    }

    @objc(injectScriptCode:)
    func injectScriptCode(command: CDVInvokedUrlCommand) {
        let jsCode = command.arguments[0] as? String ?? ""

        print("Running injectScriptCode with \njavascript: \(jsCode)")

        self.webViewController?.runJavascript(jsCode: jsCode, completionHandler: { returnVal, error in
            if error == nil {
                let jsResponse = returnVal as? String ?? ""
                let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [jsResponse])
                pluginResult?.setKeepCallbackAs(true)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
            } else {
                print("Ran into an issue running javascript: \(error!)")
            }
        })
    }

    private func createRequestOptions(command: CDVInvokedUrlCommand) -> RequestOptions {
        let url = command.arguments[0] as? String ?? ""
        let requestType = command.arguments[1] as? String ?? ""
        let windowFeatures = command.arguments[2] as? String ?? ""

        let requestOptionsString = command.arguments[3] as? String ?? "{}"
        let requestOptionsData = requestOptionsString.data(using: .utf8)
        var passedOptions: [String: Any]
        do {
            passedOptions = try JSONSerialization.jsonObject(with: requestOptionsData!) as? [String:Any] ?? [:]
        } catch {
            passedOptions = [:]
        }

        let passedHidden = passedOptions["hidden"] as? Bool? ?? nil
        let displayWebview =  windowFeatures == "hidden=no" || passedHidden == false

        let passedBlock = passedOptions["enable_request_blocking"] as? Bool ?? false
        let passedFileExtensions = passedOptions["file_extensions_to_block"] as? String ?? ""
        let fileExtensionsToBlock = !passedFileExtensions.isEmpty ? passedFileExtensions.components(separatedBy: ",") : []

        let passedMethod = passedOptions["method"] as? String ?? "GET"

        var isContentJSON = false
        let passedHeaders = passedOptions["headers"] as? [String: String] ?? [:]
        if passedHeaders["Content-Type"] == "application/json" {
            isContentJSON = true
        }

        var requestOptionsHeaders: [String: String] = [:]
        for (k, v) in passedHeaders {
            if !["Content-Type", "Cookie", "Referrer", "User-Agent"].contains(k) {
                requestOptionsHeaders[k] = v
            }
        }

        var requestOptions = RequestOptions(
            blockNonEssentialRequests: passedBlock,
            fileExtensionsToBlock: fileExtensionsToBlock,
            displayWebview: displayWebview,
            isContentJSON: isContentJSON,
            method: passedMethod,
            headers: requestOptionsHeaders,
            requestType: requestType,
            url: url)

        if passedOptions["content"] != nil {
            requestOptions.captchaContentHtml = passedOptions["content"] as? String ?? nil
        }

        let passedCookies = passedOptions["cookies"] as? String ?? ""
        if passedCookies != "" {
            requestOptions.cookies = passedCookies
        }

        let passedParams = passedOptions["params"] as? [String:Any] ?? [:]
        if passedParams.count != 0 {
            requestOptions.params = passedParams
        }

        let passedUserAgent = passedOptions["useragent"] as? String ?? ""
        if passedUserAgent != "" {
            requestOptions.userAgent = passedUserAgent
        }

        return requestOptions
    }

    func showWebView() {
        if !self.webViewIsVisible && self.webViewController != nil {
            self.webViewIsVisible = true
            self.viewController.show(self.webViewController!, sender: self)
        } else {
            print("Tried to show the WebView when already visible")
        }
    }

    func hideWebView() {
        if self.webViewIsVisible && self.webViewController != nil{
            self.webViewIsVisible = false
            self.webViewController!.dismiss(animated: false)
        } else {
            print("Tried to hide WebView when it is not already visible")
        }
    }

    ////////////////////////////////////////////
    // WebViewPropagateDelegate Methods Start //
    ////////////////////////////////////////////

    func requestDidSucceed(request: URLRequest?,  response: HTTPURLResponse?) {
        if (self.requestOptions?.requestType == HTTP_REQUEST) {
            let currentURL = self.webViewController?.webView.url?.absoluteString

            self.webViewController?.getCookiesForUrl(currentURL ?? "", completionHandler: {cookies in
                let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [
                    "status": self.requestStatus ?? 200,
                    "cookies": convertCookiesToString(cookies),
                    "type": "requestdone",
                    "url": currentURL,
                ])
                pluginResult?.setKeepCallbackAs(true)
                self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
            })
        }
    }

    func requestDidFail(request: URLRequest?,  error: URLError) {
        let currentURL = self.webViewController?.webView.url?.absoluteString

        let pluginResult = CDVPluginResult(status:CDVCommandStatus_ERROR, messageAs: [
            "type": "loaderror",
            "url": currentURL,
            "code": error.code.rawValue,
            "message": error.localizedDescription,
        ])
        pluginResult?.setKeepCallbackAs(true)
        self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
    }

    func webViewControllerDidClose() {
        // Ensure no more references to the webViewController
        // https://docs.swift.org/swift-book/LanguageGuide/Deinitialization.html
        self.webViewController?.propagateDelegate = nil
        self.webViewController = nil

        let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: ["type": "exit"])
        self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
    }

    func shouldStartLoadForURL(request: URLRequest) -> Bool {
        let url = request.url?.absoluteString ?? ""
        if self.requestOptions?.requestType == CAPTCHA_REQUEST {

            // The first load is always called directly after loadHTMLString. It indicates
            // the provided content will be loaded into the WKWebview
            //
            // The second load occurs when the incapsula auth logic finishes successfully. The
            // incapsula then tries to reload the original processor page. We do not need load
            // the processor page though. We just need to grab the cookies and inform the
            // javascript layer that the captcha is done
            if url == self.requestOptions?.url && self.captchaCount == 0 {
                self.captchaCount += 1
                return true
            } else if url == self.requestOptions?.url && self.captchaCount == 1 {
                self.captchaCount += 1

                let getCookiesAndReturn = {
                    self.webViewController?.getCookies { cookies in
                        let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [
                            "type": "captchadone",
                            "url": url,
                            "cookies": convertCookiesToString(cookies)
                        ])
                        pluginResult?.setKeepCallbackAs(true)
                        self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
                    }
                }

                DispatchQueue.main.async {
                    // Incapsula sets some cookies in document.cookie that do not get
                    // properly propagated back up to the HTTPCookieStore. To rectify this
                    // we grab the cookies in javascript and save them to the HTTPCookieStore.
                    self.webViewController?.runJavascript(jsCode: "document.cookie", completionHandler: { cookieString, data in
                            if cookieString != nil {
                                print("Successfully grabbed cookie string from js \(cookieString!)")
                                let cookies = convertStringToCookies(cookieString as! String, host: request.url?.host ?? "")
                                self.webViewController?.setCookies(cookies: cookies, completionHandler:{
                                        getCookiesAndReturn()
                                    }
                                )
                            } else {
                                print("Failed to get cookie string")
                                getCookiesAndReturn()
                            }
                        }
                    )
                }
                return false
            }
        }
        return true
    }

    //////////////////////////////////////////
    // WebViewPropagateDelegate Methods End //
    //////////////////////////////////////////
  }

struct NavigationData {
    var request: URLRequest?
}

/*
    WebViewViewController is responsible for managing the WKWebview. It also abstracts away
    the specifics for the WKWebView and presents a simpler interface to the CDVWKLocalTunnel
    class. The goal of this simplification is to allow the CDVWkLocalTunnel deal with implementing
    the plugins interface and allow WebViewViewController to deal with the navigation and routing
    logic
*/
class WebViewViewController: UIViewController, URLSessionTaskDelegate, WKNavigationDelegate, WKUIDelegate {
    var webView: WKWebView!
    var blockRules: String;
    var propagateDelegate: WebViewPropagateDelegate!
    // WKWebView passes around WKNavigation objects to to track a request through its load
    // cycle. The WKNavigation object holds almost no context on what the request is trying
    // to do. The navigationData dictionary is intended as a way add in request information
    // for the WKNavigation objects
    var navigationData: [WKNavigation: NavigationData] = [:]
    // Stored on the class so that `decidePolicyFor:NavigationRequest` can set it and then
    // `didStartProvisionalNavigation` can grab unset and add to navigationData
    var startedRequest: URLRequest?
    // Stored on the class so that `decidePolicyFor:NavigationResponse` can set it and then
    //  `didFinish` can grab unset and add to navigationData
    var finishedResponse: HTTPURLResponse?

    var isVisible = false;

    var urlSession: URLSession!

    var OKRedirectString = "chfs.non-pci.portmapper.vip"


    init() {
        // This dict specifies the rules for request blocking
        // https://developer.apple.com/documentation/safariservices/creating_a_content_blocker
        // https://stackoverflow.com/questions/32119975/how-to-block-external-resources-to-load-on-a-wkjwebview
        // https://developer.apple.com/documentation/webkit/wkcontentruleliststore
        let blockRulesDict: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*",
                    "resource-type": ["image", "media", "popup", "style-sheet"],
                ],
                "action": [
                    "type": "block",
                ],
            ],
        ]
        self.blockRules = jsonDumps(blockRulesDict) ?? "[]"

        super.init(nibName:nil, bundle: nil)

        self.urlSession = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
    }

    // NOTE(Alex) - I am not sure what to do with this initializer. Xcode insists
    // I need it
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createWebViewWithConfiguration(_ requestOptions: RequestOptions, _ webConfiguration: WKWebViewConfiguration, _ completionHandler: () -> Void) {
        let webViewBounds = self.view.bounds;
        self.webView = WKWebView(frame: webViewBounds, configuration: webConfiguration)
        self.webView.uiDelegate = self
        self.webView.navigationDelegate = self

        self.view.addSubview(self.webView)

        if requestOptions.userAgent != nil {
            self.webView.customUserAgent = requestOptions.userAgent
        }

        // Copied from inappbrowser
        // https://github.com/apache/cordova-plugin-inappbrowser/blob/3.2.x/src/ios/CDVWKInAppBrowser.m#L789
        self.webView.clearsContextBeforeDrawing = true
        self.webView.clipsToBounds = true
        self.webView.contentMode = UIView.ContentMode.scaleToFill
        self.webView.isMultipleTouchEnabled = true
        self.webView.isOpaque = true
        self.webView.isUserInteractionEnabled = true
        self.webView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        self.webView.allowsLinkPreview = false;
        self.webView.allowsBackForwardNavigationGestures = false;
        // Copied from inappbrowser

        completionHandler()
    }

    func createWebView(_ requestOptions: RequestOptions, completionHandler: @escaping () -> Void) {
        let webConfiguration = WKWebViewConfiguration()
        // Note(Alex): 01/12/2021
        // Setting up a non persistent store is needed in order to allow us to consistently access all
        // tokens that are written to the store. I am not sure if the main cause is that this store
        // is different than the store that cordova's wkwebview uses or that this store is in memory
        // instead of on disk which means it might be faster and thus less likely to fall prey to race
        // conditions. Either way, please don't change this code!
        // https://developer.apple.com/documentation/webkit/wkwebsitedatastore
        let webStore = WKWebsiteDataStore.nonPersistent()
        webConfiguration.websiteDataStore = webStore

        let rules = getBlockRulesForOptions(requestOptions: requestOptions)

        if (!rules.isEmpty) {
            WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "block_rules", encodedContentRuleList: rules, completionHandler: {contentRuleList, error in
                if contentRuleList != nil {
                    webConfiguration.userContentController.add(contentRuleList!)
                }
                self.createWebViewWithConfiguration(requestOptions, webConfiguration, completionHandler)
            })

        } else {
            self.createWebViewWithConfiguration(requestOptions, webConfiguration, completionHandler)
        }
    }

    func updateWebView(_ requestOptions: RequestOptions, completionHandler: @escaping () -> Void) {
        self.webView.customUserAgent = requestOptions.userAgent

        let rules = getBlockRulesForOptions(requestOptions: requestOptions)
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "block_rules", encodedContentRuleList: rules, completionHandler: {contentRuleList, error in

            self.webView.configuration.userContentController.removeAllContentRuleLists()

            if contentRuleList != nil {
                self.webView.configuration.userContentController.add(contentRuleList!)
            }
            completionHandler()
        })
    }

    private func getBlockRulesForOptions(requestOptions: RequestOptions) -> String {
        if (requestOptions.blockNonEssentialRequests) {
            return self.blockRules
        } else if (!requestOptions.fileExtensionsToBlock.isEmpty) {
            return getBlockRulesForFileExtensions(extensions: requestOptions.fileExtensionsToBlock)
        }
        return "[]"
    }

    private func getBlockRulesForFileExtensions(extensions: [String]) -> String {
        // Note (Jeff) 1/20/21 - the "url-filter" only supports a subset of regular expression functionality,
        // not including the "logical or" operator (|). So  we need to build the rules one per per file extension
        // at a time, rather than building one comprehesive regex. 
        // ref: https://webkit.org/blog/3476/content-blockers-first-look/
        var blockRulesDict: [[String: Any]] = []

        for ext in extensions {
            blockRulesDict.append([
                "trigger": [
                    "url-filter": "(.+)(\\.\(ext))(\\?.*)?",
                ],
                "action": [
                    "type": "block",
                ],
            ])
        }
        return jsonDumps(blockRulesDict) ?? "[]"
    }

    func close() {
        let postDismiss = {
            // Ensuring we don't leave any circular references
            // https://docs.swift.org/swift-book/LanguageGuide/Deinitialization.html
            self.webView.uiDelegate = nil
            self.webView.navigationDelegate = nil
            self.webView = nil
            for view in self.view.subviews {
                view.removeFromSuperview()
            }
            self.propagateDelegate.webViewControllerDidClose()
        }

        DispatchQueue.main.async {
            if self.presentingViewController != nil {
                self.presentingViewController!.dismiss(animated: true, completion: postDismiss)
            } else if self.parent != nil {
                self.parent!.dismiss(animated: true, completion: postDismiss)
            } else {
                postDismiss()
            }
        }
    }

    func load(_ request: URLRequest) {
        self.webView.load(request);
    }

    // Note(Alex): 01/12/2021 See comment in createWebView. Now that we are setting up the store
    // properly, WKWebview is not havving issues with loading the cookies from HTTPCookieStore.
    // That means that we could probably refactor the code below to just use the self.webView. We
    // would still need to check if cookies on redirects are working properly.
    //
    //
    // WKWebview does not do a great job handling cookies
    //  * It does not set cookies on redirect
    //  *̶ ̶I̶t̶ ̶d̶o̶e̶s̶ ̶n̶o̶t̶ ̶a̶l̶w̶a̶y̶s̶ ̶p̶r̶o̶p̶a̶g̶a̶t̶e̶ ̶t̶h̶e̶ ̶d̶o̶c̶u̶m̶e̶n̶t̶.̶c̶o̶o̶k̶i̶e̶ ̶o̶b̶j̶e̶c̶t̶ ̶u̶p̶ ̶t̶o̶ ̶H̶T̶T̶P̶C̶o̶o̶k̶i̶e̶S̶t̶o̶r̶e̶ (modified 01/12/2021)
    //
    // This function uses urlSession to make all requests and update cookies properly.
    // Once the request has succeeded, the response is loaded into the WKWebview. This
    // will allow users of the plugin to still interact with the WKWebview as if it was
    // loading all requests itself.
    func urlSessionLoad(_ request: URLRequest, requestOptions: RequestOptions? = nil) {
        self.makeURLSessionRequest(request, requestOptions: requestOptions, completionHandler: { url, data, response, error in
            if error == nil && url != nil && response != nil {
                self.propagateDelegate.requestStatus = response!.statusCode
                DispatchQueue.main.async {
                    self.webView.load(data!, mimeType: "text/html", characterEncodingName: "utf8", baseURL: createBaseURL(url!))
                }
            } else if error != nil {
                self.propagateDelegate.requestDidFail(request: request, error: error!)
            } else {
                print("No response returned from urlSessionLoad")
                let error = URLError(URLError.Code.init(rawValue: -100))
                self.propagateDelegate.requestDidFail(request: request, error: error)
            }
        })
    }

    // Defaulting to using storedCookies always unless storedCookies is empty and
    // requesetOptionCookies has a value
    func combineCookies(requestOptionCookies: [HTTPCookie], storedCookies: [HTTPCookie]) -> [HTTPCookie] {
        var cookieNames: Set<String> = []
        var returnCookies: [HTTPCookie] = []

        if storedCookies.count > 0 {
            return storedCookies
        } else {
            return requestOptionCookies
        }
    }

    func makeURLSessionRequest(_ passedRequest: URLRequest, requestOptions: RequestOptions?, completionHandler: @escaping (URL?, Data?, HTTPURLResponse?, URLError?) -> Void) {
        print("Making request to \(passedRequest.url)")

        self.getCookiesForUrl(passedRequest.url?.absoluteString ?? "", completionHandler: {storedCookies in
            var request = passedRequest

            let requestOptionCookies: [HTTPCookie] = requestOptions?.cookies != nil ? convertStringToCookies(requestOptions!.cookies!, host:request.url?.host ?? "") : []

            let requestCookies = self.combineCookies(requestOptionCookies: requestOptionCookies, storedCookies: storedCookies)
            let cookieDict = HTTPCookie.requestHeaderFields(with: requestCookies)
            request.addValue(cookieDict["Cookie"] ?? "", forHTTPHeaderField: "Cookie")

            let handleResponse = { (data: Data?, response: URLResponse?, error: Error?) in
                if error == nil {
                    let statusCode = (response as! HTTPURLResponse).statusCode
                    let headers = (response as! HTTPURLResponse).allHeaderFields

                    if 200 <= statusCode && statusCode < 400 {
                        let returnedCookies = HTTPCookie.cookies(withResponseHeaderFields: headers as! [String: String], for: request.url!)

                        self.setCookies(cookies: returnedCookies, completionHandler: {
                            print("Set cookies from URL response \(returnedCookies) \(response)")

                            if 200 <= statusCode && statusCode < 300 {
                                completionHandler(request.url, data, response as? HTTPURLResponse ?? nil, nil)
                            } else if 300 <= statusCode && statusCode < 400 && headers["Location"] != nil {

                                let location = headers["Location"] as! String
                                var redirectRequest: URLRequest
                                if location.starts(with: "/") && request.url?.host != nil {
                                    redirectRequest = createRequest(urlString: "https://\(request.url!.host!)\(location)", method: "GET")
                                } else {
                                    redirectRequest = createRequest(urlString: location, method: "GET")
                                }

                                if redirectRequest.url?.absoluteString.contains(self.OKRedirectString) ?? false {
                                    redirectRequest = self.createOKRedirectRequest(badRedirectURL: redirectRequest.url!)
                                }

                                self.makeURLSessionRequest(redirectRequest, requestOptions: requestOptions, completionHandler: completionHandler)
                            } else {
                                print("No location header passed in 3XX Redirect")
                                let error = URLError(URLError.Code.init(rawValue: -300))
                                completionHandler(nil, nil, nil, error)
                            }
                        })
                    } else {
                        print("Url request returned non success error code")
                        completionHandler(request.url, data, response as? HTTPURLResponse ?? nil, nil)
                    }

                } else {
                    print("Url request hit an error")
                    let defaultError = URLError(URLError.Code.init(rawValue: -100))
                    completionHandler(nil, nil, nil, error as? URLError ?? defaultError)
                }
            }

            let task = self.urlSession.dataTask(with: request, completionHandler:handleResponse)
            // We need to make sure that the cookies we are using for the request are in
            // the HTTPCookieStore. If not, we will not return them properly after the request
            // is completed.
            self.setCookies(cookies: requestCookies, completionHandler: task.resume)
        })
    }

    func loadHTMLString(_ htmlString: String, baseURL: URL?) {
        self.webView.loadHTMLString(htmlString, baseURL: baseURL)
    }

    //////////////////////////////////////////
    // Cookie Methods Start                 //
    //////////////////////////////////////////
    // Descriptions of how cookies work with WKWebView
    //
    // 1. Cookies persist between WKWebview opens and closes
    //
    // 2. Cookies persist between device opens
    //
    // 3. Cookies are app specific. You can completely clear your cookies without
    // having to worry about clobbering the user's cookies in another app or in
    // their web browser

    func clearCookies(completionHandler: @escaping () -> Void){
        if self.webView == nil {
            completionHandler()
            return;
        }

        DispatchQueue.main.async {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
                self.recursiveClearCookies(cookies: cookies, completionHandler: completionHandler)
            })
        }
    }

    private func recursiveClearCookies(cookies: [HTTPCookie], completionHandler: @escaping () -> Void) {
        if cookies.count == 0 {
            completionHandler()
        } else {
            self.webView.configuration.websiteDataStore.httpCookieStore.delete(cookies[0], completionHandler: {
                self.recursiveClearCookies(cookies: Array(cookies[1...]), completionHandler: completionHandler)
            })
        }
    }

    func setCookies(cookies: [HTTPCookie], completionHandler: @escaping () -> Void) {
        if cookies.count == 0 || self.webView == nil {
            completionHandler()
            return
        }

        DispatchQueue.main.async {
            self.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookies[0], completionHandler: {
                self.setCookies(cookies: Array(cookies[1...]), completionHandler: completionHandler)
            })
        }
    }

    func printCookies(completionHandler: @escaping () -> Void) {
        if self.webView == nil {
            completionHandler()
            return;
        }

        DispatchQueue.main.async {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
                for cookie in cookies {
                    print("Cookie: \(cookie)")
                }
                completionHandler()
            })
        }
    }

    func getCookies(completionHandler: @escaping ([HTTPCookie]) -> Void) {
        if self.webView == nil {
            completionHandler([])
            return;
        }

        DispatchQueue.main.async {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
                completionHandler(cookies)
            })
        }
    }

    func getCookiesForUrl(_ url: String, completionHandler: @escaping ([HTTPCookie]) -> Void) {
        if self.webView == nil {
            completionHandler([])
            return;
        }

        DispatchQueue.main.async {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
                var returnCookies: [HTTPCookie] = []
                for cookie in cookies {
                    if url.contains(cookie.domain) {
                        returnCookies.append(cookie)
                    }
                }
                completionHandler(returnCookies)
            })
        }
    }

    //////////////////////////////////////////
    // Cookie Methods End                   //
    //////////////////////////////////////////

    func runJavascript(jsCode: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        self.webView.evaluateJavaScript(jsCode, completionHandler: completionHandler)
    }

    //MARK: NavigationDelegate

    //////////////////////////////////////////
    // WKNavigationDelegate Methods Start   //
    //////////////////////////////////////////
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("in webviewDelegate:didStartProvisionalNavigation \(navigation)")

        self.navigationData[navigation] = NavigationData(request: self.startedRequest)
        self.startedRequest = nil
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        print("in webviewDelegate:didReceiveServerRedirectForProvisionalNavigation \(navigation)")

        var navigationData = self.navigationData[navigation]
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: URLError) {
        print("in webviewDelegate:didFail \nnavigation: \(navigation) \nerror: \(error)")

        self.propagateDelegate.requestDidFail(request: self.navigationData[navigation]?.request, error: error)
        self.navigationData[navigation] = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: URLError) {
        print("in webviewDelegate:didFailProvisional \nnavigation: \(navigation) \nerror: \(error)")

        self.propagateDelegate.requestDidFail(request: self.navigationData[navigation]?.request, error: error)
        self.navigationData[navigation] = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("in webViewDelegate:DidFinish \(navigation)")

        self.finishedResponse = nil
        self.propagateDelegate.requestDidSucceed(request: self.navigationData[navigation]?.request, response: self.finishedResponse)
        self.navigationData[navigation] = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("in webViewDelegate:DidTerminate")
    }

    func createOKRedirectRequest(badRedirectURL: URL) -> URLRequest {
        let path = badRedirectURL.path
        let query = badRedirectURL.query != nil ? "?\(badRedirectURL.query!)" : ""
        let urlString = "https://www.connectebt.com\(path)\(query)"
        return createRequest(urlString: urlString, method: "GET")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
     print("in webViewDelegate:DecisionHandler \nnavigationAction:\(navigationAction)")
        let requestUrl = navigationAction.request.url

        // Corrects for erroneous redirects in Oklahoma
        if requestUrl?.absoluteString.contains(self.OKRedirectString) ?? false {
            decisionHandler(WKNavigationActionPolicy.cancel);
            webView.load(self.createOKRedirectRequest(badRedirectURL: requestUrl!))
        } else if !(self.propagateDelegate.shouldStartLoadForURL(request: navigationAction.request)) {
            decisionHandler(WKNavigationActionPolicy.cancel);
        } else if navigationAction.targetFrame == nil {
            // This is the case where WKWebview wants to open a link in a new page
            // Instead we cancel the request and start the request in this page
            webView.load(navigationAction.request);
            decisionHandler(WKNavigationActionPolicy.cancel);
        } else {
            self.startedRequest = navigationAction.request
            decisionHandler(WKNavigationActionPolicy.allow);
        }

    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        print("in webViewDelegate:DecisionHandlerResponse \nnavigationResponse: \(navigationResponse)")

        let httpResponse = navigationResponse.response as! HTTPURLResponse
        self.finishedResponse = httpResponse

        decisionHandler(WKNavigationResponsePolicy.allow);
    }

    //////////////////////////////////////////
    // WKNavigationDelegate Methods End   //
    //////////////////////////////////////////



    //////////////////////////////////////////
    // NSURLSessionTaskDelegate Methods Start   //
    //////////////////////////////////////////

    // To handle 302s with cookies properly we need to not automatically redirect.
    // Returning nil in this function will return the 302 response to the dataTask
    // completion handler.
    // https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/1411626-urlsession
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    //////////////////////////////////////////
    // NSURLSessionTaskDelegate Methods End   //
    //////////////////////////////////////////

}

//////////////////////////////////////////
// Helper Functions Start               //
//////////////////////////////////////////

// Built using this: https://useyourloaf.com/blog/how-to-percent-encode-a-url-string/ and
// comparing to a basic requests going through flask
func urlEncodeString(_ queryArgString: String) -> String? {
    let unreserved = "*-._&= "
    let allowed = NSMutableCharacterSet.alphanumeric()
    allowed.addCharacters(in: unreserved)

    var encoded = queryArgString.addingPercentEncoding(withAllowedCharacters: allowed as CharacterSet)
    encoded = encoded?.replacingOccurrences(of: " ", with: "+")
    return encoded
}

func urlEncodeParams(_ params: [String: Any]) -> String? {
    var combinedArray: [String] = []
    for (key, val) in params {
        combinedArray.append("\(key)=\(val)")
    }

    let queryArgString = combinedArray.joined(separator: "&")
    return urlEncodeString(queryArgString)
}

func convertToFormData(_ params: [String: Any]) -> Data? {
    let urlEncodedString = urlEncodeParams(params)
    return urlEncodedString?.data(using: String.Encoding.utf8)
}

func convertToJSONData(_ params: Any) -> Data? {
    do {
        return try JSONSerialization.data(withJSONObject: params)
    } catch {
        return nil
    }
}

func addRequestHeaders(_ request: inout URLRequest, _ headers: [String: String]) {
    for (k, v) in headers {
        request.addValue(v, forHTTPHeaderField: k)
    }
}

func createRequest(urlString: String, method: String, params: [String: Any]? = nil, headers: [String: String]? = nil, postType: String = "form") -> URLRequest {
    if method.lowercased() == "post" {
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        if postType.lowercased() == "form" {
            request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if params != nil {
                request.httpBody = convertToFormData(params!)
            }
        } else if postType.lowercased() == "json" {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if params != nil {
                request.httpBody = convertToJSONData(params!)
            }
        }
        addRequestHeaders(&request, headers ?? [:])
        return request
    } else {
        var finalUrlString = urlString
        if params != nil {
            finalUrlString = "\(finalUrlString)?\(urlEncodeParams(params!) ?? "")"
        }

        let url = URL(string: finalUrlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addRequestHeaders(&request, headers ?? [:])
        return request
    }
}

func jsonDumps(_ jsonObject: Any) -> String? {
    let data = convertToJSONData(jsonObject)
    if data == nil {
        return nil
    } else {
        return String(data: data!, encoding: .utf8)
    }
}

func convertCookiesToString(_ cookies: [HTTPCookie]) -> String {
    return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
}

func convertStringToCookies(_ cookieString: String, host: String) -> [HTTPCookie] {
    var cookies: [HTTPCookie] = []
    if cookieString == "" {
        return cookies
    }

    let hostParts = host.components(separatedBy: "www")
    var domain: String
    if hostParts.count == 2 {
         domain = hostParts[1]
    } else {
        domain = host
    }

    for cookiePair in cookieString.components(separatedBy: "; ") {
        let equalsIndex = cookiePair.firstIndex(of: "=")!
        let equalsIndexPlusOne = cookiePair.index(equalsIndex, offsetBy: 1)
        let name = cookiePair[..<equalsIndex]
        let value = cookiePair[equalsIndexPlusOne...]

        let cookie = HTTPCookie(properties: [
            HTTPCookiePropertyKey.domain: domain,
            HTTPCookiePropertyKey.path: "/",
            HTTPCookiePropertyKey.name: name,
            HTTPCookiePropertyKey.value: value,
        ])
        if cookie != nil {
            cookies.append(cookie!)
        }
    }

    return cookies
}

// BaseURLs are important because of how webView.load(data, ...
// and webView.loadHTMLString(... work. Both require that the URL argument
// is a base url that helps resolve relative URLs in the html body.
// https://developer.apple.com/documentation/webkit/wkwebview/1415011-load
func createBaseURL(_ url: URL) -> URL {
    let urlString = url.absoluteString
    let parts = urlString.components(separatedBy: "://")
    let hostname = parts[1].split(separator: "/")[0]
    return URL(string: "\(parts[0])://\(hostname)")!
}

//////////////////////////////////////////
// Helper Functions End                 //
//////////////////////////////////////////
