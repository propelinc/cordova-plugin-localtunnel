/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVLocalTunnel.h"
#import <Cordova/CDVPluginResult.h>
#import <Cordova/CDVUserAgentUtil.h>

#import "swizzling.h"

#define    kLocalTunnelTargetSelf @"_self"
#define    kLocalTunnelTargetSystem @"_system"
#define    kLocalTunnelTargetBlank @"_blank"
#define    kLocalTunnelTargetCaptcha @"_captcha"
#define    kLocalTunnelTargetRequest @"_httprequest"
#define    kLocalTunnelTargetClearCookies @"_clearcookies"

#define    kLocalTunnelToolbarBarPositionBottom @"bottom"
#define    kLocalTunnelToolbarBarPositionTop @"top"

#define    TOOLBAR_HEIGHT 44.0
#define    STATUSBAR_HEIGHT 20.0
#define    LOCATIONBAR_HEIGHT 21.0
#define    FOOTER_HEIGHT ((TOOLBAR_HEIGHT) + (LOCATIONBAR_HEIGHT))


static NSURL* captchaUrl = nil;
static NSURL* requestUrl = nil;
static int captchaCount = 0;
static bool enableRequestBlocking = false;


#pragma mark CDVLocalTunnel

@interface BlockAllRequestsProtocol : NSURLProtocol
@end

@implementation BlockAllRequestsProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    if (enableRequestBlocking &&
            [requestUrl.host isEqual:request.URL.host] &&
            ![requestUrl isEqual:request.URL]) {

        NSLog(@"Blocking request %@", request.URL);
        return YES;
    }

    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (NSCachedURLResponse *)cachedResponse { return nil; }

- (void)startLoading
{
    // For every request, emit "didFailWithError:" with an NSError to reflect the network blocking state
    id<NSURLProtocolClient> client = [self client];
    NSError* error = [NSError errorWithDomain:NSURLErrorDomain
        code:kCFURLErrorNotConnectedToInternet // = -1009 = error code when network is down
        userInfo:@{ NSLocalizedDescriptionKey:@"All network requests are blocked by the application"}];
    [client URLProtocol:self didFailWithError:error];
}
- (void)stopLoading { }

@end


@interface CDVLocalTunnel () {
    NSInteger _previousStatusBarStyle;
}
@end

static void (*show)(id, SEL) = NULL;

static void swizzle_show(UIAlertView *self, SEL _cmd)
{
    if (requestUrl == nil) {
        show(self, _cmd);
    } else {
        NSLog(@"Suppressing alerts for background requests.");
    }
}

@implementation UIAlertView (Blocker)
+ (void)load
{
    SwizzleSelector(self, @selector(show), &swizzle_show, &show);
}
@end

@implementation CDVLocalTunnel

static NSString *toString(id object) {
    return [NSString stringWithFormat: @"%@", object];
}

