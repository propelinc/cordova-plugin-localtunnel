import UIKit
import WebKit

let CLEAR_COOKIES_REQUEST = "_clearcookies"
let HTTP_REQUEST = "_httprequest"
let CAPTCHA_REQUEST = "_captcha"

struct RequestOptions {
    var blockNonEssentialRequests: Bool
    var displayWebview: Bool
    var method: String

    var captchaContentHtml: String?
    var cookies: String?
    var params: [String: Any]?
    var userAgent: String?
}

protocol PropagateDelegate {
    func requestDidSucceed(request: URLRequest?,  response: HTTPURLResponse?)
    func shouldStartLoadForURL(url: String) -> Bool
    func webViewControllerDidClose()
}

@objc(CDVWKLocalTunnel) class CDVWKLocalTunnel : CDVPlugin, PropagateDelegate {
    var webViewController: WebViewViewController!

    var captchaCount = 0

    var openCallbackId: String!
    var closeCallbackId: String!

    var requestType: String!
    var url: String!
    var requestOptions: RequestOptions!

    var webViewIsVisible = false

    func clearState() {
        self.captchaCount = 0

        self.openCallbackId = nil
        self.closeCallbackId = nil

        self.requestType = nil
        self.url = nil
    }

  @objc(open:)
  func open(command: CDVInvokedUrlCommand) {
    self.clearState()

    self.url = command.arguments[0] as? String ?? ""
    self.requestType = command.arguments[1] as? String ?? ""
    self.requestOptions = self.createRequestOptions(command: command)
    self.openCallbackId = command.callbackId;

    let runOpen = {
        if self.requestOptions.displayWebview {
            self.showWebView()
        } else {
            self.hideWebView()
        }

        if self.requestType == CLEAR_COOKIES_REQUEST {
            // Delete cookies asynchronously does not follow the pattern in other places of synchronously deleting the cookies
            self.webViewController.clearCookies(completionHander: {
                let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
                self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
                self.tearDown()
            })
        } else if self.requestType == HTTP_REQUEST {
            var request = createRequest(urlString: self.url, method: self.requestOptions.method, params: self.requestOptions.params)
            if self.requestOptions.cookies != nil {
                request.addValue(self.requestOptions.cookies!, forHTTPHeaderField: "Cookie")
            }
            self.webViewController.webView.load(request)

            // NOTE(Alex): I cannot seem to make sending multiple commandDelegate responses on open work. So I am not sending one on the initial open and will just send one when the load is done
//            let pluginResult = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
//            pluginResult!.setKeepCallbackAs(true)
//            self.commandDelegate.send(pluginResult, callbackId: self.callbackId)

        } else if self.requestType == CAPTCHA_REQUEST {
            self.webViewController.webView.loadHTMLString(self.requestOptions.captchaContentHtml!, baseURL: URL(string: self.url))
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
            self.commandDelegate.send(pluginResult, callbackId: self.openCallbackId)
        }
    }

    if self.webViewController == nil {
        self.webViewController = WebViewViewController()
        self.webViewController.propagateDelegate = self;
        self.webViewController.createWebView(requestOptions, completionHander: {
            runOpen()
        })
    } else {
        runOpen()
    }
   }

