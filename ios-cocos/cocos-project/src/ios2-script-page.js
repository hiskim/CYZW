/* JavaScript file management page. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;
    var GLOBAL_SCRIPTS_KEY = 'ios2.scripts.globalEnabled';

    function fairyText(value, size, color, width, height, align) {
        var item = new fgui.GTextField();
        item.autoSize = fgui.AutoSizeType.None;
        item.setSize(width, height);
        item.font = 'PingFang SC';
        item.fontSize = size;
        item.color = color;
        item.align = align === undefined ? fgui.AlignType.Left : align;
        item.verticalAlign = fgui.VertAlignType.Middle;
        item.singleLine = true;
        item.text = String(value || '');
        return item;
    }

    function fairyGraph(width, height, fill, radius, border) {
        var item = new fgui.GGraph();
        item.setSize(width, height);
        item.drawRect(border ? 1 : 0, border || cc.Color.TRANSPARENT, fill, radius ? [radius] : null);
        return item;
    }

    function fairyButton(caption, width, height, fill, color, callback) {
        var item = new fgui.GComponent();
        item.setSize(width, height);
        item.opaque = true;
        item.addChild(fairyGraph(width, height, fill, 10));
        item.addChild(fairyText(caption, 17, color, width, height, fgui.AlignType.Center));
        item.onClick(function (event) {
            if (event && event.stopPropagation) event.stopPropagation();
            if (item.enabled !== false && typeof callback === 'function') callback();
        });
        // Script page is hosted in the legacy Cocos content node. Bridge the
        // touch event there as well as FairyGUI's event so it remains
        // interactive outside GRoot's input processor.
        item.node.on(cc.Node.EventType.TOUCH_END, function (event) {
            if (event && event.stopPropagation) event.stopPropagation();
            if (item.enabled !== false && typeof callback === 'function') callback();
        });
        return item;
    }

    function fairySwitch(enabled, callback) {
        var width = 54, height = 32;
        var item = new fgui.GComponent();
        item.setSize(width, height);
        item.opaque = true;
        item.addChild(fairyGraph(width, height,
            enabled ? cc.color(16, 185, 129, 255) : cc.color(210, 216, 224, 255), height / 2));
        var thumb = fairyGraph(26, 26, cc.Color.WHITE, 13, cc.color(196, 203, 212, 255));
        thumb.setPosition(enabled ? 25 : 3, 3);
        item.addChild(thumb);
        item.node.on(cc.Node.EventType.TOUCH_END, function (event) {
            if (event && event.stopPropagation) event.stopPropagation();
            if (item.enabled === false || typeof callback !== 'function') return;
            var finish = function () { callback(); };
            if (cc.tween) {
                cc.tween(thumb).to(0.12, { x: enabled ? 3 : 25 }, { easing: 'sineOut' }).call(finish).start();
            } else finish();
        });
        return item;
    }

    function isWebKitBackend() {
        if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
            try { return String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native') === 'webkit'; }
            catch (ignored) {}
        }
        return false;
    }

    parts.scripts = {
        _refreshScripts: function () {
            if (!isWebKitBackend()) return;
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'listScriptFiles'); } catch (error) {}
            }
        },

        _loadScripts: function () {
            var raw = this.storage && this.storage.getItem('ios2.scripts');
            try { this.scripts = raw ? JSON.parse(raw) : []; } catch (error) { this.scripts = []; }
            if (!Array.isArray(this.scripts)) this.scripts = [];
            this.scripts = this.scripts.filter(function (script) {
                return script && script.name && script.name !== 'launcher.js' && !script.builtin;
            });
            for (var index = 0; index < this.scripts.length; index++) {
                this.scripts[index].enabled = this.scripts[index].enabled === true;
                this.scripts[index].scope = this.scripts[index].scope === 'multi' ? 'multi' : 'single';
            }
            try { this.scriptsGlobalEnabled = !this.storage || this.storage.getItem(GLOBAL_SCRIPTS_KEY) !== '0'; }
            catch (ignored) { this.scriptsGlobalEnabled = true; }
            try { this.multiScriptGate = !!(this.storage && this.storage.getItem('ios2.scripts.multiGate') === '1'); }
            catch (ignored2) { this.multiScriptGate = false; }
        },

        _saveScripts: function () {
            if (this.storage) this.storage.setItem('ios2.scripts', JSON.stringify(this.scripts));
            try {
                if (this.storage) {
                    this.storage.setItem(GLOBAL_SCRIPTS_KEY, this.scriptsGlobalEnabled === false ? '0' : '1');
                    this.storage.setItem('ios2.scripts.multiGate', this.multiScriptGate ? '1' : '0');
                }
            } catch (ignored) {}
        },

        _disposeScriptFairy: function () {
            if (this._scriptFairyRoot && this._scriptFairyRoot.node) this._scriptFairyRoot.node.removeFromParent(true);
            this._scriptFairyRoot = null;
            this._scriptFairyPopup = null;
        },

        _showScriptFairyPopup: function (script) {
            var root = this._scriptFairyRoot;
            if (!root) return;
            if (this._scriptFairyPopup) this._scriptFairyPopup.removeFromParent(true);
            var self = this;
            var overlay = new fgui.GComponent();
            overlay.setSize(root.width, root.height);
            overlay.addChild(fairyGraph(root.width, root.height, cc.color(12, 18, 28, 150)));
            var panelWidth = Math.min(360, root.width - 32), rowHeight = 52;
            var panel = new fgui.GComponent();
            panel.setSize(panelWidth, 74 + rowHeight * 4);
            panel.setPosition((root.width - panelWidth) / 2, Math.max(20, (root.height - panel.height) / 2));
            panel.addChild(fairyGraph(panelWidth, panel.height, COLORS.panel, 14, COLORS.border));
            var heading = fairyText(script.name, 21, COLORS.text, panelWidth - 32, 42);
            heading.setPosition(16, 10); panel.addChild(heading);
            var options = [
                { label: '仅单开生效', action: function () { script.scope = 'single'; self._saveScripts(); self._showScripts(); } },
                { label: '单开 + 多开生效', action: function () { script.scope = 'multi'; self._saveScripts(); self._showScripts(); } },
                { label: '禁用', action: function () { script.enabled = false; self._saveScripts(); self._showScripts(); } },
                { label: '删除', danger: true, action: function () { self._deleteScript(script.name); } }
            ];
            for (var index = 0; index < options.length; index++) {
                (function (option, itemIndex) {
                    var button = fairyButton(option.label, panelWidth - 24, rowHeight - 6,
                        option.danger ? cc.color(224, 82, 82, 255) : COLORS.panelAlt,
                        option.danger ? cc.Color.WHITE : COLORS.text, option.action);
                    button.setPosition(12, 58 + itemIndex * rowHeight); panel.addChild(button);
                }(options[index], index));
            }
            overlay.addChild(panel);
            overlay.onClick(function () { overlay.removeFromParent(true); self._scriptFairyPopup = null; });
            panel.onClick(function (event) { if (event && event.stopPropagation) event.stopPropagation(); });
            overlay.node.on(cc.Node.EventType.TOUCH_END, function (event) {
                if (event && event.stopPropagation) event.stopPropagation();
                overlay.removeFromParent(true); self._scriptFairyPopup = null;
            });
            panel.node.on(cc.Node.EventType.TOUCH_END, function (event) { if (event && event.stopPropagation) event.stopPropagation(); });
            root.addChild(overlay, 20); this._scriptFairyPopup = overlay;
        },

        _showScripts: function () {
            var size = cc.winSize, self = this;
            this._disposeScriptFairy();
            if (!isWebKitBackend()) {
                this._header('JS 脚本管理', '控制本地脚本的启用状态');
                var unavailable = common.label('JS 脚本仅支持 WebKit 模式', 24, COLORS.muted);
                unavailable.setPosition(size.width / 2, size.height / 2 + 34); this.content.addChild(unavailable);
                this._setStatus('切换到 WebKit 多开后可导入和启动脚本。', COLORS.warning); return;
            }
            var root = this._scriptFairyRoot = new fgui.GComponent();
            root.name = 'IOS2ScriptManager'; root.setSize(size.width, size.height);
            root.addChild(fairyGraph(root.width, root.height, COLORS.background));
            root.node.setAnchorPoint(0, 1); root.node.setPosition(0, size.height); this.content.addChild(root.node, 10);
            var top = common.NAV_HEIGHT + common.safeAreaTop(size) + 12;
            var title = fairyText('JS 脚本管理器', 30, COLORS.text, Math.max(120, root.width - 180), 48); title.setPosition(22, top); root.addChild(title);
            var importButton = fairyButton('+ 导入脚本', 126, 40, cc.color(37, 117, 224, 255), cc.Color.WHITE, this._importScript.bind(this)); importButton.setPosition(root.width - 148, top + 2); root.addChild(importButton);
            var gap = 12, cardWidth = (root.width - 44 - gap) / 2, cardY = top + 62;
            var makeCard = function (x, cardTitle, detail, onClick, enabled) {
                var card = new fgui.GComponent(); card.setSize(cardWidth, 112); card.setPosition(x, cardY);
                card.addChild(fairyGraph(cardWidth, 112, enabled ? cc.color(244, 252, 248, 255) : COLORS.panel, 12, enabled ? cc.color(34, 177, 112, 255) : COLORS.border));
                var name = fairyText(cardTitle, 19, enabled ? COLORS.success : COLORS.text, cardWidth - 24, 32); name.setPosition(12, 10); card.addChild(name);
                var desc = fairyText(detail, 15, COLORS.muted, cardWidth - 24, 30); desc.setPosition(12, 43); card.addChild(desc);
                var toggle = fairySwitch(enabled, onClick); toggle.setPosition(cardWidth - 66, 72); card.addChild(toggle); return card;
            };
            root.addChild(makeCard(22, 'JS 引擎总开关', this.scriptsGlobalEnabled ? '控制全部脚本运行状态' : '全局已暂停，不修改子状态', function () { self.scriptsGlobalEnabled = !self.scriptsGlobalEnabled; self._saveScripts(); self._showScripts(); }, this.scriptsGlobalEnabled));
            root.addChild(makeCard(22 + cardWidth + gap, '多开全局门禁', '允许在多开窗口中执行脚本', function () { self.multiScriptGate = !self.multiScriptGate; self._saveScripts(); self._showScripts(); }, self.multiScriptGate));
            var listTop = cardY + 132;
            var count = this.scripts.filter(function (item) { return item.enabled; }).length;
            var listTitle = fairyText('脚本列表  ·  已启用 ' + count + '/' + this.scripts.length, 20, COLORS.text, root.width - 44, 36); listTitle.setPosition(22, listTop); root.addChild(listTitle);
            if (!this.scripts.length) { var empty = fairyText('暂无导入的 JS 脚本', 19, COLORS.muted, root.width - 44, 54, fgui.AlignType.Center); empty.setPosition(22, listTop + 66); root.addChild(empty); }
            for (var index = 0; index < this.scripts.length; index++) {
                (function (script, rowIndex) {
                    var rowWidth = root.width - 44, row = new fgui.GComponent(); row.setSize(rowWidth, 76); row.setPosition(22, listTop + 42 + rowIndex * 84);
                    row.addChild(fairyGraph(rowWidth, 76, self.scriptsGlobalEnabled ? COLORS.panel : cc.color(245, 247, 250, 255), 10, script.enabled ? cc.color(179, 224, 198, 255) : COLORS.border));
                    var name = fairyText(script.name, 18, COLORS.text, rowWidth - 92, 30); name.setPosition(14, 7); row.addChild(name);
                    var scope = fairyText(script.scope === 'multi' ? '单开 + 多开' : '仅单开', 15, script.scope === 'multi' ? cc.color(126, 82, 200, 255) : COLORS.accent, 140, 25); scope.setPosition(14, 42); row.addChild(scope);
                    var state = fairySwitch(script.enabled, function () { script.enabled = !script.enabled; self._saveScripts(); self._showScripts(); }); state.setPosition(rowWidth - 68, 22); row.addChild(state);
                    row.node.on(cc.Node.EventType.TOUCH_END, function (event) { if (event && event.stopPropagation) event.stopPropagation(); self._showScriptFairyPopup(script); });
                    row.onClick(function () { self._showScriptFairyPopup(script); }); root.addChild(row);
                }(this.scripts[index], index));
            }
            this.status = this.status || '';
        },

        _showScriptSubmenu: function (active) {
            var size = cc.winSize;
            var self = this;
            var bar = common.surfaceNode(size.width - 64, 42, COLORS.panelAlt, 10, COLORS.border);
            bar.setPosition(32, this._navTop(size) - 202);
            this.content.addChild(bar, 4);
            var names = [{ key: 'scripts', text: '脚本列表' }, { key: 'settings', text: '资源 JS 配置' }];
            for (var index = 0; index < names.length; index++) {
                (function (item, itemIndex) {
                    var button = common.button(item.text, 17, function () {
                        self._scriptSubpage = item.key;
                        self.showPage(1);
                    }, item.key === active ? COLORS.accent : COLORS.muted, 150);
                    button.setContentSize(size.width / 2 - 40, 40);
                    button.setPosition(size.width * (itemIndex + 0.5) / 2 - 32, 21);
                    bar.addChild(button);
                }(names[index], index));
            }
        },

        _showSettingsConfig: function () {
            var size = cc.winSize;
            var self = this;
            this._header('资源 JS 配置', '启动时优先使用导入的 settings.js');
            this._showScriptSubmenu('settings');
            var activeName = '';
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { activeName = String(jsb.reflection.callStaticMethod('IOS2Native', 'settingsFileName') || ''); }
                catch (ignored) {}
            }
            var state = common.surfaceNode(size.width - 64, 112, COLORS.panel, 14, COLORS.border);
            state.setPosition(32, this._navTop(size) - 338);
            this.content.addChild(state, 5);
            var title = common.label(activeName ? '当前使用：导入配置' : '当前使用：App 自带配置', 21,
                activeName ? COLORS.success : COLORS.text);
            title.setAnchorPoint(0, 0.5);
            title.setPosition(22, 76);
            state.addChild(title);
            var detail = common.label(activeName ? activeName + '（下次启动生效）' : 'settings.*.js（下次启动生效）', 17, COLORS.muted);
            detail.setAnchorPoint(0, 0.5);
            detail.setPosition(22, 38);
            state.addChild(detail);
            var importButton = common.actionButton('导入 settings.js', 17, this._importSettings.bind(this), COLORS.accent, 176);
            importButton.setPosition(size.width / 2 - 96, this._navTop(size) - 414);
            var restoreButton = common.actionButton('恢复 App 配置', 17, this._deleteSettings.bind(this), COLORS.muted, 176);
            restoreButton.setPosition(size.width / 2 + 96, this._navTop(size) - 414);
            this._menu([importButton, restoreButton]);
            this._setStatus(this.status || '导入后重启 App，新的资源版本和 CDN 配置才会加载。');
        },

        _importScript: function () {
            if (!isWebKitBackend()) {
                this.status = 'JS 脚本仅支持 WebKit 模式';
                return;
            }
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) {
                this.status = '当前环境不支持文件选择';
                return;
            }
            this.status = '正在打开文件选择器…';
            try { jsb.reflection.callStaticMethod('IOS2Native', 'selectScriptFile'); }
            catch (error) { this.status = '无法打开文件选择器'; }
        },

        _importSettings: function () {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) {
                this._setStatus('当前环境不支持文件选择', COLORS.warning);
                return;
            }
            this._setStatus('正在打开 settings.js 文件选择器…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'selectSettingsFile'); }
            catch (error) { this._setStatus('无法打开文件选择器', COLORS.warning); }
        },

        _deleteSettings: function () {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            this._setStatus('正在恢复 App 自带配置…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'deleteSettingsFile'); }
            catch (error) { this._setStatus('恢复失败', COLORS.warning); }
        },

        _deleteScript: function (name) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            this.status = '正在删除 ' + name + '…';
            try { jsb.reflection.callStaticMethod('IOS2Native', 'deleteScriptFile:', name); }
            catch (error) { this.status = '删除失败'; }
        },

        _runEnabledScripts: function (callback) {
            var errors = [];
            if (!isWebKitBackend()) {
                if (typeof callback === 'function') callback(errors);
                return errors;
            }
            var webViewScripts = this._enabledScriptRecords(errors, 'single');
            // Cocos JSB keeps access to the real game modules; WKWebView gives
            // the same untouched source a real DOM so its HTML/CSS controls
            // become visible. The native bridge forwards WebSocket requests
            // from this view back to the Cocos socket.
            if (webViewScripts.length && global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try {
                    jsb.reflection.callStaticMethod('IOS2Native', 'showScripts:', JSON.stringify(webViewScripts));
                } catch (error) {
                    errors.push('WebView: ' + (error && (error.message || error.stack) || '启动失败'));
                }
            }
            if (typeof callback === 'function') callback(errors);
            return errors;
        },

        _enabledScriptRecords: function (errors, environment) {
            if (!isWebKitBackend()) return [];
            var records = [];
            errors = errors || [];
            environment = environment === 'multi' ? 'multi' : 'single';
            if (environment === 'multi' && this.multiScriptGate === false) return records;
            if (this.scriptsGlobalEnabled === false) return records;
            var enabled = this.scripts.filter(function (script) {
                if (!script || !script.enabled || !script.name) return false;
                return environment === 'single' || script.scope === 'multi';
            });
            for (var index = 0; index < enabled.length; index++) {
                var name = enabled[index].name;
                try {
                    var source = global.jsb && jsb.reflection && jsb.reflection.callStaticMethod ?
                        jsb.reflection.callStaticMethod('IOS2Native', 'scriptFileContent:', name) : '';
                    if (!source) throw new Error('脚本内容为空');
                    records.push({ name: name, source: String(source) });
                    // The imported source runs once in WKWebView, where its
                    // DOM/UI is rendered. Cocos JSB only hosts the bridge and
                    // executes requested game-module calls, preventing two
                    // independent script instances from racing each other.
                    if (global.__ios2ScriptRuntime && typeof global.__ios2ScriptRuntime.install === 'function') {
                        global.__ios2ScriptRuntime.install();
                    }
                } catch (error) {
                    errors.push(name + ': ' + (error && (error.message || error.stack) || '执行失败'));
                }
            }
            return records;
        },

        _runEnabledScriptsAfterLogin: function () {
            if (this.scriptRunPending) return;
            this.scriptRunPending = true;
            var self = this;
            var runtime = global.__ios2ScriptRuntime;
            var run = function (environment) {
                var errors = self._runEnabledScripts();
                if (errors.length) {
                    self.status = '脚本执行失败：' + errors.join('；');
                    try {
                        jsb.reflection.callStaticMethod('IOS2Native', 'trace:', self.status);
                    } catch (ignored) {}
                } else {
                    var enabledCount = self.scriptsGlobalEnabled === false ? 0 : self.scripts.filter(function (script) {
                        return script && script.enabled && script.name;
                    }).length;
                    if (environment && !environment.socket && !environment.bridge) {
                        self.status = '脚本已启动，但未发现游戏 WebSocket，读取游戏信息可能失败';
                    } else {
                        self.status = enabledCount ? '已启动 ' + enabledCount + ' 个启用脚本' : '没有启用的脚本';
                    }
                }
            };
            if (runtime) runtime.waitForGame(15000, function (environment, timedOut) {
                if (timedOut) {
                    try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'script environment timeout'); } catch (ignored) {}
                }
                run(environment);
            });
            else setTimeout(function () { run(null); }, 1000);
        },

        _resetScriptRuntime: function () {
            this.scriptRunPending = false;
            if (global.__ios2ScriptRuntime) global.__ios2ScriptRuntime.reset();
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'hideScriptWebView'); } catch (ignored) {}
            }
        },

        onScriptFiles: function (json) {
            var records = [];
            try { records = JSON.parse(String(json || '[]')) || []; } catch (error) {}
            var previous = {};
            for (var index = 0; index < this.scripts.length; index++) previous[this.scripts[index].name] = this.scripts[index];
            this.scripts = [];
            for (var item = 0; item < records.length; item++) {
                var record = records[item];
                if (!record || !record.name) continue;
                // Imported scripts are opt-in. A multi-open launch evaluates
                // each enabled script in every WebKit instance.
                this.scripts.push({
                    name: record.name,
                    enabled: previous[record.name] ? previous[record.name].enabled : false,
                    scope: previous[record.name] && previous[record.name].scope === 'multi' ? 'multi' : 'single',
                    size: record.size
                });
            }
            this._saveScripts();
            if (this.page === 1) this.showPage(1);
        },

        onScriptImported: function (name) {
            this.status = '已导入 ' + name;
            this._refreshScripts();
        },

        onScriptImportFailed: function (message) {
            this.status = '脚本导入失败：' + String(message || '未知错误');
        },

        onSettingsImported: function (name) {
            this.status = '已导入 ' + String(name || 'settings.js') + '，重启 App 后生效';
            this._scriptSubpage = 'settings';
            if (this.page === 1) this.showPage(1);
        },

        onSettingsImportFailed: function (message) {
            this._setStatus('资源 JS 配置导入失败：' + String(message || '未知错误'), COLORS.warning);
        },

        onSettingsDeleted: function () {
            this.status = '已恢复 App 自带配置';
            this._scriptSubpage = 'settings';
            if (this.page === 1) this.showPage(1);
        },

        onSettingsDeleteFailed: function (message) {
            this._setStatus('恢复 App 配置失败：' + String(message || '未知错误'), COLORS.warning);
        },

        onScriptDeleted: function (name) {
            this.status = '已删除 ' + name;
            this._refreshScripts();
        },

        onScriptDeleteFailed: function (message) {
            this.status = '删除失败：' + String(message || '未知错误');
        }
    };
}(window));