// helper function: get the url encoded string form of any object
static NSString *urlEncode(id object) {
    NSString *string = toString(object);
    return [string stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
}

- (void)pluginInitialize
{
    _previousStatusBarStyle = -1;
    _callbackIdPattern = nil;
    [NSURLProtocol registerClass:[BlockAllRequestsProtocol class]];
}

- (id)settingForKey:(NSString*)key
{
    return [self.commandDelegate.settings objectForKey:[key lowercaseString]];
}

- (void)onReset
{
    [self close:nil];
}

- (void)close:(CDVInvokedUrlCommand*)command
{
    if (self.localTunnelViewController == nil) {
        NSLog(@"IAB.close() called but it was already closed.");
        return;
    }
    // Things are cleaned up in tunnelExit.
    [self.localTunnelViewController close];
}

- (BOOL) isSystemUrl:(NSURL*)url
{
    if ([[url host] isEqualToString:@"itunes.apple.com"]) {
        return YES;
    }
    return NO;
}

- (void)open:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;

    NSString* url = [command argumentAtIndex:0];
    NSString* target = [command argumentAtIndex:1 withDefault:kLocalTunnelTargetSelf];
    NSString* options = [command argumentAtIndex:2 withDefault:@"" andClass:[NSString class]];

    self.callbackId = command.callbackId;
    self.loadedUrl = @"";

    if (url != nil) {
#ifdef __CORDOVA_4_0_0
        NSURL* baseUrl = [self.webViewEngine URL];
#else
        NSURL* baseUrl = [self.webView.request URL];
#endif
        NSURL* absoluteUrl = [[NSURL URLWithString:url relativeToURL:baseUrl] absoluteURL];

        if ([self isSystemUrl:absoluteUrl]) {
            target = kLocalTunnelTargetSystem;
        }

        if ([target isEqualToString:kLocalTunnelTargetSelf]) {
            [self openInCordovaWebView:absoluteUrl withOptions:options];
        } else if ([target isEqualToString:kLocalTunnelTargetSystem]) {
            [self openInSystem:absoluteUrl];
        } else if ([target isEqualToString:kLocalTunnelTargetCaptcha]) {
            NSString* captchaJson = [command argumentAtIndex:3 withDefault:@"" andClass:[NSString class]];
            NSData* captchaJsonData = [captchaJson dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error = nil;
            id captchaObj = [NSJSONSerialization JSONObjectWithData:captchaJsonData options:0 error:&error];
            NSDictionary *captcha = captchaObj;
            [self openCaptchaInLocalTunnel:absoluteUrl withOptions:options withCaptcha:captcha];
        } else if ([target isEqualToString:kLocalTunnelTargetRequest]) {
            NSString* requestJson = [command argumentAtIndex:3 withDefault:@"" andClass:[NSString class]];
            NSData* requestJsonData = [requestJson dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error = nil;
            id requestObj = [NSJSONSerialization JSONObjectWithData:requestJsonData options:0 error:&error];
            NSDictionary *request = requestObj;
            [self openRequestInLocalTunnel:absoluteUrl withOptions:options withRequest:request];
        } else if ([target isEqualToString:kLocalTunnelTargetClearCookies]) {
            NSHTTPCookie *cookie;
            NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            for (cookie in [storage cookies])
            {
                if (![cookie.domain isEqual: @".^filecookies^"]) {
                    [storage deleteCookie:cookie];
                }
            }
        } else { // _blank or anything else
            [self openInLocalTunnel:absoluteUrl withOptions:options];
        }

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"incorrect number of arguments"];
    }

    [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)openInLocalTunnel:(NSURL*)url withOptions:(NSString*)options
{
    CDVLocalTunnelOptions* tunnelOptions = [CDVLocalTunnelOptions parseOptions:options];

    enableRequestBlocking = false;
    requestUrl = nil;
    captchaUrl = nil;
    captchaCount = 0;

    if (tunnelOptions.clearcache) {
        NSHTTPCookie *cookie;
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (cookie in [storage cookies])
        {
            if (![cookie.domain isEqual: @".^filecookies^"]) {
                [storage deleteCookie:cookie];
            }
        }
    }

    if (tunnelOptions.clearsessioncache) {
        NSHTTPCookie *cookie;
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (cookie in [storage cookies])
        {
            if (![cookie.domain isEqual: @".^filecookies^"] && cookie.isSessionOnly) {
                [storage deleteCookie:cookie];
            }
        }
    }

    if (self.localTunnelViewController == nil) {
        NSString* userAgent = [CDVUserAgentUtil originalUserAgent];

        if ([url.host containsString:@"ebtpr.com"]) {
            userAgent = @"Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)";
        }

        NSString* overrideUserAgent = [self settingForKey:@"OverrideUserAgent"];
        NSString* appendUserAgent = [self settingForKey:@"AppendUserAgent"];
        if(overrideUserAgent){
            userAgent = overrideUserAgent;
        }
        if(appendUserAgent){
            userAgent = [userAgent stringByAppendingString: appendUserAgent];
        }
        self.localTunnelViewController = [[CDVLocalTunnelViewController alloc] initWithUserAgent:userAgent prevUserAgent:[self.commandDelegate userAgent] tunnelOptions: tunnelOptions];
        self.localTunnelViewController.navigationDelegate = self;

        if ([self.viewController conformsToProtocol:@protocol(CDVScreenOrientationDelegate)]) {
            self.localTunnelViewController.orientationDelegate = (UIViewController <CDVScreenOrientationDelegate>*)self.viewController;
        }
    }

    [self.localTunnelViewController showLocationBar:tunnelOptions.location];
    [self.localTunnelViewController showToolBar:tunnelOptions.toolbar :tunnelOptions.toolbarposition];
    if (tunnelOptions.closebuttoncaption != nil || tunnelOptions.closebuttoncolor != nil) {
        [self.localTunnelViewController setCloseButtonTitle:tunnelOptions.closebuttoncaption :tunnelOptions.closebuttoncolor];
    }
    // Set Presentation Style
    UIModalPresentationStyle presentationStyle = UIModalPresentationFullScreen; // default
    if (tunnelOptions.presentationstyle != nil) {
        if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"pagesheet"]) {
            presentationStyle = UIModalPresentationPageSheet;
        } else if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"formsheet"]) {
            presentationStyle = UIModalPresentationFormSheet;
        }
    }
    self.localTunnelViewController.modalPresentationStyle = presentationStyle;

    // Set Transition Style
    UIModalTransitionStyle transitionStyle = UIModalTransitionStyleCoverVertical; // default
    if (tunnelOptions.transitionstyle != nil) {
        if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"fliphorizontal"]) {
            transitionStyle = UIModalTransitionStyleFlipHorizontal;
        } else if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"crossdissolve"]) {
            transitionStyle = UIModalTransitionStyleCrossDissolve;
        }
    }
    self.localTunnelViewController.modalTransitionStyle = transitionStyle;

    // prevent webView from bouncing
    if (tunnelOptions.disallowoverscroll) {
        if ([self.localTunnelViewController.webView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[self.localTunnelViewController.webView scrollView]).bounces = NO;
        } else {
            for (id subview in self.localTunnelViewController.webView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }

    // UIWebView options
    self.localTunnelViewController.webView.scalesPageToFit = tunnelOptions.enableviewportscale;
    self.localTunnelViewController.webView.mediaPlaybackRequiresUserAction = tunnelOptions.mediaplaybackrequiresuseraction;
    self.localTunnelViewController.webView.allowsInlineMediaPlayback = tunnelOptions.allowinlinemediaplayback;
    if (IsAtLeastiOSVersion(@"6.0")) {
        self.localTunnelViewController.webView.keyboardDisplayRequiresUserAction = tunnelOptions.keyboarddisplayrequiresuseraction;
        self.localTunnelViewController.webView.suppressesIncrementalRendering = tunnelOptions.suppressesincrementalrendering;
    }

    [self.localTunnelViewController navigateTo:url];
    if (!tunnelOptions.hidden) {
        [self show:nil];
    }
}


- (void)openCaptchaInLocalTunnel:(NSURL*)url withOptions:(NSString*)options withCaptcha:captcha
{
    CDVLocalTunnelOptions* tunnelOptions = [
        CDVLocalTunnelOptions parseOptions:@"location=no,toolbar=yes,disallowoverscroll=yes"];

    NSDictionary* captchaCookies = [captcha objectForKey:@"cookies"];
    NSString* content = [captcha objectForKey:@"content"];
    NSString* userAgent = [captcha objectForKey:@"useragent"];
    bool hidden = [[captcha objectForKey:@"hidden"] boolValue];

    captchaUrl = url;
    captchaCount = 0;
    requestUrl = nil;
    enableRequestBlocking = false;

    if (self.localTunnelViewController == nil) {
        self.localTunnelViewController = [[CDVLocalTunnelViewController alloc] initWithUserAgent:userAgent prevUserAgent:[self.commandDelegate userAgent] tunnelOptions: tunnelOptions];
        self.localTunnelViewController.navigationDelegate = self;

        if ([self.viewController conformsToProtocol:@protocol(CDVScreenOrientationDelegate)]) {
            self.localTunnelViewController.orientationDelegate = (UIViewController <CDVScreenOrientationDelegate>*)self.viewController;
        }
    }

    [self.localTunnelViewController showLocationBar:tunnelOptions.location];
    [self.localTunnelViewController showToolBar:tunnelOptions.toolbar :tunnelOptions.toolbarposition];
    if (tunnelOptions.closebuttoncaption != nil || tunnelOptions.closebuttoncolor != nil) {
        [self.localTunnelViewController setCloseButtonTitle:tunnelOptions.closebuttoncaption :tunnelOptions.closebuttoncolor];
    }

    // Set Presentation Style
    UIModalPresentationStyle presentationStyle = UIModalPresentationFullScreen; // default
    if (tunnelOptions.presentationstyle != nil) {
        if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"pagesheet"]) {
            presentationStyle = UIModalPresentationPageSheet;
        } else if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"formsheet"]) {
            presentationStyle = UIModalPresentationFormSheet;
        }
    }
    self.localTunnelViewController.modalPresentationStyle = presentationStyle;

    // Set Transition Style
    UIModalTransitionStyle transitionStyle = UIModalTransitionStyleCoverVertical; // default
    if (tunnelOptions.transitionstyle != nil) {
        if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"fliphorizontal"]) {
            transitionStyle = UIModalTransitionStyleFlipHorizontal;
        } else if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"crossdissolve"]) {
            transitionStyle = UIModalTransitionStyleCrossDissolve;
        }
    }
    self.localTunnelViewController.modalTransitionStyle = transitionStyle;

    // prevent webView from bouncing
    if (tunnelOptions.disallowoverscroll) {
        if ([self.localTunnelViewController.webView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[self.localTunnelViewController.webView scrollView]).bounces = NO;
        } else {
            for (id subview in self.localTunnelViewController.webView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }

    // UIWebView options
    self.localTunnelViewController.webView.scalesPageToFit = tunnelOptions.enableviewportscale;
    self.localTunnelViewController.webView.mediaPlaybackRequiresUserAction = tunnelOptions.mediaplaybackrequiresuseraction;
    self.localTunnelViewController.webView.allowsInlineMediaPlayback = tunnelOptions.allowinlinemediaplayback;
    if (IsAtLeastiOSVersion(@"6.0")) {
        self.localTunnelViewController.webView.keyboardDisplayRequiresUserAction = tunnelOptions.keyboarddisplayrequiresuseraction;
        self.localTunnelViewController.webView.suppressesIncrementalRendering = tunnelOptions.suppressesincrementalrendering;
    }

    [self.localTunnelViewController navigateToCaptcha:url :content];
    if (!hidden) {
        [self show:nil];
    }
}


- (void)openRequestInLocalTunnel:(NSURL*)url withOptions:(NSString*)options withRequest:request
{
    CDVLocalTunnelOptions* tunnelOptions = [CDVLocalTunnelOptions parseOptions:options];
    NSDictionary* requestCookies = [request objectForKey:@"cookies"];
    NSDictionary* requestParams = [request objectForKey:@"params"];
    NSString* method = [request objectForKey:@"method"];
    NSString* userAgent = [request objectForKey:@"useragent"];
    enableRequestBlocking = [[request objectForKey:@"enable_request_blocking"] boolValue];

    NSURL* lastRequestUrl = requestUrl;
    requestUrl = url;
    captchaUrl = nil;
    captchaCount = 0;

    if (self.localTunnelViewController == nil) {
        self.localTunnelViewController = [[CDVLocalTunnelViewController alloc] initWithUserAgent:userAgent prevUserAgent:[self.commandDelegate userAgent] tunnelOptions: tunnelOptions];
        self.localTunnelViewController.navigationDelegate = self;

        if ([self.viewController conformsToProtocol:@protocol(CDVScreenOrientationDelegate)]) {
            self.localTunnelViewController.orientationDelegate = (UIViewController <CDVScreenOrientationDelegate>*)self.viewController;
        }
    }

    [self.localTunnelViewController showLocationBar:tunnelOptions.location];
    [self.localTunnelViewController showToolBar:tunnelOptions.toolbar :tunnelOptions.toolbarposition];
    if (tunnelOptions.closebuttoncaption != nil || tunnelOptions.closebuttoncolor != nil) {
        [self.localTunnelViewController setCloseButtonTitle:tunnelOptions.closebuttoncaption :tunnelOptions.closebuttoncolor];
    }

    // Set Presentation Style
    UIModalPresentationStyle presentationStyle = UIModalPresentationFullScreen; // default
    if (tunnelOptions.presentationstyle != nil) {
        if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"pagesheet"]) {
            presentationStyle = UIModalPresentationPageSheet;
        } else if ([[tunnelOptions.presentationstyle lowercaseString] isEqualToString:@"formsheet"]) {
            presentationStyle = UIModalPresentationFormSheet;
        }
    }
    self.localTunnelViewController.modalPresentationStyle = presentationStyle;

    // Set Transition Style
    UIModalTransitionStyle transitionStyle = UIModalTransitionStyleCoverVertical; // default
    if (tunnelOptions.transitionstyle != nil) {
        if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"fliphorizontal"]) {
            transitionStyle = UIModalTransitionStyleFlipHorizontal;
        } else if ([[tunnelOptions.transitionstyle lowercaseString] isEqualToString:@"crossdissolve"]) {
            transitionStyle = UIModalTransitionStyleCrossDissolve;
        }
    }
    self.localTunnelViewController.modalTransitionStyle = transitionStyle;

    // prevent webView from bouncing
    if (tunnelOptions.disallowoverscroll) {
        if ([self.localTunnelViewController.webView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[self.localTunnelViewController.webView scrollView]).bounces = NO;
        } else {
            for (id subview in self.localTunnelViewController.webView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }

    // UIWebView options
    self.localTunnelViewController.webView.scalesPageToFit = tunnelOptions.enableviewportscale;
    self.localTunnelViewController.webView.mediaPlaybackRequiresUserAction = tunnelOptions.mediaplaybackrequiresuseraction;
    self.localTunnelViewController.webView.allowsInlineMediaPlayback = tunnelOptions.allowinlinemediaplayback;
    if (IsAtLeastiOSVersion(@"6.0")) {
        self.localTunnelViewController.webView.keyboardDisplayRequiresUserAction = tunnelOptions.keyboarddisplayrequiresuseraction;
        self.localTunnelViewController.webView.suppressesIncrementalRendering = tunnelOptions.suppressesincrementalrendering;
    }

    NSMutableArray *queryItems = [NSMutableArray array];
    for (NSString *key in requestParams) {
        id value = requestParams[key];
        [queryItems addObject: [
            NSString stringWithFormat: @"%@=%@", urlEncode(key), urlEncode(value)]];
    }

    NSString *body = [queryItems componentsJoinedByString: @"&"];
    NSMutableURLRequest *req;

    if ([method isEqualToString:@"get"]) {
        if ([queryItems count] > 0) {
            NSString *URLString = [NSString stringWithFormat: @"%@?%@", [url absoluteString], body];
            url = [NSURL URLWithString:URLString];
        }

        req = [[NSMutableURLRequest alloc]initWithURL: url];
        [req setHTTPMethod: @"GET"];
    } else if ([method isEqualToString:@"post"]) {
        req = [[NSMutableURLRequest alloc]initWithURL: url];
        [req setHTTPMethod: @"POST"];
        [req setHTTPBody: [body dataUsingEncoding: NSUTF8StringEncoding]];
    }

    if (lastRequestUrl != nil) {
        [req setValue:[lastRequestUrl absoluteString] forHTTPHeaderField: @"Referer"];
    }

    [self.localTunnelViewController navigateToForm:req];

    if (!tunnelOptions.hidden) {
        [self show:nil];
    }
}


- (void)show:(CDVInvokedUrlCommand*)command
{
    if (self.localTunnelViewController == nil) {
        NSLog(@"Tried to show IAB after it was closed.");
        return;
    }
    if (_previousStatusBarStyle != -1) {
        NSLog(@"Tried to show IAB while already shown");
        return;
    }

    _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;

    __block CDVLocalTunnelNavigationController* nav = [[CDVLocalTunnelNavigationController alloc]
                                                        initWithRootViewController:self.localTunnelViewController];
    nav.orientationDelegate = self.localTunnelViewController;
    nav.navigationBarHidden = YES;
    nav.modalPresentationStyle = self.localTunnelViewController.modalPresentationStyle;

    __weak CDVLocalTunnel* weakSelf = self;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.localTunnelViewController != nil) {
            CGRect frame = [[UIScreen mainScreen] bounds];
            UIWindow *tmpWindow = [[UIWindow alloc] initWithFrame:frame];
            UIViewController *tmpController = [[UIViewController alloc] init];
            [tmpWindow setRootViewController:tmpController];
            [tmpWindow setWindowLevel:UIWindowLevelNormal];

            [tmpWindow makeKeyAndVisible];
            [tmpController presentViewController:nav animated:YES completion:nil];
        }
    });
}

