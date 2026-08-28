(function () {
    'use strict';

    var IOS2_WEB_RUNTIME_REVISION = '20260828-cocos-release-manager-1';
    window.__IOS2_WEB_RUNTIME_REVISION__ = IOS2_WEB_RUNTIME_REVISION;

    function showFatal(message) {
        var panel = document.getElementById('ios2WebError');
        if (!panel) {
            panel = document.createElement('div');
            panel.id = 'ios2WebError';
            panel.style.cssText = 'position:fixed;inset:0;z-index:99999;padding:72px 24px 24px;' +
                'box-sizing:border-box;background:#101318;color:#f1f5f9;font:15px/1.55 -apple-system,sans-serif;' +
                'white-space:pre-wrap;overflow:auto;';
            document.body.appendChild(panel);
        }
        panel.textContent = String(message || 'WebKit 游戏启动失败');
    }

    // Cocos' release manager only frees assets whose reference count has
    // reached zero. Keep this entry point shared by scene, WebKit and native
    // lifecycle notifications so cleanup is safe to request more than once.
    var assetReleaseState = {
        busy: false,
        sequence: 0,
        shuttingDown: false
    };

    function managedAssetCount() {
        var manager = window.cc && window.cc.assetManager;
        var assets = manager && manager.assets;
        return assets && typeof assets.count === 'number' ? assets.count : -1;
    }

    function releaseUnusedAssets(reason) {
        var manager = window.cc && window.cc.assetManager;
        if (!manager || typeof manager.releaseUnusedAssets !== 'function') return false;
        if (assetReleaseState.busy) return false;

        assetReleaseState.busy = true;
        var sequence = ++assetReleaseState.sequence;
        var before = managedAssetCount();
        try {
            manager.releaseUnusedAssets();
        } catch (error) {
            assetReleaseState.busy = false;
            console.warn('[ios2-web] Cocos releaseUnusedAssets failed', reason || 'unknown', error);
            return false;
        }

        // ReleaseManager defers destruction to the next tick. Log after that
        // tick so the count reflects the actual cleanup when available.
        window.setTimeout(function () {
            if (sequence !== assetReleaseState.sequence) return;
            assetReleaseState.busy = false;
            console.log('[ios2-web] Cocos unused assets released', reason || 'unknown',
                'assets=' + before + '->' + managedAssetCount());
        }, 0);
        return true;
    }
    window.__ios2ReleaseUnusedAssets = releaseUnusedAssets;

    // Logout closes the whole game instance, so it is safe to tear down the
    // director and release every Cocos asset before the native WKWebView is
    // removed. This is intentionally separate from normal scene cleanup.
    function shutdownGame() {
        var manager = window.cc && window.cc.assetManager;
        if (!manager || assetReleaseState.shuttingDown) return !!manager;
        assetReleaseState.shuttingDown = true;
        try {
            if (window.cc.game && typeof window.cc.game.pause === 'function') window.cc.game.pause();
            var director = window.cc.director;
            if (director && typeof director.purgeDirector === 'function') {
                director.purgeDirector();
            } else if (typeof manager.releaseAll === 'function') {
                manager.releaseAll();
            } else {
                manager.releaseUnusedAssets();
            }
            console.log('[ios2-web] Cocos game instance shut down',
                'assets=' + managedAssetCount());
        } catch (error) {
            console.warn('[ios2-web] Cocos game shutdown failed', error);
            try { manager.releaseAll(); } catch (ignored) {}
        }
        return true;
    }
    window.__ios2ShutdownGame = shutdownGame;

    function installAssetReleaseHooks() {
        if (window.__ios2AssetReleaseHooksInstalled) return;
        window.__ios2AssetReleaseHooksInstalled = true;
        document.addEventListener('visibilitychange', function () {
            if (document.hidden) releaseUnusedAssets('document-hidden');
        });
        window.addEventListener('pagehide', function () {
            releaseUnusedAssets('pagehide');
        });
    }

    function installDirectorAssetReleaseHook() {
        var director = window.cc && window.cc.director;
        var Director = window.cc && window.cc.Director;
        if (!director || !Director || !Director.EVENT_AFTER_SCENE_LAUNCH ||
            director.__ios2AssetReleaseHookInstalled) return;
        director.__ios2AssetReleaseHookInstalled = true;
        director.on(Director.EVENT_AFTER_SCENE_LAUNCH, function () {
            releaseUnusedAssets('after-scene-launch');
        });
    }

    function decryptJSC(data, keyText) {
        var bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
        var keyBytes = new TextEncoder().encode(keyText);
        var key = new Uint8Array(16);
        key.set(keyBytes.subarray(0, 16));

        function uint32(source, includeLength) {
            var length = source.length;
            var count = Math.ceil(length / 4);
            var values = new Uint32Array(count + (includeLength ? 1 : 0));
            for (var index = 0; index < length; index++) {
                values[index >>> 2] |= source[index] << ((index & 3) << 3);
            }
            if (includeLength) values[count] = length;
            return values;
        }

        var values = uint32(bytes, false);
        var keyValues = uint32(key, false);
        var last = values.length - 1;
        if (last < 1) return bytes;
        var rounds = Math.floor(6 + 52 / values.length);
        var sum = rounds * 0x9E3779B9;
        var y = values[0];
        while (sum !== 0) {
            var e = sum >>> 2 & 3;
            for (var position = last; position > 0; position--) {
                var z = values[position - 1];
                var mix = ((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
                    ((sum ^ y) + (keyValues[position & 3 ^ e] ^ z));
                y = values[position] = values[position] - mix >>> 0;
            }
            z = values[last];
            mix = ((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
                ((sum ^ y) + (keyValues[e] ^ z));
            y = values[0] = values[0] - mix >>> 0;
            sum = sum - 0x9E3779B9 >>> 0;
        }

        var decodedLength = values[last];
        var maximumLength = last << 2;
        if (decodedLength < maximumLength - 3 || decodedLength > maximumLength) {
            throw new Error('Invalid XXTEA payload length');
        }
        var output = new Uint8Array(decodedLength);
        for (var outputIndex = 0; outputIndex < decodedLength; outputIndex++) {
            output[outputIndex] = values[outputIndex >>> 2] >>> ((outputIndex & 3) << 3) & 0xFF;
        }
        return output;
    }
    window.__ios2DecryptJSC = decryptJSC;

    function installTypeScriptRuntimeHelpers() {
        var extendStatics = Object.setPrototypeOf ||
            ({ __proto__: [] } instanceof Array && function (target, source) { target.__proto__ = source; }) ||
            function (target, source) {
                for (var key in source) {
                    if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
                }
            };

        if (typeof window.__extends !== 'function') {
            window.__extends = function (derived, base) {
                if (typeof base !== 'function' && base !== null) {
                    throw new TypeError('Class extends value ' + String(base) + ' is not a constructor or null');
                }
                extendStatics(derived, base);
                function TemporaryConstructor() { this.constructor = derived; }
                derived.prototype = base === null ? Object.create(base) :
                    (TemporaryConstructor.prototype = base.prototype, new TemporaryConstructor());
            };
        }
        if (typeof window.__assign !== 'function') {
            window.__assign = Object.assign || function (target) {
                for (var source, index = 1, length = arguments.length; index < length; index++) {
                    source = arguments[index];
                    for (var key in source) {
                        if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
                    }
                }
                return target;
            };
        }
        if (typeof window.__rest !== 'function') {
            window.__rest = function (source, exclude) {
                var target = {};
                for (var key in source) {
                    if (Object.prototype.hasOwnProperty.call(source, key) && exclude.indexOf(key) < 0) target[key] = source[key];
                }
                if (source !== null && typeof Object.getOwnPropertySymbols === 'function') {
                    var symbols = Object.getOwnPropertySymbols(source);
                    for (var index = 0; index < symbols.length; index++) {
                        if (exclude.indexOf(symbols[index]) < 0 && Object.prototype.propertyIsEnumerable.call(source, symbols[index])) {
                            target[symbols[index]] = source[symbols[index]];
                        }
                    }
                }
                return target;
            };
        }
        if (typeof window.__decorate !== 'function') {
            window.__decorate = function (decorators, target, key, descriptor) {
                var result, count = arguments.length;
                var value = count < 3 ? target : descriptor === null ? descriptor = Object.getOwnPropertyDescriptor(target, key) : descriptor;
                if (typeof Reflect === 'object' && typeof Reflect.decorate === 'function') {
                    value = Reflect.decorate(decorators, target, key, descriptor);
                } else {
                    for (var index = decorators.length - 1; index >= 0; index--) {
                        if ((result = decorators[index])) {
                            value = (count < 3 ? result(value) : count > 3 ? result(target, key, value) : result(target, key)) || value;
                        }
                    }
                }
                return count > 3 && value && Object.defineProperty(target, key, value), value;
            };
        }
        if (typeof window.__param !== 'function') {
            window.__param = function (paramIndex, decorator) {
                return function (target, key) { decorator(target, key, paramIndex); };
            };
        }
        if (typeof window.__metadata !== 'function') {
            window.__metadata = function (metadataKey, metadataValue) {
                if (typeof Reflect === 'object' && typeof Reflect.metadata === 'function') {
                    return Reflect.metadata(metadataKey, metadataValue);
                }
            };
        }
        if (typeof window.__awaiter !== 'function') {
            window.__awaiter = function (thisArg, args, PromiseCtor, generator) {
                function adopt(value) {
                    return value instanceof PromiseCtor ? value : new PromiseCtor(function (resolve) { resolve(value); });
                }
                return new (PromiseCtor || (PromiseCtor = Promise))(function (resolve, reject) {
                    function fulfilled(value) { try { step(generator.next(value)); } catch (error) { reject(error); } }
                    function rejected(value) { try { step(generator.throw(value)); } catch (error) { reject(error); } }
                    function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
                    step((generator = generator.apply(thisArg, args || [])).next());
                });
            };
        }
        if (typeof window.__generator !== 'function') {
            window.__generator = function (thisArg, body) {
                var state = { label: 0, sent: sent, trys: [], ops: [] };
                var iterator, result, operation, generator = { next: verb(0), throw: verb(1), return: verb(2) };
                if (typeof Symbol === 'function') generator[Symbol.iterator] = function () { return this; };
                return generator;

                function sent() {
                    if (result[0] & 1) throw result[1];
                    return result[1];
                }
                function verb(type) { return function (value) { return step([type, value]); }; }
                function step(op) {
                    if (iterator) throw new TypeError('Generator is already executing.');
                    while (state) {
                        try {
                            iterator = 1;
                            if (result && (operation = op[0] & 2 ? result.return : op[0] ? result.throw || ((operation = result.return) && operation.call(result), 0) : result.next) && !(operation = operation.call(result, op[1])).done) return operation;
                            result = 0;
                            if (operation) op = [op[0] & 2, operation.value];
                            switch (op[0]) {
                            case 0:
                            case 1:
                                operation = op;
                                break;
                            case 4:
                                state.label++;
                                return { value: op[1], done: false };
                            case 5:
                                state.label++;
                                result = op[1];
                                op = [0];
                                continue;
                            case 7:
                                op = state.ops.pop();
                                state.trys.pop();
                                continue;
                            default:
                                operation = state.trys;
                                operation = operation.length > 0 && operation[operation.length - 1];
                                if (!operation && (op[0] === 6 || op[0] === 2)) { state = 0; continue; }
                                if (op[0] === 3 && (!operation || (op[1] > operation[0] && op[1] < operation[3]))) { state.label = op[1]; break; }
                                if (op[0] === 6 && state.label < operation[1]) { state.label = operation[1]; operation = op; break; }
                                if (operation && state.label < operation[2]) { state.label = operation[2]; state.ops.push(op); break; }
                                if (operation[2]) state.ops.pop();
                                state.trys.pop();
                                continue;
                            }
                            op = body.call(thisArg, state);
                        } catch (error) {
                            op = [6, error];
                            result = 0;
                        } finally {
                            iterator = operation = 0;
                        }
                    }
                    if (op[0] & 5) throw op[1];
                    return { value: op[0] ? op[1] : void 0, done: true };
                }
            };
        }
        if (typeof window.__createBinding !== 'function') {
            window.__createBinding = Object.create ? function (target, module, key, alias) {
                if (alias === undefined) alias = key;
                Object.defineProperty(target, alias, { enumerable: true, get: function () { return module[key]; } });
            } : function (target, module, key, alias) {
                if (alias === undefined) alias = key;
                target[alias] = module[key];
            };
        }
        if (typeof window.__exportStar !== 'function') {
            window.__exportStar = function (module, exports) {
                for (var key in module) {
                    if (key !== 'default' && !Object.prototype.hasOwnProperty.call(exports, key)) window.__createBinding(exports, module, key);
                }
            };
        }
        if (typeof window.__values !== 'function') {
            window.__values = function (value) {
                var iteratorSymbol = typeof Symbol === 'function' && Symbol.iterator;
                var iterator = iteratorSymbol && value[iteratorSymbol];
                var index = 0;
                if (iterator) return iterator.call(value);
                if (value && typeof value.length === 'number') {
                    return { next: function () {
                        if (value && index >= value.length) value = void 0;
                        return { value: value && value[index++], done: !value };
                    } };
                }
                throw new TypeError(iteratorSymbol ? 'Object is not iterable.' : 'Symbol.iterator is not defined.');
            };
        }
        if (typeof window.__read !== 'function') {
            window.__read = function (value, count) {
                var iteratorSymbol = typeof Symbol === 'function' && value[Symbol.iterator];
                if (!iteratorSymbol) return value;
                var iterator = iteratorSymbol.call(value), item, error, result = [];
                try {
                    while ((count === undefined || count-- > 0) && !(item = iterator.next()).done) result.push(item.value);
                } catch (exception) {
                    error = { error: exception };
                } finally {
                    try {
                        if (item && !item.done && (iteratorSymbol = iterator.return)) iteratorSymbol.call(iterator);
                    } finally {
                        if (error) throw error.error;
                    }
                }
                return result;
            };
        }
        if (typeof window.__spread !== 'function') {
            window.__spread = function () {
                var result = [];
                for (var index = 0; index < arguments.length; index++) result = result.concat(window.__read(arguments[index]));
                return result;
            };
        }
        if (typeof window.__spreadArrays !== 'function') {
            window.__spreadArrays = function () {
                var total = 0;
                for (var index = 0; index < arguments.length; index++) total += arguments[index].length;
                var result = Array(total), offset = 0;
                for (index = 0; index < arguments.length; index++) {
                    var source = arguments[index];
                    for (var itemIndex = 0; itemIndex < source.length; itemIndex++, offset++) result[offset] = source[itemIndex];
                }
                return result;
            };
        }
        if (typeof window.__spreadArray !== 'function') {
            window.__spreadArray = function (target, source, pack) {
                if (pack || arguments.length === 2) {
                    for (var index = 0, length = source.length, copy; index < length; index++) {
                        if (copy || !(index in source)) {
                            if (!copy) copy = Array.prototype.slice.call(source, 0, index);
                            copy[index] = source[index];
                        }
                    }
                    source = copy || Array.prototype.slice.call(source);
                }
                return target.concat(source);
            };
        }
        if (typeof window.__await !== 'function') {
            window.__await = function (value) {
                return this instanceof window.__await ? (this.v = value, this) : new window.__await(value);
            };
        }
        if (typeof window.__asyncGenerator !== 'function') {
            window.__asyncGenerator = function (thisArg, args, generator) {
                if (!Symbol.asyncIterator) throw new TypeError('Symbol.asyncIterator is not defined.');
                var method, gen = generator.apply(thisArg, args || []), queue = [];
                var asyncIterator = {};
                resume('next');
                resume('throw', function (value) { throw value; });
                resume('return');
                asyncIterator[Symbol.asyncIterator] = function () { return this; };
                return asyncIterator;

                function resume(name, fallback) {
                    if (gen[name]) asyncIterator[name] = function (value) {
                        return new Promise(function (resolve, reject) {
                            queue.push([name, value, resolve, reject]) > 1 || step(name, value);
                        });
                    };
                    else if (fallback) asyncIterator[name] = fallback;
                }
                function step(name, value) {
                    try {
                        method = gen[name](value);
                        method.value instanceof window.__await ? Promise.resolve(method.value.v).then(next, fail) : settle(queue[0][2], method);
                    } catch (error) {
                        settle(queue[0][3], error);
                    }
                }
                function next(value) { step('next', value); }
                function fail(value) { step('throw', value); }
                function settle(resolve, value) {
                    resolve(value);
                    queue.shift();
                    if (queue.length) step(queue[0][0], queue[0][1]);
                }
            };
        }
        if (typeof window.__asyncDelegator !== 'function') {
            window.__asyncDelegator = function (iterator) {
                var pending, delegator = {};
                verb('next');
                verb('throw', function (value) { throw value; });
                verb('return');
                delegator[Symbol.iterator] = function () { return this; };
                return delegator;

                function verb(name, fallback) {
                    delegator[name] = iterator[name] ? function (value) {
                        return (pending = !pending) ? { value: window.__await(iterator[name](value)), done: name === 'return' } :
                            fallback ? fallback(value) : value;
                    } : fallback;
                }
            };
        }
        if (typeof window.__asyncValues !== 'function') {
            window.__asyncValues = function (value) {
                if (!Symbol.asyncIterator) throw new TypeError('Symbol.asyncIterator is not defined.');
                var iterator = value[Symbol.asyncIterator];
                var asyncIterator;
                if (iterator) return iterator.call(value);
                value = typeof window.__values === 'function' ? window.__values(value) : value[Symbol.iterator]();
                asyncIterator = {};
                verb('next');
                verb('throw');
                verb('return');
                asyncIterator[Symbol.asyncIterator] = function () { return this; };
                return asyncIterator;

                function verb(name) {
                    asyncIterator[name] = value[name] && function (arg) {
                        return new Promise(function (resolve, reject) {
                            settle(resolve, reject, (arg = value[name](arg)).done, arg.value);
                        });
                    };
                }
                function settle(resolve, reject, done, value) {
                    Promise.resolve(value).then(function (value) { resolve({ value: value, done: done }); }, reject);
                }
            };
        }
        if (typeof window.__makeTemplateObject !== 'function') {
            window.__makeTemplateObject = function (cooked, raw) {
                if (Object.defineProperty) Object.defineProperty(cooked, 'raw', { value: raw });
                else cooked.raw = raw;
                return cooked;
            };
        }
        if (typeof window.__importStar !== 'function') {
            window.__importStar = function (module) {
                if (module && module.__esModule) return module;
                var result = {};
                if (module != null) {
                    for (var key in module) {
                        if (key !== 'default' && Object.prototype.hasOwnProperty.call(module, key)) window.__createBinding(result, module, key);
                    }
                }
                Object.defineProperty(result, 'default', { enumerable: true, value: module });
                return result;
            };
        }
        if (typeof window.__importDefault !== 'function') {
            window.__importDefault = function (module) {
                return module && module.__esModule ? module : { default: module };
            };
        }
        if (typeof window.__classPrivateFieldGet !== 'function') {
            window.__classPrivateFieldGet = function (receiver, privateMap) {
                if (!privateMap.has(receiver)) throw new TypeError('attempted to get private field on non-instance');
                return privateMap.get(receiver);
            };
        }
        if (typeof window.__classPrivateFieldSet !== 'function') {
            window.__classPrivateFieldSet = function (receiver, privateMap, value) {
                if (!privateMap.has(receiver)) throw new TypeError('attempted to set private field on non-instance');
                privateMap.set(receiver, value);
                return value;
            };
        }
    }

    function installEncryptedBundleLoader() {
        var downloader = cc.assetManager && cc.assetManager.downloader;
        if (!downloader || downloader.__ios2EncryptedBundles) return;
        downloader.__ios2EncryptedBundles = true;
        var originalScripts = downloader._downloaders || {};
        var originalJSONDownloader = originalScripts['.json'];
        var originalScriptDownloader = originalScripts['.js'];
        // Remote bundles can arrive as ios2-game://app/remote/<name>/... or
        // ios2-game://app/<name>/... depending on which loader requested them.
        var encryptedBundle = /(?:^|\/)(?:remote\/)?(?:game|launcher|TEST_REMOTE_MODULE)\/index\.[^/]+\.js(?:\?|$)/;
        var loaded = Object.create(null);

        function execute(code, url) {
            installTypeScriptRuntimeHelpers();
            code = code.replace(/cc\.assetManager\.loadAny=function\(\)\{\},?/g, '');
            code = code.replace(/[a-zA-Z]\.PlatformManager\.instance\.isH5&&\(cc\.assetManager\.loadBundle=function\(\)\{\}\),?/g, '');
            // Keep Cocos in its WebKit runtime, but expose the native iOS
            // business profile to the remote game's PlatformManager.
            var nativeProfileApplied = false;
            code = code.replace(/get _isH5\(\)\{return [^{}]*\},get isH5\(\)\{/,
                function () {
                    nativeProfileApplied = true;
                    return 'get _isH5(){return!1},get isH5(){';
                });
            if (nativeProfileApplied) {
                console.log('[ios2-web] native iOS platform profile applied', url);
            }
            (0, eval)(code + '\n//# sourceURL=' + url);
            // launcher installs a JSB-only PVR parser while applying its ASTC
            // patch. Restore the WebKit parser after each remote bundle runs.
            installASTCTextureSupport();
        }

        downloader.register('.js', function (url, options, onComplete) {
            if (!encryptedBundle.test(url)) {
                return originalScriptDownloader(url, options, onComplete);
            }
            var encryptedURL = url + 'c';
            if (loaded[encryptedURL]) {
                onComplete(null);
                return;
            }
            fetch(encryptedURL, { cache: 'force-cache' })
                .then(function (response) {
                    if (!response.ok) throw new Error('download failed: ' + encryptedURL + ', status: ' + response.status);
                    return response.arrayBuffer();
                })
                .then(function (buffer) {
                    var bytes = decryptJSC(buffer, '0Aed5E79bbEa69f8');
                    var code = new TextDecoder().decode(bytes);
                    execute(code, encryptedURL);
                    loaded[encryptedURL] = true;
                    console.log('[ios2-web] decrypted bundle', encryptedURL, bytes.length);
                    onComplete(null);
                })
                .catch(function (error) { onComplete(error); });
        });

        function downloadJSON(url, options, onComplete) {
            if (typeof originalJSONDownloader === 'function') {
                return originalJSONDownloader(url, options, onComplete);
            }
            fetch(url, { cache: 'force-cache' })
                .then(function (response) {
                    if (!response.ok) throw new Error('download failed: ' + url + ', status: ' + response.status);
                    return response.json();
                })
                .then(function (json) { onComplete(null, json); })
                .catch(function (error) { onComplete(error); });
        }

        function downloadBundle(url, options, onComplete) {
            var bundleName = cc.path.basename(url);
            var version = options.version || downloader.bundleVers && downloader.bundleVers[bundleName];
            var versionPart = version ? version + '.' : '';
            var completeCount = 0;
            var failure = null;
            var config = null;

            function done(error) {
                if (error && !failure) failure = error;
                completeCount++;
                if (completeCount === 2) onComplete(failure, config);
            }

            downloadJSON(url + '/config.' + versionPart + 'json', options, function (error, data) {
                if (data) {
                    data.base = url + '/';
                    config = data;
                }
                done(error);
            });
            downloader._downloaders['.js'](url + '/index.' + versionPart + 'js', options, done);
        }

        downloader.register('bundle', downloadBundle);
        console.log('[ios2-web] custom bundle loader installed');
    }
    window.__ios2InstallEncryptedBundleLoader = installEncryptedBundleLoader;

    function installASTCTextureSupport() {
        var downloader = cc.assetManager && cc.assetManager.downloader;
        var parser = cc.assetManager && cc.assetManager.parser;
        var texturePrototype = cc.Texture2D && cc.Texture2D.prototype;
        if (!parser || !texturePrototype) return;
        if (parser.__ios2ASTCInstalled) {
            // A remote bundle can replace this parser with a JSB variant that
            // reads from window.fsUtils. WebKit must parse the downloaded data.
            if (parser.__ios2ASTCPVRParser) {
                parser.register('.pvr', parser.__ios2ASTCPVRParser);
            }
            return;
        }
        parser.__ios2ASTCInstalled = true;

        // Creator serializes this project's texture alternatives as "0_5@...".
        // The supplied Web engine omits index 5, so it used PNG (index 0) even
        // when the device can upload the ASTC payload carried by the PVR file.
        var textureExtnames = cc.Texture2D.extnames;
        if (textureExtnames) textureExtnames[5] = '.pvr';

        if (downloader && !downloader.__ios2PVRDownloaderInstalled) {
            downloader.__ios2PVRDownloaderInstalled = true;
            downloader.register('.pvr', function (url, options, onComplete) {
                var binaryOptions = Object.assign({}, options, { responseType: 'arraybuffer' });
                downloader.downloadFile(url, binaryOptions, function (error, buffer) {
                    if (!error) {
                        console.log('[ios2-web] PVR texture loaded', url,
                            buffer && buffer.byteLength || 0, 'bytes');
                    }
                    onComplete(error, buffer);
                });
            });
        }

        var originalPVRParser = parser.parsePVRTex;
        var astcPVRParser = function (file, options, onComplete) {
            var buffer = file instanceof ArrayBuffer ? file : file && file.buffer;
            var bytes = buffer ? new Uint8Array(buffer) : null;
            if (!bytes || bytes.length < 16 || bytes[0] !== 0x13 || bytes[1] !== 0xAB ||
                bytes[2] !== 0xA1 || bytes[3] !== 0x5C) {
                if (typeof originalPVRParser === 'function') {
                    originalPVRParser(file, options, onComplete);
                } else {
                    onComplete(new Error('Unsupported PVR texture header'));
                }
                return;
            }
            var blockX = bytes[4];
            var blockY = bytes[5];
            var blockZ = bytes[6];
            var width = bytes[7] | bytes[8] << 8 | bytes[9] << 16;
            var height = bytes[10] | bytes[11] << 8 | bytes[12] << 16;
            var formats = {
                '4x4': 0x93B0, '5x4': 0x93B1, '5x5': 0x93B2,
                '6x5': 0x93B3, '6x6': 0x93B4, '8x5': 0x93B5,
                '8x6': 0x93B6, '8x8': 0x93B7, '10x5': 0x93B8,
                '10x6': 0x93B9, '10x8': 0x93BA, '10x10': 0x93BB,
                '12x10': 0x93BC, '12x12': 0x93BD
            };
            var internalFormat = formats[blockX + 'x' + blockY];
            if (blockZ !== 1 || !width || !height || !internalFormat) {
                onComplete(new Error('Unsupported ASTC texture header'));
                return;
            }
            var payloadLength = Math.ceil(width / blockX) * Math.ceil(height / blockY) * 16;
            if (16 + payloadLength > bytes.length) {
                onComplete(new Error('Truncated ASTC texture payload'));
                return;
            }
            onComplete(null, {
                _compressed: true,
                _data: new Uint8Array(buffer, 16, payloadLength),
                width: width,
                height: height,
                __ios2ASTCFormat: internalFormat
            });
        };
        parser.__ios2ASTCPVRParser = astcPVRParser;
        parser.register('.pvr', astcPVRParser);

        var descriptor = Object.getOwnPropertyDescriptor(texturePrototype, '_nativeAsset');
        if (!descriptor || typeof descriptor.set !== 'function') return;
        Object.defineProperty(texturePrototype, '_nativeAsset', {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: descriptor.get,
            set: function (data) {
                if (!(data && data.__ios2ASTCFormat)) {
                    descriptor.set.call(this, data);
                    return;
                }
                var renderer = cc.renderer;
                var device = renderer && renderer.device;
                var gl = device && device._gl;
                var extension = gl && gl.getExtension('WEBGL_compressed_texture_astc');
                if (!extension) throw new Error('ASTC WebGL extension is unavailable');
                if (this._texture) this._texture.destroy();
                var texture = new renderer.Texture2D(device, {
                    images: [],
                    width: data.width,
                    height: data.height,
                    format: cc.Texture2D.PixelFormat.RGBA8888,
                    genMipmaps: false
                });
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, texture._glID);
                gl.compressedTexImage2D(gl.TEXTURE_2D, 0, data.__ios2ASTCFormat,
                    data.width, data.height, 0, data._data);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
                device._restoreTexture(0);
                this._texture = texture;
                this._image = data;
                this.width = data.width;
                this.height = data.height;
                this._packable = false;
                this.loaded = true;
                this.emit('load');
            }
        });
    }

    function reportCapabilities(gl) {
        if (!gl || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.ios2Game) return;
        var support = window.IOS2PVR && window.IOS2PVR.extensions ? window.IOS2PVR.extensions(gl) : {};
        window.webkit.messageHandlers.ios2Game.postMessage({
            type: 'capabilities',
            instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
            pvrtc: !!support.pvrtc,
            astc: !!support.astc
        });
    }

    function boot() {
        console.log('[ios2-web] boot revision', IOS2_WEB_RUNTIME_REVISION);
        installAssetReleaseHooks();
        var settings = window._CCSettings;
        if (!settings || !window.cc) {
            showFatal('WebKit 游戏启动失败\n\n缺少 Web runtime settings 或 Cocos Web 引擎。');
            throw new Error('Web runtime settings or Cocos engine is missing');
        }
        var manifest = window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.manifest || {};
        var bundledVers = settings.bundleVers || {};
        var liveBundleVers = manifest.bundleVers;
        if (typeof liveBundleVers === 'string') liveBundleVers = JSON.parse(liveBundleVers);
        if (liveBundleVers && typeof liveBundleVers === 'object') {
            settings.bundleVers = Object.assign({}, bundledVers, liveBundleVers);
        }
        window.BATTLE_VERSION = manifest.battleVersion || window.BATTLE_VERSION;
        settings.platform = 'web-mobile';
        settings.server = 'ios2-game://app/cdn';
        settings.remoteBundles = settings.remoteBundles || [];
        Object.keys(settings.bundleVers || {}).forEach(function (name) {
            if (name !== 'internal' && name !== 'codeVersion' && name !== 'COMMIT_ID' &&
                settings.remoteBundles.indexOf(name) < 0) settings.remoteBundles.push(name);
        });
        var canvas = document.getElementById('GameCanvas');
        installTypeScriptRuntimeHelpers();
        installASTCTextureSupport();
        cc.macro.SUPPORT_TEXTURE_FORMATS = ['.pvr'];
        var option = {
            id: canvas,
            debugMode: cc.debug.DebugMode.ERROR,
            showFPS: false,
            frameRate: 30,
            groupList: settings.groupList,
            collisionMatrix: settings.collisionMatrix
        };
        cc.assetManager.init({
            bundleVers: settings.bundleVers,
            remoteBundles: settings.remoteBundles,
            server: settings.server
        });
        installEncryptedBundleLoader();
        var bundles = [{
            name: cc.AssetManager.BuiltinBundleName.INTERNAL,
            url: 'ios2-game://app/assets/internal'
        }];
        if (settings.hasResourcesBundle) {
            bundles.push({
                name: cc.AssetManager.BuiltinBundleName.RESOURCES,
                url: 'ios2-game://app/assets/resources'
            });
        }
        bundles.push({
            name: 'launcher',
            url: 'ios2-game://app/cdn/remote/launcher'
        });
        var scripts = settings.jsList || [];
        var pending = bundles.length + (scripts.length ? 1 : 0);
        var failed = false;
        function complete(error, name) {
            if (failed) return;
            if (error) {
                failed = true;
                console.error('[ios2-web] load failed', name, error);
                var detail = error && (error.stack || error.message) || String(error || '未知错误');
                if (name === 'launcher') {
                    var version = settings.bundleVers && settings.bundleVers.launcher || '<unknown>';
                    showFatal('WebKit 游戏代码加载失败\n\n无法下载或解密：\n' +
                        'remote/launcher/index.' + version + '.jsc\n\n' + detail);
                } else {
                    showFatal('WebKit 游戏启动失败\n\n加载 ' + name + ' 失败：\n' + detail);
                }
                return;
            }
            pending--;
            if (!pending) {
                cc.game.run(option, function () {
                    // The launcher registers its JSB-only ASTC parser from
                    // EVENT_ENGINE_INITED. Restore the WebKit parser after
                    // that event has completed and before loading the scene.
                    installASTCTextureSupport();
                    console.log('[ios2-web] WebKit PVR parser restored after engine init');
                    installDirectorAssetReleaseHook();
                    var device = cc.renderer && cc.renderer.device;
                    var gl = device && device._gl;
                    var pvrtc = device && device.ext('WEBGL_compressed_texture_pvrtc');
                    var astc = gl && gl.getExtension('WEBGL_compressed_texture_astc');
                    reportCapabilities(gl);
                    if (!pvrtc && !astc) {
                        throw new Error('PVRTC or ASTC is required; PNG/WebP fallback is disabled');
                    }
                    // Cocos 2.4.9 only considers .pvr when it sees the PVRTC
                    // extension. This project's .pvr files contain ASTC data,
                    // parsed and uploaded by installASTCTextureSupport above.
                    if (!pvrtc && astc) {
                        device._extensions.WEBGL_compressed_texture_pvrtc = astc;
                        console.log('[ios2-web] ASTC enabled for PVR texture selection');
                    }
                    cc.view.enableRetina(true);
                    cc.view.resizeWithBrowserSize(true);
                    cc.director.loadScene(settings.launchScene, function (sceneError) {
                        if (sceneError) console.error('[ios2-web] scene failed', sceneError);
                    });
                });
            }
        }
        if (scripts.length) {
            cc.assetManager.loadScript(scripts.map(function (path) {
                return 'ios2-game://app/src/' + path;
            }), function (error) { complete(error, 'scripts'); });
        }
        bundles.forEach(function (bundle) {
            cc.assetManager.loadBundle(bundle.url, {
                version: settings.bundleVers && settings.bundleVers[bundle.name]
            }, function (error) {
                complete(error, bundle.name);
            });
        });
    }

    window.addEventListener('load', boot);
}());
