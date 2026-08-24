window._hortor_sceneok = false;
window._hortor_sdkok = false;
window._hortor_launcher_started = false;
window._hortor_launcher_retry_count = 0;
window.__ios2LaunchScene = null;
function ios2Trace(message) {
    try {
        if (window.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
            jsb.reflection.callStaticMethod('IOS2Native', 'trace:', String(message));
        }
    } catch (error) {
    }
}

// The launcher normally copies battleVersion from cc.sys.manifestResult. Keep
// that value authoritative on the native startup path as well: older launcher
// bundles contain a fallback BATTLE_VERSION which can otherwise survive when
// the manifest state is initialized in a different order.
function ios2InstallBattleVersionBridge() {
    try {
        var rawData = cc.sys && cc.sys.manifestResult && cc.sys.manifestResult.rawData;
        var manifestBattleVersion = rawData && rawData.battleVersion;
        if (manifestBattleVersion === undefined || manifestBattleVersion === null || manifestBattleVersion === '') return;

        // Some remote game code still reads the version-ext global directly.
        // Keep it aligned with the server manifest instead of the bundled fallback,
        // including when a later remote bundle tries to overwrite that fallback.
        var battleVersionDescriptor = Object.getOwnPropertyDescriptor(window, 'BATTLE_VERSION');
        if (!battleVersionDescriptor || battleVersionDescriptor.configurable) {
            Object.defineProperty(window, 'BATTLE_VERSION', {
                configurable: true,
                enumerable: true,
                get: function () { return manifestBattleVersion; },
                set: function (value) {
                    if (value !== manifestBattleVersion) {
                        ios2Trace('ignored stale BATTLE_VERSION=' + value + ', manifest=' + manifestBattleVersion);
                    }
                }
            });
        } else {
            window.BATTLE_VERSION = manifestBattleVersion;
        }

        var launcherRequire = window.__require;
        if (typeof launcherRequire !== 'function') return;
        var platformModule = launcherRequire('PlatformManager', true);
        var PlatformManager = platformModule && platformModule.PlatformManager;
        if (!PlatformManager || !PlatformManager.prototype || PlatformManager.prototype.__ios2BattleVersionBridge) return;

        var originalGetBattleVersion = PlatformManager.prototype.getBattleVersion;
        if (typeof originalGetBattleVersion !== 'function') return;
        PlatformManager.prototype.__ios2BattleVersionBridge = true;
        PlatformManager.prototype.getBattleVersion = function () {
            var actual = originalGetBattleVersion.call(this);
            if (actual !== manifestBattleVersion) {
                ios2Trace('battle version bridge: ' + actual + ' -> ' + manifestBattleVersion);
                this._battleVersion = manifestBattleVersion;
                return manifestBattleVersion;
            }
            return actual;
        };
        ios2Trace('battle version manifest=' + manifestBattleVersion + ', bridge installed');
    } catch (error) {
        ios2Trace('battle version bridge unavailable: ' + (error.stack || error.message || error));
    }
}

function ios2InstallBattleDownloadTrace() {
    try {
        var downloader = cc.assetManager && cc.assetManager.downloader;
        if (!downloader || typeof downloader.download !== 'function' || downloader.__ios2BattleTrace) return;
        var originalDownload = downloader.download;
        downloader.__ios2BattleTrace = true;
        downloader.download = function (url, downloadFunc, preset, options, onComplete) {
            var textUrl = String(url || '');
            var isBattleUrl = /service-battle|battle/i.test(textUrl);
            if (!isBattleUrl || typeof onComplete !== 'function') {
                return originalDownload.apply(this, arguments);
            }
            ios2Trace('battle download start: ' + textUrl);
            var args = Array.prototype.slice.call(arguments);
            args[4] = function (error, data) {
                ios2Trace('battle download ' + (error ? 'failed: ' + (error.message || error) :
                    'finished bytes=' + (data && data.byteLength !== undefined ? data.byteLength : 'unknown')));
                return onComplete.apply(this, arguments);
            };
            return originalDownload.apply(this, args);
        };
        ios2Trace('battle download trace installed');
    } catch (error) {
        ios2Trace('battle download trace unavailable: ' + (error.stack || error.message || error));
    }
}