- (void)hide:(CDVInvokedUrlCommand*)command
{
    if (self.localTunnelViewController == nil) {
        NSLog(@"Tried to hide IAB after it was closed.");
        return;


    }
    if (_previousStatusBarStyle == -1) {
        NSLog(@"Tried to hide IAB while already hidden");
        return;
    }

    _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.localTunnelViewController != nil) {
            _previousStatusBarStyle = -1;
            [self.localTunnelViewController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)openInCordovaWebView:(NSURL*)url withOptions:(NSString*)options
{
    NSURLRequest* request = [NSURLRequest requestWithURL:url];

#ifdef __CORDOVA_4_0_0
    // the webview engine itself will filter for this according to <allow-navigation> policy
    // in config.xml for cordova-ios-4.0
    [self.webViewEngine loadRequest:request];
#else
    if ([self.commandDelegate URLIsWhitelisted:url]) {
        [self.webView loadRequest:request];
    } else { // this assumes the LocalTunnel can be excepted from the white-list
        [self openInLocalTunnel:url withOptions:options];
    }
#endif
}

- (void)openInSystem:(NSURL*)url
{
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];
    [[UIApplication sharedApplication] openURL:url];
}

// This is a helper method for the inject{Script|Style}{Code|File} API calls, which
// provides a consistent method for injecting JavaScript code into the document.
//
// If a wrapper string is supplied, then the source string will be JSON-encoded (adding
// quotes) and wrapped using string formatting. (The wrapper string should have a single
// '%@' marker).
//
// If no wrapper is supplied, then the source string is executed directly.

