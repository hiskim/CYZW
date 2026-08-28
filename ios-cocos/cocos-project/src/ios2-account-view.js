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

    function graph(width, height, fill, radius, border) {
        var item = new fgui.GGraph();
        item.setSize(width, height);
        item.drawRect(border ? 1 : 0, border || cc.Color.TRANSPARENT, fill, radius ? [radius] : null);
        return item;
    }

    function text(value, fontSize, color, width, height, align) {
        var item = new fgui.GTextField();
        item.autoSize = fgui.AutoSizeType.None;
        item.setSize(width, height);
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
        item.addChild(text(caption, 17, color, width, height, fgui.AlignType.Center));
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
        item.tooltips = tooltip || '';
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

    function IOS2AccountView(actions) {
        this.actions = actions || {};
        this.accounts = [];
        this.page = 0;
        this.busyName = '';
        this.viewMode = 'list';
        this.sortMode = 'recent';
        this.root = new fgui.GComponent();
        this.root.name = 'IOS2AccountHome';
        this.root.opaque = true;
        this._build();
        fgui.GRoot.inst.addChild(this.root);
    }

    IOS2AccountView.prototype._build = function () {
        this.root.removeChildren(0, -1, true);
        var width = fgui.GRoot.inst.width;
        var height = fgui.GRoot.inst.height;
        this.layoutWidth = width;
        this.layoutHeight = height;
        this.root.setSize(width, height);
        this.root.addChild(graph(width, height, COLORS.background));

        var top = 40;
        var compact = width < 360;
        var toolbarSize = compact ? 38 : 46;
        var toolbarGap = compact ? 5 : 9;
        var title = text('账号管理', compact ? 26 : 31, COLORS.text,
            Math.max(112, width - (toolbarSize * 4 + toolbarGap * 3 + 48)), 48);
        title.bold = true;
        title.setPosition(28, top);
        this.root.addChild(title);

        var toolbarRight = width - (compact ? 14 : 22);
        var gear = iconButton('⚙', toolbarSize, this._showGearMenu.bind(this), '打开脚本与配置');
        gear.setPosition(toolbarRight - toolbarSize, top - 2);
        this.root.addChild(gear);
        var sort = iconButton('↕', toolbarSize, this._showSortMenu.bind(this), '排序账号');
        sort.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 2, top - 2);
        this.root.addChild(sort);
        var mode = gridIcon(toolbarSize, this.viewMode === 'grid');
        mode.tooltips = this.viewMode === 'grid' ? '切换列表视图' : '切换多块视图';
        mode.onClick(this._toggleView.bind(this));
        mode.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 3, top - 2);
        this.root.addChild(mode);
        var importButton = iconButton('+', toolbarSize, this.actions.importAccounts, '导入账号');
        importButton.setPosition(toolbarRight - (toolbarSize + toolbarGap) * 4, top - 2);
        this.root.addChild(importButton);
        var backend = 'native';
        try { backend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native'); }
        catch (ignored) {}
        this.runtimeBackend = backend;
        if (backend === 'webkit') {
            var multiButton = button('多开', 82, 40, COLORS.success, cc.Color.WHITE,
                this._showMultiOpen.bind(this), 8);
            multiButton.setPosition(width - 116, top + 56);
            this.root.addChild(multiButton);
        }

        var groupTitle = text('本机账号', 20, COLORS.text, 180, 38);
        groupTitle.bold = true;
        groupTitle.setPosition(30, top + 74);
        this.root.addChild(groupTitle);
        this.accountCount = text('', 14, COLORS.muted, 120, 34, fgui.AlignType.Right);
        this.accountCount.setPosition(width - 150, top + 77);
        this.root.addChild(this.accountCount);

        this.list = new fgui.GComponent();
        this.list.setPosition(24, top + 116);
        this.list.setSize(width - 48, Math.max(190, height - top - 188));
        this.list.overflow = fgui.OverflowType.Hidden;
        this.root.addChild(this.list);

        this.status = text('', 14, COLORS.muted, width - 48, 32);
        this.status.setPosition(24, height - 48);
        this.root.addChild(this.status);
        this.render();
    };

    IOS2AccountView.prototype._row = function (record, width, y) {
        var self = this;
        var row = new fgui.GComponent();
        var rowHeight = 124;
        var active = this.busyName === record.name;
        row.setSize(width, rowHeight);
        row.setPosition(0, y);
        row.addChild(graph(width, rowHeight, record.last ? cc.color(249, 253, 252, 255) : COLORS.surface,
            18, cc.color(234, 237, 243, 255)));
        var accountIcon = userIcon();
        accountIcon.setPosition(18, 17);
        row.addChild(accountIcon);
        var displayName = String(record.name || '').replace(/\.bin$/i, '') || '未命名账号';
        var name = text(displayName, 22, COLORS.text, Math.max(80, width - 178), 34);
        name.bold = true;
        name.setPosition(64, 15);
        row.addChild(name);
        var details = formatDate(record.modified) || '时间未知';
        var detail = text('◷  ' + details, 15, COLORS.muted, Math.max(80, width - 178), 28);
        detail.setPosition(64, 58);
        row.addChild(detail);
        var state = button(active ? '登录中…' : '待机', 102, 38,
            active ? COLORS.accentSoft : cc.color(229, 230, 232, 255),
            active ? COLORS.accent : cc.color(132, 136, 144, 255),
            function () { self.actions.login(record.name); }, 8);
        state.enabled = !this.busyName;
        state.setPosition(width - 128, 64);
        row.addChild(state);
        var remove = new fgui.GComponent();
        remove.setSize(34, 34);
        remove.tooltips = '删除账号';
        remove.addChild(graph(34, 34, cc.Color.TRANSPARENT, 17));
        remove.addChild(trashIcon(COLORS.danger)).setPosition(2, 2);
        remove.onClick(function () {
            if (remove.enabled) self._confirmDelete(record);
        });
        remove.enabled = !this.busyName;
        remove.setPosition(width - 50, 14);
        row.addChild(remove);
        return row;
    };

    IOS2AccountView.prototype._gridCard = function (record, width, height, x, y) {
        var self = this;
        var card = new fgui.GComponent();
        card.setSize(width, height);
        card.setPosition(x, y);
        card.addChild(graph(width, height, record.last ? cc.color(249, 253, 252, 255) : COLORS.surface,
            18, cc.color(234, 237, 243, 255)));
        var icon = userIcon();
        icon.setPosition(18, height - 54);
        card.addChild(icon);
        var name = text(String(record.name || '').replace(/\.bin$/i, '') || '未命名账号', 19,
            COLORS.text, width - 72, 30);
        name.bold = true;
        name.setPosition(60, height - 53);
        card.addChild(name);
        var detail = text('◷  ' + (formatDate(record.modified) || '时间未知'), 13, COLORS.muted,
            width - 32, 26);
        detail.setPosition(16, height - 91);
        card.addChild(detail);
        var state = button(this.busyName === record.name ? '登录中…' : '待机', width - 32, 36,
            this.busyName === record.name ? COLORS.accentSoft : cc.color(229, 230, 232, 255),
            this.busyName === record.name ? COLORS.accent : cc.color(132, 136, 144, 255),
            function () { self.actions.login(record.name); }, 8);
        state.enabled = !this.busyName;
        state.setPosition(16, 18);
        card.addChild(state);
        var remove = new fgui.GComponent();
        remove.setSize(30, 30);
        remove.tooltips = '删除账号';
        remove.addChild(graph(30, 30, cc.Color.TRANSPARENT, 15));
        remove.addChild(trashIcon(COLORS.danger)).setPosition(0, 0);
        remove.enabled = !this.busyName;
        remove.onClick(function () { if (remove.enabled) self._confirmDelete(record); });
        remove.setPosition(width - 42, height - 42);
        card.addChild(remove);
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
        this.viewMode = this.viewMode === 'grid' ? 'list' : 'grid';
        this.page = 0;
        this._build();
    };

    IOS2AccountView.prototype._showSortMenu = function () {
        var self = this;
        this._showQuickMenu('账号排序', [
            { key: 'recent', label: '最近使用', action: function () { self.sortMode = 'recent'; } },
            { key: 'updated', label: '更新时间', action: function () { self.sortMode = 'updated'; } },
            { key: 'name', label: '账号名称', action: function () { self.sortMode = 'name'; } }
        ]);
    };

    IOS2AccountView.prototype._showGearMenu = function () {
        var self = this;
        this._showQuickMenu('配置', [
            { label: 'JS 脚本管理', action: this.actions.openScripts },
            { label: '运行配置', action: this.actions.openConfig }
        ]);
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
        panel.setPosition(width - panelWidth - 18, 96);
        panel.addChild(graph(panelWidth, panelHeight, COLORS.surface, 16, COLORS.border));
        var heading = text(headingText, 18, COLORS.text, panelWidth - 32, 38);
        heading.bold = true;
        heading.setPosition(16, 10);
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
        this.list.removeChildren(0, -1, true);
        var width = this.list.width;
        var records = this._orderedAccounts();
        if (this.accountCount) this.accountCount.text = this.accounts.length + ' 个账号';
        var rowStep = this.viewMode === 'grid' ? 172 : 136;
        var columns = this.viewMode === 'grid' ? 2 : 1;
        var perPage = Math.max(1, Math.floor(this.list.height / rowStep) * columns);
        var pageCount = Math.max(1, Math.ceil(records.length / perPage));
        this.page = Math.max(0, Math.min(this.page, pageCount - 1));
        var start = this.page * perPage;
        var visible = records.slice(start, start + perPage);
        if (!visible.length) {
            var empty = text('还没有账号，点击“导入账号”添加 .bin 文件', 18, COLORS.muted,
                width, 56, fgui.AlignType.Center);
            empty.setPosition(0, Math.max(24, this.list.height / 2 - 28));
            this.list.addChild(empty);
            return;
        }
        if (this.viewMode === 'grid') {
            var gap = 12;
            var cardWidth = (width - gap) / 2;
            for (var gridIndex = 0; gridIndex < visible.length; gridIndex++) {
                var gridRow = Math.floor(gridIndex / 2);
                var gridColumn = gridIndex % 2;
                this.list.addChild(this._gridCard(visible[gridIndex], cardWidth, 158,
                    gridColumn * (cardWidth + gap), gridRow * rowStep));
            }
        } else {
            for (var index = 0; index < visible.length; index++) {
                this.list.addChild(this._row(visible[index], width, index * rowStep));
            }
        }
        if (pageCount > 1) this._pagination(pageCount);
    };

    IOS2AccountView.prototype._pagination = function (pageCount) {
        var self = this;
        var width = this.list.width;
        var y = this.list.height - 46;
        var previous = button('‹', 42, 38, COLORS.surface, COLORS.accent, function () {
            self.page--;
            self.render();
        }, 8);
        previous.enabled = this.page > 0;
        previous.setPosition(width / 2 - 82, y);
        this.list.addChild(previous);
        var count = text((this.page + 1) + ' / ' + pageCount, 15, COLORS.muted, 76, 38, fgui.AlignType.Center);
        count.setPosition(width / 2 - 38, y);
        this.list.addChild(count);
        var next = button('›', 42, 38, COLORS.surface, COLORS.accent, function () {
            self.page++;
            self.render();
        }, 8);
        next.enabled = this.page < pageCount - 1;
        next.setPosition(width / 2 + 40, y);
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
        heading.bold = true;
        heading.setPosition(20, 22);
        panel.addChild(heading);
        var message = text(String(record.name || ''), 16, COLORS.muted, panelWidth - 40, 32, fgui.AlignType.Center);
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
        var overlay = new fgui.GComponent();
        overlay.setSize(width, height);
        overlay.opaque = true;
        overlay.addChild(graph(width, height, cc.color(16, 24, 36, 132)));
        var panelWidth = Math.min(width - 36, 460);
        var visibleCount = Math.min(this.accounts.length, 8);
        var panelHeight = Math.min(height - 80, 154 + visibleCount * 52);
        var panel = new fgui.GComponent();
        panel.setSize(panelWidth, panelHeight);
        panel.setPosition((width - panelWidth) / 2, (height - panelHeight) / 2);
        panel.addChild(graph(panelWidth, panelHeight, COLORS.surface, 8, COLORS.border));
        var heading = text('选择 2 到 4 个账号', 23, COLORS.text, panelWidth - 40, 42, fgui.AlignType.Center);
        heading.bold = true;
        heading.setPosition(20, 16);
        panel.addChild(heading);
        var selected = [];
        var list = new fgui.GComponent();
        list.setPosition(20, 62);
        list.setSize(panelWidth - 40, panelHeight - 132);
        list.overflow = fgui.OverflowType.Scroll;
        panel.addChild(list);
        function refreshRows() {
            list.removeChildren(0, -1, true);
            for (var index = 0; index < self.accounts.length; index++) {
                (function (record, rowIndex) {
                    var checked = selected.indexOf(record.name) >= 0;
                    var row = button((checked ? '✓  ' : '○  ') + String(record.name || '').replace(/\.bin$/i, ''),
                        panelWidth - 40, 46, checked ? COLORS.accentSoft : COLORS.background,
                        checked ? COLORS.accent : COLORS.text, function () {
                            var selectedIndex = selected.indexOf(record.name);
                            if (selectedIndex >= 0) selected.splice(selectedIndex, 1);
                            else if (selected.length < 4) selected.push(record.name);
                            refreshRows();
                        }, 6);
                    row.setPosition(0, rowIndex * 52);
                    list.addChild(row);
                }(self.accounts[index], index));
            }
        }
        refreshRows();
        var close = function () { overlay.dispose(); };
        var cancel = button('取消', 118, 44, COLORS.background, COLORS.text, close, 8);
        cancel.setPosition(panelWidth / 2 - 128, panelHeight - 60);
        panel.addChild(cancel);
        var confirm = button('启动多开', 118, 44, COLORS.success, cc.Color.WHITE, function () {
            if (selected.length < 2 || selected.length > 4) {
                self.setStatus('请选择 2 到 4 个账号', 'warning');
                return;
            }
            close();
            self.actions.multiOpen(selected.slice(0));
        }, 8);
        confirm.setPosition(panelWidth / 2 + 10, panelHeight - 60);
        panel.addChild(confirm);
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

    IOS2AccountView.prototype.show = function () {
        var backend = 'native';
        try { backend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native'); }
        catch (ignored) {}
        if (backend !== this.runtimeBackend || this.layoutWidth !== fgui.GRoot.inst.width ||
            this.layoutHeight !== fgui.GRoot.inst.height) this._build();
        this.root.visible = true;
    };
    IOS2AccountView.prototype.hide = function () { this.root.visible = false; };

    global.IOS2AccountView = IOS2AccountView;
}(window));