function ios2LoadManagerShell() {
    if (window.__ios2ManagerMount) return;
    try {
        var managerFiles = [
            'src/ios2-manager-common.js',
            'src/ios2-script-runtime.js',
            'src/ios2-bin-page.js',
            'src/ios2-script-page.js',
            'src/ios2-config-page.js',
            'src/ios2-manager.js'
        ];
        for (var index = 0; index < managerFiles.length; index++) {
            var managerPath = jsb.fileUtils.fullPathForFilename(managerFiles[index]);
            var managerSource = jsb.fileUtils.getStringFromFile(managerPath);
            if (!managerSource) throw new Error('management module is empty: ' + managerFiles[index]);
            eval(managerSource);
        }
    } catch (error) {
        console.error('[ios2] management shell failed to load', error);
        ios2Trace('management shell load failed: ' + (error.stack || error.message || error));
    }
}

function ios2PreferredFrameRate() {
    if (!window.jsb || !jsb.reflection || !jsb.reflection.callStaticMethod) return null;
    var frameRate = Number(jsb.reflection.callStaticMethod('IOS2Native', 'preferredFrameRate'));
    return [0, 15, 24, 30, 45, 60].indexOf(frameRate) >= 0 ? frameRate : null;
}

window.__ios2RestorePerformancePreferences = function (reason) {
    try {
        var frameRate = ios2PreferredFrameRate();
        if (frameRate === null) return;

        // Keep Cocos' JS state and the iOS CADisplayLink in agreement. If only
        // the native loop is updated, a game bundle can later reset it to 30.
        if (frameRate > 0 && cc.game && typeof cc.game.setFrameRate === 'function') {
            cc.game.setFrameRate(frameRate);
        }
        jsb.reflection.callStaticMethod('IOS2Native', 'applyPerformancePreferences');
        ios2Trace('restored performance=' + frameRate + ' FPS (' + reason + ')');
    } catch (error) {
        console.warn('[ios2] unable to restore performance preferences', error);
    }
};

window.__ios2InstallPerformancePreferenceGuard = function () {
    if (!cc.game || cc.game.__ios2FrameRateGuardInstalled) return;
    var setFrameRate = cc.game.setFrameRate;
    if (typeof setFrameRate !== 'function') return;

    cc.game.__ios2FrameRateGuardInstalled = true;
    cc.game.setFrameRate = function (requestedFrameRate) {
        var preferredFrameRate = ios2PreferredFrameRate();
        if (preferredFrameRate > 0 && requestedFrameRate !== preferredFrameRate) {
            ios2Trace('ignored game frame rate=' + requestedFrameRate +
                '; preserving user preference=' + preferredFrameRate);
            requestedFrameRate = preferredFrameRate;
        }
        return setFrameRate.call(this, requestedFrameRate);
    };
};

window.__ios2SchedulePerformanceRestore = function (reason) {
    [0, 500, 2000].forEach(function (delay) {
        setTimeout(function () {
            window.__ios2RestorePerformancePreferences(reason + '+' + delay + 'ms');
        }, delay);
    });
};

function findLauncherComponent(node) {
    if (!node) return null;

    // Scene activation can finish one tick after runSceneImmediate returns.
    // Prefer the engine's component lookup so this also works when the scene
    // object is a native Scene proxy rather than a plain JS node tree.
    try {
        var launcherClass = cc.js && cc.js._getClassById && cc.js._getClassById('f5ce8gzRX5ET7keNw43jpJj');
        if (launcherClass && typeof node.getComponentInChildren === 'function') {
            var launcher = node.getComponentInChildren(launcherClass);
            if (launcher) return launcher;
        }
    } catch (error) {
    }

    var components = node._components || [];
    for (var i = 0; i < components.length; i++) {
        if (components[i] && typeof components[i].onLoadFunc === 'function') {
            return components[i];
        }
    }

    var children = node._children || [];
    for (var j = 0; j < children.length; j++) {
        var component = findLauncherComponent(children[j]);
        if (component) return component;
    }
    return null;
}