- (void)injectDeferredObject:(NSString*)source withWrapper:(NSString*)jsWrapper
{
    if (jsWrapper != nil) {
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:@[source] options:0 error:nil];
        NSString* sourceArrayString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (sourceArrayString) {
            NSString* sourceString = [sourceArrayString substringWithRange:NSMakeRange(1, [sourceArrayString length] - 2)];
            NSString* jsToInject = [NSString stringWithFormat:jsWrapper, sourceString];
            [self.localTunnelViewController.webView stringByEvaluatingJavaScriptFromString:jsToInject];
        }
    } else {
        [self.localTunnelViewController.webView stringByEvaluatingJavaScriptFromString:source];
    }
}

- (void)injectScriptCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper = nil;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"window.location.href='gap-iab://%@/'+encodeURIComponent(JSON.stringify([eval(%%@)]));", command.callbackId];
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectScriptFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('script'); c.src = %%@; c.onload = function() { window.location.href='gap-iab://%@'; }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('script'); c.src = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('style'); c.innerHTML = %%@; c.onload = function() { window.location.href='gap-iab://%@'; }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('style'); c.innerHTML = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('link'); c.rel='stylesheet'; c.type='text/css'; c.href = %%@; c.onload = function() { window.location.href='gap-iab://%@'; }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('link'); c.rel='stylesheet', c.type='text/css'; c.href = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (BOOL)isValidCallbackId:(NSString *)callbackId
{
    NSError *err = nil;
    // Initialize on first use
    if (self.callbackIdPattern == nil) {
        self.callbackIdPattern = [NSRegularExpression regularExpressionWithPattern:@"^LocalTunnel[0-9]{1,10}$" options:0 error:&err];
        if (err != nil) {
            // Couldn't initialize Regex; No is safer than Yes.
            return NO;
        }
    }
    if ([self.callbackIdPattern firstMatchInString:callbackId options:0 range:NSMakeRange(0, [callbackId length])]) {
        return YES;
    }
    return NO;
}

/**
 * The iframe bridge provided for the LocalTunnel is capable of executing any oustanding callback belonging
 * to the LocalTunnel plugin. Care has been taken that other callbacks cannot be triggered, and that no
 * other code execution is possible.
 *
 * To trigger the bridge, the iframe (or any other resource) should attempt to load a url of the form:
 *
 * gap-iab://<callbackId>/<arguments>
 *
 * where <callbackId> is the string id of the callback to trigger (something like "LocalTunnel0123456789")
 *
 * If present, the path component of the special gap-iab:// url is expected to be a URL-escaped JSON-encoded
 * value to pass to the callback. [NSURL path] should take care of the URL-unescaping, and a JSON_EXCEPTION
 * is returned if the JSON is invalid.
 */