    @objc(injectScriptCode:)
    func injectScriptCode(command: CDVInvokedUrlCommand) {
        let jsCode = command.arguments[0] as? String ?? ""
        self.webViewController.runJavascript(jsCode: jsCode, completionHandler: { returnVal, error in
            if error == nil {
                let executeResponse = returnVal as? String ?? ""
                NSLog("Javascript code: %@ output: %@", jsCode, executeResponse)
                let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [executeResponse])
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
            }
        })
    }

    @objc(close:)
    func close(command: CDVInvokedUrlCommand) {
        self.closeCallbackId = command.callbackId
        self.tearDown()
    }

    func tearDown() {
        self.hideWebView()
        self.webViewController.close()
    }

    private func createRequestOptions(command: CDVInvokedUrlCommand) -> RequestOptions {
        let windowFeatures = command.arguments[2] as? String ?? ""
        let requestOptionsString = command.arguments[3] as? String ?? "{}"
        let requestOptionsData = requestOptionsString.data(using: .utf8)
        var passedRequestOptions: [String: Any]
        do {
            passedRequestOptions = try JSONSerialization.jsonObject(with: requestOptionsData!) as? [String:Any] ?? [:]
        } catch {
            passedRequestOptions = [:]
        }

        let passedHidden = passedRequestOptions["hidden"] as? Bool? ?? nil
        let displayWebview =  windowFeatures == "hidden=no" || passedHidden == true
        var requestOptions = RequestOptions(blockNonEssentialRequests: passedRequestOptions["enable_request_blocking"] as? Bool ?? false, displayWebview: displayWebview, method: passedRequestOptions["method"] as? String ?? "get")

        if passedRequestOptions["content"] != nil {
            requestOptions.captchaContentHtml = passedRequestOptions["content"] as? String ?? nil
        }

        let passedCookies = passedRequestOptions["key"] as? String? ?? nil
        if passedCookies != nil && passedCookies != "" {
            requestOptions.cookies = passedCookies!
        }

        let passedParams = passedRequestOptions["params"] as? [String:Any] ?? [:]
        if passedParams.count != 0 {
            requestOptions.params = passedParams
        }

        // Using server passed user agents seemed to dramaticaly increase the Incapsula issues we hit
        let passedUserAgent = passedRequestOptions["useragent"] as? String ?? ""
        if passedUserAgent != "" {
            requestOptions.userAgent = passedUserAgent
        }

        return requestOptions
    }


    // Prop

    // Whole reason we need these functions is to propagate success and errors from the WKWebview
    // So that proper PluginResults can be sent back to the javascript layer. This delegate pattern
    // Helps avoid having to pass self.commandDelegate around and isolates all Javascript interface
    // code to this class

//    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
//        print("in webviewDelegate:didFail %@ %@", navigation, error)
//    }
//
//    func webView(_ webView: WKWebView,
//    didFailProvisionalNavigation navigation: WKNavigation!,
//    withError error: Error) {
//        print("in webviewDelegate:didFailProvisional %@ %@", navigation, error)
//    }


    func requestDidSucceed(request: URLRequest?,  response: HTTPURLResponse?) {
        if (self.requestType == HTTP_REQUEST) {
            let currentURL = self.webViewController.currentURL

            self.webViewController.getCookiesForUrl(currentURL ?? "", completionHandler: {cookies in
                let callbackId = self.openCallbackId
                self.openCallbackId = nil

                let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [
                    "type": "requestdone",
                    "url": currentURL,
                    "cookies": convertCookiesToString(cookies)
                ])
                pluginResult?.setKeepCallbackAs(true)

                self.commandDelegate.send(pluginResult, callbackId: callbackId)
            })
        }
    }

    func webViewControllerDidClose() {
        self.webViewController = nil

        let callbackId = self.closeCallbackId
        self.closeCallbackId = nil
        if callbackId != nil {
            let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: ["type": "exist"])

            self.commandDelegate.send(pluginResult, callbackId: callbackId)
        }
    }

    func shouldStartLoadForURL(url: String) -> Bool {
        if self.requestType == CAPTCHA_REQUEST {
            // First load is simply adding the html to the page
            // Second load occurs when the incapsula script tries to reload the page
            if url == self.url && self.captchaCount > 0 {
                self.webViewController.getCookiesForUrl(url, completionHandler: {cookies in
                    let callbackId = self.openCallbackId
                    self.openCallbackId = nil

                    let pluginResult = CDVPluginResult(status:CDVCommandStatus_OK, messageAs: [
                        "type": "captchadone",
                        "url": url,
                        "cookies": convertCookiesToString(cookies)
                    ])

                    self.commandDelegate.send(pluginResult, callbackId: callbackId)
                })
                return false
            } else if url == self.url {
                self.captchaCount += 1
            }
        }
        return true
    }

    func showWebView() {
        if !self.webViewIsVisible {
            self.webViewIsVisible = true
            self.viewController.show(self.webViewController, sender: self)
        } else {
            NSLog("Tried to show the WebView when already visible")
        }
    }

    func hideWebView() {
        if self.webViewIsVisible {
            self.webViewIsVisible = false
            self.webViewController.dismiss(animated: false)
        } else {
            NSLog("Tried to hide WebView when it is not already visible")
        }
    }

  }

