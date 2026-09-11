/* Configuration management page. Definitions and rendering are intentionally separate. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;
    var DISABLED_TEXT = cc.color(164, 173, 186, 255);
    var DISABLED_SURFACE = cc.color(239, 242, 246, 255);
    var QUALITY_LEVELS = ['low', 'medium', 'high'];
    var QUALITY_LABELS = { low: '低', medium: '中', high: '高' };
    var FRAME_RATES = ['30', '45', '60'];
    var QUALITY_SINGLE_KEY = 'ios2.renderQuality.single';
    var QUALITY_MULTI_KEY = 'ios2.renderQuality.multi';
    var INSTANCE_TARGET_KEY = 'ios2.webInstanceTarget';

    function nativeCall(method, value, hasValue) {
        if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return null;
        try { return hasValue ? jsb.reflection.callStaticMethod('IOS2Native', method + ':', value) : jsb.reflection.callStaticMethod('IOS2Native', method); }
        catch (ignored) { return null; }
    }
    function storageGet(storage, key, fallback) {
        if (!storage) return fallback;
        try { var value = storage.getItem(key); return value === null || value === undefined || value === '' ? fallback : value; }
        catch (ignored) { return fallback; }
    }
    function storageSet(storage, key, value) {
        try { if (storage) storage.setItem(key, String(value)); return true; } catch (ignored) { return false; }
    }
    function normalizeQuality(value, fallback) {
        value = String(value || '');
        return QUALITY_LEVELS.indexOf(value) >= 0 ? value : fallback;
    }
    function readQuality(storage, nativeMethod, key, fallback) {
        var value = nativeCall(nativeMethod);
        if (QUALITY_LEVELS.indexOf(String(value || '')) < 0) value = storageGet(storage, key, fallback);
        return normalizeQuality(value, fallback);
    }
    function writeQuality(storage, nativeMethod, key, value, fallback) {
        value = normalizeQuality(value, fallback);
        storageSet(storage, key, value);
        return nativeCall(nativeMethod, value, true) !== null || !(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod);
    }
    function readBoolean(storage, key, nativeMethod, fallback) {
        var value = nativeCall(nativeMethod);
        if (value === null || value === undefined) return storageGet(storage, key, fallback ? '1' : '0') === '1';
        return !!value;
    }
    function readState(storage) {
        var backend = String(nativeCall('runtimeBackend') || 'native');
        var frameRate = Number(nativeCall('preferredFrameRate'));
        if (FRAME_RATES.indexOf(String(frameRate)) < 0) frameRate = Number(storageGet(storage, 'ios2.frameRate', '60'));
        if (FRAME_RATES.indexOf(String(frameRate)) < 0) frameRate = 60;
        var startup = String(nativeCall('webGameStartupMode') || storageGet(storage, 'ios2.webStartupMode', 'serial'));
        var layout = String(nativeCall('webGameLayoutMode') || storageGet(storage, 'ios2.webLayoutMode', 'split'));
        var navigation = String(storageGet(storage, 'ios2.accountNavigationMode', 'page'));
        var target = Number(storageGet(storage, INSTANCE_TARGET_KEY, '4'));
        return {
            backend: backend === 'webkit' ? 'webkit' : 'native',
            singleQuality: backend === 'webkit' ? readQuality(storage, 'renderQualitySingle', QUALITY_SINGLE_KEY, 'high') : 'high',
            multiQuality: backend === 'webkit' ? readQuality(storage, 'renderQualityMulti', QUALITY_MULTI_KEY, 'medium') : 'medium',
            frameRate: String(frameRate),
            autoRestore: storageGet(storage, 'ios2.autoRestore', '1') !== '0',
            showFPS: readBoolean(storage, 'ios2.showFPS', 'showFPS', false),
            hsdkVerboseDebug: readBoolean(storage, 'ios2.hsdkVerboseDebug', 'hsdkVerboseDebug', false),
            webInstanceTarget: Math.max(2, Math.min(4, isFinite(target) ? target : 4)),
            webGameInstances: Number(nativeCall('webGameInstanceCount')) || 0,
            webStartupMode: startup === 'parallel' ? 'parallel' : 'serial',
            webLayoutMode: layout === 'stacked' ? 'stacked' : 'split',
            accountNavigationMode: navigation === 'scroll' ? 'scroll' : 'page'
        };
    }
    function setText(node, value, color) {
        if (!node) return;
        if (node.__ios2LabelComponent) node.__ios2LabelComponent.string = String(value);
        if (color) node.setColor(color);
    }

    function qualitySlider(width, height, value, onValue, onCommit) {
        if (!global.fgui || !global.fgui.GSlider) return null;
        var slider = new global.fgui.GSlider();
        var trackHeight = 8, gripSize = 34, gripInset = gripSize / 2;
        var travelWidth = Math.max(1, width - gripSize);
        slider.name = 'IOS2RenderQualitySlider'; slider.setSize(width, height); slider.node.setAnchorPoint(0, 0);
        var track = new global.fgui.GGraph(); track.setSize(travelWidth, trackHeight); track.node.setAnchorPoint(0, 0); track.drawRect(0, cc.Color.TRANSPARENT, cc.color(181, 207, 245, 255), 3); track.node.setPosition(gripInset, Math.floor((height - trackHeight) / 2));
        var fill = new global.fgui.GGraph(); fill.setSize(travelWidth, trackHeight); fill.node.setAnchorPoint(0, 0); fill.drawRect(0, cc.Color.TRANSPARENT, COLORS.accent, 3); fill.node.setPosition(gripInset, Math.floor((height - trackHeight) / 2));
        var grip = new global.fgui.GGraph(); grip.setSize(gripSize, gripSize); grip.node.setAnchorPoint(0, 0); grip.drawEllipse(2, COLORS.accent, cc.Color.WHITE);
        slider.addChild(track); slider.addChild(fill); slider.addChild(grip);
        slider._barObjectH = null; slider._gripObject = grip; slider._barMaxWidth = travelWidth; slider._barMaxWidthDelta = 0; slider._barStartX = 0; slider.min = 0; slider.max = 2; slider.wholeNumbers = true;
        var render = function () { var percent = slider.max > slider.min ? (slider.value - slider.min) / (slider.max - slider.min) : 0; percent = Math.max(0, Math.min(1, percent)); fill.setSize(Math.max(0, travelWidth * percent), trackHeight); grip.node.setPosition(gripInset + travelWidth * percent - gripSize / 2, (height - gripSize) / 2); };
        slider.update = render; slider.value = QUALITY_LEVELS.indexOf(normalizeQuality(value, 'high')); render();
        var committedValue = normalizeQuality(value, 'high');
        var commit = function (next) { if (next === committedValue) return; if (typeof onCommit === 'function' && onCommit(next) === false) return; committedValue = next; };
        slider.on(global.fgui.Event.STATUS_CHANGED, function () { var next = QUALITY_LEVELS[Math.round(slider.value)] || 'high'; if (typeof onValue === 'function') onValue(next); commit(next); });
        var target = new cc.Node(); target.setAnchorPoint(0, 0); target.setContentSize(width + 40, height + 24); target.setPosition(-20, -12); slider.node.addChild(target, 10);
        var dragging = false;
        var updateTouch = function (event) { var location = event && event.getLocation ? event.getLocation() : null; if (!location) return; var point = slider.node.convertToNodeSpaceAR(location); slider.updateWithPercent((point.x - gripInset) / travelWidth, true); render(); if (event.stopPropagation) event.stopPropagation(); };
        target.on(cc.Node.EventType.TOUCH_START, function (event) { dragging = true; updateTouch(event); }); target.on(cc.Node.EventType.TOUCH_MOVE, function (event) { if (dragging) updateTouch(event); }); target.on(cc.Node.EventType.TOUCH_END, function (event) { if (dragging) commit(QUALITY_LEVELS[Math.round(slider.value)] || 'high'); dragging = false; if (event.stopPropagation) event.stopPropagation(); }); target.on(cc.Node.EventType.TOUCH_CANCEL, function () { dragging = false; });
        return slider;
    }

    function saveDescriptor(manager, descriptor, state, next, refresh) {
        if (typeof descriptor.set === 'function') descriptor.set(state, next, manager.storage, manager);
        state[descriptor.key] = next;
        if (refresh !== false) manager._showConfig();
    }

    /* Add settings here. The renderer below only consumes this schema. */
    var CONFIG_SCHEMA = [
        { id: 'engine', title: '核心引擎', items: [
            { key: 'backend', label: '运行模式', type: 'select', values: ['native', 'webkit'], valueLabels: { native: 'Cocos 极速', webkit: 'WebKit 多开' }, set: function (state, value) { if (nativeCall('setRuntimeBackend', value, true) === null) throw new Error('runtime'); state.backend = value; } }
        ] },
        { id: 'performance', title: '画面与性能', items: [
            { key: 'singleQuality', label: '单开画质', type: 'quality', valueLabels: QUALITY_LABELS, disabledWhen: function (state) { return state.backend !== 'webkit'; }, set: function (state, value, storage) { if (!writeQuality(storage, 'setRenderQualitySingle', QUALITY_SINGLE_KEY, value, 'high')) throw new Error('single quality'); } },
            { key: 'multiQuality', label: '多开画质', type: 'quality', valueLabels: QUALITY_LABELS, disabledWhen: function (state) { return state.backend !== 'webkit'; }, set: function (state, value, storage) { if (!writeQuality(storage, 'setRenderQualityMulti', QUALITY_MULTI_KEY, value, 'medium')) throw new Error('multi quality'); } },
            { key: 'frameRate', label: '目标帧率', type: 'select', values: FRAME_RATES, valueLabels: { '30': '30 FPS', '45': '45 FPS', '60': '60 FPS' }, set: function (state, value, storage, manager) { storageSet(storage, 'ios2.frameRate', value); manager._setNativePerformance('frameRate', Number(value)); } },
            { key: 'autoRestore', label: '登录后降载恢复性能', type: 'toggle', valueLabels: { true: '开', false: '关' }, set: function (state, value, storage) { storageSet(storage, 'ios2.autoRestore', value ? '1' : '0'); } }
        ] },
        { id: 'multi', title: '多开与调度', items: [
            { key: 'webInstanceTarget', label: '实例数量', type: 'stepper', min: 2, max: 4, suffix: ' 个', disabledWhen: function (state) { return state.backend !== 'webkit'; }, set: function (state, value, storage) { storageSet(storage, INSTANCE_TARGET_KEY, value); } },
            { key: 'webStartupMode', label: '启动方式', type: 'select', values: ['serial', 'parallel'], valueLabels: { serial: '串行启动', parallel: '并行启动' }, disabledWhen: function (state) { return state.backend !== 'webkit'; }, set: function (state, value, storage) { storageSet(storage, 'ios2.webStartupMode', value); if (nativeCall('setWebGameStartupMode', value, true) === null) throw new Error('startup'); } },
            { key: 'webLayoutMode', label: '窗口布局', type: 'select', values: ['split', 'stacked'], valueLabels: { split: '均分布局', stacked: '堆叠布局' }, disabledWhen: function (state) { return state.backend !== 'webkit'; }, set: function (state, value, storage) { storageSet(storage, 'ios2.webLayoutMode', value); if (nativeCall('setWebGameLayoutMode', value, true) === null) throw new Error('layout'); } },
            { key: 'accountNavigationMode', label: '账号切换', type: 'select', values: ['page', 'scroll'], valueLabels: { page: '左右按钮翻页', scroll: '上下滚动' }, set: function (state, value, storage) { storageSet(storage, 'ios2.accountNavigationMode', value); } }
        ] },
        { id: 'debug', title: '开发者与调试', items: [
            { key: 'showFPS', label: '显示实时 FPS', type: 'toggle', valueLabels: { true: '开', false: '关' }, set: function (state, value, storage, manager) { storageSet(storage, 'ios2.showFPS', value ? '1' : '0'); manager._setNativePerformance('showFPS', value); } },
            { key: 'hsdkVerboseDebug', label: 'HSDK 详细日志', type: 'toggle', valueLabels: { true: '开', false: '关' }, set: function (state, value, storage, manager) { storageSet(storage, 'ios2.hsdkVerboseDebug', value ? '1' : '0'); manager._setHSDKVerboseDebug(value); } }
        ] }
    ];
    parts.configSchema = CONFIG_SCHEMA;

    parts.config = {
        _showConfig: function () {
            // Re-rendering a setting must replace the previous tree. Without
            // clearing it, every toggle/select leaves another interactive
            // layer above the page and the next drag exposes both layers.
            this._clearContent();
            this.statusItem = null;
            this.status = '';
            var size = cc.view && typeof cc.view.getVisibleSize === 'function' ? cc.view.getVisibleSize() : cc.winSize;
            var state = readState(this.storage), self = this;
            this._header('配置管理', '设置客户端运行引擎、画质及多开调度偏好');
            var viewportTop = this._navTop(size) - 112, viewportBottom = 56, viewportHeight = Math.max(180, viewportTop - viewportBottom), width = size.width - 48;
            var rowHeight = 70, sectionGap = 26, totalHeight = 24, sectionIndex, section;
            for (sectionIndex = 0; sectionIndex < CONFIG_SCHEMA.length; sectionIndex++) { section = CONFIG_SCHEMA[sectionIndex]; if (!(section.visibleWhen && !section.visibleWhen(state))) totalHeight += 40 + section.items.length * rowHeight + sectionGap; }
            var view = new cc.Node(); view.setAnchorPoint(0, 0); view.setContentSize(width, viewportHeight); view.setPosition(24, viewportBottom); if (cc.Mask) view.addComponent(cc.Mask); this.content.addChild(view, 2);
            var content = new cc.Node(); content.setAnchorPoint(0, 0); content.setContentSize(width, Math.max(viewportHeight, totalHeight)); content.setPosition(0, 0); view.addChild(content);
            var cursor = content.height - 24;
            for (sectionIndex = 0; sectionIndex < CONFIG_SCHEMA.length; sectionIndex++) {
                section = CONFIG_SCHEMA[sectionIndex]; if (section.visibleWhen && !section.visibleWhen(state)) continue;
                var heading = common.label(section.title, 24, COLORS.text); heading.setAnchorPoint(0, 0.5); heading.setPosition(4, cursor - 20); if (heading.__ios2LabelComponent) heading.__ios2LabelComponent.bold = true; content.addChild(heading); cursor -= 40;
                var cardHeight = section.items.length * rowHeight, card = common.surfaceNode(width, cardHeight, COLORS.panel, 14, COLORS.border); card.setPosition(0, cursor - cardHeight); content.addChild(card, 1);
                for (var itemIndex = 0; itemIndex < section.items.length; itemIndex++) {
                    var descriptor = section.items[itemIndex];
                    var row = this._renderConfigRow(descriptor, state, width, rowHeight);
                    row.setPosition(0, cardHeight - (itemIndex + 1) * rowHeight);
                    card.addChild(row);
                    if (itemIndex) {
                        var separator = common.rectNode(width - 32, 1, COLORS.border);
                        separator.setPosition(16, cardHeight - itemIndex * rowHeight);
                        card.addChild(separator, 2);
                    }
                }
                cursor -= cardHeight + sectionGap;
            }
            if (cc.ScrollView) { var scroll = view.addComponent(cc.ScrollView); scroll.horizontal = false; scroll.vertical = true; scroll.inertia = true; scroll.brake = 0.78; scroll.content = content; if (typeof scroll.scrollToTop === 'function') scroll.scrollToTop(0); }
        },

        _renderConfigRow: function (descriptor, state, width, height) {
            var self = this, row = new cc.Node(); row.setAnchorPoint(0, 0); row.setContentSize(width, height);
            var disabled = typeof descriptor.disabledWhen === 'function' && descriptor.disabledWhen(state);
            var label = common.label(descriptor.label, 20, disabled ? DISABLED_TEXT : COLORS.text); label.setAnchorPoint(0, 0.5); label.setContentSize(Math.max(140, width * 0.46), height); if (label.__ios2LabelComponent) label.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT; label.setPosition(24, height / 2); row.addChild(label);
            var value = state[descriptor.key], valueText = descriptor.valueLabels ? descriptor.valueLabels[String(value)] : String(value);
            if (descriptor.type === 'quality') {
                var current = common.label(QUALITY_LABELS[value] || '高', 18, disabled ? DISABLED_TEXT : COLORS.accent); current.setAnchorPoint(1, 0.5); current.setPosition(width - 24, height - 20); row.addChild(current, 3);
                var sliderWidth = Math.max(150, Math.min(300, width - 150)), slider = null;
                if (!disabled) slider = qualitySlider(sliderWidth, 34, value, function (next) { setText(current, QUALITY_LABELS[next], COLORS.accent); }, function (next) { try { saveDescriptor(self, descriptor, state, next, false); self._setStatus('画质设置已保存，下次启动游戏生效。', COLORS.success); return true; } catch (ignored) { self._setStatus('无法保存画质设置', COLORS.warning); return false; } });
                if (slider) { slider.node.setPosition(width - sliderWidth - 24, 8); row.addChild(slider.node, 2); }
            } else if (descriptor.type === 'toggle') {
                var toggle = common.surfaceNode(68, 34, disabled ? DISABLED_SURFACE : (value ? COLORS.accent : COLORS.panelAlt), 17, disabled ? DISABLED_TEXT : (value ? COLORS.accent : COLORS.border)); toggle.setPosition(width - 92, 18); row.addChild(toggle, 2); var knob = common.surfaceNode(26, 26, cc.Color.WHITE, 13); knob.setPosition(value ? 38 : 4, 4); toggle.addChild(knob); if (!disabled) row.on(cc.Node.EventType.TOUCH_END, function () { try { saveDescriptor(self, descriptor, state, !value); } catch (ignored) { self._setStatus('无法保存设置', COLORS.warning); } });
            } else if (descriptor.type === 'stepper') {
                var stepperFill = disabled ? DISABLED_SURFACE : COLORS.panelAlt;
                var minus = common.actionButton('-', 24, function () { if (!disabled && value > descriptor.min) try { saveDescriptor(self, descriptor, state, value - 1); } catch (ignored) {} }, stepperFill, 42); var plus = common.actionButton('+', 24, function () { if (!disabled && value < descriptor.max) try { saveDescriptor(self, descriptor, state, value + 1); } catch (ignored) {} }, stepperFill, 42); minus.setPosition(width - 128, height / 2); plus.setPosition(width - 32, height / 2); row.addChild(minus); row.addChild(plus); var count = common.label(String(value) + (descriptor.suffix || ''), 18, disabled ? DISABLED_TEXT : COLORS.accent); count.setAnchorPoint(0.5, 0.5); count.setPosition(width - 80, height / 2); row.addChild(count, 2);
            } else {
                var currentValue = common.label(valueText || '', 18, disabled ? DISABLED_TEXT : COLORS.accent); currentValue.setAnchorPoint(1, 0.5); currentValue.setPosition(width - 52, height / 2); row.addChild(currentValue, 2); var arrow = common.label('›', 28, disabled ? DISABLED_TEXT : COLORS.muted); arrow.setAnchorPoint(1, 0.5); arrow.setPosition(width - 20, height / 2); row.addChild(arrow, 2);
                if (!disabled) row.on(cc.Node.EventType.TOUCH_END, function () { var values = descriptor.values || [], next = values[(values.indexOf(value) + 1) % values.length]; try { saveDescriptor(self, descriptor, state, next); } catch (ignored) { self._setStatus('无法应用设置', COLORS.warning); } });
            }
            return row;
        },
        _setNativePerformance: function (kind, value) { if (kind === 'showFPS') nativeCall('setShowFPS', !!value, true); else nativeCall('setPreferredFrameRate', Number(value), true); },
        _setHSDKVerboseDebug: function (enabled) { enabled = !!enabled; try { if (typeof global.__ios2SetHSDKVerboseDebug === 'function') global.__ios2SetHSDKVerboseDebug(enabled); } catch (ignored) {} nativeCall('setHSDKVerboseDebug', enabled, true); try { if (global.HSDK && HSDK.config) HSDK.config.isOpenDebug = enabled; } catch (ignored2) {} }
    };
}(window));