- (BOOL)webView:(UIWebView*)theWebView shouldStartLoadWithRequest:(NSURLRequest*)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL* url = request.URL;
    BOOL isTopLevelNavigation = [request.URL isEqual:[request mainDocumentURL]];

    NSLog(@"---- LOADING RESOURCE %@", url);
    // See if the url uses the 'gap-iab' protocol. If so, the host should be the id of a callback to execute,
    // and the path, if present, should be a JSON-encoded value to pass to the callback.
    if ([[url scheme] isEqualToString:@"gap-iab"]) {
        NSString* scriptCallbackId = [url host];
        CDVPluginResult* pluginResult = nil;

        if ([self isValidCallbackId:scriptCallbackId]) {
            NSString* scriptResult = [url path];
            NSError* __autoreleasing error = nil;

            // The message should be a JSON-encoded array of the result of the script which executed.
            if ((scriptResult != nil) && ([scriptResult length] > 1)) {
                scriptResult = [scriptResult substringFromIndex:1];
                NSData* decodedResult = [NSJSONSerialization JSONObjectWithData:[scriptResult dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
                if ((error == nil) && [decodedResult isKindOfClass:[NSArray class]]) {
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:(NSArray*)decodedResult];
                } else {
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_JSON_EXCEPTION];
                }
            } else {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
            }
            [self.commandDelegate sendPluginResult:pluginResult callbackId:scriptCallbackId];
            return NO;
        }
    }
    //if is an app store link, let the system handle it, otherwise it fails to load it
    else if ([[ url scheme] isEqualToString:@"itms-appss"] || [[ url scheme] isEqualToString:@"itms-apps"]) {
        [theWebView stopLoading];
        [self openInSystem:url];
        return NO;
    }
    else if ([[url absoluteString] containsString:@"chfs.non-pci.portmapper.vip"]) {
        NSURLComponents *components = [NSURLComponents new];
        components.scheme = @"https";
        components.host = @"www.connectebt.com";
        components.path = [url path];
        components.query = [url query];
        NSURL *actualUrl = [components URL];
        requestUrl = actualUrl;
        [self.localTunnelViewController navigateTo:actualUrl];
        return NO;
    }
    else if (requestUrl != nil && ![url isEqual:requestUrl] && ![[url absoluteString] isEqualToString:@"about:blank"]) {
        NSLog(@"---- HANDLE PAGE REDIRECT FROM %@", requestUrl);
        if (enableRequestBlocking) {
            requestUrl = url;
        }
        return YES;
    }
    else if ([url isEqual:captchaUrl]) {
        if (captchaCount++ > 0) {
            NSArray* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:captchaUrl];
            NSDictionary* cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
            NSString* cookieStr = [cookieHeader objectForKey:@"Cookie"];
            CDVPluginResult* pluginResult = [
                CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                messageAsDictionary:@{@"type":@"captchadone", @"url":[url absoluteString], @"cookies":cookieStr}];

            [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];

            captchaUrl = nil;
            captchaCount = 0;
            return NO;
        }
    }
    else if ((self.callbackId != nil) && isTopLevelNavigation) {
        if ([self.loadedUrl isEqualToString:[url absoluteString]]) {
            self.loadedUrl = @"";
            return NO;
        }
        self.loadedUrl = [url absoluteString];

        // Send a loadstart event for each top-level navigation (includes redirects).
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"loadstart", @"url":[url absoluteString]}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }

    return YES;
}

- (void)webViewDidStartLoad:(UIWebView*)theWebView
{
}

- (void)webViewDidFinishLoad:(UIWebView*)theWebView
{
    if (self.callbackId != nil) {
        // TODO: It would be more useful to return the URL the page is actually on (e.g. if it's been redirected).
        NSURL* url = self.localTunnelViewController.currentURL;
        if (requestUrl != nil && [url isEqual:requestUrl]) {
            enableRequestBlocking = false;
            NSArray* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:requestUrl];
            NSDictionary* cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
            NSString* cookieStr = [cookieHeader objectForKey:@"Cookie"];
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                messageAsDictionary:@{@"type":@"requestdone", @"url":[url absoluteString], @"cookies":cookieStr}];

            [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        }

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
            messageAsDictionary:@{@"type":@"loadstop", @"url":[url  absoluteString]}];

        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)webView:(UIWebView*)theWebView didFailLoadWithError:(NSError*)error
{
    if (self.callbackId != nil) {
        NSString* url = [self.localTunnelViewController.currentURL absoluteString];
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                      messageAsDictionary:@{@"type":@"loaderror", @"url":url, @"code": [NSNumber numberWithInteger:error.code], @"message": error.localizedDescription}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)tunnelExit
{
    // Set navigationDelegate to nil to ensure no callbacks are received from it.
    self.localTunnelViewController.navigationDelegate = nil;
    // Don't recycle the ViewController since it may be consuming a lot of memory.
    // Also - this is required for the PDF/User-Agent bug work-around.
    self.localTunnelViewController = nil;

    // NOTE(Alex) We want to avoid race conditions where "exit" event happens before view controller
    // is set to nil. This would happen if the sendPluginResult yeilds to the javascript call. To
    // avoid any weirdness around erroneous localTunnelViewSetting, I have moved the
    // sendPluginResult call to after we have set the localTunnelViewController to nil
    if (self.callbackId != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"exit"}];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        self.callbackId = nil;
    }

    if (IsAtLeastiOSVersion(@"7.0")) {
        if (_previousStatusBarStyle != -1) {
            [[UIApplication sharedApplication] setStatusBarStyle:_previousStatusBarStyle];
        }
    }

    _previousStatusBarStyle = -1; // this value was reset before reapplying it. caused statusbar to stay black on ios7
}

@end

#pragma mark CDVLocalTunnelViewController

@implementation CDVLocalTunnelViewController

@synthesize currentURL;

- (id)initWithUserAgent:(NSString*)userAgent prevUserAgent:(NSString*)prevUserAgent tunnelOptions: (CDVLocalTunnelOptions*) tunnelOptions
{
    self = [super init];
    if (self != nil) {
        _userAgent = userAgent;
        _prevUserAgent = prevUserAgent;
        _tunnelOptions = tunnelOptions;
#ifdef __CORDOVA_4_0_0
        _webViewDelegate = [[CDVUIWebViewDelegate alloc] initWithDelegate:self];
#else
        _webViewDelegate = [[CDVWebViewDelegate alloc] initWithDelegate:self];
#endif

        [self createViews];
    }

    return self;
}

// Prevent crashes on closing windows
-(void)dealloc {
    self.webView.delegate = nil;
}

