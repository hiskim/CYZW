/* FairyGUI account-management view. Contains no login or native bridge logic. */
(function (global) {
    'use strict';

    var COLORS = {
        background: cc.color(245, 247, 250, 255),
        surface: cc.color(255, 255, 255, 255),
        border: cc.color(219, 226, 235, 255),
        text: cc.color(28, 36, 48, 255),
        muted: cc.color(100, 113, 132, 255),
        accent: cc.color(31, 111, 235, 255),
        accentSoft: cc.color(232, 241, 255, 255),
        success: cc.color(21, 139, 91, 255),
        danger: cc.color(205, 61, 61, 255),
        warning: cc.color(174, 101, 26, 255)
    };
    var FONT_FAMILY = 'PingFang SC';

    function graph(width, height, fill, radius, border) {
        var item = new fgui.GGraph();
        item.setSize(width, height);
        item.drawRect(border ? 1 : 0, border || cc.Color.TRANSPARENT, fill, radius ? [radius] : null);
        return item;
    }

    function ellipse(width, height, fill, border, lineSize) {
        var item = new fgui.GGraph();
        item.setSize(width, height);
        item.drawEllipse(border ? (lineSize || 2) : 0, border || cc.Color.TRANSPARENT, fill);
        return item;
    }

    function text(value, fontSize, color, width, height, align) {
        var item = new fgui.GTextField();
        item.autoSize = fgui.AutoSizeType.None;
        item.setSize(width, height);
        item.font = FONT_FAMILY;
        item.fontSize = fontSize;
        item.color = color;
        item.align = align === undefined ? fgui.AlignType.Left : align;
        item.verticalAlign = fgui.VertAlignType.Middle;
        item.singleLine = true;
        item.text = String(value || '');
        return item;
    }

    function button(caption, width, height, fill, color, callback, radius) {
        var item = new fgui.GComponent();
        item.setSize(width, height);
        item.opaque = true;
        item.addChild(graph(width, height, fill, radius || 8));
        item.addChild(text(caption, 18, color, width, height, fgui.AlignType.Center));
        item.onClick(function () {
            if (item.enabled && typeof callback === 'function') callback();
        });
        return item;
    }

    function iconButton(label, size, callback, tooltip) {
        var item = new fgui.GComponent();
        item.setSize(size, size);
        item.opaque = true;
        item.addChild(graph(size, size, cc.Color.TRANSPARENT, size / 2));
        item.addChild(text(label, 31, COLORS.accent, size, size, fgui.AlignType.Center));
        // The project does not ship a FairyGUI tooltip window resource.
        // Avoid registering hover handlers that only log UIConfig errors.
        item.tooltips = (fgui.UIConfig && fgui.UIConfig.tooltipsWin) ? (tooltip || '') : '';
        item.onClick(function () {
            if (item.enabled && typeof callback === 'function') callback();
        });
        return item;
    }

    function gridIcon(size, selected) {
        var item = new fgui.GComponent();
        item.setSize(size, size);
        item.opaque = true;
        item.addChild(graph(size, size, cc.Color.TRANSPARENT, size / 2));
        var color = selected ? COLORS.accent : COLORS.muted;
        var cell = 6;
        var gap = 4;
        var start = (size - cell * 3 - gap * 2) / 2;
        for (var row = 0; row < 3; row++) {
            for (var column = 0; column < 3; column++) {
                item.addChild(graph(cell, cell, color, 1)).setPosition(
                    start + column * (cell + gap), start + row * (cell + gap));
            }
        }
        return item;
    }

    function userIcon() {
        var item = new fgui.GComponent();
        item.setSize(34, 34);
        item.addChild(graph(34, 34, COLORS.accentSoft, 17));
        item.addChild(graph(9, 9, COLORS.accent, 5)).setPosition(12.5, 6);
        item.addChild(graph(20, 10, COLORS.accent, 5)).setPosition(7, 18);
        return item;
    }

    function trashIcon(color) {
        var item = new fgui.GComponent();
        item.setSize(30, 30);
        item.addChild(graph(16, 17, color, 2)).setPosition(7, 7);
        item.addChild(graph(20, 3, color, 1)).setPosition(5, 4);
        item.addChild(graph(8, 3, color, 1)).setPosition(11, 1);
        return item;
    }

    function checkCircle(selected, size) {
        var item = new fgui.GComponent();
        item.setSize(size, size);
        if (selected) {
            item.addChild(ellipse(size, size, COLORS.accent, null, 0));
            var mark = text('✓', Math.max(23, Math.floor(size * 0.72)), cc.Color.WHITE,
                size, size, fgui.AlignType.Center);
            mark.setPosition(0, -1);
            item.addChild(mark);
        } else {
            item.addChild(ellipse(size, size, cc.Color.TRANSPARENT, cc.color(202, 204, 208, 255), 3));
        }
        return item;
    }

    function accountDisplayName(record) {
        return String(record && record.name || '').replace(/\.bin$/i, '') || '未命名账号';
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

    function formatSize(bytes) {
        bytes = Number(bytes) || 0;
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / 1024 / 1024).toFixed(1) + ' MB';
    }

    function formatDate(timestamp) {
        if (!timestamp) return '';
        var date = new Date(Number(timestamp) * 1000);
        if (isNaN(date.getTime())) return '';
        var month = String(date.getMonth() + 1);
        var day = String(date.getDate());
        var hours = String(date.getHours());
        var minutes = String(date.getMinutes());
        if (month.length < 2) month = '0' + month;
        if (day.length < 2) day = '0' + day;
        if (hours.length < 2) hours = '0' + hours;
        if (minutes.length < 2) minutes = '0' + minutes;
        return date.getFullYear() + '-' + month + '-' + day + ' ' + hours + ':' + minutes;
    }

    function readPreference(storage, key, fallback, allowed) {
        if (!storage || typeof storage.getItem !== 'function') return fallback;
        try {
            var value = storage.getItem(key);
            if (allowed && allowed.indexOf(value) < 0) return fallback;
            return value === null || value === undefined || value === '' ? fallback : String(value);
        } catch (ignored) {
            return fallback;
        }
    }

    function writePreference(storage, key, value) {
        if (!storage || typeof storage.setItem !== 'function') return;
        try { storage.setItem(key, String(value)); } catch (ignored) {}
    }

    function readNavigationState(storage) {
        var fallback = { page: {}, scrollY: {} };
        if (!storage || typeof storage.getItem !== 'function') return fallback;
        try {
            var raw = storage.getItem('ios2.accountNavigationState');
            var state = raw ? JSON.parse(raw) : null;
            if (!state || typeof state !== 'object') return fallback;
            if (!state.page || typeof state.page !== 'object') state.page = {};
            if (!state.scrollY || typeof state.scrollY !== 'object') state.scrollY = {};
            return state;
        } catch (ignored) {
            return fallback;
        }
    }

    function safeAreaTop(width, height) {
        var common = global.__ios2ManagerParts && global.__ios2ManagerParts.common;
        var fallback = common && common.SAFE_AREA_FALLBACK_TOP || 44;
        var extra = common && common.SAFE_AREA_EXTRA_TOP || 8;
        var top = 0;
        var hasRect = false;
        var safeRect;
        if (cc.sys && typeof cc.sys.getSafeAreaRect === 'function') {
            try {
                safeRect = cc.sys.getSafeAreaRect();
                if (safeRect && isFinite(Number(safeRect.y)) && isFinite(Number(safeRect.height))) {
                    top = Math.max(0, height - Number(safeRect.y) - Number(safeRect.height));
                    hasRect = true;
                }
            } catch (ignored) {}
        }
        var isIOS = !!(cc.sys && (cc.sys.os === cc.sys.OS_IOS || cc.sys.os === 'iOS'));
        if (isIOS && height >= width && top <= 0) top = fallback;
        else if (!hasRect && !isIOS) top = 0;
        if (top <= 0) return 0;
        return Math.min(top + extra, Math.max(0, height - 120));
    }

    function IOS2AccountView(actions) {
        this.actions = actions || {};
        this.storage = this.actions.storage || null;
        this.accounts = [];
        this.page = 0;
        this.busyName = '';
        this.viewMode = readPreference(this.storage, 'ios2.accountViewMode', 'list', ['list', 'grid']);
        this.sortMode = readPreference(this.storage, 'ios2.accountSortMode', 'recent', ['recent', 'updated', 'name']);
        this.navigationMode = readPreference(this.storage, 'ios2.accountNavigationMode', 'page', ['scroll', 'page']);
        this.navigationState = readNavigationState(this.storage);
        this.page = this._storedPage();
        this._hasRenderedContent = false;
        this.runtimeBackend = String(this.actions.runtimeBackend || 'native');
        this.root = new fgui.GComponent();
        this.root.name = 'IOS2AccountHome';
        this.root.opaque = true;
        this._build();
        fgui.GRoot.inst.addChild(this.root);
    }

    IOS2AccountView.prototype._storedPage = function () {
        var value = Number(this.navigationState.page[this.viewMode]);
        return isFinite(value) && value >= 0 ? Math.floor(value) : 0;
    };

    IOS2AccountView.prototype._storedScrollY = function () {
        var value = Number(this.navigationState.scrollY[this.viewMode]);
        return isFinite(value) && value >= 0 ? value : 0;
    };

    IOS2AccountView.prototype._saveNavigationState = function () {
        if (!this.navigationState) this.navigationState = { page: {}, scrollY: {} };
        if (!this.navigationState.page) this.navigationState.page = {};
        if (!this.navigationState.scrollY) this.navigationState.scrollY = {};
        if (this.navigationMode === 'scroll' && this.list && this.list.scrollPane) {
            this.navigationState.scrollY[this.viewMode] = Math.max(0, Number(this.list.scrollPane.posY) || 0);
        } else {
            this.navigationState.page[this.viewMode] = Math.max(0, Math.floor(Number(this.page) || 0));
        }
        writePreference(this.storage, 'ios2.accountNavigationState', JSON.stringify(this.navigationState));
    };

    IOS2AccountView.prototype._build = function () {
        this._closeSwipeRow();
        this.root.removeChildren(0, -1, true);
        this._swipeRow = null;
        this._hasRenderedContent = false;
        var width = fgui.GRoot.inst.width;
        var height = fgui.GRoot.inst.height;
        this.layoutWidth = width;
        this.layoutHeight = height;
        this.layoutSafeTop = safeAreaTop(width, height);
        this.root.setSize(width, height);
        this.root.addChild(graph(width, height, COLORS.background));
        this.root.clearClick();
        this.root.on(fgui.Event.CLICK, this._handleOutsideSwipeClick, this);

        // The app hides the iOS status bar and lays out the management shell
        // edge-to-edge. Do not add the native safe-area inset again here: it
        // pushes the whole FairyGUI toolbar noticeably below the top edge.
        var top = 40 + this.layoutSafeTop;
        var compact = width < 360;
        var toolbarSize = compact ? 32 : 34;
        var toolbarGap = compact ? 4 : 5;
        var toolbarRight = width - (compact ? 14 : 8);
        var toolbarLeft = toolbarRight - toolbarSize * 4 - toolbarGap * 3;
        var titleWidth = Math.max(80, toolbarLeft - 38);
        var titleSize = compact ? Math.min(30, Math.max(22, Math.floor(titleWidth / 4))) : 38;
        var title = text('账号管理', titleSize, COLORS.text, titleWidth, 52);
        title.setPosition(28, top);
        this.root.addChild(title);

        var gear = iconButton('⚙', toolbarSize, this._showGearMenu.bind(this), '打开脚本与配置');
        gear.setPosition(toolbarRight - toolbarSize, top - 2);
        this.root.addChild(gear);
        var sort = iconButton('↕', toolbarSize, this._showSortMenu.bind(this), '排序账号');
        sort.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 2, top - 2);
        this.root.addChild(sort);
        var mode = gridIcon(toolbarSize, this.viewMode === 'grid');
        mode.tooltips = (fgui.UIConfig && fgui.UIConfig.tooltipsWin) ?
            (this.viewMode === 'grid' ? '切换列表视图' : '切换多块视图') : '';
        mode.onClick(this._toggleView.bind(this));
        mode.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 3, top - 2);
        this.root.addChild(mode);
        var importButton = iconButton('+', toolbarSize, this.actions.importAccounts, '导入账号');
        importButton.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 4, top - 2);
        this.root.addChild(importButton);
        var backend = this.runtimeBackend || 'native';
        this.runtimeBackend = backend;
        if (backend === 'webkit') {
            var multiButton = button('多开', 82, 40, COLORS.success, cc.Color.WHITE,
                this._showMultiOpen.bind(this), 8);
            multiButton.setPosition(width - 116, top + 56);
            this.root.addChild(multiButton);
        }

        var countRight = backend === 'webkit' ? width - 124 : width - 18;
        var countWidth = Math.max(48, Math.min(132, countRight - 30));
        this.accountCount = text('', 16, COLORS.muted, countWidth, 36, fgui.AlignType.Right);
        this.accountCount.autoSize = fgui.AutoSizeType.Shrink;
        this.accountCount.setPosition(countRight - countWidth, top + 77);
        this.root.addChild(this.accountCount);

        this.list = this.navigationMode === 'scroll' ? new fgui.GList() : new fgui.GComponent();
        this.list.setPosition(24, top + 104);
        this.list.setSize(width - 48, Math.max(190, height - top - 176));
        if (this.navigationMode === 'scroll') {
            this.list.layout = this.viewMode === 'grid' ? fgui.ListLayoutType.FlowHorizontal :
                fgui.ListLayoutType.SingleColumn;
            this.list.lineGap = this.viewMode === 'grid' ? 12 : 12;
            this.list.columnGap = 12;
            this.list.scrollItemToViewOnClick = false;
            this.list.setupScroll(verticalScrollBuffer());
            this.list.on(fgui.Event.TOUCH_BEGIN, this._onListActivity, this);
            this.list.on(fgui.Event.SCROLL, this._onListActivity, this);
            this.list.on(fgui.Event.SCROLL_END, this._saveNavigationState, this);
        } else {
            this.list.overflow = fgui.OverflowType.Hidden;
        }
        this.root.addChild(this.list);

        this.status = text('', 16, COLORS.muted, width - 48, 32);
        this.status.setPosition(24, height - 48);
        this.root.addChild(this.status);
        this.render();
    };

    IOS2AccountView.prototype._onListActivity = function () {
        if (typeof this.actions.wakePerformance === 'function') {
            this.actions.wakePerformance('account list scroll');
        }
    };

    IOS2AccountView.prototype._closeSwipeRow = function () {
        if (this._swipeRow && typeof this._swipeRow.closeSwipe === 'function') {
            this._swipeRow.closeSwipe(true);
        }
        this._swipeRow = null;
    };

    IOS2AccountView.prototype._handleOutsideSwipeClick = function (evt) {
        var active = this._swipeRow;
        if (!active) return;
        var target = evt && evt.initiator;
        if (target && active.isAncestorOf && active.isAncestorOf(target)) return;
        this._closeSwipeRow();
    };

    IOS2AccountView.prototype._swipeDeleteItem = function (record, width, height, renderContent) {
        var self = this;
        var deleteWidth = Math.min(112, Math.max(92, Math.round(width * 0.25)));
        var row = new fgui.GComponent();
        var foreground = new fgui.GComponent();
        var deleteArea = new fgui.GComponent();
        var swipeState = { offset: 0 };
        var touch = {
            startX: 0,
            startY: 0,
            baseOffset: 0,
            deltaX: 0,
            deltaY: 0,
            dragging: false,
            dismissedOpenRow: false,
            wasOpen: false,
            startedOnDelete: false,
            direction: 0
        };

        row.setSize(width, height);
        row.opaque = true;
        if (typeof row.setupOverflow === 'function') row.setupOverflow(fgui.OverflowType.Hidden);
        deleteArea.setSize(deleteWidth, height);
        deleteArea.setPosition(width - deleteWidth, 0);
        deleteArea.opaque = true;
        deleteArea.addChild(graph(deleteWidth, height, COLORS.danger, 16));
        deleteArea.addChild(trashIcon(cc.Color.WHITE)).setPosition(14, (height - 30) / 2);
        deleteArea.addChild(text('删除', 18, cc.Color.WHITE, deleteWidth - 54, height, fgui.AlignType.Center))
            .setPosition(48, 0);
        deleteArea.tooltips = (fgui.UIConfig && fgui.UIConfig.tooltipsWin) ? '删除账号' : '';
        deleteArea.touchable = !self.busyName;

        foreground.setSize(width, height);
        foreground.opaque = true;
        row.addChild(deleteArea);
        row.addChild(foreground);
        // The rounded card leaves its corner pixels transparent. Paint a
        // matching full-rect base first so the hidden delete layer cannot
        // bleed through as a red outline while the row is closed.
        foreground.addChild(graph(width, height, COLORS.background));
        if (typeof renderContent === 'function') renderContent(foreground);

        row.setSwipeOffset = function (offset) {
            var clamped = Math.max(-deleteWidth, Math.min(0, Number(offset) || 0));
            foreground.setPosition(clamped, 0);
            swipeState.offset = clamped;
            row.__swipeOffset = clamped;
        };
        row.animateSwipeOffset = function (offset) {
            var target = Math.max(-deleteWidth, Math.min(0, offset));
            if (!cc.tween) {
                row.setSwipeOffset(target);
                return;
            }
            cc.Tween.stopAllByTarget(swipeState);
            cc.tween(swipeState).to(0.14, { offset: target }, {
                easing: 'sineOut',
                onUpdate: function (state) { row.setSwipeOffset(state.offset); }
            }).start();
        };
        row.closeSwipe = function (immediate) {
            if (immediate && cc.Tween) cc.Tween.stopAllByTarget(swipeState);
            if (immediate) row.setSwipeOffset(0);
            else row.animateSwipeOffset(0);
            if (self._swipeRow === row) self._swipeRow = null;
        };
        row.openSwipe = function () {
            if (self._swipeRow && self._swipeRow !== row && self._swipeRow.closeSwipe) {
                self._swipeRow.closeSwipe();
            }
            row.animateSwipeOffset(-deleteWidth);
            self._swipeRow = row;
        };
        row.setSwipeOffset(0);

        row.on(fgui.Event.TOUCH_BEGIN, function (evt) {
            var active = self._swipeRow;
            touch.startX = evt.pos.x;
            touch.startY = evt.pos.y;
            touch.baseOffset = row.__swipeOffset || 0;
            touch.deltaX = 0;
            touch.deltaY = 0;
            touch.dragging = false;
            touch.dismissedOpenRow = !!(active && active !== row);
            touch.wasOpen = active === row;
            touch.startedOnDelete = !!(touch.wasOpen && evt.initiator &&
                (evt.initiator === deleteArea || deleteArea.isAncestorOf(evt.initiator)));
            touch.direction = 0;
            if (touch.dismissedOpenRow) active.closeSwipe();
            if (evt.captureTouch) evt.captureTouch();
        });
        row.on(fgui.Event.TOUCH_MOVE, function (evt) {
            touch.deltaX = evt.pos.x - touch.startX;
            touch.deltaY = evt.pos.y - touch.startY;
            if (!touch.direction) {
                var absX = Math.abs(touch.deltaX);
                var absY = Math.abs(touch.deltaY);
                // Lock the gesture direction early. A deliberately larger
                // horizontal threshold and strong axis bias keeps vertical
                // list scrolling from exposing the delete action.
                if (absY > 10 && absY > absX * 0.65) touch.direction = -1;
                else if (absX > 28 && absX > absY * 1.6) touch.direction = 1;
            }
            if (!touch.dragging && touch.direction === 1) {
                touch.dragging = true;
                if (fgui.GRoot.inst.inputProcessor) {
                    fgui.GRoot.inst.inputProcessor.cancelClick(evt.touchId);
                }
            }
            if (touch.dragging) {
                row.setSwipeOffset(touch.baseOffset + touch.deltaX);
                if (evt.stopPropagation) evt.stopPropagation();
            }
        });
        row.on(fgui.Event.TOUCH_END, function (evt) {
            if (touch.dragging) {
                if ((touch.baseOffset + touch.deltaX) < -deleteWidth / 2) row.openSwipe();
                else row.closeSwipe();
                if (evt.stopPropagation) evt.stopPropagation();
            } else if (touch.dismissedOpenRow) {
                if (fgui.GRoot.inst.inputProcessor) {
                    fgui.GRoot.inst.inputProcessor.cancelClick(evt.touchId);
                }
                row.closeSwipe();
            } else if (touch.wasOpen || self._swipeRow === row) {
                if (!touch.startedOnDelete && fgui.GRoot.inst.inputProcessor) {
                    fgui.GRoot.inst.inputProcessor.cancelClick(evt.touchId);
                }
                row.closeSwipe();
            }
        });
        row.on(fgui.Event.TOUCH_CANCEL, function (evt) {
            row.closeSwipe();
            if (evt.stopPropagation) evt.stopPropagation();
        });
        deleteArea.onClick(function () {
            row.closeSwipe();
            if (!self.busyName) self._confirmDelete(record);
        });
        return row;
    };

    IOS2AccountView.prototype._row = function (record, width, y) {
        var self = this;
        var rowHeight = 124;
        var active = this.busyName === record.name;
        var row = this._swipeDeleteItem(record, width, rowHeight, function (foreground) {
            foreground.addChild(graph(width, rowHeight,
                record.last ? cc.color(249, 253, 252, 255) : COLORS.surface,
                18, cc.color(234, 237, 243, 255)));
            var accountIcon = userIcon();
            accountIcon.setPosition(18, 17);
            foreground.addChild(accountIcon);
            var displayName = String(record.name || '').replace(/\.bin$/i, '') || '未命名账号';
            var name = text(displayName, 26, COLORS.text, Math.max(80, width - 178), 38);
            name.autoSize = fgui.AutoSizeType.Shrink;
            name.setPosition(64, 11);
            foreground.addChild(name);
            var details = formatDate(record.modified) || '时间未知';
            var detail = text('◷  ' + details, 17, COLORS.muted, Math.max(80, width - 178), 30);
            detail.autoSize = fgui.AutoSizeType.Shrink;
            detail.setPosition(64, 58);
            foreground.addChild(detail);
            var state = button(active ? '登录中…' : '待机', 102, 38,
                active ? COLORS.accentSoft : cc.color(229, 230, 232, 255),
                active ? COLORS.accent : cc.color(132, 136, 144, 255),
                function () { self.actions.login(record.name); }, 8);
            state.enabled = !self.busyName;
            state.setPosition(width - 128, 64);
            foreground.addChild(state);
        });
        row.setPosition(0, y);
        return row;
    };

    IOS2AccountView.prototype._gridCard = function (record, width, height, x, y) {
        var self = this;
        var card = this._swipeDeleteItem(record, width, height, function (foreground) {
            foreground.addChild(graph(width, height,
                record.last ? cc.color(249, 253, 252, 255) : COLORS.surface,
                18, cc.color(234, 237, 243, 255)));
            var icon = userIcon();
            icon.setPosition(18, height - 54);
            foreground.addChild(icon);
            var name = text(String(record.name || '').replace(/\.bin$/i, '') || '未命名账号', 22,
                COLORS.text, width - 72, 34);
            name.autoSize = fgui.AutoSizeType.Shrink;
            name.setPosition(60, height - 55);
            foreground.addChild(name);
            var detail = text('◷  ' + (formatDate(record.modified) || '时间未知'), 15, COLORS.muted,
                width - 32, 28);
            detail.autoSize = fgui.AutoSizeType.Shrink;
            detail.setPosition(16, height - 93);
            foreground.addChild(detail);
            var state = button(self.busyName === record.name ? '登录中…' : '待机', width - 32, 36,
                self.busyName === record.name ? COLORS.accentSoft : cc.color(229, 230, 232, 255),
                self.busyName === record.name ? COLORS.accent : cc.color(132, 136, 144, 255),
                function () { self.actions.login(record.name); }, 8);
            state.enabled = !self.busyName;
            state.setPosition(16, 18);
            foreground.addChild(state);
        });
        card.setPosition(x, y);
        return card;
    };

    IOS2AccountView.prototype._orderedAccounts = function () {
        var records = this.accounts.slice(0);
        var mode = this.sortMode;
        records.sort(function (left, right) {
            if (mode === 'name') return String(left.name || '').localeCompare(String(right.name || ''));
            var leftTime = Number(left.modified) || 0;
            var rightTime = Number(right.modified) || 0;
            if (mode === 'updated') return rightTime - leftTime;
            if (!!left.last !== !!right.last) return left.last ? -1 : 1;
            return rightTime - leftTime;
        });
        return records;
    };

    IOS2AccountView.prototype._toggleView = function () {
        this._saveNavigationState();
        this.viewMode = this.viewMode === 'grid' ? 'list' : 'grid';
        writePreference(this.storage, 'ios2.accountViewMode', this.viewMode);
        this.page = this._storedPage();
        this._build();
    };

    IOS2AccountView.prototype._showSortMenu = function () {
        var self = this;
        this._showQuickMenu('账号排序', [
            { key: 'recent', label: '最近使用', action: function () {
                self.sortMode = 'recent';
                writePreference(self.storage, 'ios2.accountSortMode', self.sortMode);
            } },
            { key: 'updated', label: '更新时间', action: function () {
                self.sortMode = 'updated';
                writePreference(self.storage, 'ios2.accountSortMode', self.sortMode);
            } },
            { key: 'name', label: '账号名称', action: function () {
                self.sortMode = 'name';
                writePreference(self.storage, 'ios2.accountSortMode', self.sortMode);
            } }
        ]);
    };

    IOS2AccountView.prototype._showGearMenu = function () {
        var self = this;
        var items = [
            { label: '运行配置', action: this.actions.openConfig }
        ];
        if (this.runtimeBackend === 'webkit') {
            items.unshift({ label: 'JS 脚本管理', action: this.actions.openScripts });
        }
        this._showQuickMenu('配置', items);
    };

    IOS2AccountView.prototype._showQuickMenu = function (headingText, items) {
        var self = this;
        var width = this.root.width;
        var height = this.root.height;
        var overlay = new fgui.GComponent();
        overlay.setSize(width, height);
        var backdrop = graph(width, height, cc.color(17, 27, 43, 70));
        overlay.addChild(backdrop);
        var panelWidth = Math.min(260, width - 32);
        var panelHeight = 58 + items.length * 52;
        var panel = new fgui.GComponent();
        panel.setSize(panelWidth, panelHeight);
        panel.setPosition(width - panelWidth - 18, 96 + this.layoutSafeTop);
        panel.addChild(graph(panelWidth, panelHeight, COLORS.surface, 16, COLORS.border));
        var heading = text(headingText, 18, COLORS.text, panelWidth - 32, 38);
        heading.setPosition(16, 8);
        panel.addChild(heading);
        for (var index = 0; index < items.length; index++) {
            (function (item, itemIndex) {
                var choice = button(item.label, panelWidth - 24, 44,
                    item.key && item.key === self.sortMode ? COLORS.accentSoft : COLORS.background,
                    item.key && item.key === self.sortMode ? COLORS.accent : COLORS.text,
                    function () {
                        overlay.dispose();
                        if (typeof item.action === 'function') item.action();
                        self.render();
                    }, 8);
                choice.setPosition(12, 49 + itemIndex * 52);
                panel.addChild(choice);
            }(items[index], index));
        }
        backdrop.onClick(function () { overlay.dispose(); });
        overlay.addChild(panel);
        this.root.addChild(overlay);
    };

    IOS2AccountView.prototype.render = function () {
        if (!this.list) return;
        // A freshly rebuilt ScrollPane starts at zero. Keep the stored offset
        // until the new content has been measured and can restore it below.
        if (this._hasRenderedContent) this._saveNavigationState();
        this._closeSwipeRow();
        this.list.removeChildren(0, -1, true);
        var width = this.list.width;
        var records = this._orderedAccounts();
        if (this.accountCount) this.accountCount.text = this.accounts.length + ' 个账号';
        var rowStep = this.viewMode === 'grid' ? 172 : 136;
        var columns = this.viewMode === 'grid' ? 2 : 1;
        var availableHeight = this.navigationMode === 'page' ? this.list.height - 70 : this.list.height;
        var perPage = Math.max(1, Math.floor(Math.max(rowStep, availableHeight) / rowStep) * columns);
        var pageCount = Math.max(1, Math.ceil(records.length / perPage));
        this.page = Math.max(0, Math.min(this.page, pageCount - 1));
        var start = this.page * perPage;
        var visible = this.navigationMode === 'page' ? records.slice(start, start + perPage) : records;
        if (!visible.length) {
            var empty = text('还没有账号，点击“导入账号”添加 .bin 文件', 20, COLORS.muted,
                width, 56, fgui.AlignType.Center);
            empty.setPosition(0, Math.max(24, this.list.height / 2 - 28));
            this.list.addChild(empty);
            this._hasRenderedContent = false;
            return;
        }
        if (this.viewMode === 'grid') {
            var gap = 12;
            var cardWidth = (width - gap) / 2;
            for (var gridIndex = 0; gridIndex < visible.length; gridIndex++) {
                var gridRow = Math.floor(gridIndex / 2);
                var gridColumn = gridIndex % 2;
                this.list.addChild(this._gridCard(visible[gridIndex], cardWidth, 158,
                    this.navigationMode === 'page' ? gridColumn * (cardWidth + gap) : 0,
                    this.navigationMode === 'page' ? gridRow * rowStep : 0));
            }
        } else {
            for (var index = 0; index < visible.length; index++) {
                this.list.addChild(this._row(visible[index], width,
                    this.navigationMode === 'page' ? index * rowStep : 0));
            }
        }
        if (this.navigationMode === 'scroll') {
            this.list.ensureBoundsCorrect();
            if (this.list.scrollPane) this.list.scrollPane.setPosY(this._storedScrollY(), false);
            this._saveNavigationState();
        } else {
            if (pageCount > 1) this._pagination(pageCount);
            this._saveNavigationState();
        }
        this._hasRenderedContent = true;
    };

    IOS2AccountView.prototype._pagination = function (pageCount) {
        var self = this;
        var width = this.list.width;
        var buttonWidth = 58;
        var buttonHeight = 52;
        var y = this.list.height - buttonHeight - 6;
        var previous = button('‹', buttonWidth, buttonHeight, COLORS.surface, COLORS.accent, function () {
            self.page--;
            self._saveNavigationState();
            self.render();
        }, 10);
        previous.tooltips = (fgui.UIConfig && fgui.UIConfig.tooltipsWin) ? '上一页' : '';
        previous.enabled = this.page > 0;
        previous.setPosition(width / 2 - 112, y);
        this.list.addChild(previous);
        var count = text((this.page + 1) + ' / ' + pageCount, 17, COLORS.muted, 92, buttonHeight,
            fgui.AlignType.Center);
        count.setPosition(width / 2 - 46, y);
        this.list.addChild(count);
        var next = button('›', buttonWidth, buttonHeight, COLORS.surface, COLORS.accent, function () {
            self.page++;
            self._saveNavigationState();
            self.render();
        }, 10);
        next.tooltips = (fgui.UIConfig && fgui.UIConfig.tooltipsWin) ? '下一页' : '';
        next.enabled = this.page < pageCount - 1;
        next.setPosition(width / 2 + 54, y);
        this.list.addChild(next);
    };

    IOS2AccountView.prototype._confirmDelete = function (record) {
        var self = this;
        var width = this.root.width;
        var height = this.root.height;
        var overlay = new fgui.GComponent();
        overlay.setSize(width, height);
        overlay.opaque = true;
        overlay.addChild(graph(width, height, cc.color(16, 24, 36, 132)));
        var panelWidth = Math.min(width - 48, 430);
        var panel = new fgui.GComponent();
        panel.setSize(panelWidth, 190);
        panel.setPosition((width - panelWidth) / 2, (height - 190) / 2);
        panel.addChild(graph(panelWidth, 190, COLORS.surface, 8, COLORS.border));
        var heading = text('删除账号文件？', 23, COLORS.text, panelWidth - 40, 42, fgui.AlignType.Center);
        heading.fontSize = 25;
        heading.setPosition(20, 22);
        panel.addChild(heading);
        var message = text(String(record.name || ''), 18, COLORS.muted, panelWidth - 40, 34, fgui.AlignType.Center);
        message.setPosition(20, 68);
        panel.addChild(message);
        var close = function () { overlay.dispose(); };
        var cancel = button('取消', 118, 44, COLORS.background, COLORS.text, close, 8);
        cancel.setPosition(panelWidth / 2 - 128, 122);
        panel.addChild(cancel);
        var confirm = button('删除', 118, 44, COLORS.danger, cc.Color.WHITE, function () {
            close();
            self.actions.remove(record.name);
        }, 8);
        confirm.setPosition(panelWidth / 2 + 10, 122);
        panel.addChild(confirm);
        overlay.addChild(panel);
        this.root.addChild(overlay);
    };

    IOS2AccountView.prototype._showMultiOpen = function () {
        var self = this;
        var width = this.root.width;
        var height = this.root.height;
        var records = this._orderedAccounts();
        var overlay = new fgui.GComponent();
        overlay.setSize(width, height);
        overlay.opaque = true;
        overlay.addChild(graph(width, height, cc.color(8, 12, 18, 154)));

        var sheetTop = Math.max(this.layoutSafeTop + 84, Math.floor(height * 0.06));
        var panelWidth = width;
        var panelHeight = height - sheetTop;
        var sideMargin = Math.max(20, Math.min(40, Math.floor(width * 0.04)));
        var navHeight = height > 1200 ? 96 : 84;
        var rowHeight = Math.max(72, Math.min(110, Math.floor(height * 0.043)));
        var iconSize = Math.max(34, Math.min(50, Math.floor(rowHeight * 0.48)));
        var listWidth = panelWidth - sideMargin * 2;

        var panel = new fgui.GComponent();
        panel.setSize(panelWidth, panelHeight);
        panel.setPosition(0, sheetTop);
        panel.addChild(graph(panelWidth, panelHeight, cc.color(248, 249, 253, 255), 18));
        var selected = [];
        var minSelection = 2;
        var maxSelection = 4;

        var nav = new fgui.GComponent();
        nav.setSize(panelWidth, navHeight);
        nav.addChild(graph(panelWidth, navHeight, cc.color(248, 249, 253, 255)));
        panel.addChild(nav);

        var cancel = new fgui.GComponent();
        cancel.setSize(88, navHeight);
        cancel.opaque = true;
        cancel.addChild(text('取消', 27, COLORS.accent, 88, navHeight, fgui.AlignType.Center));
        cancel.setPosition(Math.max(0, sideMargin - 16), 0);
        nav.addChild(cancel);

        var heading = text('', 28, cc.color(0, 0, 0, 255), Math.max(120, panelWidth - 230), navHeight,
            fgui.AlignType.Center);
        heading.fontSize = 30;
        heading.bold = true;
        heading.setPosition((panelWidth - heading.width) / 2, 0);
        nav.addChild(heading);

        var confirm = new fgui.GComponent();
        confirm.setSize(88, navHeight);
        confirm.opaque = true;
        confirm.addChild(text('启动', 27, COLORS.accent, 88, navHeight, fgui.AlignType.Center));
        confirm.setPosition(panelWidth - sideMargin - 72, 0);
        nav.addChild(confirm);
        nav.addChild(graph(panelWidth, 1, cc.color(226, 228, 234, 255))).setPosition(0, navHeight - 1);

        var list = new fgui.GList();
        list.setPosition(sideMargin, navHeight);
        list.setSize(listWidth, Math.max(rowHeight, panelHeight - navHeight));
        list.layout = fgui.ListLayoutType.SingleColumn;
        list.lineGap = 0;
        list.selectionMode = fgui.ListSelectionMode.None;
        list.scrollItemToViewOnClick = false;
        list.setupScroll(verticalScrollBuffer());
        panel.addChild(graph(listWidth, Math.max(rowHeight, panelHeight - navHeight), COLORS.surface, 18))
            .setPosition(sideMargin, navHeight);
        panel.addChild(list);

        var close = function () { overlay.dispose(); };
        cancel.onClick(close);
        confirm.onClick(function () {
            if (selected.length < minSelection || selected.length > maxSelection) return;
            close();
            self.actions.multiOpen(selected.slice(0));
        });

        function updateHeader() {
            var ready = selected.length >= minSelection && selected.length <= maxSelection;
            heading.text = '群控启动（' + selected.length + '/' + maxSelection + '）';
            confirm.visible = ready;
            confirm.touchable = ready;
        }

        function refreshRows() {
            var scrollY = list.scrollPane ? list.scrollPane.posY : 0;
            list.removeChildren(0, -1, true);
            if (!records.length) {
                var empty = text('还没有可用 bin 文件', 22, COLORS.muted, listWidth, 88,
                    fgui.AlignType.Center);
                empty.setPosition(0, Math.max(0, list.height / 2 - 44));
                list.addChild(empty);
                list.ensureBoundsCorrect();
                updateHeader();
                return;
            }
            for (var index = 0; index < records.length; index++) {
                (function (record, rowIndex) {
                    var checked = selected.indexOf(record.name) >= 0;
                    var row = new fgui.GComponent();
                    row.__ios2AccountName = record.name;
                    row.setSize(listWidth, rowHeight);
                    row.opaque = true;
                    row.addChild(graph(listWidth, rowHeight,
                        checked ? cc.color(207, 208, 212, 255) : COLORS.surface));

                    var marker = checkCircle(checked, iconSize);
                    marker.setPosition(Math.max(18, Math.floor(sideMargin * 0.95)),
                        Math.floor((rowHeight - iconSize) / 2));
                    row.addChild(marker);

                    var label = text(accountDisplayName(record), Math.max(25, Math.min(38, Math.floor(rowHeight * 0.36))),
                        cc.color(0, 0, 0, 255), listWidth - marker.x - iconSize - 44,
                        rowHeight, fgui.AlignType.Left);
                    label.autoSize = fgui.AutoSizeType.Shrink;
                    label.setPosition(marker.x + iconSize + 42, 0);
                    row.addChild(label);

                    if (!checked && rowIndex < records.length - 1) {
                        var line = graph(listWidth - marker.x - iconSize - 42, 1, cc.color(222, 222, 224, 255));
                        line.setPosition(marker.x + iconSize + 42, rowHeight - 1);
                        row.addChild(line);
                    }

                    list.addChild(row);
                }(records[index], index));
            }
            list.ensureBoundsCorrect();
            if (list.scrollPane) list.scrollPane.setPosY(scrollY, false);
            updateHeader();
        }
        list.on(fgui.Event.CLICK_ITEM, function (item) {
            if (!item || !item.__ios2AccountName) return;
            var selectedIndex = selected.indexOf(item.__ios2AccountName);
            if (selectedIndex >= 0) selected.splice(selectedIndex, 1);
            else {
                if (selected.length >= maxSelection) return;
                selected.push(item.__ios2AccountName);
            }
            refreshRows();
        });
        refreshRows();
        overlay.addChild(panel);
        this.root.addChild(overlay);
    };

    IOS2AccountView.prototype.setAccounts = function (accounts) {
        this.accounts = Array.isArray(accounts) ? accounts.slice(0) : [];
        this.render();
    };

    IOS2AccountView.prototype.setBusy = function (accountName) {
        this.busyName = accountName || '';
        this.render();
    };

    IOS2AccountView.prototype.setStatus = function (message, tone) {
        if (!this.status) return;
        this.status.text = String(message || '');
        this.status.color = COLORS[tone] || COLORS.muted;
    };

    IOS2AccountView.prototype.setRuntimeBackend = function (backend) {
        var next = String(backend || 'native');
        if (next === this.runtimeBackend) return;
        this._saveNavigationState();
        this.runtimeBackend = next;
        this._build();
    };

    IOS2AccountView.prototype.show = function () {
        var configuredMode = readPreference(this.storage, 'ios2.accountNavigationMode', 'page', ['scroll', 'page']);
        if (configuredMode !== this.navigationMode) {
            this._saveNavigationState();
            this.navigationMode = configuredMode;
            this.page = this._storedPage();
            this._build();
        }
        if (this.layoutWidth !== fgui.GRoot.inst.width || this.layoutHeight !== fgui.GRoot.inst.height ||
            this.layoutSafeTop !== safeAreaTop(fgui.GRoot.inst.width, fgui.GRoot.inst.height)) {
            this._saveNavigationState();
            this._build();
        }
        this.root.visible = true;
    };
    IOS2AccountView.prototype.hide = function () { this.root.visible = false; };

    global.IOS2AccountView = IOS2AccountView;
}(window));
