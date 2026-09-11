/* Coordinates the persistent ios2 management shell and its page modules. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts || {};
    var common = parts.common;
    if (!common) throw new Error('ios2 manager common module is missing');
    var NAV_HEIGHT = common.NAV_HEIGHT;
    var COLORS = common.COLORS;
    var PENDING_SINGLE_LOGIN_KEY = 'ios2.pendingSingleLogin';
    global.__ios2ManagerShellVersion = 's3-hud-v2';

    function displayAccountName(name) {
        return String(name || '').replace(/\.bin$/i, '') || '账号';
    }

    function stopEvent(event) {
        if (event && typeof event.stopPropagation === 'function') event.stopPropagation();
    }

    function isLiveNode(node) {
        if (!node) return false;
        return !cc.isValid || cc.isValid(node);
    }

    var methods = {
        ctor: function (scene, launcher) {
            this.scene = scene;
            this.launcher = launcher;
            this.page = 0;
            this.gameStarted = false;
            this.scriptRunPending = false;
            this.status = '';
            this.currentGameAccountName = '';
            this.pendingLoginAfterRestart = '';
            this.gamePopupLayer = null;
            this.gameStartedAt = Number(global.__ios2GameHudStartedAt || 0);
            this.gameToolbarExpanded = false;
            this.gameToolStates = {};
            this.storage = common.safeStorage();
            this.binFiles = this._loadBins();
            this.binGroups = this._loadBinGroups();
            this._ensureBinGroups();
            this.scripts = [];
            this.safeTopInset = common.safeAreaTop(cc.winSize);
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
                wakePerformance: function (reason) {
                    if (typeof global.__ios2WakeLauncherIdlePerformance === 'function') {
                        global.__ios2WakeLauncherIdlePerformance(reason);
                    }
                },
                getEnabledScripts: function (environment) {
                    if (self._runtimeBackend() !== 'webkit') return [];
                    return typeof self._enabledScriptRecords === 'function' ?
                        self._enabledScriptRecords([], environment || 'single') : [];
                }
            });
        },

        _runtimeBackend: function () {
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { return String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native'); }
                catch (ignored) {}
            }
            return 'native';
        },

        _setFairyRootActive: function (active) {
            if (global.__ios2FairyRoot && global.__ios2FairyRoot.node) {
                global.__ios2FairyRoot.node.active = !!active;
            }
        },

        _setLegacyChromeVisible: function (visible) {
            var items = [this.background, this.content, this.navBackground, this.navShadow,
                this.navSeparator, this.navIndicator, this.navTouchSurface, this.nav];
            for (var index = 0; index < items.length; index++) {
                if (items[index]) items[index].active = visible;
            }
        },

        _buildChrome: function () {
            var size = cc.winSize;
            this.safeTopInset = common.safeAreaTop(size);
            this.navTop = this._navTop(size);
            this.background = common.rectNode(size.width, size.height, COLORS.background);
            this.addChild(this.background, 0);
            this.content = new cc.Node();
            this.addChild(this.content, 1);

            this.gameToolbar = this._createGameToolbar(size);
            this.gameToolbar.active = false;
            this.addChild(this.gameToolbar, 30);

            // The management navigation follows the account home layout and
            // stays below the device's top safe area.
            this.navBackground = common.rectNode(size.width, NAV_HEIGHT, cc.color(255, 255, 255, 255));
            this.navBackground.setPosition(0, this.navTop);
            this.addChild(this.navBackground, 20);
            this.navShadow = common.rectNode(size.width, 5, cc.color(38, 59, 89, 12));
            this.navShadow.setPosition(0, this.navTop - 5);
            this.addChild(this.navShadow, 21);
            this.navSeparator = common.rectNode(size.width, 1, COLORS.border);
            this.navSeparator.setPosition(0, this.navTop - 1);
            this.addChild(this.navSeparator, 22);

            this.nav = new cc.Node();
            this.nav.setPosition(0, 0);
            this.addChild(this.nav, 24);
            var names = ['Bin 文件', 'JS 脚本', '配置'];
            var self = this;
            this.navIndicator = common.surfaceNode(size.width / 3 - 56, 4, COLORS.accent, 2);
            this.navIndicator.setPosition(28, this.navTop);
            this.addChild(this.navIndicator, 25);
            this.navTouchSurface = new cc.Node();
            this.navTouchSurface.setAnchorPoint(0, 0);
            this.navTouchSurface.setContentSize(size.width, NAV_HEIGHT);
            this.navTouchSurface.setPosition(0, this.navTop);
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
                    navItem.setPosition(size.width * (page + 0.5) / 3, self.navTop + NAV_HEIGHT / 2);
                    self.nav.addChild(navItem);
                }(index));
            }
        },

        showPage: function (page) {
            if (Number(page) === 1 && this._runtimeBackend() !== 'webkit') {
                page = 2;
                this.status = 'JS 脚本仅支持 WebKit 模式';
            }
            if (!this.gameStarted && typeof global.__ios2ApplyLauncherIdlePerformance === 'function') {
                global.__ios2ApplyLauncherIdlePerformance('show page');
            }
            this._dismissGamePopup();
            if (this.gameToolbar) this.gameToolbar.active = false;
            this.page = Math.max(0, Math.min(2, Number(page) || 0));
            if (this.page === 0 && this.accountPresenter) {
                this._setFairyRootActive(true);
                this._setLegacyChromeVisible(false);
                this.accountPresenter.show();
                if (this.accountPresenter.isScrollNavigation &&
                    this.accountPresenter.isScrollNavigation() &&
                    typeof global.__ios2KeepLauncherActivePerformance === 'function') {
                    global.__ios2KeepLauncherActivePerformance('account scroll page');
                }
                this._consumePendingSingleLogin();
                return;
            }
            this._setFairyRootActive(false);
            if (typeof this._disposeScriptFairy === 'function') this._disposeScriptFairy();
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
                } else this.navIndicator.setPosition(targetX, this._navTop(cc.winSize));
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
                self.gameStartedAt = 0;
                global.__ios2GameHudActive = false;
                global.__ios2GameHudAccountName = '';
                global.__ios2GameHudStartedAt = 0;
                if (self._hudClock) {
                    clearInterval(self._hudClock);
                    self._hudClock = null;
                }
                if (typeof self._resetScriptRuntime === 'function') self._resetScriptRuntime();
                self._dismissGamePopup();
                if (self.gameToolbar) self.gameToolbar.active = false;
                self.background.active = true;
                self.content.active = true;
                self.status = '已退出当前登录';
                if (!self.pendingLoginAfterRestart) self.showPage(0);
                if (typeof global.__ios2ResetToLauncher === 'function') setTimeout(global.__ios2ResetToLauncher, 0);
                else if (self.pendingLoginAfterRestart) self.showPage(0);
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
            this._setFairyRootActive(false);
            this.background.active = false;
            this.content.active = false;
            this._dismissGamePopup();
            this._updateGameToolbar(this.currentGameAccountName);
            if (this.gameToolbar) this.gameToolbar.active = true;
        },

        // S3 game HUD. It is intentionally a Cocos overlay: the game scene stays
        // untouched underneath, while all launcher controls remain native and isolated.
        _hudPalette: function () {
            return {
                surface: cc.color(13, 15, 23, 232),
                surfaceStrong: cc.color(23, 26, 38, 246),
                border: cc.color(255, 255, 255, 30),
                text: cc.color(255, 255, 255, 255),
                muted: cc.color(196, 200, 211, 255),
                accent: cc.color(41, 150, 255, 255),
                danger: cc.color(255, 94, 94, 255),
                active: cc.color(68, 202, 144, 255)
            };
        },

        _createHudIcon: function (kind, size, color) {
            var icon = new cc.Node();
            icon.setAnchorPoint(0, 0);
            icon.setContentSize(size, size);
            var graphics = icon.addComponent(cc.Graphics);
            var c = size / 2;
            graphics.lineWidth = Math.max(1.8, size * 0.075);
            graphics.strokeColor = color;
            graphics.fillColor = color;
            if (kind === 'exit') {
                graphics.rect(size * 0.19, size * 0.20, size * 0.42, size * 0.60); graphics.stroke();
                graphics.moveTo(size * 0.48, c); graphics.lineTo(size * 0.84, c);
                graphics.moveTo(size * 0.68, c + size * 0.16); graphics.lineTo(size * 0.84, c); graphics.lineTo(size * 0.68, c - size * 0.16); graphics.stroke();
            } else if (kind === 'boost') {
                graphics.moveTo(c + size * 0.08, size * 0.91); graphics.lineTo(size * 0.25, c + size * 0.05);
                graphics.lineTo(c - size * 0.02, c + size * 0.05); graphics.lineTo(c + size * 0.02, size * 0.11);
                graphics.lineTo(size * 0.76, c - size * 0.06); graphics.lineTo(c + size * 0.11, c - size * 0.06); graphics.close(); graphics.fill();
            } else if (kind === 'more') {
                for (var dot = 0; dot < 3; dot++) graphics.circle(size * (0.28 + dot * 0.22), c, size * 0.065); graphics.fill();
            } else if (kind === 'camera') {
                graphics.roundRect(size * 0.15, size * 0.25, size * 0.70, size * 0.51, size * 0.08); graphics.stroke();
                graphics.rect(size * 0.32, size * 0.74, size * 0.22, size * 0.08); graphics.fill(); graphics.circle(c, c, size * 0.15); graphics.stroke();
            } else if (kind === 'record') {
                graphics.roundRect(size * 0.16, size * 0.25, size * 0.54, size * 0.50, size * 0.08); graphics.stroke();
                graphics.moveTo(size * 0.70, size * 0.61); graphics.lineTo(size * 0.86, size * 0.71); graphics.lineTo(size * 0.86, size * 0.29); graphics.lineTo(size * 0.70, size * 0.39); graphics.close(); graphics.stroke();
            } else if (kind === 'sound') {
                graphics.moveTo(size * 0.17, c - size * 0.11); graphics.lineTo(size * 0.37, c - size * 0.11); graphics.lineTo(size * 0.58, c - size * 0.30); graphics.lineTo(size * 0.58, c + size * 0.30); graphics.lineTo(size * 0.37, c + size * 0.11); graphics.lineTo(size * 0.17, c + size * 0.11); graphics.close(); graphics.stroke();
                graphics.arc(size * 0.56, c, size * 0.21, -0.72, 0.72, false); graphics.stroke();
            } else if (kind === 'keyboard') {
                graphics.roundRect(size * 0.13, size * 0.25, size * 0.74, size * 0.50, size * 0.08); graphics.stroke();
                for (var row = 0; row < 2; row++) for (var column = 0; column < 4; column++) {
                    graphics.rect(size * (0.23 + column * 0.14), size * (0.40 + row * 0.14), size * 0.07, size * 0.06);
                } graphics.fill();
            } else if (kind === 'fullscreen') {
                var inset = size * 0.20, edge = size * 0.20;
                graphics.moveTo(inset, size - inset - edge); graphics.lineTo(inset, size - inset); graphics.lineTo(inset + edge, size - inset);
                graphics.moveTo(size - inset - edge, size - inset); graphics.lineTo(size - inset, size - inset); graphics.lineTo(size - inset, size - inset - edge);
                graphics.moveTo(inset, inset + edge); graphics.lineTo(inset, inset); graphics.lineTo(inset + edge, inset);
                graphics.moveTo(size - inset - edge, inset); graphics.lineTo(size - inset, inset); graphics.lineTo(size - inset, inset + edge); graphics.stroke();
            } else {
                for (var square = 0; square < 4; square++) graphics.rect(size * (0.20 + (square % 2) * 0.34), size * (0.20 + Math.floor(square / 2) * 0.34), size * 0.22, size * 0.22); graphics.fill();
            }
            return icon;
        },

        _createHudButton: function (kind, callback, options) {
            var palette = this._hudPalette();
            options = options || {};
            var hitSize = options.hitSize || 48;
            var visualSize = options.visualSize || 44;
            var button = new cc.Node();
            button.setAnchorPoint(0.5, 0.5);
            button.setContentSize(hitSize, hitSize);
            var background = common.surfaceNode(visualSize, visualSize,
                options.active ? palette.accent : (options.fill || palette.surface), visualSize / 2,
                options.active ? null : palette.border);
            background.setPosition(-visualSize / 2, -visualSize / 2);
            button.addChild(background);
            var icon = this._createHudIcon(kind, visualSize * 0.48, options.iconColor || palette.text);
            icon.setPosition(-visualSize * 0.24, -visualSize * 0.24);
            button.addChild(icon, 2);
            button.on(cc.Node.EventType.TOUCH_START, function (event) { button.setScale(0.94); stopEvent(event); });
            button.on(cc.Node.EventType.TOUCH_CANCEL, function (event) { button.setScale(1); stopEvent(event); });
            button.on(cc.Node.EventType.TOUCH_END, function (event) { button.setScale(1); if (callback) callback(); stopEvent(event); });
            button.__ios2HudBackground = background;
            return button;
        },

        _createHudTextButton: function (text, callback, fill, color) {
            var palette = this._hudPalette();
            var button = new cc.Node();
            button.setAnchorPoint(0.5, 0.5);
            button.setContentSize(68, 44);
            var surface = common.surfaceNode(68, 32, fill || palette.danger, 16);
            surface.setPosition(-34, -16);
            button.addChild(surface);
            var label = common.label(text, 14, color || palette.text);
            label.setPosition(0, 0); button.addChild(label);
            button.on(cc.Node.EventType.TOUCH_END, function (event) { if (callback) callback(); stopEvent(event); });
            return button;
        },

        _createGameToolbar: function (size) {
            var palette = this._hudPalette();
            var toolbar = new cc.Node();
            toolbar.setAnchorPoint(0, 0);
            toolbar.setContentSize(size.width, size.height);
            toolbar.setPosition(0, 0);
            var top = Math.max(12, size.height - this.safeTopInset - 60);
            var pillWidth = Math.min(size.width - 32, 350);
            var identity = common.surfaceNode(pillWidth, 52, palette.surfaceStrong, 26, palette.border);
            identity.setPosition(16, top); toolbar.addChild(identity, 1);
            var avatar = common.surfaceNode(32, 32, palette.accent, 10);
            avatar.setPosition(26, top + 10); toolbar.addChild(avatar, 2);
            var title = common.label('账号', 15, palette.text);
            title.setAnchorPoint(0, 0.5); title.setContentSize(pillWidth - 194, 20);
            title.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            title.setPosition(68, top + 33); toolbar.addChild(title, 2); toolbar.__ios2Title = title;
            var subtitle = common.label('游戏运行中', 11, palette.muted);
            subtitle.setAnchorPoint(0, 0.5); subtitle.setContentSize(pillWidth - 194, 16);
            subtitle.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            subtitle.setPosition(68, top + 17); toolbar.addChild(subtitle, 2); toolbar.__ios2Subtitle = subtitle;
            var self = this;
            var exit = this._createHudTextButton('退出', function () { self._showGameExitConfirmation(); });
            exit.setPosition(16 + pillWidth - 105, top + 26); toolbar.addChild(exit, 3);
            var boost = this._createHudButton('boost', function () { self._toggleGameTool('boost', '性能加速'); }, { hitSize: 44, visualSize: 34 });
            boost.setPosition(16 + pillWidth - 61, top + 26); toolbar.addChild(boost, 3); toolbar.__ios2Boost = boost;
            var more = this._createHudButton('more', function () { self._toggleHudLabels(); }, { hitSize: 44, visualSize: 34 });
            more.setPosition(16 + pillWidth - 25, top + 26); toolbar.addChild(more, 3);
            this._addHudSideTools(toolbar, size);
            this._addHudRuntimeBar(toolbar, size);
            return toolbar;
        },

        _addHudSideTools: function (toolbar, size) {
            var self = this;
            var palette = this._hudPalette();
            var tools = [
                { key: 'camera', text: '截图', action: function () { self._toggleGameTool('camera', '截图'); } },
                { key: 'record', text: '录屏', action: function () { self._toggleGameTool('record', '录屏'); } },
                { key: 'sound', text: '音量', action: function () { self._toggleGameTool('sound', '音量'); } },
                { key: 'keyboard', text: '键位', action: function () { self._toggleGameTool('keyboard', '键位'); } },
                { key: 'fullscreen', text: '全屏', action: function () { self._toggleGameTool('fullscreen', '全屏'); } }
            ];
            var right = size.width - 38;
            var startY = Math.max(158, size.height * 0.54);
            toolbar.__ios2SideToolLabels = [];
            toolbar.__ios2SideTools = {};
            for (var index = 0; index < tools.length; index++) {
                (function (tool, toolIndex) {
                    var y = startY - toolIndex * 58;
                    var label = common.surfaceNode(60, 30, palette.surfaceStrong, 15, palette.border);
                    label.setPosition(right - 86, y - 15); label.active = false;
                    var labelText = common.label(tool.text, 12, palette.text); labelText.setPosition(30, 15); label.addChild(labelText);
                    toolbar.addChild(label, 2); toolbar.__ios2SideToolLabels.push(label);
                    var control = self._createHudButton(tool.key, tool.action, { hitSize: 52, visualSize: 44 });
                    control.setPosition(right, y); toolbar.addChild(control, 3); toolbar.__ios2SideTools[tool.key] = control;
                }(tools[index], index));
            }
        },

        _addHudRuntimeBar: function (toolbar, size) {
            var palette = this._hudPalette();
            var width = 184, height = 34;
            var bar = common.surfaceNode(width, height, palette.surfaceStrong, 17, palette.border);
            bar.setPosition((size.width - width) / 2, 24); toolbar.addChild(bar, 2);
            var metrics = common.label('00:00:00  ·  28 ms  ·  60 FPS', 11, palette.muted);
            metrics.setPosition(width / 2, height / 2); bar.addChild(metrics); toolbar.__ios2Metrics = metrics;
            var self = this;
            var fab = this._createHudButton('tools', function () { self._showGameToolsPanel(); }, { hitSize: 58, visualSize: 48, fill: palette.accent });
            fab.setPosition(size.width - 46, 46); toolbar.addChild(fab, 4);
        },

        _gameToolbarHeight: function () { return this.safeTopInset + 60; },

        _updateGameToolbar: function (accountName) {
            this.currentGameAccountName = accountName || this.currentGameAccountName ||
                (this.accountPresenter && this.accountPresenter.currentAccountName ? this.accountPresenter.currentAccountName() : '');
            if (!this.gameStartedAt) this.gameStartedAt = Date.now();
            global.__ios2GameHudAccountName = this.currentGameAccountName;
            global.__ios2GameHudStartedAt = this.gameStartedAt;
            if (this.gameToolbar && this.gameToolbar.__ios2Title) {
                this.gameToolbar.__ios2Title.__ios2LabelComponent.string = displayAccountName(this.currentGameAccountName);
                this.gameToolbar.__ios2Subtitle.__ios2LabelComponent.string = '单开模式 · 已登录';
            }
            this._updateHudMetrics();
            if (!this._hudClock) {
                var self = this;
                this._hudClock = setInterval(function () { self._updateHudMetrics(); }, 1000);
            }
        },

        _updateHudMetrics: function () {
            if (!this.gameToolbar || !this.gameToolbar.__ios2Metrics || !this.gameStartedAt) return;
            var seconds = Math.max(0, Math.floor((Date.now() - this.gameStartedAt) / 1000));
            var h = String(Math.floor(seconds / 3600)); if (h.length < 2) h = '0' + h;
            var m = String(Math.floor(seconds / 60) % 60); if (m.length < 2) m = '0' + m;
            var s = String(seconds % 60); if (s.length < 2) s = '0' + s;
            this.gameToolbar.__ios2Metrics.__ios2LabelComponent.string = h + ':' + m + ':' + s + '  ·  28 ms  ·  60 FPS';
        },

        _toggleHudLabels: function () {
            this.gameToolbarExpanded = !this.gameToolbarExpanded;
            var labels = this.gameToolbar && this.gameToolbar.__ios2SideToolLabels || [];
            for (var index = 0; index < labels.length; index++) labels[index].active = this.gameToolbarExpanded;
        },

        _toggleGameTool: function (key, title) {
            this.gameToolStates[key] = !this.gameToolStates[key];
            var control = this.gameToolbar && this.gameToolbar.__ios2SideTools && this.gameToolbar.__ios2SideTools[key];
            if (key === 'boost') control = this.gameToolbar && this.gameToolbar.__ios2Boost;
            if (control && control.__ios2HudBackground) {
                control.__ios2HudBackground.setColor(this.gameToolStates[key] ? this._hudPalette().accent : this._hudPalette().surface);
            }
            this._showHudToast(title + (this.gameToolStates[key] ? '已开启' : '已关闭'));
        },

        _showHudToast: function (message) {
            if (!this.gameToolbar) return;
            if (this.hudToast) this.hudToast.removeFromParent(true);
            var palette = this._hudPalette();
            var toast = common.surfaceNode(152, 36, palette.surfaceStrong, 18, palette.border);
            toast.setPosition((cc.winSize.width - 152) / 2, 72);
            var text = common.label(message, 12, palette.text);
            text.setPosition(76, 18); toast.addChild(text);
            this.gameToolbar.addChild(toast, 9);
            this.hudToast = toast;
            var self = this;
            setTimeout(function () {
                if (self.hudToast === toast) {
                    toast.removeFromParent(true);
                    self.hudToast = null;
                }
            }, 1500);
        },

        _showGameExitConfirmation: function () {
            var palette = this._hudPalette();
            var size = cc.winSize;
            var layer = this._popupLayer();
            var width = Math.min(size.width - 40, 330), height = 188;
            var panel = common.surfaceNode(width, height, palette.surfaceStrong, 18, palette.border);
            panel.setPosition((size.width - width) / 2, (size.height - height) / 2);
            this._protectGamePopupPanel(panel); layer.addChild(panel, 1);
            var title = common.label('退出当前游戏？', 18, palette.text);
            title.setPosition(width / 2, height - 42); panel.addChild(title);
            var detail = common.label('退出后将返回账号库。', 13, palette.muted);
            detail.setPosition(width / 2, height - 72); panel.addChild(detail);
            var self = this;
            var cancel = this._createHudTextButton('取消', function () { self._dismissGamePopup(); }, palette.surface, palette.text);
            cancel.setPosition(width / 2 - 46, 38); panel.addChild(cancel);
            var confirm = this._createHudTextButton('退出', function () { self._dismissGamePopup(); self._logout(); }, palette.danger, palette.text);
            confirm.setPosition(width / 2 + 46, 38); panel.addChild(confirm);
        },

        _showGameToolsPanel: function () {
            var palette = this._hudPalette();
            var size = cc.winSize;
            var layer = this._popupLayer();
            var width = Math.min(size.width - 32, 352), height = 258;
            var panel = common.surfaceNode(width, height, palette.surfaceStrong, 20, palette.border);
            panel.setPosition((size.width - width) / 2, Math.max(18, size.height * 0.17));
            this._protectGamePopupPanel(panel); layer.addChild(panel, 1);
            var title = common.label('工具面板', 17, palette.text);
            title.setAnchorPoint(0, 0.5); title.setPosition(18, height - 26); panel.addChild(title);
            var close = this._createHudButton('more', this._dismissGamePopup.bind(this), { hitSize: 40, visualSize: 28 });
            close.setPosition(width - 28, height - 26); panel.addChild(close);
            var self = this;
            var tools = [
                { key: 'camera', text: '截图', action: function () { self._toggleGameTool('camera', '截图'); } },
                { key: 'record', text: '录屏', action: function () { self._toggleGameTool('record', '录屏'); } },
                { key: 'sound', text: '音量', action: function () { self._toggleGameTool('sound', '音量'); } },
                { key: 'keyboard', text: '键位', action: function () { self._toggleGameTool('keyboard', '键位'); } },
                { key: 'boost', text: '性能', action: function () { self._toggleGameTool('boost', '性能加速'); } },
                { key: 'fullscreen', text: '全屏', action: function () { self._toggleGameTool('fullscreen', '全屏'); } },
                { key: 'tools', text: '账号', action: function () { self._dismissGamePopup(); self._showGameBinSwitcher(); } },
                { key: 'more', text: '设置', action: function () { self._dismissGamePopup(); self._showGameGearMenu(); } }
            ];
            var columns = 4, cellWidth = (width - 24) / columns, cellHeight = 88;
            for (var index = 0; index < tools.length; index++) {
                (function (tool, toolIndex) {
                    var column = toolIndex % columns, row = Math.floor(toolIndex / columns);
                    var cell = new cc.Node(); cell.setAnchorPoint(0.5, 0.5); cell.setContentSize(cellWidth, cellHeight);
                    cell.setPosition(12 + cellWidth * (column + 0.5), height - 72 - cellHeight * (row + 0.5));
                    var tile = common.surfaceNode(cellWidth - 8, cellHeight - 8, palette.surface, 12, palette.border);
                    tile.setPosition(-(cellWidth - 8) / 2, -(cellHeight - 8) / 2); cell.addChild(tile);
                    var glyph = self._createHudIcon(tool.key, 22, palette.text); glyph.setPosition(-11, 7); cell.addChild(glyph);
                    var caption = common.label(tool.text, 11, palette.muted); caption.setPosition(0, -23); cell.addChild(caption);
                    cell.on(cc.Node.EventType.TOUCH_END, function (event) { tool.action(); stopEvent(event); });
                    panel.addChild(cell);
                }(tools[index], index));
            }
        },

        _dismissGamePopup: function () {
            if (this.gamePopupLayer) {
                this.gamePopupLayer.removeFromParent(true);
                this.gamePopupLayer = null;
            }
        },

        _popupLayer: function () {
            this._dismissGamePopup();
            var size = cc.winSize;
            var layer = new cc.Node();
            layer.setAnchorPoint(0, 0);
            layer.setContentSize(size.width, size.height);
            layer.setPosition(0, 0);
            layer.on(cc.Node.EventType.TOUCH_END, function (event) {
                this._dismissGamePopup();
                stopEvent(event);
            }, this);
            var shade = common.rectNode(size.width, size.height, cc.color(0, 0, 0, 70));
            shade.on(cc.Node.EventType.TOUCH_END, function (event) {
                this._dismissGamePopup();
                stopEvent(event);
            }, this);
            layer.addChild(shade, 0);
            this.gamePopupLayer = layer;
            this.addChild(layer, 31);
            return layer;
        },

        _protectGamePopupPanel: function (panel) {
            var stop = function (event) { stopEvent(event); };
            panel.on(cc.Node.EventType.TOUCH_START, stop);
            panel.on(cc.Node.EventType.TOUCH_MOVE, stop);
            panel.on(cc.Node.EventType.TOUCH_END, stop);
            panel.on(cc.Node.EventType.TOUCH_CANCEL, stop);
        },

        _menuRow: function (labelText, width, height, callback) {
            var row = new cc.Node();
            row.setAnchorPoint(0, 0);
            row.setContentSize(width, height);
            var label = common.label(labelText, 21, COLORS.text);
            label.setAnchorPoint(0, 0.5);
            label.setContentSize(width - 28, height);
            if (label.__ios2LabelComponent) label.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            label.setPosition(16, height / 2);
            row.addChild(label);
            row.on(cc.Node.EventType.TOUCH_END, function (event) {
                this._dismissGamePopup();
                if (typeof callback === 'function') callback();
                stopEvent(event);
            }, this);
            return row;
        },

        _showGameGearMenu: function () {
            var size = cc.winSize;
            var layer = this._popupLayer();
            var width = 176;
            var rowHeight = 54;
            var height = rowHeight * 2;
            var panel = common.surfaceNode(width, height, cc.color(255, 255, 255, 255), 14, COLORS.border);
            panel.setPosition(size.width - width - 16, size.height - this._gameToolbarHeight() - height - 8);
            this._protectGamePopupPanel(panel);
            layer.addChild(panel, 1);
            var self = this;
            var relogin = this._menuRow('重新登录', width, rowHeight, function () {
                self._requestGameAccountLogin(self.currentGameAccountName);
            });
            relogin.setPosition(0, rowHeight);
            panel.addChild(relogin);
            var separator = common.rectNode(width, 1, cc.color(229, 232, 238, 255));
            separator.setPosition(0, rowHeight);
            panel.addChild(separator);
            var close = this._menuRow('关闭', width, rowHeight, function () { self._logout(); });
            close.setPosition(0, 0);
            panel.addChild(close);
        },

        _showGameInfo: function () {
            var size = cc.winSize;
            var layer = this._popupLayer();
            var width = Math.min(size.width - 48, 320);
            var height = 74;
            var panel = common.surfaceNode(width, height, cc.color(255, 255, 255, 255), 14, COLORS.border);
            panel.setPosition((size.width - width) / 2, size.height - this._gameToolbarHeight() - height - 12);
            this._protectGamePopupPanel(panel);
            layer.addChild(panel, 1);
            var label = common.label('当前账号：' + displayAccountName(this.currentGameAccountName), 19, COLORS.text);
            label.setAnchorPoint(0, 0.5);
            label.setContentSize(width - 32, height);
            if (label.__ios2LabelComponent) label.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            label.setPosition(16, height / 2);
            panel.addChild(label);
        },

        _gameAccountRecords: function () {
            var source = this.accountRepository ? this.accountRepository.cached() : (this.binFiles || []);
            var records = [];
            for (var index = 0; index < source.length; index++) {
                var record = source[index];
                if (!record || !record.name || record.last || record.name === 'last.bin') continue;
                records.push(record);
            }
            records.sort(function (left, right) {
                var leftTime = Number(left.modified) || 0;
                var rightTime = Number(right.modified) || 0;
                if (leftTime !== rightTime) return rightTime - leftTime;
                return String(left.name || '').localeCompare(String(right.name || ''));
            });
            return records;
        },

        _showGameBinSwitcher: function () {
            var size = cc.winSize;
            var records = this._gameAccountRecords();
            var currentName = this.currentGameAccountName;
            var filtered = [];
            for (var index = 0; index < records.length; index++) {
                if (records[index].name !== currentName) filtered.push(records[index]);
            }
            if (filtered.length) records = filtered;
            var layer = this._popupLayer();
            var width = Math.min(size.width - 48, 430);
            var rowHeight = 58;
            var headerHeight = 54;
            var maxPanelHeight = Math.max(190, size.height - this._gameToolbarHeight() - 48);
            var contentHeight = records.length ? records.length * rowHeight : rowHeight;
            var listHeight = Math.min(contentHeight, maxPanelHeight - headerHeight);
            var panelHeight = headerHeight + listHeight;
            var panel = common.surfaceNode(width, panelHeight, cc.color(255, 255, 255, 255), 18, COLORS.border);
            panel.setPosition((size.width - width) / 2,
                Math.max(16, size.height - this._gameToolbarHeight() - panelHeight - 10));
            this._protectGamePopupPanel(panel);
            layer.addChild(panel, 1);

            var title = common.label('切换 bin', 22, COLORS.text);
            title.setAnchorPoint(0, 0.5);
            title.setContentSize(width - 112, headerHeight);
            if (title.__ios2LabelComponent) title.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            title.setPosition(16, panelHeight - headerHeight / 2);
            panel.addChild(title);
            var cancel = common.label('取消', 19, cc.color(0, 122, 255, 255));
            cancel.setAnchorPoint(0.5, 0.5);
            cancel.setContentSize(78, headerHeight);
            cancel.setPosition(width - 45, panelHeight - headerHeight / 2);
            cancel.on(cc.Node.EventType.TOUCH_END, function (event) {
                this._dismissGamePopup();
                stopEvent(event);
            }, this);
            panel.addChild(cancel, 2);
            var headerSeparator = common.rectNode(width, 1, cc.color(229, 232, 238, 255));
            headerSeparator.setPosition(0, panelHeight - headerHeight);
            panel.addChild(headerSeparator);

            var view = new cc.Node();
            view.setAnchorPoint(0, 0);
            view.setContentSize(width, listHeight);
            view.setPosition(0, 0);
            if (cc.Mask) view.addComponent(cc.Mask);
            panel.addChild(view);

            var content = new cc.Node();
            content.setAnchorPoint(0, 0);
            content.setContentSize(width, Math.max(listHeight, contentHeight));
            content.setPosition(0, Math.min(0, listHeight - contentHeight));
            view.addChild(content);
            if (cc.ScrollView) {
                var scroll = view.addComponent(cc.ScrollView);
                scroll.horizontal = false;
                scroll.vertical = true;
                scroll.inertia = true;
                scroll.brake = 0.78;
                scroll.content = content;
                if (typeof scroll.scrollToTop === 'function') scroll.scrollToTop(0);
            }

            if (!records.length) {
                var empty = common.label('没有其他 bin 文件', 20, COLORS.muted);
                empty.setPosition(width / 2, Math.max(rowHeight / 2, listHeight - rowHeight / 2));
                content.addChild(empty);
                return;
            }

            var self = this;
            for (var rowIndex = 0; rowIndex < records.length; rowIndex++) {
                (function (record, y) {
                    var row = new cc.Node();
                    var touchState = { startX: 0, startY: 0, dragging: false };
                    row.setAnchorPoint(0, 0);
                    row.setContentSize(width, rowHeight);
                    row.setPosition(0, y);
                    var label = common.label(displayAccountName(record.name), 21, COLORS.text);
                    label.setAnchorPoint(0, 0.5);
                    label.setContentSize(width - 36, rowHeight);
                    if (label.__ios2LabelComponent) {
                        label.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
                        if (cc.Label.Overflow && cc.Label.Overflow.CLAMP !== undefined) {
                            label.__ios2LabelComponent.overflow = cc.Label.Overflow.CLAMP;
                        }
                    }
                    label.setPosition(18, rowHeight / 2);
                    row.addChild(label);
                    var rowSeparator = common.rectNode(width - 18, 1, cc.color(234, 236, 240, 255));
                    rowSeparator.setPosition(18, 0);
                    row.addChild(rowSeparator);
                    row.on(cc.Node.EventType.TOUCH_START, function (event) {
                        var location = event && typeof event.getLocation === 'function' ? event.getLocation() : null;
                        touchState.startX = location ? location.x : 0;
                        touchState.startY = location ? location.y : 0;
                        touchState.dragging = false;
                    });
                    row.on(cc.Node.EventType.TOUCH_MOVE, function (event) {
                        var location = event && typeof event.getLocation === 'function' ? event.getLocation() : null;
                        if (!location) return;
                        if (Math.abs(location.y - touchState.startY) > 12 || Math.abs(location.x - touchState.startX) > 12) {
                            touchState.dragging = true;
                        }
                    });
                    row.on(cc.Node.EventType.TOUCH_END, function (event) {
                        if (touchState.dragging) {
                            stopEvent(event);
                            return;
                        }
                        self._dismissGamePopup();
                        self._requestGameAccountLogin(record.name);
                        stopEvent(event);
                    });
                    content.addChild(row);
                }(records[rowIndex], contentHeight - (rowIndex + 1) * rowHeight));
            }
        },

        _requestGameAccountLogin: function (name) {
            name = String(name || '');
            if (!name) return;
            this.pendingLoginAfterRestart = name;
            try { if (this.storage) this.storage.setItem(PENDING_SINGLE_LOGIN_KEY, name); } catch (ignored) {}
            this._logout();
        },

        _consumePendingSingleLogin: function () {
            if (this.gameStarted || this._pendingLoginTimer) return;
            var name = String(global.__ios2NativeLaunchBin || '');
            if (name) {
                global.__ios2NativeLaunchBin = '';
            } else {
                if (!this.storage) return;
                try { name = String(this.storage.getItem(PENDING_SINGLE_LOGIN_KEY) || ''); } catch (ignored) {}
            }
            if (!name) return;
            try { if (this.storage) this.storage.removeItem(PENDING_SINGLE_LOGIN_KEY); } catch (ignored2) {}
            this.pendingLoginAfterRestart = '';
            var self = this;
            this._pendingLoginTimer = setTimeout(function () {
                self._pendingLoginTimer = null;
                if (!self.accountPresenter) return;
                self.currentGameAccountName = name;
                self.accountPresenter.login(name);
            }, 160);
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
            global.__ios2GameHudActive = true;
            if (typeof global.__ios2RestorePerformancePreferences === 'function') {
                global.__ios2RestorePerformancePreferences('login ready');
            }
            this.pendingLoginAfterRestart = '';
            this._updateGameToolbar(this.accountPresenter && this.accountPresenter.currentAccountName ?
                this.accountPresenter.currentAccountName() : this.currentGameAccountName);
            if (this.accountPresenter) this.accountPresenter.hide();
            this._setFairyRootActive(false);
            if (this.gameToolbar) this.gameToolbar.active = true;
            if (this.background) this.background.active = false;
            if (this.content) this.content.active = false;
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'legacyCocosGameReady'); }
                catch (error) { console.error('[ios2] unable to notify SwiftUI game handoff', error); }
            }
            if (typeof global.__ios2StartGame === 'function') global.__ios2StartGame();
            else if (this.launcher && typeof this.launcher.onLoadFunc === 'function') this.launcher.onLoadFunc();
        },

        onLoginFailed: function (message) {
            if (this.accountPresenter) this.accountPresenter.onLoginFailed(message);
            this._setStatus('登录失败：' + String(message || '未知错误'), COLORS.warning);
        },

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
        if (global.__ios2Manager && !isLiveNode(global.__ios2Manager)) {
            if (global.__ios2Manager._hudClock) clearInterval(global.__ios2Manager._hudClock);
            global.__ios2Manager = null;
            if (global.__ios2FairyRoot && !isLiveNode(global.__ios2FairyRoot.node)) {
                global.__ios2FairyRoot = null;
            }
        }
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

    // The original launcher may call cc.game.restart() after authentication.
    // That removes all persistent nodes, including the management shell. Keep
    // the HUD state outside of the scene and restore it after every new scene.
    global.__ios2RestoreGameHud = function (scene) {
        if (!global.__ios2GameHudActive || !scene) return;
        global.__ios2ManagerMount(scene, null);
        var manager = global.__ios2Manager;
        if (!manager) return;
        manager.gameStarted = true;
        manager.currentGameAccountName = String(global.__ios2GameHudAccountName || manager.currentGameAccountName || '');
        manager.gameStartedAt = Number(global.__ios2GameHudStartedAt || manager.gameStartedAt || Date.now());
        manager._resumeGame();
    };

    global.__ios2InstallGameHudSceneHook = function () {
        var director = cc.director;
        if (!director || !cc.Director || !cc.Director.EVENT_AFTER_SCENE_LAUNCH || director.__ios2GameHudSceneHookInstalled) return;
        director.__ios2GameHudSceneHookInstalled = true;
        director.on(cc.Director.EVENT_AFTER_SCENE_LAUNCH, function (scene) {
            if (!global.__ios2GameHudActive) return;
            setTimeout(function () { global.__ios2RestoreGameHud(scene); }, 0);
        });
    };
    global.__ios2InstallGameHudSceneHook();
    global.__ios2ManagerSetLauncher = function (launcher) {
        if (global.__ios2Manager) global.__ios2Manager.launcher = launcher;
    };
    function wakeLauncherIdle(reason) {
        if (typeof global.__ios2WakeLauncherIdlePerformance === 'function') {
            global.__ios2WakeLauncherIdlePerformance(reason);
        }
    }
    global.__ios2OnBinFiles = function (json) {
        wakeLauncherIdle('bin files');
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) {
            manager.accountPresenter.onAccounts(json);
            manager.binFiles = manager.accountRepository.cached();
        } else manager.onBinFiles(json);
    };
    global.__ios2BinFilesReady = global.__ios2OnBinFiles;
    global.__ios2OnBinImported = function (name) {
        wakeLauncherIdle('bin imported');
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onImported(name);
        else manager.onBinImported(name);
    };
    global.__ios2BinImported = global.__ios2OnBinImported;
    global.__ios2OnBinDeleted = function (name) {
        wakeLauncherIdle('bin deleted');
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onDeleted(name);
        else manager.onBinDeleted(name);
    };
    global.__ios2BinDeleted = global.__ios2OnBinDeleted;
    global.__ios2OnBinDeleteFailed = function (message) {
        wakeLauncherIdle('bin delete failed');
        var manager = global.__ios2Manager;
        if (!manager) return;
        if (manager.accountPresenter) manager.accountPresenter.onDeleteFailed(message);
        else manager.onBinDeleteFailed(message);
    };
    global.__ios2BinDeleteFailed = global.__ios2OnBinDeleteFailed;
    global.__ios2OnScriptFiles = function (json) { wakeLauncherIdle('script files'); if (global.__ios2Manager) global.__ios2Manager.onScriptFiles(json); };
    global.__ios2ScriptFilesReady = global.__ios2OnScriptFiles;
    global.__ios2OnScriptImported = function (name) { wakeLauncherIdle('script imported'); if (global.__ios2Manager) global.__ios2Manager.onScriptImported(name); };
    global.__ios2ScriptImported = global.__ios2OnScriptImported;
    global.__ios2OnScriptDeleted = function (name) { wakeLauncherIdle('script deleted'); if (global.__ios2Manager) global.__ios2Manager.onScriptDeleted(name); };
    global.__ios2ScriptDeleted = global.__ios2OnScriptDeleted;
    global.__ios2OnScriptDeleteFailed = function (message) { wakeLauncherIdle('script delete failed'); if (global.__ios2Manager) global.__ios2Manager.onScriptDeleteFailed(message); };
    global.__ios2ScriptDeleteFailed = global.__ios2OnScriptDeleteFailed;
    global.__ios2OnScriptImportFailed = function (message) { wakeLauncherIdle('script import failed'); if (global.__ios2Manager) global.__ios2Manager.onScriptImportFailed(message); };
    global.__ios2ScriptImportFailed = global.__ios2OnScriptImportFailed;
    global.__ios2OnSettingsImported = function (name) { wakeLauncherIdle('settings imported'); if (global.__ios2Manager) global.__ios2Manager.onSettingsImported(name); };
    global.__ios2SettingsImported = global.__ios2OnSettingsImported;
    global.__ios2OnSettingsImportFailed = function (message) { wakeLauncherIdle('settings import failed'); if (global.__ios2Manager) global.__ios2Manager.onSettingsImportFailed(message); };
    global.__ios2SettingsImportFailed = global.__ios2OnSettingsImportFailed;
    global.__ios2OnSettingsDeleted = function (name) { wakeLauncherIdle('settings deleted'); if (global.__ios2Manager) global.__ios2Manager.onSettingsDeleted(name); };
    global.__ios2SettingsDeleted = global.__ios2OnSettingsDeleted;
    global.__ios2OnSettingsDeleteFailed = function (message) { wakeLauncherIdle('settings delete failed'); if (global.__ios2Manager) global.__ios2Manager.onSettingsDeleteFailed(message); };
    global.__ios2SettingsDeleteFailed = global.__ios2OnSettingsDeleteFailed;
    global.__ios2OnBinLoginReady = function () { wakeLauncherIdle('login ready'); if (global.__ios2Manager) global.__ios2Manager.onLoginReady(); };
    global.__ios2OnBinLoginFailed = function (message) { wakeLauncherIdle('login failed'); if (global.__ios2Manager) global.__ios2Manager.onLoginFailed(message); };
    global.__ios2MultiLoginReady = function () {
        global._hortor_launcher_started = true;
        if (typeof global.__ios2RestorePerformancePreferences === 'function') {
            global.__ios2RestorePerformancePreferences('webkit game ready');
        }
        if (global.__ios2Manager) {
            global.__ios2Manager.gameStarted = true;
            if (global.__ios2Manager.accountPresenter) {
                global.__ios2Manager.accountPresenter.onMultiLoginReady();
            }
        }
    };
    global.__ios2MultiLoginFailed = function (message) {
        wakeLauncherIdle('multi login failed');
        if (global.__ios2Manager) global.__ios2Manager.onLoginFailed(message);
    };
    global.__ios2WebGameManagerRequested = function () {
        if (!global.__ios2Manager) return;
        global._hortor_launcher_started = false;
        global.__ios2Manager.gameStarted = false;
        global.__ios2Manager.showPage(0);
    };
}(window));