- (void)createViews
{
    // We create the views in code for primarily for ease of upgrades and not requiring an external .xib to be included

    CGRect webViewBounds = self.view.bounds;
    BOOL toolbarIsAtBottom = ![_tunnelOptions.toolbarposition isEqualToString:kLocalTunnelToolbarBarPositionTop];
    webViewBounds.size.height -= _tunnelOptions.location ? FOOTER_HEIGHT : TOOLBAR_HEIGHT;
    self.webView = [[UIWebView alloc] initWithFrame:webViewBounds];

    self.webView.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

    [self.view addSubview:self.webView];
    [self.view sendSubviewToBack:self.webView];

    self.webView.delegate = _webViewDelegate;
    self.webView.backgroundColor = [UIColor whiteColor];

    self.webView.clearsContextBeforeDrawing = YES;
    self.webView.clipsToBounds = YES;
    self.webView.contentMode = UIViewContentModeScaleToFill;
    self.webView.multipleTouchEnabled = YES;
    self.webView.opaque = YES;
    self.webView.scalesPageToFit = NO;
    self.webView.userInteractionEnabled = YES;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.alpha = 1.000;
    self.spinner.autoresizesSubviews = YES;
    self.spinner.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin);
    self.spinner.clearsContextBeforeDrawing = NO;
    self.spinner.clipsToBounds = NO;
    self.spinner.contentMode = UIViewContentModeScaleToFill;
    self.spinner.frame = CGRectMake(CGRectGetMidX(self.webView.frame), CGRectGetMidY(self.webView.frame), 20.0, 20.0);
    self.spinner.hidden = NO;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.multipleTouchEnabled = NO;
    self.spinner.opaque = NO;
    self.spinner.userInteractionEnabled = NO;
    [self.spinner stopAnimating];

    self.closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.closeButton.enabled = YES;

    UIBarButtonItem* flexibleSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    UIBarButtonItem* fixedSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpaceButton.width = 20;

    float toolbarY = toolbarIsAtBottom ? self.view.bounds.size.height - TOOLBAR_HEIGHT : 0.0;
    CGRect toolbarFrame = CGRectMake(0.0, toolbarY, self.view.bounds.size.width, TOOLBAR_HEIGHT);

    self.toolbar = [[UIToolbar alloc] initWithFrame:toolbarFrame];
    self.toolbar.alpha = 1.000;
    self.toolbar.autoresizesSubviews = YES;
    self.toolbar.autoresizingMask = toolbarIsAtBottom ? (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin) : UIViewAutoresizingFlexibleWidth;
    self.toolbar.barStyle = UIBarStyleBlackOpaque;
    self.toolbar.clearsContextBeforeDrawing = NO;
    self.toolbar.clipsToBounds = NO;
    self.toolbar.contentMode = UIViewContentModeScaleToFill;
    self.toolbar.hidden = NO;
    self.toolbar.multipleTouchEnabled = NO;
    self.toolbar.opaque = NO;
    self.toolbar.userInteractionEnabled = YES;
    if (_tunnelOptions.toolbarcolor != nil) { // Set toolbar color if user sets it in options
        self.toolbar.barTintColor = [self colorFromHexString:_tunnelOptions.toolbarcolor];
    }
    if (!_tunnelOptions.toolbartranslucent) { // Set toolbar translucent to no if user sets it in options
        self.toolbar.translucent = NO;
    }

    CGFloat labelInset = 5.0;
    float locationBarY = toolbarIsAtBottom ? self.view.bounds.size.height - FOOTER_HEIGHT : self.view.bounds.size.height - LOCATIONBAR_HEIGHT;

    self.addressLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelInset, locationBarY, self.view.bounds.size.width - labelInset, LOCATIONBAR_HEIGHT)];
    self.addressLabel.adjustsFontSizeToFitWidth = NO;
    self.addressLabel.alpha = 1.000;
    self.addressLabel.autoresizesSubviews = YES;
    self.addressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    self.addressLabel.backgroundColor = [UIColor clearColor];
    self.addressLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    self.addressLabel.clearsContextBeforeDrawing = YES;
    self.addressLabel.clipsToBounds = YES;
    self.addressLabel.contentMode = UIViewContentModeScaleToFill;
    self.addressLabel.enabled = YES;
    self.addressLabel.hidden = NO;
    self.addressLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    if ([self.addressLabel respondsToSelector:NSSelectorFromString(@"setMinimumScaleFactor:")]) {
        [self.addressLabel setValue:@(10.0/[UIFont labelFontSize]) forKey:@"minimumScaleFactor"];
    } else if ([self.addressLabel respondsToSelector:NSSelectorFromString(@"setMinimumFontSize:")]) {
        [self.addressLabel setValue:@(10.0) forKey:@"minimumFontSize"];
    }

    self.addressLabel.multipleTouchEnabled = NO;
    self.addressLabel.numberOfLines = 1;
    self.addressLabel.opaque = NO;
    self.addressLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    self.addressLabel.textAlignment = NSTextAlignmentLeft;
    self.addressLabel.textColor = [UIColor colorWithWhite:1.000 alpha:1.000];
    self.addressLabel.userInteractionEnabled = NO;

    NSString* frontArrowString = NSLocalizedString(@"►", nil); // create arrow from Unicode char
    self.forwardButton = [[UIBarButtonItem alloc] initWithTitle:frontArrowString style:UIBarButtonItemStylePlain target:self action:@selector(goForward:)];
    self.forwardButton.enabled = YES;
    self.forwardButton.imageInsets = UIEdgeInsetsZero;

    NSString* backArrowString = NSLocalizedString(@"◄", nil); // create arrow from Unicode char
    self.backButton = [[UIBarButtonItem alloc] initWithTitle:backArrowString style:UIBarButtonItemStylePlain target:self action:@selector(goBack:)];
    self.backButton.enabled = YES;
    self.backButton.imageInsets = UIEdgeInsetsZero;

    // Filter out Navigation Buttons if user requests so
    if (_tunnelOptions.hidenavigationbuttons) {
        [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton]];
    } else {
        [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton, self.backButton, fixedSpaceButton, self.forwardButton]];
    }
    [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton]];

    self.view.backgroundColor = [UIColor grayColor];
    [self.view addSubview:self.toolbar];
    [self.view addSubview:self.addressLabel];
    [self.view addSubview:self.spinner];
}

- (void) setWebViewFrame : (CGRect) frame {
    NSLog(@"Setting the WebView's frame to %@", NSStringFromCGRect(frame));
    [self.webView setFrame:frame];
}