struct NavigationData {
    var request: URLRequest?
}

class WebViewViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {
    var webView: WKWebView!
    var CONTENT_RULE_LIST_NAME = "block_rules"
    var blockRules: String;
    var propagateDelegate: PropagateDelegate!
    var navigationData: [WKNavigation: NavigationData] = [:]
    // Stored on the class so that `decidePolicyFor:NavigationRequest` can set it and then `didStartProvisionalNavigation` can grab unset and add to navigationData
    var startedRequest: URLRequest?
    // Stored on the class so that `decidePolicyFor:NavigationResponse` can set it and then `didFinish` can grab unset and add to navigationData
    var finishedResponse: HTTPURLResponse?

    var isVisible = false;


    // TODO: add an initializer
    init() {
        // https://developer.apple.com/documentation/safariservices/creating_a_content_blocker
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createWebViewWithConfiguration(_ requestOptions: RequestOptions, _ webConfiguration: WKWebViewConfiguration, _ completionHander: () -> Void) {
        let webViewBounds = self.view.bounds;

        self.webView = WKWebView(frame: webViewBounds, configuration: webConfiguration)
        self.webView.uiDelegate = self
        self.webView.navigationDelegate = self

        self.view.addSubview(self.webView)

        if requestOptions.userAgent != nil {
            self.webView.customUserAgent = requestOptions.userAgent
        }

        // Copied from inappbrowser
        // https://github.com/apache/cordova-plugin-inappbrowser/blob/master/src/ios/CDVWKInAppBrowser.m#L776
        self.webView.clearsContextBeforeDrawing = true
        self.webView.clipsToBounds = true
        self.webView.contentMode = UIViewContentMode.scaleToFill
        self.webView.isMultipleTouchEnabled = true
        self.webView.isOpaque = true
        self.webView.isUserInteractionEnabled = true
        self.webView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        self.webView.allowsLinkPreview = false;
        self.webView.allowsBackForwardNavigationGestures = false;
        // Copied from inappbrowser

        completionHander()
    }

    func createWebView(_ requestOptions: RequestOptions, completionHander: @escaping () -> Void) {
        let webConfiguration = WKWebViewConfiguration()

        if (requestOptions.blockNonEssentialRequests) {
            WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: CONTENT_RULE_LIST_NAME, encodedContentRuleList:self.blockRules , completionHandler: {contentRuleList, error in
                if contentRuleList != nil {
                    webConfiguration.userContentController.add(contentRuleList!)
                }
                self.createWebViewWithConfiguration(requestOptions, webConfiguration, completionHander)
            })

        } else {
            self.createWebViewWithConfiguration(requestOptions, webConfiguration, completionHander)
        }
    }

    func close() {
        let postDismiss = {
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

    var currentURL: String? {
        get {
            return self.webView.url?.absoluteString
        }
    }

    // COOKIE BEHAVIOR SUMMARY WITH WKWEBVIEW
    // Cookies persist between app opens and closes. Cookies persist between device opens
    // That means these are being written to disk
    // Cookies are applicaiton specific. You can completely clear your cookies without
    // having to worry about clobbering anyone else's cookies
    func clearCookies(completionHander: @escaping () -> Void){
        self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
            self.deleteCookies(cookies: cookies, completionHandler: completionHander)
        })
    }

    private func deleteCookies(cookies: [HTTPCookie], completionHandler: @escaping () -> Void) {
        if cookies.count == 0 {
            completionHandler()
        } else {
            self.webView.configuration.websiteDataStore.httpCookieStore.delete(cookies[0], completionHandler: {
                self.deleteCookies(cookies: Array(cookies[1...]), completionHandler: completionHandler)
            })
        }
    }