window.__ios2ResetToLauncher = function () {
    window._hortor_launcher_started = false;
    window._hortor_launcher_component = null;
    window._hortor_launcher_retry_count = 0;
    // Recreate the management layer after logout. Reusing a persist root
    // across the game scene can leave its old scene-graph touch listener
    // registered with the previous scene.
    var oldManager = window.__ios2Manager;
    if (oldManager) {
        try {
            if (cc.game && typeof cc.game.removePersistRootNode === 'function') {
                cc.game.removePersistRootNode(oldManager);
            }
            oldManager.removeFromParent(true);
        } catch (error) {
            ios2Trace('unable to remove old management shell: ' + (error.message || error));
        }
        window.__ios2Manager = null;
    }
    // Cocos' restart path resets the Director, event manager, scene graph and
    // all persist roots before running the normal launcher boot sequence.
    if (cc.game && typeof cc.game.restart === 'function') {
        ios2Trace('restarting Cocos runtime after logout');
        cc.game.restart();
        return;
    }
    // `settings` is scoped to boot(), so keep the resolved scene name on the
    // window for the later logout path.
    var launchScene = window.__ios2LaunchScene;
    if (!launchScene || !cc.assetManager || !cc.assetManager.bundles) return;
    ios2Trace('resetting launcher scene=' + launchScene);
    var bundle = cc.assetManager.bundles.find(function (item) {
        return item && typeof item.getSceneInfo === 'function' && item.getSceneInfo(launchScene);
    });
    if (!bundle) {
        ios2Trace('unable to reset to launcher: scene bundle missing');
        return;
    }
    bundle.loadScene(launchScene, null, null, function (error, scene) {
        if (error || !scene) {
            ios2Trace('unable to reset to launcher: ' + (error && (error.stack || error.message) || 'scene missing'));
            return;
        }
        cc.director.runSceneImmediate(scene);
        if (cc.director && typeof cc.director.resume === 'function') cc.director.resume();
        if (cc.game && typeof cc.game.resume === 'function') cc.game.resume();
        var eventManager = (cc.internal && cc.internal.eventManager) || cc.eventManager;
        if (eventManager && typeof eventManager.setEnabled === 'function') eventManager.setEnabled(true);
        ios2Trace('launcher scene reset complete');
        window._hortor_callOnLoad(scene, false);
    });
};

window._hortor_callOnLoad = function(scene, sdkOk){
    if(scene){
        window._hortor_sceneok = scene;
    }
    
    if(sdkOk){
        window._hortor_sdkok = sdkOk;
    }
    
    // The management shell must be usable while HSDK is still completing its
    // network initialization. Only starting the remote launcher is gated by
    // the user's bin selection and the later HSDK login callback.
    if(window._hortor_sceneok && !window._hortor_launcher_started){
        // Cocos 2.4 normally supplies a SceneAsset here, while some native
        // paths supply the Scene directly.
        var t_scene = window._hortor_sceneok.scene || window._hortor_sceneok;
        if(t_scene){
            // Mount the shell as soon as the scene exists. The remote
            // Launcher component can be instantiated a few ticks later.
            if (typeof window.__ios2ManagerMount === 'function') {
                window.__ios2ManagerMount(t_scene, null);
            }
            var launchComp = findLauncherComponent(t_scene);
            if(launchComp){
                window._hortor_launcher_component = launchComp;
                window._hortor_launcher_retry_count = 0;
                if (typeof window.__ios2ManagerSetLauncher === 'function') {
                    window.__ios2ManagerSetLauncher(launchComp);
                }
            }
            window.__ios2StartGame = function () {
                if (window._hortor_launcher_started) return;
                var component = window._hortor_launcher_component || findLauncherComponent(t_scene);
                if (!component || typeof component.onLoadFunc !== 'function') {
                    setTimeout(window.__ios2StartGame, 100);
                    return;
                }
                window._hortor_launcher_component = component;
                window._hortor_launcher_started = true;
                console.log('[ios2] Launcher interaction flow started');
                ios2Trace('Launcher interaction flow started');
                component.onLoadFunc();
            };
            if (!launchComp && window._hortor_launcher_retry_count < 50) {
                window._hortor_launcher_retry_count++;
                setTimeout(function () {
                    window._hortor_callOnLoad();
                }, 100);
            } else {
                ios2Trace('Launcher interaction unavailable: handler missing');
            }
        } else {
            ios2Trace('Launcher interaction unavailable: scene missing');
        }
    }
}