- (void)setCloseButtonTitle:(NSString*)title : (NSString*) colorString
{
    // the advantage of using UIBarButtonSystemItemDone is the system will localize it for you automatically
    // but, if you want to set this yourself, knock yourself out (we can't set the title for a system Done button, so we have to create a new one)
    self.closeButton = nil;
    // Initialize with title if title is set, otherwise the title will be 'Done' localized
    self.closeButton = title != nil ? [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStyleBordered target:self action:@selector(close)] : [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.closeButton.enabled = YES;
    // If color on closebutton is requested then initialize with that that color, otherwise use initialize with default
    self.closeButton.tintColor = colorString != nil ? [self colorFromHexString:colorString] : [UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1];

    NSMutableArray* items = [self.toolbar.items mutableCopy];
    [items replaceObjectAtIndex:0 withObject:self.closeButton];
    [self.toolbar setItems:items];
}

- (void)showLocationBar:(BOOL)show
{
    CGRect locationbarFrame = self.addressLabel.frame;

    BOOL toolbarVisible = !self.toolbar.hidden;

    // prevent double show/hide
    if (show == !(self.addressLabel.hidden)) {
        return;
    }

    if (show) {
        self.addressLabel.hidden = NO;

        if (toolbarVisible) {
            // toolBar at the bottom, leave as is
            // put locationBar on top of the toolBar

            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= FOOTER_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no toolBar, so put locationBar at the bottom

            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        }
    } else {
        self.addressLabel.hidden = YES;

        if (toolbarVisible) {
            // locationBar is on top of toolBar, hide locationBar

            // webView take up whole height less toolBar height
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];
        } else {
            // no toolBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)showToolBar:(BOOL)show : (NSString *) toolbarPosition
{
    CGRect toolbarFrame = self.toolbar.frame;
    CGRect locationbarFrame = self.addressLabel.frame;

    BOOL locationbarVisible = !self.addressLabel.hidden;

    // prevent double show/hide
    if (show == !(self.toolbar.hidden)) {
        return;
    }

    if (show) {
        self.toolbar.hidden = NO;
        CGRect webViewBounds = self.view.bounds;

        if (locationbarVisible) {
            // locationBar at the bottom, move locationBar up
            // put toolBar at the bottom
            webViewBounds.size.height -= FOOTER_HEIGHT;
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
            self.toolbar.frame = toolbarFrame;
        } else {
            // no locationBar, so put toolBar at the bottom
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            self.toolbar.frame = toolbarFrame;
        }

        if ([toolbarPosition isEqualToString:kLocalTunnelToolbarBarPositionTop]) {
            toolbarFrame.origin.y = 0;
            webViewBounds.origin.y += toolbarFrame.size.height;
            [self setWebViewFrame:webViewBounds];
        } else {
            toolbarFrame.origin.y = (webViewBounds.size.height + LOCATIONBAR_HEIGHT);
        }
        [self setWebViewFrame:webViewBounds];

    } else {
        self.toolbar.hidden = YES;

        if (locationbarVisible) {
            // locationBar is on top of toolBar, hide toolBar
            // put locationBar at the bottom

            // webView take up whole height less locationBar height
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            // move locationBar down
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no locationBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
}

- (void)viewDidUnload
{
    [self.webView loadHTMLString:nil baseURL:nil];
    [CDVUserAgentUtil releaseLock:&_userAgentLockToken];
    [super viewDidUnload];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleDefault;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (void)close
{
    [CDVUserAgentUtil releaseLock:&_userAgentLockToken];
    self.currentURL = nil;

    if ((self.navigationDelegate != nil) && [self.navigationDelegate respondsToSelector:@selector(tunnelExit)]) {
        [self.navigationDelegate tunnelExit];
    }

    __weak UIViewController* weakSelf = self;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([weakSelf respondsToSelector:@selector(presentingViewController)]) {
            [[weakSelf presentingViewController] dismissViewControllerAnimated:YES completion:nil];
        } else {
            [[weakSelf parentViewController] dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)navigateToForm:(NSURLRequest*)request
{
    if (_userAgentLockToken != 0) {
        [self.webView loadRequest :request];
    } else {
        __weak CDVLocalTunnelViewController* weakSelf = self;
        [CDVUserAgentUtil acquireLock:^(NSInteger lockToken) {
            _userAgentLockToken = lockToken;
            [CDVUserAgentUtil setUserAgent:_userAgent lockToken:lockToken];
            [weakSelf.webView loadRequest :request];
        }];
    }
}

- (void)navigateToCaptcha:(NSURL*)url :(NSString*)content
{
    if (_userAgentLockToken != 0) {
        [self.webView loadHTMLString :content baseURL:url];
    } else {
        __weak CDVLocalTunnelViewController* weakSelf = self;
        [CDVUserAgentUtil acquireLock:^(NSInteger lockToken) {
            _userAgentLockToken = lockToken;
            [CDVUserAgentUtil setUserAgent:_userAgent lockToken:lockToken];
            [weakSelf.webView loadHTMLString:content baseURL:url];
        }];
    }
}

- (void)navigateTo:(NSURL*)url
{
    NSURLRequest* request = [NSURLRequest requestWithURL:url];

    if (_userAgentLockToken != 0) {
        [self.webView loadRequest:request];
    } else {
        __weak CDVLocalTunnelViewController* weakSelf = self;
        [CDVUserAgentUtil acquireLock:^(NSInteger lockToken) {
            _userAgentLockToken = lockToken;
            [CDVUserAgentUtil setUserAgent:_userAgent lockToken:lockToken];
            [weakSelf.webView loadRequest:request];
        }];
    }
}

- (void)goBack:(id)sender
{
    [self.webView goBack];
}

- (void)goForward:(id)sender
{
    [self.webView goForward];
}

- (void)viewWillAppear:(BOOL)animated
{
    if (IsAtLeastiOSVersion(@"7.0")) {
        [[UIApplication sharedApplication] setStatusBarStyle:[self preferredStatusBarStyle]];
    }
    [self rePositionViews];

    [super viewWillAppear:animated];
}

//
// On iOS 7 the status bar is part of the view's dimensions, therefore it's height has to be taken into account.
// The height of it could be hardcoded as 20 pixels, but that would assume that the upcoming releases of iOS won't
// change that value.
//
- (float) getStatusBarOffset {
    CGRect statusBarFrame = [[UIApplication sharedApplication] statusBarFrame];
    float statusBarOffset = IsAtLeastiOSVersion(@"7.0") ? MIN(statusBarFrame.size.width, statusBarFrame.size.height) : 0.0;
    return statusBarOffset;
}

- (void) rePositionViews {
    if ([_tunnelOptions.toolbarposition isEqualToString:kLocalTunnelToolbarBarPositionTop]) {
        [self.webView setFrame:CGRectMake(self.webView.frame.origin.x, TOOLBAR_HEIGHT, self.webView.frame.size.width, self.webView.frame.size.height)];
        [self.toolbar setFrame:CGRectMake(self.toolbar.frame.origin.x, [self getStatusBarOffset], self.toolbar.frame.size.width, self.toolbar.frame.size.height)];
    }
}

// Helper function to convert hex color string to UIColor
// Assumes input like "#00FF00" (#RRGGBB).
// Taken from https://stackoverflow.com/questions/1560081/how-can-i-create-a-uicolor-from-a-hex-string
- (UIColor *)colorFromHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner setScanLocation:1]; // bypass '#' character
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

#pragma mark UIWebViewDelegate

- (void)webViewDidStartLoad:(UIWebView*)theWebView
{
    // loading url, start spinner, update back/forward

    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;

    [self.spinner startAnimating];

    return [self.navigationDelegate webViewDidStartLoad:theWebView];
}

- (BOOL)webView:(UIWebView*)theWebView shouldStartLoadWithRequest:(NSURLRequest*)request navigationType:(UIWebViewNavigationType)navigationType
{
    BOOL isTopLevelNavigation = [request.URL isEqual:[request mainDocumentURL]];

    if (isTopLevelNavigation) {
        self.currentURL = request.URL;
    }
    return [self.navigationDelegate webView:theWebView shouldStartLoadWithRequest:request navigationType:navigationType];
}

- (void)webViewDidFinishLoad:(UIWebView*)theWebView
{
    // update url, stop spinner, update back/forward

    self.addressLabel.text = [self.currentURL absoluteString];
    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;

    [self.spinner stopAnimating];

    // Work around a bug where the first time a PDF is opened, all UIWebViews
    // reload their User-Agent from NSUserDefaults.
    // This work-around makes the following assumptions:
    // 1. The app has only a single Cordova Webview. If not, then the app should
    //    take it upon themselves to load a PDF in the background as a part of
    //    their start-up flow.
    // 2. That the PDF does not require any additional network requests. We change
    //    the user-agent here back to that of the CDVViewController, so requests
    //    from it must pass through its white-list. This *does* break PDFs that
    //    contain links to other remote PDF/websites.
    // More info at https://issues.apache.org/jira/browse/CB-2225
    BOOL isPDF = [@"true" isEqualToString :[theWebView stringByEvaluatingJavaScriptFromString:@"document.body==null"]];
    if (isPDF) {
        [CDVUserAgentUtil setUserAgent:_prevUserAgent lockToken:_userAgentLockToken];
    }

    [self.navigationDelegate webViewDidFinishLoad:theWebView];
}

- (void)webView:(UIWebView*)theWebView didFailLoadWithError:(NSError*)error
{
    // log fail message, stop spinner, update back/forward
    NSLog(@"webView:didFailLoadWithError - %ld: %@", (long)error.code, [error localizedDescription]);

    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;
    [self.spinner stopAnimating];

    self.addressLabel.text = NSLocalizedString(@"Load Error", nil);

    [self.navigationDelegate webView:theWebView didFailLoadWithError:error];
}

#pragma mark CDVScreenOrientationDelegate

- (BOOL)shouldAutorotate
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotate)]) {
        return [self.orientationDelegate shouldAutorotate];
    }
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [self.orientationDelegate supportedInterfaceOrientations];
    }

    return 1 << UIInterfaceOrientationPortrait;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotateToInterfaceOrientation:)]) {
        return [self.orientationDelegate shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }

    return YES;
}

