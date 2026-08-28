/* JavaScript file management page. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;

    parts.scripts = {
        _refreshScripts: function () {
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
        },

        _saveScripts: function () {
            if (this.storage) this.storage.setItem('ios2.scripts', JSON.stringify(this.scripts));
        },

        _showScripts: function () {
            var size = cc.winSize;
            var self = this;
            this._scriptSwipeRow = null;
            this._header('JS 脚本管理', '控制本地脚本的启用状态');
            this._showScriptSubmenu('scripts');
            var add = common.actionButton('+ 导入脚本', 18, this._importScript.bind(this), COLORS.accent, 146);
            add.setPosition(size.width - 38 - add.width / 2, this._navTop(size) - 164);
            this._menu([add]);
            this.background.off(cc.Node.EventType.TOUCH_END);
            this.background.on(cc.Node.EventType.TOUCH_END, function () {
                if (self._scriptSwipeRow) self._scriptSwipeRow.closeSwipe();
            });
            if (!this.scripts.length) {
                var empty = common.label('暂无导入的 JS 脚本', 24, COLORS.muted);
                empty.setPosition(size.width / 2, size.height / 2 + 34);
                this.content.addChild(empty);
            }
            for (var index = 0; index < this.scripts.length; index++) {
                (function (script, rowIndex) {
                    var y = self._navTop(size) - 286 - rowIndex * 90;
                    var row = common.swipeDeleteRow(self, '_scriptSwipeRow', {
                        width: size.width - 64,
                        height: 72,
                        title: script.name,
                        fontSize: 21,
                        accessory: {
                            text: script.enabled ? '✓' : '×',
                            color: script.enabled ? COLORS.success : COLORS.warning
                        },
                        onActivate: function () {
                            script.enabled = !script.enabled;
                            self._saveScripts();
                            self._showScripts();
                        },
                        onDelete: function () { self._deleteScript(script.name); }
                    });
                    row.setPosition(32, y - 36);
                    self.content.addChild(row, 5);
                }(this.scripts[index], index));
            }
            this._setStatus(this.status || '勾选的脚本会在登录成功、游戏环境就绪后执行。');
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
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) {
                this._setStatus('当前环境不支持文件选择', COLORS.warning);
                return;
            }
            this._setStatus('正在打开文件选择器…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'selectScriptFile'); }
            catch (error) { this._setStatus('无法打开文件选择器', COLORS.warning); }
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
            this._setStatus('正在删除 ' + name + '…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'deleteScriptFile:', name); }
            catch (error) { this._setStatus('删除失败', COLORS.warning); }
        },

        _runEnabledScripts: function (callback) {
            var errors = [];
            var webViewScripts = this._enabledScriptRecords(errors);
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

        _enabledScriptRecords: function (errors) {
            var records = [];
            errors = errors || [];
            var enabled = this.scripts.filter(function (script) { return script && script.enabled && script.name; });
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
                    var enabledCount = self.scripts.filter(function (script) { return script && script.enabled && script.name; }).length;
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
                this.scripts.push({ name: record.name, enabled: previous[record.name] ? previous[record.name].enabled : true, size: record.size });
            }
            this._saveScripts();
            if (this.page === 1) this.showPage(1);
        },

        onScriptImported: function (name) {
            this.status = '已导入 ' + name;
            this._refreshScripts();
        },

        onScriptImportFailed: function (message) {
            this._setStatus('脚本导入失败：' + String(message || '未知错误'), COLORS.warning);
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
            this._setStatus('删除失败：' + String(message || '未知错误'), COLORS.warning);
        }
    };
}(window));
