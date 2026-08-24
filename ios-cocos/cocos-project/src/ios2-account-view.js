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
        if (month.length < 2) month = '0' + month;
        if (day.length < 2) day = '0' + day;
        return date.getFullYear() + '-' + month + '-' + day;
    }

    function IOS2AccountView(actions) {
        this.actions = actions || {};
        this.accounts = [];
        this.page = 0;
        this.busyName = '';
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
        this.root.setSize(width, height);
        this.root.addChild(graph(width, height, COLORS.background));

        var top = 44;
        var title = text('账号管理', 34, COLORS.text, width - 48, 52);
        title.bold = true;
        title.setPosition(24, top);
        this.root.addChild(title);
        var subtitle = text('选择本机账号文件登录', 16, COLORS.muted, width - 48, 30);
        subtitle.setPosition(25, top + 48);
        this.root.addChild(subtitle);

        var importButton = button('＋  导入账号', 142, 48, COLORS.accent, cc.Color.WHITE,
            this.actions.importAccounts, 8);
        importButton.setPosition(width - 166, top + 12);
        this.root.addChild(importButton);
        var backend = 'native';
        try { backend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native'); }
        catch (ignored) {}
        this.runtimeBackend = backend;
        if (backend === 'webkit') {
            var multiButton = button('多开', 92, 48, COLORS.success, cc.Color.WHITE,
                this._showMultiOpen.bind(this), 8);
            multiButton.setPosition(width - 274, top + 12);
            this.root.addChild(multiButton);
        }

        this.list = new fgui.GComponent();
        this.list.setPosition(20, top + 104);
        this.list.setSize(width - 40, Math.max(150, height - top - 230));
        this.root.addChild(this.list);

        this.status = text('', 15, COLORS.muted, width - 48, 34);
        this.status.setPosition(24, height - 105);
        this.root.addChild(this.status);
        this._buildNavigation(width, height);
        this.render();
    };

    IOS2AccountView.prototype._buildNavigation = function (width, height) {
        var navY = height - 68;
        this.root.addChild(graph(width, 68, COLORS.surface, 0, COLORS.border)).setPosition(0, navY);
        var labels = ['账号', 'JS 脚本', '配置'];
        var actions = [null, this.actions.openScripts, this.actions.openConfig];
        for (var index = 0; index < labels.length; index++) {
            var color = index === 0 ? COLORS.accent : COLORS.muted;
            var nav = button(labels[index], width / 3, 64, COLORS.surface, color, actions[index], 0);
            nav.setPosition(index * width / 3, navY + 4);
            this.root.addChild(nav);
        }
        var indicator = graph(Math.max(44, width / 3 - 76), 3, COLORS.accent, 2);
        indicator.setPosition(38, navY);
        this.root.addChild(indicator);
    };

    IOS2AccountView.prototype._row = function (record, width, y) {
        var self = this;
        var row = new fgui.GComponent();
        var rowHeight = 82;
        var active = this.busyName === record.name;
        row.setSize(width, rowHeight);
        row.setPosition(0, y);
        row.addChild(graph(width, rowHeight, record.last ? cc.color(239, 249, 245, 255) : COLORS.surface,
            8, COLORS.border));

        var dot = graph(10, 10, record.last ? COLORS.success : COLORS.accent, 5);
        dot.setPosition(18, 22);
        row.addChild(dot);
        var displayName = String(record.name || '').replace(/\.bin$/i, '') || '未命名账号';
        var name = text(displayName, 20, COLORS.text, Math.max(80, width - 244), 32);
        name.bold = true;
        name.setPosition(40, 10);
        row.addChild(name);
        var details = [formatSize(record.size), formatDate(record.modified)].filter(Boolean).join('  ·  ');
        var detail = text((record.last ? '最近使用  ·  ' : '') + details, 14, COLORS.muted,
            Math.max(80, width - 244), 26);
        detail.setPosition(40, 43);
        row.addChild(detail);

        var login = button(active ? '登录中…' : '登录', 82, 44,
            active ? COLORS.accentSoft : COLORS.accent,
            active ? COLORS.accent : cc.Color.WHITE,
            function () { self.actions.login(record.name); }, 8);
        login.enabled = !this.busyName;
        login.setPosition(width - 144, 19);
        row.addChild(login);
        var remove = button('×', 44, 44, cc.color(250, 237, 237, 255), COLORS.danger,
            function () { self._confirmDelete(record); }, 8);
        remove.enabled = !this.busyName;
        remove.setPosition(width - 54, 19);
        row.addChild(remove);
        return row;
    };

    IOS2AccountView.prototype.render = function () {
        if (!this.list) return;
        this.list.removeChildren(0, -1, true);
        var width = this.list.width;
        var rowStep = 92;
        var perPage = Math.max(1, Math.floor(this.list.height / rowStep));
        var pageCount = Math.max(1, Math.ceil(this.accounts.length / perPage));
        this.page = Math.max(0, Math.min(this.page, pageCount - 1));
        var start = this.page * perPage;
        var visible = this.accounts.slice(start, start + perPage);
        if (!visible.length) {
            var empty = text('还没有账号，点击“导入账号”添加 .bin 文件', 18, COLORS.muted,
                width, 56, fgui.AlignType.Center);
            empty.setPosition(0, Math.max(24, this.list.height / 2 - 28));
            this.list.addChild(empty);
            return;
        }
        for (var index = 0; index < visible.length; index++) {
            this.list.addChild(this._row(visible[index], width, index * rowStep));
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
        if (backend !== this.runtimeBackend) this._build();
        this.root.visible = true;
    };
    IOS2AccountView.prototype.hide = function () { this.root.visible = false; };

    global.IOS2AccountView = IOS2AccountView;
}(window));