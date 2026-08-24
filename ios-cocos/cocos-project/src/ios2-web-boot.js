(function () {
    'use strict';

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

    function installASTCTextureSupport() {
        var parser = cc.assetManager && cc.assetManager.parser;
        var texturePrototype = cc.Texture2D && cc.Texture2D.prototype;
        if (!parser || !texturePrototype || parser.__ios2ASTCInstalled) return;
        parser.__ios2ASTCInstalled = true;

        var originalPVRParser = parser.parsePVRTex;
        parser.register('.pvr', function (file, options, onComplete) {
            var buffer = file instanceof ArrayBuffer ? file : file && file.buffer;
            var bytes = buffer ? new Uint8Array(buffer) : null;
            if (!bytes || bytes.length < 16 || bytes[0] !== 0x13 || bytes[1] !== 0xAB ||
                bytes[2] !== 0xA1 || bytes[3] !== 0x5C) {
                originalPVRParser(file, options, onComplete);
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
        });

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

    function boot() {
        var settings = window._CCSettings;
        if (!settings || !window.cc) {
            showFatal('WebKit 游戏启动失败\n\n缺少 Web runtime settings 或 Cocos Web 引擎。');
            throw new Error('Web runtime settings or Cocos engine is missing');
        }
        var manifest = window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.manifest || {};
        var liveBundleVers = manifest.bundleVers;
        if (typeof liveBundleVers === 'string') liveBundleVers = JSON.parse(liveBundleVers);
        if (liveBundleVers && typeof liveBundleVers === 'object') settings.bundleVers = liveBundleVers;
        window.BATTLE_VERSION = manifest.battleVersion || window.BATTLE_VERSION;
        settings.platform = 'web-mobile';
        settings.server = 'ios2-game://app/cdn';
        settings.remoteBundles = settings.remoteBundles || [];
        Object.keys(settings.bundleVers || {}).forEach(function (name) {
            if (name !== 'internal' && name !== 'codeVersion' && name !== 'COMMIT_ID' &&
                settings.remoteBundles.indexOf(name) < 0) settings.remoteBundles.push(name);
        });
        var canvas = document.getElementById('GameCanvas');
        cc.macro.SUPPORT_TEXTURE_FORMATS = ['.pvr'];
        installASTCTextureSupport();
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
                    showFatal('WebKit 游戏代码不可用\n\nCDN 缺少浏览器代码：\n' +
                        'remote/launcher/index.' + version + '.js\n\n' +
                        '当前 iOS CDN 只有 index.' + version + '.jsc。该文件是 V8/JSB 二进制字节码，' +
                        'WKWebView 的 JavaScriptCore 无法执行。\n\n' + detail);
                } else {
                    showFatal('WebKit 游戏启动失败\n\n加载 ' + name + ' 失败：\n' + detail);
                }
                return;
            }
            pending--;
            if (!pending) {
                cc.game.run(option, function () {
                    var device = cc.renderer && cc.renderer.device;
                    var gl = device && device._gl;
                    var pvrtc = device && device.ext('WEBGL_compressed_texture_pvrtc');
                    var astc = gl && gl.getExtension('WEBGL_compressed_texture_astc');
                    if (!pvrtc && !astc) {
                        throw new Error('PVRTC or ASTC is required; PNG/WebP fallback is disabled');
                    }
                    if (!pvrtc && astc) device._extensions.WEBGL_compressed_texture_pvrtc = astc;
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
