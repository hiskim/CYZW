/* Coordinates the persistent ios2 management shell and its page modules. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts || {};
    var common = parts.common;
    if (!common) throw new Error('ios2 manager common module is missing');
    var NAV_HEIGHT = common.NAV_HEIGHT;
    var COLORS = common.COLORS;

    var methods = {
        ctor: function (scene, launcher) {
            this.scene = scene;
            this.launcher = launcher;
            this.page = 0;
            this.gameStarted = false;
            this.scriptRunPending = false;
            this.status = '';
            this.storage = common.safeStorage();
            this.binFiles = this._loadBins();
            this.binGroups = this._loadBinGroups();
            this._ensureBinGroups();
            this.scripts = [];
            this._buildChrome();
            this._buildAccountHome();
            this._loadScripts();
            this.showPage(0);
            this._refreshScripts();
            return true;
        },

        _buildAccountHome: function () {
            if (!(global.IOS2AccountRepository && global.IOS2LoginService && global.IOS2AccountPresenter)) {
                throw new Error('FairyGUI account modules are missing');
            }
            var self = this;
            this.accountRepository = new global.IOS2AccountRepository(this.storage);
            this.accountPresenter = new global.IOS2AccountPresenter({
                repository: this.accountRepository,
                loginService: new global.IOS2LoginService(),
                onOpenPage: function (page) { self.showPage(page); },
                getEnabledScripts: function () {
                    return typeof self._enabledScriptRecords === 'function' ? self._enabledScriptRecords([]) : [];
                }
            });
        },

        _setLegacyChromeVisible: function (visible) {
            var items = [this.background, this.content, this.navBackground, this.navIndicator,
                this.navTouchSurface, this.nav];
            for (var index = 0; index < items.length; index++) {
                if (items[index]) items[index].active = visible;
            }
        },

        _buildChrome: function () {
            var size = cc.winSize;
            this.background = common.rectNode(size.width, size.height, COLORS.background);
            this.addChild(this.background, 0);
            this.content = new cc.Node();
            this.addChild(this.content, 1);

            this.logoutOverlay = common.actionButton('↪', 24, this._logout.bind(this), COLORS.warning, 50);
            this.logoutOverlay.setPosition(size.width - 48, size.height - 102);
            this.logoutOverlay.active = false;
            this.addChild(this.logoutOverlay, 30);

            this.navBackground = common.rectNode(size.width, NAV_HEIGHT, cc.color(255, 255, 255, 255));
            this.navBackground.setPosition(0, 0);
            this.addChild(this.navBackground, 20);
            var shadow = common.rectNode(size.width, 5, cc.color(38, 59, 89, 12));
            shadow.setPosition(0, NAV_HEIGHT);
            this.addChild(shadow, 21);
            var separator = common.rectNode(size.width, 1, COLORS.border);
            separator.setPosition(0, NAV_HEIGHT);
            this.addChild(separator, 22);

            this.nav = new cc.Node();
            this.nav.setPosition(0, 0);
            this.addChild(this.nav, 24);
            var names = ['Bin 文件', 'JS 脚本', '配置'];
            var self = this;
            this.navIndicator = common.surfaceNode(size.width / 3 - 56, 4, COLORS.accent, 2);
            this.navIndicator.setPosition(28, NAV_HEIGHT - 4);
            this.addChild(this.navIndicator, 25);
            this.navTouchSurface = new cc.Node();
            this.navTouchSurface.setAnchorPoint(0, 0);
            this.navTouchSurface.setContentSize(size.width, NAV_HEIGHT);
            this.navTouchSurface.on(cc.Node.EventType.TOUCH_END, function (event) {
                var location = event && typeof event.getLocation === 'function' ? event.getLocation() : null;
                var width = cc.winSize.width || size.width;
                var page = location ? Math.max(0, Math.min(2, Math.floor(location.x / (width / 3)))) : self.page;
                if (self.gameStarted && self.background.active && self.page === page) self._resumeGame();
                else self.showPage(page);
            });
            this.addChild(this.navTouchSurface, 26);
            for (var index = 0; index < names.length; index++) {
                (function (page) {
                    var navItem = common.button(names[page], 22, function () {
                        if (self.gameStarted && self.background.active && self.page === page) self._resumeGame();
                        else self.showPage(page);
                    }, cc.color(45, 58, 76, 255));
                    navItem.setPosition(size.width * (page + 0.5) / 3, NAV_HEIGHT / 2);
                    self.nav.addChild(navItem);
                }(index));
            }
        },

        showPage: function (page) {
            this.page = Math.max(0, Math.min(2, Number(page) || 0));
            if (this.page === 0 && this.accountPresenter) {
                this._setLegacyChromeVisible(false);
                this.accountPresenter.show();
                return;
            }
            if (this.accountPresenter) this.accountPresenter.hide();
            this._setLegacyChromeVisible(true);
            this._clearContent();
            this.statusItem = null;
            if (this.page === 1) {
                if (this._scriptSubpage === 'settings') this._showSettingsConfig();
                else this._showScripts();
            }
            else this._showConfig();
            this._updateNav();
        },

        _updateNav: function () {
            var children = this.nav.getChildren();
            for (var index = 0; index < children.length; index++) {
                var color = index === this.page ? COLORS.accent : cc.color(45, 58, 76, 255);
                children[index].setColor(color);
                if (children[index].__ios2LabelComponent) children[index].__ios2LabelComponent.color = color;
            }
            if (this.navIndicator) {
                var targetX = cc.winSize.width * this.page / 3 + 28;
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(this.navIndicator);
                    cc.tween(this.navIndicator)
                        .to(0.18, { x: targetX }, { easing: 'sineOut' })
                        .start();
                } else this.navIndicator.setPosition(targetX, NAV_HEIGHT - 4);
            }
        },

        _logout: function () {
            if (this.logoutPending) return;
            this.logoutPending = true;
            this._setStatus('正在退出当前登录…', COLORS.warning);
            var self = this;
            var finished = false;
            var nativeLogoutRequested = false;
            var requestNativeLogout = function () {
                if (nativeLogoutRequested) return;
                nativeLogoutRequested = true;
                if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                    try { jsb.reflection.callStaticMethod('IOS2Native', 'logout'); } catch (error) {}
                }
            };
            var finish = function () {
                if (finished) return;
                finished = true;
                self.logoutPending = false;
                self.gameStarted = false;
                if (typeof self._resetScriptRuntime === 'function') self._resetScriptRuntime();
                if (self.logoutOverlay) self.logoutOverlay.active = false;
                self.background.active = true;
                self.content.active = true;
                self.status = '已退出当前登录';
                self.showPage(0);
                if (typeof global.__ios2ResetToLauncher === 'function') setTimeout(global.__ios2ResetToLauncher, 0);
            };
            try {
                if (global.HSDK && typeof global.HSDK.logout === 'function') {
                    var request = global.HSDK.logout();
                    nativeLogoutRequested = true;
                    if (request && typeof request.then === 'function') {
                        request.then(finish, finish);
                        setTimeout(finish, 1200);
                    } else finish();
                } else {
                    requestNativeLogout();
                    finish();
                }
            } catch (error) {
                requestNativeLogout();
                finish();
            }
        },

        _resumeGame: function () {
            if (!this.gameStarted) return;
            this.background.active = false;
            this.content.active = false;
        },

        onLoginReady: function () {
            if (this.accountPresenter) this.accountPresenter.onLoginReady();
            var backend = 'native';
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { backend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native'); }
                catch (ignored) {}
            }
            if (backend === 'webkit') {
                this.onLoginFailed('WebKit 模式请使用账号页的“多开”按钮');
                return;
            }
            if (this.gameStarted) return;
            this._setStatus('认证成功，正在进入游戏…', COLORS.success);
            this.gameStarted = true;
            if (this.accountPresenter) this.accountPresenter.hide();
            if (this.logoutOverlay) this.logoutOverlay.active = true;
            if (this.background) this.background.active = false;
            if (this.content) this.content.active = false;
            if (typeof global.__ios2StartGame === 'function') global.__ios2StartGame();
            else if (this.launcher && typeof this.launcher.onLoadFunc === 'function') this.launcher.onLoadFunc();
            if (typeof this._runEnabledScriptsAfterLogin === 'function') this._runEnabledScriptsAfterLogin();
        },

        onLoginFailed: function (message) {
            if (this.accountPresenter) this.accountPresenter.onLoginFailed(message);
            this._setStatus('登录失败：' + String(message || '未知错误'), COLORS.warning);
        }
    };

    function extend(target, source) {
        for (var key in source) {
            if (typeof source[key] === 'function') target[key] = source[key];
        }
    }
    extend(methods, parts.commonMethods);
    extend(methods, parts.bin);
    extend(methods, parts.scripts);
    extend(methods, parts.config);

    var IOS2ManagerLayer = function (scene, launcher) {
        var node = new cc.Node();
        for (var method in methods) node[method] = methods[method];
        node.ctor(scene, launcher);
        return node;
    };

    global.__ios2ManagerMount = function (scene, launcher) {
        if (!scene) return;
        if (global.__ios2Manager) {
            global.__ios2Manager.launcher = launcher || global.__ios2Manager.launcher;
            if (global.__ios2Manager.parent !== scene) scene.addChild(global.__ios2Manager, 999999);
            return;
        }
        try {
            if (global.fgui && global.fgui.GRoot && !global.__ios2FairyRoot) {
                global.__ios2FairyRoot = global.fgui.GRoot.create();
                if (global.__ios2FairyRoot.node.setLocalZOrder) {
                    global.__ios2FairyRoot.node.setLocalZOrder(999998);
                } else global.__ios2FairyRoot.node.zIndex = 999998;
                if (cc.game && typeof cc.game.addPersistRootNode === 'function') {
                    cc.game.addPersistRootNode(global.__ios2FairyRoot.node);
                }
            }
            global.__ios2Manager = new IOS2ManagerLayer(scene, launcher);
            scene.addChild(global.__ios2Manager, 999999);
            if (cc.game && typeof cc.game.addPersistRootNode === 'function') cc.game.addPersistRootNode(global.__ios2Manager);
        } catch (error) {
            console.error('[ios2] management shell construction failed', error);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'management shell construction failed: ' + (error.stack || error.message || error)); } catch (ignored) {}
        }
    };
    global.__ios2ManagerSetLauncher = function (launcher) {
        if (global.__ios2Manager) global.__ios2Manager.launcher = launcher;
    };
    global.__ios2OnBinFiles = function (json) {
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) {
            manager.accountPresenter.onAccounts(json);
            manager.binFiles = manager.accountRepository.cached();
        } else manager.onBinFiles(json);
    };
    global.__ios2BinFilesReady = global.__ios2OnBinFiles;
    global.__ios2OnBinImported = function (name) {
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onImported(name);
        else manager.onBinImported(name);
    };
    global.__ios2BinImported = global.__ios2OnBinImported;
    global.__ios2OnBinDeleted = function (name) {
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onDeleted(name);
        else manager.onBinDeleted(name);
    };
    global.__ios2BinDeleted = global.__ios2OnBinDeleted;
    global.__ios2OnBinDeleteFailed = function (message) {
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onDeleteFailed(message);
        else manager.onBinDeleteFailed(message);
    };
    global.__ios2BinDeleteFailed = global.__ios2OnBinDeleteFailed;
    global.__ios2OnScriptFiles = function (json) { if (global.__ios2Manager) global.__ios2Manager.onScriptFiles(json); };
    global.__ios2ScriptFilesReady = global.__ios2OnScriptFiles;
    global.__ios2OnScriptImported = function (name) { if (global.__ios2Manager) global.__ios2Manager.onScriptImported(name); };
    global.__ios2ScriptImported = global.__ios2OnScriptImported;
    global.__ios2OnScriptDeleted = function (name) { if (global.__ios2Manager) global.__ios2Manager.onScriptDeleted(name); };
    global.__ios2ScriptDeleted = global.__ios2OnScriptDeleted;
    global.__ios2OnScriptDeleteFailed = function (message) { if (global.__ios2Manager) global.__ios2Manager.onScriptDeleteFailed(message); };
    global.__ios2ScriptDeleteFailed = global.__ios2OnScriptDeleteFailed;
    global.__ios2OnScriptImportFailed = function (message) { if (global.__ios2Manager) global.__ios2Manager.onScriptImportFailed(message); };
    global.__ios2ScriptImportFailed = global.__ios2OnScriptImportFailed;
    global.__ios2OnSettingsImported = function (name) { if (global.__ios2Manager) global.__ios2Manager.onSettingsImported(name); };
    global.__ios2SettingsImported = global.__ios2OnSettingsImported;
    global.__ios2OnSettingsImportFailed = function (message) { if (global.__ios2Manager) global.__ios2Manager.onSettingsImportFailed(message); };
    global.__ios2SettingsImportFailed = global.__ios2OnSettingsImportFailed;
    global.__ios2OnSettingsDeleted = function (name) { if (global.__ios2Manager) global.__ios2Manager.onSettingsDeleted(name); };
    global.__ios2SettingsDeleted = global.__ios2OnSettingsDeleted;
    global.__ios2OnSettingsDeleteFailed = function (message) { if (global.__ios2Manager) global.__ios2Manager.onSettingsDeleteFailed(message); };
    global.__ios2SettingsDeleteFailed = global.__ios2OnSettingsDeleteFailed;
    global.__ios2OnBinLoginReady = function () { if (global.__ios2Manager) global.__ios2Manager.onLoginReady(); };
    global.__ios2OnBinLoginFailed = function (message) { if (global.__ios2Manager) global.__ios2Manager.onLoginFailed(message); };
    global.__ios2MultiLoginReady = function () {
        if (global.__ios2Manager && global.__ios2Manager.accountPresenter) {
            global.__ios2Manager.accountPresenter.onMultiLoginReady();
        }
    };
    global.__ios2MultiLoginFailed = function (message) {
        if (global.__ios2Manager) global.__ios2Manager.onLoginFailed(message);
    };
    global.__ios2WebGameManagerRequested = function () {
        if (!global.__ios2Manager) return;
        global.__ios2Manager.gameStarted = false;
        global.__ios2Manager.showPage(0);
    };
}(window));
