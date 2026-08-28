/* Configuration management page. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;

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
            var runtimeBackend = 'native';
            var webGameInstances = 0;
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try {
                    var nativeFrameRate = Number(jsb.reflection.callStaticMethod('IOS2Native', 'preferredFrameRate'));
                    if ([15, 24, 30, 45, 60].indexOf(nativeFrameRate) >= 0) frameRate = String(nativeFrameRate);
                    showFPS = !!jsb.reflection.callStaticMethod('IOS2Native', 'showFPS');
                    runtimeBackend = String(jsb.reflection.callStaticMethod('IOS2Native', 'runtimeBackend') || 'native');
                    webGameInstances = Number(jsb.reflection.callStaticMethod('IOS2Native', 'webGameInstanceCount')) || 0;
                } catch (ignored) {}
            }
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
            var firstRowY = this._navTop(size) - 260;
            option(firstRowY, '游戏运行模式', runtimeBackend === 'webkit' ? 'WebKit 多开' : 'Cocos 极速', function () {
                var nextBackend = runtimeBackend === 'webkit' ? 'native' : 'webkit';
                try { jsb.reflection.callStaticMethod('IOS2Native', 'setRuntimeBackend:', nextBackend); }
                catch (error) { self._setStatus('无法切换运行模式', COLORS.warning); return; }
                self._showConfig();
            });
            option(firstRowY - 82, 'WebKit 游戏实例', String(webGameInstances), function () {
                if (runtimeBackend !== 'webkit') self._setStatus('切换到 WebKit 多开后可启动多开实例。');
                else self._setStatus(webGameInstances ? '当前实例正在同屏运行。' : '请在 Bin 文件页面点击“多开”。');
            });
            option(firstRowY - 164, '显示 FPS', showFPS ? '开' : '关', function () {
                if (storage) storage.setItem('ios2.showFPS', showFPS ? '0' : '1');
                self._setNativePerformance('showFPS', showFPS ? 0 : 1);
                self._showConfig();
            });
            option(firstRowY - 246, '登录后恢复性能设置', autoRestore ? '开' : '关', function () {
                if (storage) storage.setItem('ios2.autoRestore', autoRestore ? '0' : '1');
                self._showConfig();
            });
            option(firstRowY - 328, '目标帧率', frameRate + ' FPS', function () {
                var values = ['30', '45', '60'];
                var next = values[(values.indexOf(frameRate) + 1) % values.length];
                if (storage) storage.setItem('ios2.frameRate', next);
                self._setNativePerformance('frameRate', Number(next));
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
        }
    };
}(window));
