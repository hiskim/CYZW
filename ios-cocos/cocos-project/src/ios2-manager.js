/* Coordinates the persistent ios2 management shell and its page modules. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts || {};
    var common = parts.common;
    if (!common) throw new Error('ios2 manager common module is missing');
    var NAV_HEIGHT = common.NAV_HEIGHT;
    var COLORS = common.COLORS;
    var PENDING_SINGLE_LOGIN_KEY = 'ios2.pendingSingleLogin';

    function displayAccountName(name) {
        return String(name || '').replace(/\.bin$/i, '') || '账号';
    }

    function stopEvent(event) {
        if (event && typeof event.stopPropagation === 'function') event.stopPropagation();
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
                getEnabledScripts: function () {
                    if (self._runtimeBackend() !== 'webkit') return [];
                    return typeof self._enabledScriptRecords === 'function' ? self._enabledScriptRecords([]) : [];
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
            this._dismissGamePopup();
            if (this.gameToolbar) this.gameToolbar.active = false;
            this.page = Math.max(0, Math.min(2, Number(page) || 0));
            if (this.page === 0 && this.accountPresenter) {
                this._setFairyRootActive(true);
                this._setLegacyChromeVisible(false);
                this.accountPresenter.show();
                this._consumePendingSingleLogin();
                return;
            }
            this._setFairyRootActive(false);
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

        _createToolbarButton: function (kind, size, callback) {
            var owner = this;
            var button = new cc.Node();
            button.setAnchorPoint(0.5, 0.5);
            button.setContentSize(size, size);
            var iconSize = size - 6;
            var icon = this._createToolbarIcon(kind, iconSize);
            icon.setPosition(-iconSize / 2, -iconSize / 2);
            button.addChild(icon);
            var restoreScale = function () {
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(button);
                    cc.tween(button).to(0.1, { scale: 1 }, { easing: 'sineOut' }).start();
                } else button.setScale(1);
            };
            button.on(cc.Node.EventType.TOUCH_START, function (event) {
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(button);
                    cc.tween(button).to(0.08, { scale: 0.94 }, { easing: 'sineOut' }).start();
                } else button.setScale(0.94);
                stopEvent(event);
            });
            button.on(cc.Node.EventType.TOUCH_END, function (event) {
                restoreScale();
                if (typeof callback === 'function') {
                    try { callback(); }
                    catch (error) {
                        owner._dismissGamePopup();
                        if (global.console && console.error) console.error('[ios2] game toolbar action failed', error);
                    }
                }
                stopEvent(event);
            });
            button.on(cc.Node.EventType.TOUCH_CANCEL, function (event) {
                restoreScale();
                stopEvent(event);
            });
            return button;
        },

        _createToolbarIcon: function (kind, size) {
            var icon = new cc.Node();
            icon.setAnchorPoint(0, 0);
            icon.setContentSize(size, size);
            var graphics = icon.addComponent(cc.Graphics);
            var blue = cc.color(0, 122, 255, 255);
            var center = size / 2;
            var roundRect = function (x, y, width, height, radius) {
                if (typeof graphics.roundRect === 'function') graphics.roundRect(x, y, width, height, radius);
                else graphics.rect(x, y, width, height);
            };
            graphics.lineWidth = Math.max(2.2, size * 0.08);
            graphics.strokeColor = blue;
            graphics.fillColor = blue;
            if (kind === 'gear') {
                for (var index = 0; index < 8; index++) {
                    var angle = Math.PI * index / 4;
                    graphics.moveTo(center + Math.cos(angle) * size * 0.33, center + Math.sin(angle) * size * 0.33);
                    graphics.lineTo(center + Math.cos(angle) * size * 0.44, center + Math.sin(angle) * size * 0.44);
                }
                graphics.circle(center, center, size * 0.26);
                graphics.circle(center, center, size * 0.10);
                graphics.stroke();
            } else if (kind === 'switch') {
                graphics.circle(center - size * 0.15, center + size * 0.15, size * 0.13);
                graphics.circle(center + size * 0.16, center + size * 0.14, size * 0.13);
                roundRect(size * 0.15, size * 0.18, size * 0.30, size * 0.22, size * 0.11);
                roundRect(size * 0.46, size * 0.18, size * 0.30, size * 0.22, size * 0.11);
                graphics.fill();
            } else if (kind === 'info') {
                graphics.circle(center, center, size * 0.38);
                graphics.stroke();
                graphics.lineWidth = Math.max(2.4, size * 0.09);
                graphics.moveTo(center, center - size * 0.18);
                graphics.lineTo(center, center + size * 0.10);
                graphics.stroke();
                graphics.circle(center, center + size * 0.24, size * 0.045);
                graphics.fill();
            } else {
                graphics.moveTo(size * 0.20, center);
                graphics.lineTo(size * 0.73, center);
                graphics.moveTo(size * 0.56, center + size * 0.18);
                graphics.lineTo(size * 0.74, center);
                graphics.lineTo(size * 0.56, center - size * 0.18);
                graphics.stroke();
            }
            return icon;
        },

        _createGameToolbar: function (size) {
            var toolbarHeight = this._gameToolbarHeight();
            var buttonSize = 40;
            var controlY = 26;
            var toolbar = new cc.Node();
            toolbar.setAnchorPoint(0, 0);
            toolbar.setContentSize(size.width, toolbarHeight);
            toolbar.setPosition(0, size.height - toolbarHeight);
            if (cc.BlockInputEvents) toolbar.addComponent(cc.BlockInputEvents);
            toolbar.addChild(common.rectNode(size.width, toolbarHeight, cc.color(239, 244, 252, 255)), 0);
            toolbar.addChild(common.rectNode(size.width, 1, cc.color(222, 228, 238, 255)), 1);

            var title = common.label('账号', 27, cc.color(24, 28, 35, 255));
            title.setAnchorPoint(0, 0.5);
            title.setContentSize(Math.max(96, size.width - 250), 42);
            if (title.__ios2LabelComponent) {
                title.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
                if (cc.Label.Overflow && cc.Label.Overflow.CLAMP !== undefined) {
                    title.__ios2LabelComponent.overflow = cc.Label.Overflow.CLAMP;
                }
            }
            title.setPosition(22, controlY);
            toolbar.addChild(title, 2);
            toolbar.__ios2Title = title;

            var right = size.width - 18;
            var icons = [
                { key: 'close', action: this._logout.bind(this) },
                { key: 'info', action: this._showGameInfo.bind(this) },
                { key: 'switch', action: this._showGameBinSwitcher.bind(this) },
                { key: 'gear', action: this._showGameGearMenu.bind(this) }
            ];
            for (var index = 0; index < icons.length; index++) {
                var icon = this._createToolbarButton(icons[index].key, buttonSize, icons[index].action);
                icon.__ios2Key = icons[index].key;
                icon.setPosition(right - buttonSize / 2 - index * (buttonSize + 5), controlY);
                toolbar.addChild(icon, 3);
            }
            return toolbar;
        },

        _gameToolbarHeight: function () {
            return Math.max(78, this.safeTopInset + 50);
        },

        _updateGameToolbar: function (accountName) {
            this.currentGameAccountName = accountName || this.currentGameAccountName ||
                (this.accountPresenter && this.accountPresenter.currentAccountName ?
                    this.accountPresenter.currentAccountName() : '');
            if (this.gameToolbar && this.gameToolbar.__ios2Title && this.gameToolbar.__ios2Title.__ios2LabelComponent) {
                this.gameToolbar.__ios2Title.__ios2LabelComponent.string = displayAccountName(this.currentGameAccountName);
            } else if (this.gameToolbar && this.gameToolbar.__ios2Title) {
                this.gameToolbar.__ios2Title.string = displayAccountName(this.currentGameAccountName);
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
            if (!this.storage || this.gameStarted || this._pendingLoginTimer) return;
            var name = '';
            try { name = String(this.storage.getItem(PENDING_SINGLE_LOGIN_KEY) || ''); } catch (ignored) {}
            if (!name) return;
            try { this.storage.removeItem(PENDING_SINGLE_LOGIN_KEY); } catch (ignored2) {}
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
            this.pendingLoginAfterRestart = '';
            this._updateGameToolbar(this.accountPresenter && this.accountPresenter.currentAccountName ?
                this.accountPresenter.currentAccountName() : this.currentGameAccountName);
            if (this.accountPresenter) this.accountPresenter.hide();
            this._setFairyRootActive(false);
            if (this.gameToolbar) this.gameToolbar.active = true;
            if (this.background) this.background.active = false;
            if (this.content) this.content.active = false;
            if (typeof global.__ios2StartGame === 'function') global.__ios2StartGame();
            else if (this.launcher && typeof this.launcher.onLoadFunc === 'function') this.launcher.onLoadFunc();
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