function getManifest(url, options, onProgress, onComplete) {

    var xhr = new XMLHttpRequest(), errInfo = 'download failed: ' + url + ', status: ';

    xhr.open('POST', url, true);

    if (options.responseType !== undefined) xhr.responseType = options.responseType;
    if (options.withCredentials !== undefined) xhr.withCredentials = options.withCredentials;
    if (options.mimeType !== undefined && xhr.overrideMimeType) xhr.overrideMimeType(options.mimeType);
    if (options.timeout !== undefined) xhr.timeout = options.timeout;

    if (options.header) {
        for (var header in options.header) {
            xhr.setRequestHeader(header, options.header[header]);
        }
    }
    xhr.onload = function () {
        if (xhr.status === 200 || xhr.status === 0) {
            onComplete && onComplete(null, xhr.response);
        } else {
            onComplete && onComplete(new Error(errInfo + xhr.status + '(no response)'));
        }

    };

    if (onProgress) {
        xhr.onprogress = function (e) {
            if (e.lengthComputable) {
                onProgress(e.loaded, e.total);
            }
        };
    }

    xhr.onerror = function () {
        onComplete && onComplete(new Error(errInfo + xhr.status + '(error)'));
    };

    xhr.ontimeout = function () {
        onComplete && onComplete(new Error(errInfo + xhr.status + '(time out)'));
    };

    xhr.onabort = function () {
        onComplete && onComplete(new Error(errInfo + xhr.status + '(abort)'));
    };

    xhr.send(null);

    return xhr;
}