@end

@implementation CDVLocalTunnelOptions

- (id)init
{
    if (self = [super init]) {
        // default values
        self.location = YES;
        self.toolbar = YES;
        self.closebuttoncaption = nil;
        self.toolbarposition = kLocalTunnelToolbarBarPositionBottom;
        self.clearcache = NO;
        self.clearsessioncache = NO;

        self.enableviewportscale = NO;
        self.mediaplaybackrequiresuseraction = NO;
        self.allowinlinemediaplayback = NO;
        self.keyboarddisplayrequiresuseraction = YES;
        self.suppressesincrementalrendering = NO;
        self.hidden = NO;
        self.disallowoverscroll = NO;
        self.hidenavigationbuttons = NO;
        self.closebuttoncolor = nil;
        self.toolbarcolor = nil;
        self.toolbartranslucent = YES;
    }

    return self;
}

+ (CDVLocalTunnelOptions*)parseOptions:(NSString*)options
{
    CDVLocalTunnelOptions* obj = [[CDVLocalTunnelOptions alloc] init];

    // NOTE: this parsing does not handle quotes within values
    NSArray* pairs = [options componentsSeparatedByString:@","];

    // parse keys and values, set the properties
    for (NSString* pair in pairs) {
        NSArray* keyvalue = [pair componentsSeparatedByString:@"="];

        if ([keyvalue count] == 2) {
            NSString* key = [[keyvalue objectAtIndex:0] lowercaseString];
            NSString* value = [keyvalue objectAtIndex:1];
            NSString* value_lc = [value lowercaseString];

            BOOL isBoolean = [value_lc isEqualToString:@"yes"] || [value_lc isEqualToString:@"no"];
            NSNumberFormatter* numberFormatter = [[NSNumberFormatter alloc] init];
            [numberFormatter setAllowsFloats:YES];
            BOOL isNumber = [numberFormatter numberFromString:value_lc] != nil;

            // set the property according to the key name
            if ([obj respondsToSelector:NSSelectorFromString(key)]) {
                if (isNumber) {
                    [obj setValue:[numberFormatter numberFromString:value_lc] forKey:key];
                } else if (isBoolean) {
                    [obj setValue:[NSNumber numberWithBool:[value_lc isEqualToString:@"yes"]] forKey:key];
                } else {
                    [obj setValue:value forKey:key];
                }
            }
        }
    }

    return obj;
}

@end

@implementation CDVLocalTunnelNavigationController : UINavigationController

- (void) dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if ( self.presentedViewController) {
        [super dismissViewControllerAnimated:flag completion:completion];
    }
}

- (void) viewDidLoad {

    CGRect statusBarFrame = [self invertFrameIfNeeded:[UIApplication sharedApplication].statusBarFrame];
    statusBarFrame.size.height = STATUSBAR_HEIGHT;
    // simplified from: http://stackoverflow.com/a/25669695/219684

    UIToolbar* bgToolbar = [[UIToolbar alloc] initWithFrame:statusBarFrame];
    bgToolbar.barStyle = UIBarStyleDefault;
    [bgToolbar setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [self.view addSubview:bgToolbar];

    [super viewDidLoad];
}

- (CGRect) invertFrameIfNeeded:(CGRect)rect {
    // We need to invert since on iOS 7 frames are always in Portrait context
    if (!IsAtLeastiOSVersion(@"8.0")) {
        if (UIInterfaceOrientationIsLandscape([[UIApplication sharedApplication] statusBarOrientation])) {
            CGFloat temp = rect.size.width;
            rect.size.width = rect.size.height;
            rect.size.height = temp;
        }
        rect.origin = CGPointZero;
    }
    return rect;
}

#pragma mark CDVScreenOrientationDelegate

- (BOOL)shouldAutorotate
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotate)]) {
        return [self.orientationDelegate shouldAutorotate];
    }
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [self.orientationDelegate supportedInterfaceOrientations];
    }

    return 1 << UIInterfaceOrientationPortrait;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotateToInterfaceOrientation:)]) {
        return [self.orientationDelegate shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }

    return YES;
}


@end
