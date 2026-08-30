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

    function fairyGraph(width, height, fill, radius, border, lineSize) {
        var item = new fgui.GGraph();
        item.setSize(width, height);
        item.drawRect(border ? (lineSize || 1) : 0, border || cc.Color.TRANSPARENT, fill, radius ? [radius] : null);
        return item;
    }

    function verticalScrollBuffer() {
        var byteValues = [fgui.ScrollType.Vertical, fgui.ScrollBarDisplayType.Hidden];
        var intValues = [16 | 64];
        return {
            readByte: function () { return byteValues.length ? byteValues.shift() : 0; },
            readInt: function () { return intValues.length ? intValues.shift() : 0; },
            readBool: function () { return false; },
            readS: function () { return null; }
        };
    }

    function fairyButton(caption, width, height, fill, color, callback) {
        var item = new fgui.GComponent();
        item.setSize(width, height);
        item.opaque = true;
        item.addChild(fairyGraph(width, height, fill, 10));
        var captionText = fairyText(caption, 17, color, width, height, fgui.AlignType.Center);
        item.addChild(captionText);
        item.__ios2Caption = captionText;
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

    function fairyCheckbox(selected, callback) {
        var item = new fgui.GComponent();
        item.setSize(28, 28);
        item.touchable = false;
        var box = fairyGraph(26, 26, selected ? COLORS.accent : cc.Color.WHITE, 5,
            selected ? COLORS.accent : cc.color(170, 180, 192, 255));
        item.addChild(box);
        var mark = fairyText('✓', 21, cc.Color.WHITE, 26, 26, fgui.AlignType.Center);
        mark.visible = !!selected;
        item.addChild(mark);
        item.setState = function (nextSelected) {
            selected = !!nextSelected;
            box.drawRect(1, selected ? COLORS.accent : cc.color(170, 180, 192, 255),
                selected ? COLORS.accent : cc.Color.WHITE, [5]);
            mark.visible = selected;
        };
        if (typeof callback === 'function') callback.__ios2Checkbox = item;
        return item;
    }

    function fairySwitch(enabled, callback) {
        var width = 72, height = 42;
        var hitWidth = 112, hitHeight = 76;
        var item = new fgui.GComponent();
        item.setSize(hitWidth, hitHeight);
        item.opaque = true;
        var track = fairyGraph(width, height,
            enabled ? cc.color(16, 185, 129, 255) : cc.color(210, 216, 224, 255), height / 2);
        track.setPosition(20, 17);
        item.addChild(track);
        var thumb = fairyGraph(34, 34, cc.Color.WHITE, 17, cc.color(196, 203, 212, 255));
        thumb.setPosition(enabled ? 54 : 24, 21);
        item.addChild(thumb);
        item.setState = function (nextEnabled) {
            enabled = !!nextEnabled;
            track.drawRect(0, cc.Color.TRANSPARENT,
                enabled ? cc.color(16, 185, 129, 255) : cc.color(210, 216, 224, 255), [height / 2]);
            thumb.setPosition(enabled ? 54 : 24, 21);
        };
        item.node.on(cc.Node.EventType.TOUCH_END, function (event) {
            if (event && event.stopPropagation) event.stopPropagation();
            if (item.enabled === false || typeof callback !== 'function') return;
            var finish = function () { callback(); };
            if (cc.tween) {
                cc.tween(thumb).to(0.12, { x: enabled ? 24 : 54 }, { easing: 'sineOut' }).call(finish).start();
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
            this._scriptList = null;
            this._scriptGlobalSwitch = null;
            this._scriptMultiGateSwitch = null;
            this._scriptGlobalCard = null;
            this._scriptMultiGateCard = null;
            this._scriptListTitle = null;
            this._scriptFairyPopup = null;
        },

        _closeScriptFairyPopup: function () {
            if (this._scriptFairyPopup && this._scriptFairyPopup.node) this._scriptFairyPopup.node.removeFromParent(true);
            this._scriptFairyPopup = null;
        },

        _updateScriptVisuals: function () {
            if (this._scriptGlobalSwitch) this._scriptGlobalSwitch.setState(this.scriptsGlobalEnabled);
            if (this._scriptMultiGateSwitch) this._scriptMultiGateSwitch.setState(this.multiScriptGate);
            if (this._scriptGlobalCard && this._scriptGlobalCard.__ios2Surface) {
                this._scriptGlobalCard.__ios2Surface.drawRect(5,
                    this.scriptsGlobalEnabled ? cc.color(34, 177, 112, 255) : COLORS.border,
                    this.scriptsGlobalEnabled ? cc.color(244, 252, 248, 255) : COLORS.panel, [12]);
            }
            if (this._scriptMultiGateCard && this._scriptMultiGateCard.__ios2Surface) {
                this._scriptMultiGateCard.__ios2Surface.drawRect(5,
                    this.multiScriptGate ? cc.color(34, 177, 112, 255) : COLORS.border,
                    this.multiScriptGate ? cc.color(244, 252, 248, 255) : COLORS.panel, [12]);
            }
            if (this._scriptGlobalCard) {
                if (this._scriptGlobalCard.__ios2Title) this._scriptGlobalCard.__ios2Title.color = this.scriptsGlobalEnabled ? COLORS.success : COLORS.text;
                if (this._scriptGlobalCard.__ios2Detail) this._scriptGlobalCard.__ios2Detail.text = this.scriptsGlobalEnabled ? '控制全部脚本运行状态' : '全局已暂停，不修改子状态';
            }
            if (this._scriptMultiGateCard) {
                if (this._scriptMultiGateCard.__ios2Title) this._scriptMultiGateCard.__ios2Title.color = this.multiScriptGate ? COLORS.success : COLORS.text;
                if (this._scriptMultiGateCard.__ios2Detail) this._scriptMultiGateCard.__ios2Detail.text = this.multiScriptGate ? '允许在多开窗口中执行脚本' : '多开脚本已禁止执行';
            }
            var count = 0;
            if (Array.isArray(this.scripts)) {
                for (var index = 0; index < this.scripts.length; index++) {
                    var script = this.scripts[index];
                    if (script && script.enabled) count++;
                }
            }
            if (this._scriptListTitle) this._scriptListTitle.text = '脚本列表  ·  已启用 ' + count + '/' + this.scripts.length;
            var selectedCount = this._scriptSelectedNames ? Object.keys(this._scriptSelectedNames).length : 0;
            if (this._scriptDeleteSelectedButton && this._scriptDeleteSelectedButton.__ios2Caption) {
                this._scriptDeleteSelectedButton.__ios2Caption.text = '删除已选 (' + selectedCount + ')';
                this._scriptDeleteSelectedButton.enabled = selectedCount > 0;
            }
            if (this._scriptSelectAllButton && this._scriptSelectAllButton.__ios2Caption) {
                this._scriptSelectAllButton.__ios2Caption.text = selectedCount === this.scripts.length && this.scripts.length ? '取消全选' : '全选';
            }
            var children = this._scriptList && this._scriptList.numChildren !== undefined ?
                this._scriptList.numChildren : 0;
            for (var childIndex = 0; childIndex < children; childIndex++) {
                var row = this._scriptList.getChildAt(childIndex);
                var scriptRecord = row && row.__ios2Script;
                if (!scriptRecord) continue;
                if (row.__ios2Switch) row.__ios2Switch.setState(scriptRecord.enabled);
                if (row.__ios2Checkbox) row.__ios2Checkbox.setState(!!(this._scriptSelectedNames && this._scriptSelectedNames[scriptRecord.name]));
                if (row.__ios2Scope) {
                    var isMultiScope = scriptRecord.scope === 'multi';
                    row.__ios2Scope.text = isMultiScope ? '单开 + 多开' : '仅单开';
                    row.__ios2Scope.color = isMultiScope ? cc.color(126, 82, 200, 255) : COLORS.accent;
                }
                if (row.__ios2Surface) {
                    row.__ios2Surface.drawRect(1,
                        scriptRecord.enabled ? cc.color(179, 224, 198, 255) : COLORS.border,
                        this.scriptsGlobalEnabled ? COLORS.panel : cc.color(245, 247, 250, 255), [10]);
                }
            }
        },

        _showScriptFairyPopup: function (script) {
            var root = this._scriptFairyRoot;
            if (!root) return;
            if (this._scriptFairyPopup) this._scriptFairyPopup.removeFromParent(true);
            var self = this;
            var overlay = new fgui.GComponent();
            overlay.setSize(root.width, root.height);
            overlay.addChild(fairyGraph(root.width, root.height, cc.color(12, 18, 28, 150)));
            var panelWidth = Math.min(380, root.width - 28), rowHeight = 58;
            var panel = new fgui.GComponent();
            panel.setSize(panelWidth, 74 + rowHeight * 4);
            panel.setPosition((root.width - panelWidth) / 2, Math.max(20, (root.height - panel.height) / 2));
            panel.addChild(fairyGraph(panelWidth, panel.height, COLORS.panel, 14, COLORS.border));
            var heading = fairyText(script.name, 23, COLORS.text, panelWidth - 32, 42);
            heading.setPosition(16, 10); panel.addChild(heading);
            var options = [
                { label: '仅单开生效', action: function () { script.scope = 'single'; self._saveScripts(); self._updateScriptVisuals(); self._closeScriptFairyPopup(); } },
                { label: '单开 + 多开生效', action: function () { script.scope = 'multi'; self._saveScripts(); self._updateScriptVisuals(); self._closeScriptFairyPopup(); } },
                { label: '禁用', action: function () { script.enabled = false; self._saveScripts(); self._updateScriptVisuals(); self._closeScriptFairyPopup(); } },
                { label: '删除', danger: true, action: function () { self._closeScriptFairyPopup(); self._deleteScript(script.name); } }
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
            var previousScrollY = Number(this._scriptScrollY) || 0;
            if (this._scriptList && this._scriptList.scrollPane) {
                previousScrollY = Math.max(0, Number(this._scriptList.scrollPane.posY) || 0);
            }
            this._scriptScrollY = previousScrollY;
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
            var title = fairyText('JS 脚本管理器', 32, COLORS.text, Math.max(120, root.width - 180), 48); title.setPosition(22, top); root.addChild(title);
            var importButton = fairyButton('+ 导入脚本', 126, 40, cc.color(37, 117, 224, 255), cc.Color.WHITE, this._importScript.bind(this)); importButton.setPosition(root.width - 148, top + 2); root.addChild(importButton);
            var gap = 14, cardWidth = (root.width - 44 - gap) / 2, cardY = top + 68;
            var makeCard = function (x, cardTitle, detail, onClick, enabled) {
                var card = new fgui.GComponent(); card.setSize(cardWidth, 136); card.setPosition(x, cardY);
                var cardSurface = fairyGraph(cardWidth, 136, enabled ? cc.color(244, 252, 248, 255) : COLORS.panel, 12, enabled ? cc.color(34, 177, 112, 255) : COLORS.border, 5);
                card.addChild(cardSurface); card.__ios2Surface = cardSurface;
                var name = fairyText(cardTitle, 23, enabled ? COLORS.success : COLORS.text, cardWidth - 24, 36); name.setPosition(12, 10); card.addChild(name);
                var desc = fairyText(detail, 19, COLORS.muted, cardWidth - 24, 34); desc.setPosition(12, 48); card.addChild(desc);
                card.__ios2Title = name;
                card.__ios2Detail = desc;
                var toggle = fairySwitch(enabled, onClick); toggle.setPosition(cardWidth - 112, 70); card.addChild(toggle);
                card.__ios2Switch = toggle;
                return card;
            };
            var globalCard = makeCard(22, 'JS 引擎总开关', this.scriptsGlobalEnabled ? '控制全部脚本运行状态' : '全局已暂停，不修改子状态', function () {
                self.scriptsGlobalEnabled = !self.scriptsGlobalEnabled;
                self._saveScripts(); self._updateScriptVisuals();
            }, this.scriptsGlobalEnabled);
            var multiGateCard = makeCard(22 + cardWidth + gap, '多开全局门禁', this.multiScriptGate ? '允许在多开窗口中执行脚本' : '多开脚本已禁止执行', function () {
                self.multiScriptGate = !self.multiScriptGate;
                self._saveScripts(); self._updateScriptVisuals();
            }, self.multiScriptGate);
            root.addChild(globalCard); root.addChild(multiGateCard);
            this._scriptGlobalSwitch = globalCard.__ios2Switch;
            this._scriptMultiGateSwitch = multiGateCard.__ios2Switch;
            this._scriptGlobalCard = globalCard;
            this._scriptMultiGateCard = multiGateCard;
            var listTop = cardY + 156;
            var count = this.scripts.filter(function (item) { return item.enabled; }).length;
            var headerWidth = this._scriptBatchMode ? Math.max(120, root.width - 250) : Math.max(120, root.width - 170);
            var listTitle = fairyText('脚本列表  ·  已启用 ' + count + '/' + this.scripts.length, 22, COLORS.text, headerWidth, 38); listTitle.setPosition(22, listTop); root.addChild(listTitle);
            this._scriptListTitle = listTitle;
            if (!this._scriptSelectedNames) this._scriptSelectedNames = {};
            var batchToggle = fairyButton(this._scriptBatchMode ? '取消批量' : '批量删除', 104, 36,
                this._scriptBatchMode ? COLORS.panelAlt : cc.color(224, 82, 82, 255),
                this._scriptBatchMode ? COLORS.text : cc.Color.WHITE, function () {
                    self._scriptBatchMode = !self._scriptBatchMode;
                    self._scriptSelectedNames = {};
                    self._showScripts();
                });
            batchToggle.setPosition(root.width - 126, listTop + 1); root.addChild(batchToggle);
            this._scriptBatchToggle = batchToggle;
            if (this._scriptBatchMode) {
                var selectAll = fairyButton('全选', 72, 32, COLORS.panelAlt, COLORS.text, function () {
                    var selected = self._scriptSelectedNames || {};
                    var allSelected = self.scripts.length > 0 && self.scripts.every(function (item) { return selected[item.name]; });
                    self._scriptSelectedNames = {};
                    if (!allSelected) self.scripts.forEach(function (item) { self._scriptSelectedNames[item.name] = true; });
                    self._updateScriptVisuals();
                });
                selectAll.setPosition(root.width - 206, listTop + 3); root.addChild(selectAll); this._scriptSelectAllButton = selectAll;
                var deleteSelected = fairyButton('删除已选 (0)', 112, 32, cc.color(224, 82, 82, 255), cc.Color.WHITE, function () { self._deleteSelectedScripts(); });
                deleteSelected.setPosition(root.width - 326, listTop + 3); root.addChild(deleteSelected); this._scriptDeleteSelectedButton = deleteSelected;
            } else {
                this._scriptSelectAllButton = null; this._scriptDeleteSelectedButton = null;
            }
            var listY = listTop + 42;
            var listHeight = Math.max(148, root.height - listY - 28);
            var list = new fgui.GList();
            list.name = 'IOS2ScriptList';
            list.setSize(root.width - 44, listHeight);
            list.setPosition(22, listY);
            list.layout = fgui.ListLayoutType.SingleColumn;
            list.lineGap = 10;
            list.scrollItemToViewOnClick = false;
            list.setupScroll(verticalScrollBuffer());
            root.addChild(list);
            this._scriptList = list;
            list.node.on(fgui.Event.SCROLL, function () {
                self._scriptScrollY = Math.max(0, Number(list.scrollPane.posY) || 0);
            });
            // This page lives below FairyGUI's GRoot, so its Cocos touch
            // events do not pass through FairyGUI's InputProcessor. Forward
            // the native touch stream to the FairyGUI ScrollPane explicitly.
            var scrollPane = list.scrollPane;
            var scrollEvent = function (event) {
                var location = event && typeof event.getLocation === 'function' ? event.getLocation() : null;
                if (!location) return null;
                return {
                    // Cocos reports Y from the bottom while this legacy
                    // FairyGUI host is anchored from the top. Invert Y
                    // before ScrollPane.globalToLocal() converts it again.
                    pos: { x: location.x, y: -location.y },
                    touchId: event.touch && typeof event.touch.getID === 'function' ? event.touch.getID() : 0,
                    captureTouch: function () {}
                };
            };
            list.node.on(cc.Node.EventType.TOUCH_START, function (event) {
                var forwarded = scrollEvent(event); if (forwarded) scrollPane.onTouchBegin(forwarded);
            });
            list.node.on(cc.Node.EventType.TOUCH_MOVE, function (event) {
                var forwarded = scrollEvent(event); if (forwarded) scrollPane.onTouchMove(forwarded);
                if (event && event.stopPropagation) event.stopPropagation();
            });
            list.node.on(cc.Node.EventType.TOUCH_END, function (event) {
                var forwarded = scrollEvent(event); if (forwarded) scrollPane.onTouchEnd(forwarded);
            });
            list.node.on(cc.Node.EventType.TOUCH_CANCEL, function (event) {
                var forwarded = scrollEvent(event); if (forwarded) scrollPane.onTouchEnd(forwarded);
            });
            if (!this.scripts.length) {
                var empty = fairyText('暂无导入的 JS 脚本', 19, COLORS.muted, root.width - 44, 54, fgui.AlignType.Center);
                empty.setPosition(0, Math.max(24, listHeight / 2 - 27)); list.addChild(empty);
            }
            for (var index = 0; index < this.scripts.length; index++) {
                (function (script, rowIndex) {
                    var rowWidth = root.width - 44, row = new fgui.GComponent(); row.setSize(rowWidth, 94);
                    var rowSurface = fairyGraph(rowWidth, 94, self.scriptsGlobalEnabled ? COLORS.panel : cc.color(245, 247, 250, 255), 10, script.enabled ? cc.color(179, 224, 198, 255) : COLORS.border);
                    row.addChild(rowSurface); row.__ios2Surface = rowSurface; row.__ios2Script = script;
                    var rowTouch = { suppress: false };
                    var leftInset = self._scriptBatchMode ? 52 : 14;
                    if (self._scriptBatchMode) {
                        var checkbox = fairyCheckbox(!!(self._scriptSelectedNames && self._scriptSelectedNames[script.name]));
                        checkbox.setPosition(14, 33); row.addChild(checkbox); row.__ios2Checkbox = checkbox;
                    }
                    var name = fairyText(script.name, 22, COLORS.text, rowWidth - leftInset - 116, 36); name.setPosition(leftInset, 6); row.addChild(name);
                    var scope = fairyText(script.scope === 'multi' ? '单开 + 多开' : '仅单开', 18, script.scope === 'multi' ? cc.color(126, 82, 200, 255) : COLORS.accent, 160, 28); scope.setPosition(leftInset, 51); row.addChild(scope); row.__ios2Scope = scope;
                    var toggleScript = function () {
                        rowTouch.suppress = true;
                        script.enabled = !script.enabled;
                        self._saveScripts(); self._updateScriptVisuals();
                        setTimeout(function () { rowTouch.suppress = false; }, 0);
                    };
                    var state = fairySwitch(script.enabled, toggleScript); state.setPosition(rowWidth - 112, 9); row.addChild(state); row.__ios2Switch = state;
                    row.node.on(cc.Node.EventType.TOUCH_END, function (event) {
                        if (rowTouch.suppress || scrollPane.isDragged) return;
                        if (event && typeof event.getLocation === 'function') {
                            var localPoint = row.node.convertToNodeSpaceAR(event.getLocation());
                            if (localPoint.x >= rowWidth - 154) {
                                toggleScript();
                                return;
                            }
                        }
                        if (self._scriptBatchMode) {
                            if (!self._scriptSelectedNames) self._scriptSelectedNames = {};
                            if (self._scriptSelectedNames[script.name]) delete self._scriptSelectedNames[script.name];
                            else self._scriptSelectedNames[script.name] = true;
                            self._updateScriptVisuals();
                        } else self._showScriptFairyPopup(script);
                    });
                    list.addChild(row);
                }(this.scripts[index], index));
            }
            list.ensureBoundsCorrect();
            if (list.scrollPane) list.scrollPane.posY = previousScrollY;
            this._scriptScrollY = Math.max(0, Number(list.scrollPane && list.scrollPane.posY) || 0);
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

        _deleteSelectedScripts: function () {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            var selected = this._scriptSelectedNames || {};
            var names = [];
            for (var index = 0; index < this.scripts.length; index++) {
                if (this.scripts[index] && selected[this.scripts[index].name]) names.push(this.scripts[index].name);
            }
            if (!names.length) return;
            this.status = '正在删除已选脚本…';
            this._scriptSelectedNames = {};
            this._scriptBatchMode = false;
            for (var item = 0; item < names.length; item++) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'deleteScriptFile:', names[item]); }
                catch (error) { this.status = '批量删除失败'; }
            }
            this._updateScriptVisuals();
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