window.boot = function () {
    var settings = window._CCSettings;
    window._CCSettings = undefined;
    var onProgress = null;
    
    var RESOURCES = cc.AssetManager.BuiltinBundleName.RESOURCES;
    var INTERNAL = cc.AssetManager.BuiltinBundleName.INTERNAL;
    var MAIN = cc.AssetManager.BuiltinBundleName.MAIN;
    function setLoadingDisplay () {
        // Loading splash scene
        var splash = document.getElementById('splash');
        var progressBar = splash.querySelector('.progress-bar span');
        onProgress = function (finish, total) {
            var percent = 100 * finish / total;
            if (progressBar) {
                progressBar.style.width = percent.toFixed(2) + '%';
            }
        };
        splash.style.display = 'block';
        progressBar.style.width = '0%';

        cc.director.once(cc.Director.EVENT_AFTER_SCENE_LAUNCH, function () {
            splash.style.display = 'none';
        });
    }

    var onStart = function () {

        cc.view.enableRetina(true);
        cc.view.resizeWithBrowserSize(true);

        if (cc.sys.isBrowser) {
            setLoadingDisplay();
        }

        if (cc.sys.isMobile) {
            // The source settings omit orientation; this native target uses
            // portrait because that is the game's authored layout.
            var ios2Orientation = settings.orientation;
            if (window.jsb && cc.sys.os === cc.sys.OS_IOS && !ios2Orientation) {
                ios2Orientation = 'portrait';
            }
            if (ios2Orientation === 'landscape') {
                cc.view.setOrientation(cc.macro.ORIENTATION_LANDSCAPE);
            }
            else if (ios2Orientation === 'portrait') {
                cc.view.setOrientation(cc.macro.ORIENTATION_PORTRAIT);
            }
            cc.view.enableAutoFullScreen([
                cc.sys.BROWSER_TYPE_BAIDU,
                cc.sys.BROWSER_TYPE_BAIDU_APP,
                cc.sys.BROWSER_TYPE_WECHAT,
                cc.sys.BROWSER_TYPE_MOBILE_QQ,
                cc.sys.BROWSER_TYPE_MIUI,
                cc.sys.BROWSER_TYPE_HUAWEI,
                cc.sys.BROWSER_TYPE_UC,
            ].indexOf(cc.sys.browserType) < 0);
        }

        // Limit downloading max concurrent task to 2,
        // more tasks simultaneously may cause performance draw back on some android system / browsers.
        // You can adjust the number based on your own test result, you have to set it before any loading process to take effect.
        if (cc.sys.isBrowser && cc.sys.os === cc.sys.OS_ANDROID) {
            cc.assetManager.downloader.maxConcurrency = 2;
            cc.assetManager.downloader.maxRequestsPerFrame = 2;
        }

        var launchScene = settings.launchScene;
        window.__ios2LaunchScene = launchScene;
        var bundle = cc.assetManager.bundles.find(function (b) {
            return b.getSceneInfo(launchScene);
        });
        ios2Trace('launch scene=' + launchScene + ', bundle=' + (bundle && bundle.name || '<missing>'));
        if (!bundle) {
            ios2Trace('launch scene bundle is missing');
            return;
        }
        
        bundle.loadScene(launchScene, null, onProgress,
            function (err, scene) {
                if (err) {
                    ios2Trace('launch scene load failed: ' + (err.stack || err.message || err));
                    return;
                }
                ios2Trace('launch scene loaded');
                cc.director.runSceneImmediate(scene);
                ios2Trace('launch scene running');
                jsb && jsb.reflection.callStaticMethod("AppController", "hideSplash");
                if (cc.sys.isBrowser) {
                    // show canvas
                    var canvas = document.getElementById('GameCanvas');
                    canvas.style.visibility = '';
                    var div = document.getElementById('GameDiv');
                    if (div) {
                        div.style.backgroundImage = '';
                    }
                    console.log('Success to load scene: ' + launchScene);
                }
                window._hortor_callOnLoad(scene, false);
            }
        );

    };

    var option = {
        id: 'GameCanvas',
        debugMode: settings.debug ? cc.debug.DebugMode.INFO : cc.debug.DebugMode.ERROR,
        showFPS: settings.debug,
        frameRate: 60,
        groupList: settings.groupList,
        collisionMatrix: settings.collisionMatrix,
    };

    var bundleRoot = [INTERNAL];
    settings.hasResourcesBundle && bundleRoot.push(RESOURCES);
    bundleRoot.push("launcher");

    var count = 0;
    function cb (err) {
        if (err) {
            ios2Trace('bundle load failed: ' + (err.stack || err.message || err));
            return console.error(err.message, err.stack);
        }
        count++;
        if (count === bundleRoot.length + 1) {
            cc.assetManager.loadBundle(MAIN, function (err) {
                if (err) {
                    ios2Trace('main bundle load failed: ' + (err.stack || err.message || err));
                } else {
                    ios2InstallBattleVersionBridge();
                    ios2InstallBattleDownloadTrace();
                    var launcherClass = cc.js._getClassById('f5ce8gzRX5ET7keNw43jpJj');
                    var userAuthClass = cc.js._getClassById('8c864A8artAjbRHk7wDg0VI');
                    ios2Trace('launcher class=' + (cc.js.getClassName(launcherClass) || '<missing>') +
                        ', userAuth class=' + (cc.js.getClassName(userAuthClass) || '<missing>') +
                        ', onYes=' + !!(userAuthClass && userAuthClass.prototype && userAuthClass.prototype.onYes));
                    ios2Trace('bundles loaded; starting game');
                    cc.game.run(option, function () {
                        ios2LoadManagerShell();
                        window.__ios2InstallPerformancePreferenceGuard();
                        onStart();
                        window.__ios2SchedulePerformanceRestore('startup');
                    });
                }
            });
        }
    }

    cc.assetManager.loadScript(settings.jsList.map(function (x) { return 'src/' + x; }), cb);

    var download_func = null;
    var retryTotal = 60;
    var retryCount = 0;
    var resourceManifestVersion =
        (typeof RESOURCE_MANIFEST_VERSION === 'string' && RESOURCE_MANIFEST_VERSION) || GAME_VERSION;
    var processManifest = function(err, result) {
        if (err) {
            cc.sys.manifestResult = {
                code: -1,
                error: err,
            };
            console.error("mainjs error download_func", err.message);
            console.error("mainjs error retryCount is", retryCount);
            if (++retryCount < retryTotal) setTimeout(download_func, 1000);
            return;
        }

        try {
            var bundleVersStr = result && result.body && result.body.bundleVers;
            var bundleVers = typeof bundleVersStr === 'string' ? JSON.parse(bundleVersStr) : bundleVersStr;
            if (!bundleVers) throw new Error('manifest has no bundleVers');
            result.body.bundleVers = bundleVers;
            var codeVersion = bundleVers.codeVersion || '';
            var resourceVersion = bundleVers.COMMIT_ID || '';
            var battleVersion = result.body.battleVersion || '';
            var bundleCount = 0;
            cc.sys.manifestResult = {
                code: 0,
                error: null,
                rawData: result.body
            };
            cc.sys.ios2ResourceVersion = {
                codeVersion: codeVersion,
                resourceVersion: resourceVersion,
                battleVersion: battleVersion
            };
            for (var bundleName in bundleVers) {
                // bundleVers also carries manifest metadata. Only actual
                // bundle hashes may be passed to Cocos' bundle downloader.
                if (bundleName === "COMMIT_ID" || bundleName === "codeVersion") continue;
                if (typeof bundleVers[bundleName] !== 'string' || !bundleVers[bundleName]) continue;
                bundleCount++;
                settings.bundleVers[bundleName] = bundleVers[bundleName];
                if (settings.remoteBundles.indexOf(bundleName) === -1) {
                    settings.remoteBundles.push(bundleName);
                }
            }
            ios2Trace('manifest ready: code=' + codeVersion + ', resource=' + resourceVersion +
                ', battle=' + battleVersion + ', bundles=' + bundleCount);
            cc.assetManager.init({
                bundleVers: settings.bundleVers,
                remoteBundles: settings.remoteBundles,
                server: settings.server,
                // Cocos' native cache is keyed by URL and otherwise survives
                // a manifest update. Include all server version fields so a
                // changed resource/code manifest invalidates stale bundles.
                cacheVersion: [codeVersion, resourceVersion, battleVersion].join('|')
            });
            for (var i = 0; i < bundleRoot.length; i++) cc.assetManager.loadBundle(bundleRoot[i], cb);
        } catch (error) {
            ios2Trace('manifest processing failed: ' + (error.stack || error.message || error));
            processManifest(error, null);
        }
    };

    download_func = function(){
        // Use the NSURLConnection bridge for the manifest on iOS.  It avoids
        // the simulator's NSURLSession HTTP/3 + chunked-response hang.
        if (window.jsb && cc.sys.os === cc.sys.OS_IOS && jsb.reflection) {
            window.__ios2ManifestReady = function(raw) {
                try {
                    processManifest(null, JSON.parse(String(raw || '')));
                }
                catch (error) { processManifest(error, null); }
            };
            window.__ios2ManifestFailed = function(message) {
                processManifest(new Error(String(message || 'manifest request failed')), null);
            };
            try {
                jsb.reflection.callStaticMethod('IOS2Native', 'fetchManifest:', resourceManifestVersion);
                return;
            } catch (error) {
                console.warn('[ios2] native manifest bridge unavailable, falling back to XHR', error);
            }
        }
        getManifest(`${SERVER}/login/manifest?platform=hortor&version=${encodeURIComponent(resourceManifestVersion)}`, {responseType: 'json', header: {
            'Content-Type': 'application/json;charset=UTF-8',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Encoding': 'gzip, deflate, br',
        }}, null, processManifest);
    };
    download_func();
};

