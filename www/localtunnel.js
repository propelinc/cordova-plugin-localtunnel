/*
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
*/

(function () {
    var exec = require('cordova/exec');
    var channel = require('cordova/channel');
    var urlutil = require('cordova/urlutil');

    function LocalTunnel () {
        this.channels = {
            'loadstart': channel.create('loadstart'),
            'loadstop': channel.create('loadstop'),
            'loaderror': channel.create('loaderror'),
            'exit': channel.create('exit'),
            'loadresource': channel.create('loadresource'),
            'captchadone': channel.create('captchadone'),
            'requestdone': channel.create('requestdone')
        };
    }

    LocalTunnel.prototype = {
        _eventHandler: function (event) {
            if (event && (event.type in this.channels)) {
                this.channels[event.type].fire(event);
            }
        },
        getAllCookies: function (url, success, error) {
            exec(success, error, 'LocalTunnel', 'getAllCookies', [url]);
        },
        close: function (eventname) {
            return new Promise((resolve) => {
                // NOTE(Alex) setTimeout seems to be needed to yield the thread so that the browser
                // can be fully cleaned up
                var handler = (function () {
                    this.removeEventListener('exit', handler);
                    resolve();
                }).bind(this);

                this.addEventListener('exit', handler);
                exec(null, null, 'LocalTunnel', 'close', []);
            });
        },
        show: function (eventname) {
            exec(null, null, 'LocalTunnel', 'show', []);
        },
        hide: function (eventname) {
            exec(null, null, 'LocalTunnel', 'hide', []);
        },
        addEventListener: function (eventname, f) {
            if (eventname in this.channels) {
                this.channels[eventname].subscribe(f);
            }
        },
        removeEventListener: function (eventname, f) {
            if (eventname in this.channels) {
                this.channels[eventname].unsubscribe(f);
            }
        },

        executeScript: function (injectDetails, cb) {
            if (injectDetails.code) {
                exec(cb, null, 'LocalTunnel', 'injectScriptCode', [injectDetails.code, !!cb]);
            } else if (injectDetails.file) {
                exec(cb, null, 'LocalTunnel', 'injectScriptFile', [injectDetails.file, !!cb]);
            } else {
                throw new Error('executeScript requires exactly one of code or file to be specified');
            }
        },

        insertCSS: function (injectDetails, cb) {
            if (injectDetails.code) {
                exec(cb, null, 'LocalTunnel', 'injectStyleCode', [injectDetails.code, !!cb]);
            } else if (injectDetails.file) {
                exec(cb, null, 'LocalTunnel', 'injectStyleFile', [injectDetails.file, !!cb]);
            } else {
                throw new Error('insertCSS requires exactly one of code or file to be specified');
            }
        }
    };

    module.exports = function (strUrl, strWindowName, strWindowFeatures, callbacks, captcha) {
        strUrl = urlutil.makeAbsolute(strUrl);
        var iab = new LocalTunnel();

        callbacks = callbacks || {};
        for (var callbackName in callbacks) {
            iab.addEventListener(callbackName, callbacks[callbackName]);
        }

        var cb = function (eventname) {
            iab._eventHandler(eventname);
        };

        strWindowFeatures = strWindowFeatures || '';

        var strCaptchaOptions = JSON.stringify(captcha || {});
        exec(cb, cb, 'LocalTunnel', 'open', [strUrl, strWindowName, strWindowFeatures, strCaptchaOptions]);
        return iab;
    };
})();