    func printCookies(completionHander: @escaping () -> Void) {
        self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
            for cookie in cookies {
                NSLog("Cookies are: %@", cookie)
            }
            completionHander()
        })
    }

    func getCookies(completionHander: @escaping ([HTTPCookie]) -> Void) {
        self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies({cookies in
            completionHander(cookies)
        })
    }

    func getCookiesForUrl(_ url: String, completionHandler: @escaping ([HTTPCookie]) -> Void) {
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

    func runJavascript(jsCode: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        self.webView.evaluateJavaScript(jsCode, completionHandler: completionHandler)
    }

    //MARK: NavigationDelegate
    func webview(_ webview: WKWebView, _ didCommit: WKNavigation) {
        NSLog("in webviewDelegate:didCommit %@", didCommit)
    }

    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {

        self.navigationData[navigation] = NavigationData(request: self.startedRequest)
        self.startedRequest = nil
        NSLog("in webviewDelegate:didStartProvisionalNavigation %@", navigation)
    }

    func webView(_ webView: WKWebView,
                          didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {

        NSLog("in webviewDelegate:didReceiveServerRedirectForProvisionalNavigation %@", navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("in webviewDelegate:didFail %@ %@", navigation, error)
//        self.propagateDelegate.webView?(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error) {
        print("in webviewDelegate:didFailProvisional %@ %@", navigation, error)
//        self.propagateDelegate.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ webView: WKWebView,
                 didFinish navigation: WKNavigation!) {
        NSLog("in webViewDelegate:DidFinish %@", navigation)

        self.finishedResponse = nil
        self.propagateDelegate.requestDidSucceed(request: self.navigationData[navigation]!.request, response: self.finishedResponse)
        self.navigationData[navigation] = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("in webViewDelegate:DidTerminate %@")
    }

    // This function can probably be used to detect redirects as well
    func webView(_ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

    // TODO: figure out what should we do if we detect a reload
    // I think it is just indicated with a https://developer.apple.com/documentation/webkit/wknavigationtype/reload navigation type

     print("in webViewDelegate:DecisionHandler %@ %@", navigationAction.request, decisionHandler)

        if !(self.propagateDelegate.shouldStartLoadForURL(url: navigationAction.request.url?.absoluteString ?? "")) {
            decisionHandler(WKNavigationActionPolicy.cancel);
        } else if (navigationAction.targetFrame == nil) {
            // always open in the same frame, don't open new ones
            webView.load(navigationAction.request);
            decisionHandler(WKNavigationActionPolicy.cancel);
        } else {
            self.startedRequest = navigationAction.request
            decisionHandler(WKNavigationActionPolicy.allow);
        }

    }

    func webView(_ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let httpResponse = navigationResponse.response as! HTTPURLResponse

        // if httpResponse?.statusCode == 403 / url
        print("in webViewDelegate:DecisionHandlerResponse %@ %@", navigationResponse.response, decisionHandler)
        self.finishedResponse = httpResponse
        decisionHandler(WKNavigationResponsePolicy.allow);
    }


    //MARK: WKUIDelegate
    // This is for launching new webViews
    func webView(_ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
                  for navigationAction: WKNavigationAction,
                  windowFeatures: WKWindowFeatures) -> WKWebView? {
        NSLog("in WKUIDelegate: createWebviewWith %@ %@ %@", configuration, navigationAction, windowFeatures)
        return nil;
    }

    func webViewDidClose(_ webView: WKWebView) {
        NSLog("in WKUIDelegate:webViewDidClose")
    }

}

// Copied from https://github.com/apache/cordova-plugin-inappbrowser/blob/master/src/ios/CDVInAppBrowserNavigationController.h
class CDVInAppBrowserNavigationController: UINavigationController {
    weak var orientationDelegate: CDVScreenOrientationDelegate?
}


// HELPER FUNCTIONS
// Built using this: https://useyourloaf.com/blog/how-to-percent-encode-a-url-string/ and comparing
// to a basic form post in flask
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

func createRequest(urlString: String, method: String, params: [String: Any]? = nil, postType: String = "form") -> URLRequest {
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
        return request
    } else {
        var finalUrlString = urlString
        if params != nil {
            finalUrlString = "\(finalUrlString)?\(urlEncodeParams(params!) ?? "")"
        }

        let url = URL(string: finalUrlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