function ios2LoadSettingsOverride() {
    if (!window.jsb || !jsb.fileUtils || typeof jsb.fileUtils.getWritablePath !== 'function') return false;
    try {
        var writablePath = jsb.fileUtils.getWritablePath();
        var overridePath = writablePath + (/[\\\/]$/.test(writablePath) ? '' : '/') + 'ios2/settings.js';
        var source = jsb.fileUtils.getStringFromFile(overridePath);
        if (!source) return false;
        // The imported file is expected to be the normal Creator settings
        // script and must assign window._CCSettings before the engine loads.
        eval(source);
        if (!window._CCSettings) throw new Error('settings file did not define window._CCSettings');
        ios2Trace('using imported settings: ' + overridePath);
        return true;
    } catch (error) {
        console.warn('[ios2] imported settings invalid, using app settings', error);
        ios2Trace('imported settings failed: ' + (error.stack || error.message || error));
        return false;
    }
}

if (window.jsb) {
    var ios2SettingsOverrideLoaded = ios2LoadSettingsOverride();
    var isRuntime = (typeof loadRuntime === 'function');

    if (isRuntime) {
        if (!ios2SettingsOverrideLoaded) require('src/settings.b2e22.js');
        require('src/cocos2d-runtime.js');
        if (CC_PHYSICS_BUILTIN || CC_PHYSICS_CANNON) {
            require('src/physics.js');
        }
        require('jsb-adapter/engine/index.js');
    }
    else {
        if (!ios2SettingsOverrideLoaded) require('src/settings.b2e22.js');
        require('src/cocos2d-jsb.07adf.js');
        if (CC_PHYSICS_BUILTIN || CC_PHYSICS_CANNON) {
            require('src/physics.js');
        }
        require('jsb-adapter/jsb-engine.js');
        ios2Trace('writable=' + jsb.fileUtils.getWritablePath() + ', cache=' + cc.assetManager.cacheManager.cacheDir);
    }

    cc.macro.CLEANUP_IMAGE_CACHE = true;
    //TODO: sdk是否可以考虑内置到模版里，不是从游戏中加载以及初始化
    //TODO: 声明统一
    {
        require("jsb-adapter/game-defines.js");
        require("src/ios2-login.js");
    }


    function bootstrap() {
        let start = new Date().valueOf();
        try {
            var init = HSDK.init({
                isOpenDebug: true,
                apmPostArea: HSDK.ApmPostArea.Default,
            });
            if (init && typeof init.then === 'function') {
                init.then(res => {
                    console.log('初始化成功, 可以调用HSDK的其他接口了', JSON.stringify(res));
                    let now = new Date().valueOf();
                    console.info(
                        `%c  _hsdkInit:  %c ${now - start} `,
                        "color: #fadfa3; background: #030307; padding:8px 0;",
                        "color: #fff; background: #ff0000; padding:8px 0;",
                    );
                    window._hortor_callOnLoad(null, true);
                }).catch(error => {
                    console.error('[ios2] HSDK initialization failed', error);
                });
            }
        } catch (error) {
            console.error('[ios2] HSDK initialization threw', error);
        }
    }

    window.boot();
    bootstrap();
}
