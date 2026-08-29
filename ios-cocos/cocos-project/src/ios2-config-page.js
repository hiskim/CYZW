/* Configuration management page. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;
    var QUALITY_LEVELS = ['low', 'medium', 'high'];
    var QUALITY_LABELS = { low: '低', medium: '中', high: '高' };
    var QUALITY_SINGLE_KEY = 'ios2.renderQuality.single';
    var QUALITY_MULTI_KEY = 'ios2.renderQuality.multi';

    function normalizeQuality(value, fallback) {
        return QUALITY_LEVELS.indexOf(String(value || '')) >= 0 ? String(value) : fallback;
    }

    function readQuality(storage, nativeMethod, key, fallback) {
        var value = '';
        if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
            try { value = String(jsb.reflection.callStaticMethod('IOS2Native', nativeMethod) || ''); }
            catch (ignored) {}
        }
        if (QUALITY_LEVELS.indexOf(value) < 0 && storage) {
            try { value = String(storage.getItem(key) || ''); } catch (ignored2) {}
        }
        return normalizeQuality(value, fallback);
    }

    function writeQuality(storage, nativeMethod, key, value, fallback) {
        value = normalizeQuality(value, fallback || 'high');
        try { if (storage) storage.setItem(key, value); } catch (ignored) {}
        if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
            try { jsb.reflection.callStaticMethod('IOS2Native', nativeMethod + ':', value); }
            catch (error) { return false; }
        }
        return true;
    }

    function qualitySlider(width, height, value, onValue, onCommit) {
        if (!global.fgui || !global.fgui.GSlider) return null;
        var slider = new global.fgui.GSlider();
        var trackHeight = 8;
        var gripSize = 34;
        var gripInset = gripSize / 2;
        var travelWidth = Math.max(1, width - gripSize);
        var trackColor = cc.color(181, 207, 245, 255);
        slider.name = 'IOS2RenderQualitySlider';
        slider.setSize(width, height);
        slider.node.setAnchorPoint(0, 0);

        var track = new global.fgui.GGraph();
        track.setSize(travelWidth, trackHeight);
        track.node.setAnchorPoint(0, 0);
        track.drawRect(0, cc.Color.TRANSPARENT, trackColor, 3);
        track.node.setPosition(gripInset, Math.floor((height - trackHeight) / 2));

        var fill = new global.fgui.GGraph();
        fill.setSize(travelWidth, trackHeight);
        fill.node.setAnchorPoint(0, 0);
        fill.drawRect(0, cc.Color.TRANSPARENT, COLORS.accent, 3);
        fill.node.setPosition(gripInset, Math.floor((height - trackHeight) / 2));

        var grip = new global.fgui.GGraph();
        grip.setSize(gripSize, gripSize);
        grip.node.setAnchorPoint(0, 0);
        grip.drawEllipse(2, COLORS.accent, cc.Color.WHITE);
        grip.node.setPosition(0, (height - gripSize) / 2);

        slider.addChild(track);
        slider.addChild(fill);
        slider.addChild(grip);
        // Keep the fill geometry under our renderer's control. GSlider's
        // default updateWithPercent also changes bar.width, which would be
        // applied twice when the custom scale below is refreshed.
        slider._barObjectH = null;
        slider._gripObject = grip;
        slider._barMaxWidth = travelWidth;
        slider._barMaxWidthDelta = 0;
        slider._barStartX = 0;
        slider.min = 0;
        slider.max = QUALITY_LEVELS.length - 1;
        slider.wholeNumbers = true;

        var render = function () {
            var percent = slider.max > slider.min ?
                (slider.value - slider.min) / (slider.max - slider.min) : 0;
            percent = Math.max(0, Math.min(1, percent));
            // Resize the graph instead of scaling it horizontally. Scaling a
            // stroked GGraph makes the fill look thick at the low end and
            // thin at the high end.
            fill.node.setScale(1, 1);
            fill.setSize(Math.max(0, travelWidth * percent), trackHeight);
            grip.node.setPosition(gripInset + travelWidth * percent - gripSize / 2,
                (height - gripSize) / 2);
        };
        slider.update = render;
        slider.value = QUALITY_LEVELS.indexOf(normalizeQuality(value, 'high'));
        render();
        var lastCommittedQuality = normalizeQuality(value, 'high');
        var commitQuality = function (quality) {
            quality = QUALITY_LEVELS.indexOf(quality) >= 0 ? quality : 'high';
            if (quality === lastCommittedQuality) return;
            var committed = typeof onCommit === 'function' ? onCommit(quality) : true;
            if (committed !== false) lastCommittedQuality = quality;
        };
        slider.on(global.fgui.Event.STATUS_CHANGED, function () {
            var quality = QUALITY_LEVELS[Math.round(slider.value)] || 'high';
            if (typeof onValue === 'function') onValue(quality);
            // Persist on the discrete value change itself. On iOS, the end
            // event can be cancelled when the finger leaves the enlarged
            // touch target, which used to lose the final high-quality choice.
            commitQuality(quality);
        });

        // A transparent Cocos touch target gives the FairyGUI slider a stable
        // hit area even when the knob is between the three small tick labels.
        var touchTarget = new cc.Node();
        touchTarget.name = 'IOS2RenderQualityTouchTarget';
        touchTarget.setAnchorPoint(0, 0);
        touchTarget.setContentSize(width + 40, height + 24);
        touchTarget.setPosition(-20, -12);
        slider.node.addChild(touchTarget, 10);

        var dragging = false;
        var updateFromTouch = function (event) {
            var location = event && event.getLocation ? event.getLocation() : null;
            if (!location) return;
            var point = slider.node.convertToNodeSpaceAR(location);
            slider.updateWithPercent((point.x - gripInset) / travelWidth, true);
            render();
            if (event.stopPropagation) event.stopPropagation();
        };
        touchTarget.on(cc.Node.EventType.TOUCH_START, function (event) {
            dragging = true;
            if (event.captureTouch) event.captureTouch();
            updateFromTouch(event);
        });
        touchTarget.on(cc.Node.EventType.TOUCH_MOVE, function (event) {
            if (dragging) updateFromTouch(event);
        });
        touchTarget.on(cc.Node.EventType.TOUCH_END, function (event) {
            if (dragging) commitQuality(QUALITY_LEVELS[Math.round(slider.value)] || 'high');
            dragging = false;
            if (event.stopPropagation) event.stopPropagation();
        });
        touchTarget.on(cc.Node.EventType.TOUCH_CANCEL, function (event) {
            dragging = false;
            if (event.stopPropagation) event.stopPropagation();
        });
        return slider;
    }

    parts.config = {
        _showConfig: function () {
            // The native view can resize after the management scene is created.
            // Read the current visible rect so rows are laid out inside the
            // viewport instead of using a stale winSize value.
            var size = cc.view && typeof cc.view.getVisibleSize === 'function' ?
                cc.view.getVisibleSize() : cc.winSize;
            this._header('配置管理', '启动与显示偏好');
            var storage = this.storage;
            var showFPS = storage ? storage.getItem('ios2.showFPS') === '1' : false;
            var autoRestore = storage ? storage.getItem('ios2.autoRestore') !== '0' : true;
            var frameRate = storage ? (storage.getItem('ios2.frameRate') || '60') : '60';
            var hsdkVerboseDebug = storage ? storage.getItem('ios2.hsdkVerboseDebug') === '1' : false;
            var webStartupMode = storage ? (storage.getItem('ios2.webStartupMode') || 'serial') : 'serial';
            var accountNavigationMode = storage ? (storage.getItem('ios2.accountNavigationMode') || 'page') : 'page';
            var runtimeBackend = 'native';
            var webGameInstances = 0;
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try {
                    var nativeFrameRate = Number(jsb.reflection.callStaticMethod('IOS2Native', 'preferredFrameRate'));
                    if ([15, 24, 30, 45, 60].indexOf(nativeFrameRate) >= 0) frameRate = String(nativeFrameRate);
                    showFPS = !!jsb.reflection.callStaticMethod('IOS2Native', 'showFPS');
                    hsdkVerboseDebug = !!jsb.reflection.callStaticMethod('IOS2Native', 'hsdkVerboseDebug');
                    runtimeBackend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native');
                    webGameInstances = Number(jsb.reflection.callStaticMethod('IOS2Native', 'webGameInstanceCount')) || 0;
                    webStartupMode = String(jsb.reflection.callStaticMethod('IOS2Native', 'webGameStartupMode') || webStartupMode);
                } catch (ignored) {}
            }
            if (webStartupMode !== 'parallel') webStartupMode = 'serial';
            if (accountNavigationMode !== 'scroll') accountNavigationMode = 'page';
            var self = this;
            function option(y, text, value, onClick) {
                var item = common.surfaceNode(size.width - 64, 72, COLORS.panel, 14, COLORS.border);
                item.setPosition(32, y - 36);
                var resetScale = function () {
                    if (cc.tween) {
                        cc.Tween.stopAllByTarget(item);
                        cc.tween(item).to(0.12, { scale: 1 }, { easing: 'sineOut' }).start();
                    } else item.setScale(1);
                };
                item.on(cc.Node.EventType.TOUCH_START, function () {
                    if (cc.tween) {
                        cc.Tween.stopAllByTarget(item);
                        cc.tween(item).to(0.08, { scale: 0.985 }, { easing: 'sineOut' }).start();
                    } else item.setScale(0.985);
                });
                item.on(cc.Node.EventType.TOUCH_END, function () {
                    resetScale();
                    if (typeof onClick === 'function') onClick();
                });
                item.on(cc.Node.EventType.TOUCH_CANCEL, resetScale);
                var name = common.label(text, 21, COLORS.text);
                name.setAnchorPoint(0, 0.5);
                name.setPosition(24, 36);
                item.addChild(name);
                var current = common.label(value, 20, COLORS.accent);
                current.setAnchorPoint(1, 0.5);
                current.setPosition(size.width - 112, 36);
                item.addChild(current);
                var arrow = common.label('›', 28, COLORS.muted);
                arrow.setAnchorPoint(1, 0.5);
                arrow.setPosition(size.width - 82, 36);
                item.addChild(arrow);
                self.content.addChild(item, 5);
            }
            function qualityOption(y, text, quality, nativeMethod, storageKey, fallback) {
                var width = size.width - 64;
                var height = 74;
                var item = common.surfaceNode(width, height, COLORS.panel, 14, COLORS.border);
                item.setPosition(32, y - height / 2);
                var name = common.label(text, 20, COLORS.text);
                name.setAnchorPoint(0, 0.5);
                name.setPosition(24, 49);
                item.addChild(name);
                var current = common.label(QUALITY_LABELS[quality], 19, COLORS.accent);
                current.setAnchorPoint(1, 0.5);
                current.setPosition(width - 24, 49);
                item.addChild(current, 2);
                var sliderWidth = Math.min(300, Math.max(160, width - 120));
                var sliderRightInset = Math.max(24, Math.min(110, width - sliderWidth - 24));
                var slider = qualitySlider(sliderWidth, 34, quality, function (next) {
                    current.__ios2LabelComponent.string = QUALITY_LABELS[next];
                }, function (next) {
                    if (!writeQuality(storage, nativeMethod, storageKey, next, fallback)) {
                        self._setStatus('无法保存画质设置', COLORS.warning);
                        return false;
                    }
                    self._setStatus('画质设置已保存，下次启动游戏生效。', COLORS.success);
                    return true;
                });
                if (slider) {
                    slider.node.setPosition(width - sliderWidth - sliderRightInset, 4);
                    item.addChild(slider.node, 3);
                    var labels = ['低', '中', '高'];
                    var sliderX = width - sliderWidth - sliderRightInset;
                    var sliderGripInset = 17;
                    for (var index = 0; index < labels.length; index++) {
                        var mark = common.label(labels[index], 12, COLORS.muted);
                        mark.setAnchorPoint(0.5, 0.5);
                        mark.setPosition(sliderX + sliderGripInset +
                            (sliderWidth - sliderGripInset * 2) * index / 2, 2);
                        item.addChild(mark, 4);
                    }
                } else {
                    item.on(cc.Node.EventType.TOUCH_END, function () {
                        var next = QUALITY_LEVELS[(QUALITY_LEVELS.indexOf(quality) + 1) % QUALITY_LEVELS.length];
                        if (writeQuality(storage, nativeMethod, storageKey, next, fallback)) self._showConfig();
                    });
                }
                self.content.addChild(item, 5);
            }
            var firstRowY = this._navTop(size) - 260;
            var rowGap = Math.max(36, Math.min(82, Math.floor((firstRowY - 70) / 9)));
            var singleQuality = readQuality(storage, 'renderQualitySingle', QUALITY_SINGLE_KEY, 'high');
            var multiQuality = readQuality(storage, 'renderQualityMulti', QUALITY_MULTI_KEY, 'medium');
            option(firstRowY, '游戏运行模式', runtimeBackend === 'webkit' ? 'WebKit 多开' : 'Cocos 极速', function () {
                var nextBackend = runtimeBackend === 'webkit' ? 'native' : 'webkit';
                try { jsb.reflection.callStaticMethod('IOS2Native', 'setRuntimeBackend:', nextBackend); }
                catch (error) { self._setStatus('无法切换运行模式', COLORS.warning); return; }
                self._showConfig();
            });
            qualityOption(firstRowY - rowGap, '单开画质', singleQuality, 'setRenderQualitySingle', QUALITY_SINGLE_KEY, 'high');
            qualityOption(firstRowY - rowGap * 2, 'WebKit 多开画质', multiQuality, 'setRenderQualityMulti', QUALITY_MULTI_KEY, 'medium');
            option(firstRowY - rowGap * 3, '账号切换方式', accountNavigationMode === 'scroll' ? '上下滚动' : '左右按钮翻页', function () {
                var next = accountNavigationMode === 'scroll' ? 'page' : 'scroll';
                try { if (storage) storage.setItem('ios2.accountNavigationMode', next); }
                catch (error) { self._setStatus('无法保存账号切换方式', COLORS.warning); return; }
                self._showConfig();
            });
            option(firstRowY - rowGap * 4, 'WebKit 游戏实例', String(webGameInstances), function () {
                if (runtimeBackend !== 'webkit') self._setStatus('切换到 WebKit 多开后可启动多开实例。');
                else self._setStatus(webGameInstances ? '当前实例正在同屏运行。' : '请在 Bin 文件页面点击“多开”。');
            });
            option(firstRowY - rowGap * 5, 'WebKit 启动方式', webStartupMode === 'parallel' ? '并行启动' : '串行启动', function () {
                var next = webStartupMode === 'parallel' ? 'serial' : 'parallel';
                if (storage) storage.setItem('ios2.webStartupMode', next);
                try { jsb.reflection.callStaticMethod('IOS2Native', 'setWebGameStartupMode:', next); }
                catch (error) { self._setStatus('无法应用 WebKit 启动方式', COLORS.warning); return; }
                self._showConfig();
            });
            option(firstRowY - rowGap * 6, '显示 FPS', showFPS ? '开' : '关', function () {
                if (storage) storage.setItem('ios2.showFPS', showFPS ? '0' : '1');
                self._setNativePerformance('showFPS', showFPS ? 0 : 1);
                self._showConfig();
            });
            option(firstRowY - rowGap * 7, '登录后恢复性能设置', autoRestore ? '开' : '关', function () {
                if (storage) storage.setItem('ios2.autoRestore', autoRestore ? '0' : '1');
                self._showConfig();
            });
            option(firstRowY - rowGap * 8, '目标帧率', frameRate + ' FPS', function () {
                var values = ['30', '45', '60'];
                var next = values[(values.indexOf(frameRate) + 1) % values.length];
                if (storage) storage.setItem('ios2.frameRate', next);
                self._setNativePerformance('frameRate', Number(next));
                self._showConfig();
            });
            option(firstRowY - rowGap * 9, 'HSDK 详细日志', hsdkVerboseDebug ? '开' : '关', function () {
                var next = !hsdkVerboseDebug;
                if (storage) storage.setItem('ios2.hsdkVerboseDebug', next ? '1' : '0');
                self._setHSDKVerboseDebug(next);
                self._showConfig();
            });
            this._setStatus('配置保存在本机，下次启动继续生效。');
        },

        _setNativePerformance: function (kind, value) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            try {
                if (kind === 'showFPS') jsb.reflection.callStaticMethod('IOS2Native', 'setShowFPS:', !!value);
                else jsb.reflection.callStaticMethod('IOS2Native', 'setPreferredFrameRate:', Number(value));
            } catch (error) {
                this._setStatus('无法应用性能设置', COLORS.warning);
            }
        },

        _setHSDKVerboseDebug: function (enabled) {
            enabled = !!enabled;
            var applied = false;
            try {
                if (typeof global.__ios2SetHSDKVerboseDebug === 'function') {
                    global.__ios2SetHSDKVerboseDebug(enabled);
                    applied = true;
                }
            } catch (ignored) {}
            if (!applied && global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try {
                    jsb.reflection.callStaticMethod('IOS2Native', 'setHSDKVerboseDebug:', enabled);
                    applied = true;
                } catch (ignored) {}
            }
            try {
                if (global.HSDK && HSDK.config) HSDK.config.isOpenDebug = enabled;
                applied = true;
            } catch (ignored) {}
            if (!applied) this._setStatus('无法应用 HSDK 日志设置', COLORS.warning);
        }
    };
}(window));
