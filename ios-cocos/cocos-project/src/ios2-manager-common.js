/* Shared UI helpers for the ios2 management pages. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    parts.common = {
        NAV_HEIGHT: 92,
        COLORS: {
            background: cc.color(255, 255, 255, 255),
            panel: cc.color(248, 250, 253, 255),
            panelAlt: cc.color(239, 244, 250, 255),
            border: cc.color(225, 232, 241, 255),
            text: cc.color(24, 34, 49, 255),
            muted: cc.color(93, 108, 128, 255),
            accent: cc.color(47, 111, 237, 255),
            success: cc.color(24, 145, 92, 255),
            warning: cc.color(181, 105, 25, 255),
            danger: cc.color(224, 82, 82, 255)
        },
        safeStorage: function () {
            try { return global.localStorage; } catch (error) { return null; }
        },
        label: function (text, size, color) {
            var item = new cc.Node();
            var component = item.addComponent(cc.Label);
            component.string = String(text || '');
            component.fontSize = size || 24;
            component.lineHeight = (size || 24) + 8;
            component.horizontalAlign = cc.Label.HorizontalAlign.CENTER;
            component.verticalAlign = cc.Label.VerticalAlign.CENTER;
            component.color = color || this.COLORS.text;
            item.__ios2LabelComponent = component;
            item.color = color || this.COLORS.text;
            item.setColor = function (nextColor) {
                component.color = nextColor;
                item.color = nextColor;
            };
            item.setColor(color || this.COLORS.text);
            item.setContentSize(Math.max(40, component.string.length * (size || 24)), (size || 24) + 12);
            return item;
        },
        button: function (text, size, callback, color, minimumWidth) {
            var item = this.label(text, size || 24, color || this.COLORS.text);
            item.setAnchorPoint(0.5, 0.5);
            item.setContentSize(Math.max(item.width, minimumWidth || 180), Math.max(item.height, 58));
            item.on(cc.Node.EventType.TOUCH_END, function () {
                if (typeof callback === 'function') callback.apply(item, arguments);
            });
            return item;
        },
        rectNode: function (width, height, color) {
            var node = new cc.Node();
            node.setAnchorPoint(0, 0);
            node.setContentSize(width, height);
            var graphics = node.addComponent(cc.Graphics);
            graphics.fillColor = color;
            graphics.rect(0, 0, width, height);
            graphics.fill();
            return node;
        },
        surfaceNode: function (width, height, color, radius, borderColor) {
            var node = new cc.Node();
            node.setAnchorPoint(0, 0);
            node.setContentSize(width, height);
            var graphics = node.addComponent(cc.Graphics);
            var draw = function () {
                if (radius && typeof graphics.roundRect === 'function') graphics.roundRect(0, 0, width, height, radius);
                else graphics.rect(0, 0, width, height);
            };
            graphics.fillColor = color;
            draw();
            graphics.fill();
            if (borderColor) {
                graphics.lineWidth = 1;
                graphics.strokeColor = borderColor;
                draw();
                graphics.stroke();
            }
            return node;
        },
        actionButton: function (text, size, callback, fillColor, minimumWidth) {
            var width = Math.max(minimumWidth || 136, String(text || '').length * (size || 22) + 42);
            var height = 48;
            var item = new cc.Node();
            item.setAnchorPoint(0.5, 0.5);
            item.setContentSize(width, height);
            var background = this.surfaceNode(width, height, fillColor || this.COLORS.accent, 14);
            background.setPosition(-width / 2, -height / 2);
            item.addChild(background);
            var caption = this.label(text, size || 20, cc.color(255, 255, 255, 255));
            caption.setPosition(0, 0);
            item.addChild(caption, 1);
            var restoreScale = function () {
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(item);
                    cc.tween(item).to(0.12, { scale: 1 }, { easing: 'sineOut' }).start();
                } else item.setScale(1);
            };
            item.on(cc.Node.EventType.TOUCH_START, function () {
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(item);
                    cc.tween(item).to(0.08, { scale: 0.97 }, { easing: 'sineOut' }).start();
                } else item.setScale(0.97);
            });
            item.on(cc.Node.EventType.TOUCH_END, function () {
                restoreScale();
                if (typeof callback === 'function') callback.apply(item, arguments);
            });
            item.on(cc.Node.EventType.TOUCH_CANCEL, restoreScale);
            return item;
        },
        trashIcon: function (color, cutoutColor) {
            var icon = new cc.Node();
            var graphics = icon.addComponent(cc.Graphics);
            icon.setAnchorPoint(0, 0);
            icon.setContentSize(32, 32);
            graphics.fillColor = color;
            graphics.rect(7, 3, 18, 20);
            graphics.fill();
            graphics.rect(5, 24, 22, 3);
            graphics.fill();
            graphics.rect(12, 28, 8, 3);
            graphics.fill();
            graphics.fillColor = cutoutColor;
            graphics.rect(11, 7, 2, 12);
            graphics.fill();
            graphics.rect(15, 7, 2, 12);
            graphics.fill();
            graphics.rect(19, 7, 2, 12);
            graphics.fill();
            return icon;
        },
        swipeDeleteRow: function (owner, activeRowKey, options) {
            var deleteWidth = 104;
            var deleteColor = this.COLORS.danger;
            var iconSize = 32;
            var row = new cc.Node();
            var foreground = new cc.Node();
            foreground.setAnchorPoint(0, 0);
            foreground.setContentSize(options.width, options.height);
            var foregroundSurface = this.surfaceNode(options.width, options.height, options.color || this.COLORS.panel, 14, this.COLORS.border);
            var deleteArea = this.surfaceNode(deleteWidth, options.height, deleteColor, 14);
            var deleteIcon = this.trashIcon(cc.color(255, 255, 255, 255), deleteColor);
            var title = this.label(options.title, options.fontSize || 23, this.COLORS.text);
            var accessory = options.accessory ? this.label(options.accessory.text, options.accessory.size || 30, options.accessory.color) : null;
            var touch = {
                startX: 0,
                startY: 0,
                deltaX: 0,
                deltaY: 0,
                dragging: false,
                reordering: false,
                longPressTimer: null,
                dismissedOpenRow: false
            };
            var swipeState = { offset: 0 };

            row.setAnchorPoint(0, 0);
            row.setContentSize(options.width, options.height);
            deleteArea.setPosition(options.width - deleteWidth, 0);
            foreground.addChild(foregroundSurface, 0);
            title.setAnchorPoint(0, 0.5);
            title.setContentSize(Math.max(80, options.width - (accessory ? 92 : 52)), options.height);
            if (title.__ios2LabelComponent) {
                title.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
                if (cc.Label.Overflow && cc.Label.Overflow.CLAMP !== undefined) {
                    title.__ios2LabelComponent.overflow = cc.Label.Overflow.CLAMP;
                }
            }
            title.setPosition(26, options.height / 2);
            foreground.addChild(title);
            if (accessory) {
                accessory.setPosition(options.width - 34, options.height / 2);
                foreground.addChild(accessory);
            }
            deleteArea.addChild(deleteIcon);
            row.addChild(deleteArea, 1);
            row.addChild(foreground, 2);

            row.setSwipeOffset = function (offset) {
                var clamped = Math.max(-deleteWidth, Math.min(0, offset));
                var visibleWidth = -clamped;
                var scale = Math.max(0, Math.min(1, (visibleWidth - 24) / iconSize, (options.height - 18) / iconSize));
                deleteIcon.active = scale > 0;
                deleteIcon.setScale(scale);
                deleteIcon.setPosition(
                    deleteWidth - visibleWidth / 2 - iconSize * scale / 2,
                    (options.height - iconSize * scale) / 2);
                foreground.setPosition(clamped, 0);
                swipeState.offset = clamped;
            };

            row.animateSwipeOffset = function (offset) {
                if (!cc.tween) {
                    row.setSwipeOffset(offset);
                    return;
                }
                cc.Tween.stopAllByTarget(swipeState);
                cc.tween(swipeState)
                    .to(0.14, { offset: Math.max(-deleteWidth, Math.min(0, offset)) }, {
                        easing: 'sineOut',
                        onUpdate: function (state) { row.setSwipeOffset(state.offset); }
                    })
                    .start();
            };

            row.closeSwipe = function () {
                row.animateSwipeOffset(0);
                if (owner[activeRowKey] === row) owner[activeRowKey] = null;
            };
            row.openSwipe = function () {
                row.animateSwipeOffset(-deleteWidth);
                owner[activeRowKey] = row;
            };
            row.setReorderVisual = function (active) {
                var targetOpacity = active ? 198 : 255;
                if (cc.tween) {
                    cc.Tween.stopAllByTarget(foregroundSurface);
                    if (active) foregroundSurface.opacity = targetOpacity;
                    else cc.tween(foregroundSurface)
                        .to(0.16, { opacity: targetOpacity }, { easing: 'sineOut' })
                        .start();
                } else foregroundSurface.opacity = targetOpacity;
            };
            row.closeSwipe();

            var cancelLongPress = function () {
                if (touch.longPressTimer) {
                    clearTimeout(touch.longPressTimer);
                    touch.longPressTimer = null;
                }
            };

            foreground.on(cc.Node.EventType.TOUCH_START, function (event) {
                var location = event && event.getLocation ? event.getLocation() : null;
                touch.startX = location ? location.x : 0;
                touch.startY = location ? location.y : 0;
                touch.deltaX = 0;
                touch.deltaY = 0;
                touch.dragging = false;
                touch.reordering = false;
                touch.dismissedOpenRow = !!(owner[activeRowKey] && owner[activeRowKey] !== row);
                if (touch.dismissedOpenRow) owner[activeRowKey].closeSwipe();
                if (cc.Tween) cc.Tween.stopAllByTarget(swipeState);
                cancelLongPress();
                if (options.reorderable && !touch.dismissedOpenRow) {
                    touch.longPressTimer = setTimeout(function () {
                        touch.longPressTimer = null;
                        if (touch.dragging || touch.reordering) return;
                        touch.reordering = true;
                        row.setSwipeOffset(0);
                        if (owner[activeRowKey] === row) owner[activeRowKey] = null;
                        row.setReorderVisual(true);
                        row.setScale(1.2, 1.2);
                        if (row.setLocalZOrder) row.setLocalZOrder(50);
                        else row.zIndex = 50;
                        if (typeof options.onReorderStart === 'function') {
                            options.onReorderStart(row, { x: touch.startX, y: touch.startY });
                        }
                    }, 320);
                }
                if (event && event.stopPropagation) event.stopPropagation();
            });
            foreground.on(cc.Node.EventType.TOUCH_MOVE, function (event) {
                var location = event && event.getLocation ? event.getLocation() : null;
                touch.deltaX = location ? location.x - touch.startX : 0;
                touch.deltaY = location ? location.y - touch.startY : 0;
                if (touch.reordering) {
                    if (typeof options.onReorderMove === 'function') options.onReorderMove(row, location);
                    if (event && event.stopPropagation) event.stopPropagation();
                    return;
                }
                if (Math.abs(touch.deltaX) > 14 || (!options.reorderable && Math.abs(touch.deltaY) > 14)) cancelLongPress();
                if (touch.deltaX < -8) {
                    cancelLongPress();
                    touch.dragging = true;
                }
                if (touch.dragging) row.setSwipeOffset(touch.deltaX);
                if (event && event.stopPropagation) event.stopPropagation();
            });
            foreground.on(cc.Node.EventType.TOUCH_END, function (event) {
                cancelLongPress();
                if (touch.reordering) {
                    touch.reordering = false;
                    if (typeof options.onReorderEnd === 'function') options.onReorderEnd(row, false);
                    else row.setScale(1);
                    row.setReorderVisual(false);
                    if (row.setLocalZOrder) row.setLocalZOrder(5);
                    else row.zIndex = 5;
                    if (event && event.stopPropagation) event.stopPropagation();
                    return;
                }
                if (touch.dragging) {
                    if (touch.deltaX < -deleteWidth / 2) row.openSwipe();
                    else row.closeSwipe();
                } else if (touch.dismissedOpenRow || owner[activeRowKey] === row) {
                    row.closeSwipe();
                } else if (typeof options.onActivate === 'function') {
                    options.onActivate();
                }
                if (event && event.stopPropagation) event.stopPropagation();
            });
            foreground.on(cc.Node.EventType.TOUCH_CANCEL, function (event) {
                cancelLongPress();
                if (touch.reordering) {
                    touch.reordering = false;
                    if (typeof options.onReorderEnd === 'function') options.onReorderEnd(row, true);
                    else row.setScale(1);
                    row.setReorderVisual(false);
                    if (row.setLocalZOrder) row.setLocalZOrder(5);
                    else row.zIndex = 5;
                    if (event && event.stopPropagation) event.stopPropagation();
                    return;
                }
                row.closeSwipe();
                if (event && event.stopPropagation) event.stopPropagation();
            });
            deleteArea.on(cc.Node.EventType.TOUCH_END, function (event) {
                row.closeSwipe();
                if (typeof options.onDelete === 'function') options.onDelete();
                if (event && event.stopPropagation) event.stopPropagation();
            });
            return row;
        }
    };

    parts.commonMethods = {
        _clearContent: function () {
            this.content.removeAllChildren(true);
        },

        _header: function (title, subtitle) {
            var size = cc.winSize;
            var titleItem = parts.common.label(title, 36, parts.common.COLORS.text);
            titleItem.setAnchorPoint(0, 1);
            titleItem.setPosition(38, size.height - 94);
            this.content.addChild(titleItem);
            if (subtitle) {
                var subtitleItem = parts.common.label(subtitle, 17, parts.common.COLORS.muted);
                subtitleItem.setAnchorPoint(0, 1);
                subtitleItem.setPosition(40, size.height - 140);
                this.content.addChild(subtitleItem);
            }
        },

        _panel: function (x, y, width, height, color) {
            var node = parts.common.surfaceNode(width, height, color || parts.common.COLORS.panel, 14, parts.common.COLORS.border);
            node.setPosition(x, y);
            this.content.addChild(node);
            return node;
        },

        _menu: function (items) {
            var menu = new cc.Node();
            menu.setPosition(0, 0);
            for (var index = 0; index < items.length; index++) menu.addChild(items[index]);
            this.content.addChild(menu, 5);
            return menu;
        },

        _formatSize: function (bytes) {
            bytes = Number(bytes) || 0;
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            return (bytes / 1024 / 1024).toFixed(1) + ' MB';
        },

        _setStatus: function (message, color) {
            if (this.statusItem) this.statusItem.removeFromParent(true);
            this.status = message || '';
            if (!message) return;
            this.statusItem = parts.common.label(message, 16, color || parts.common.COLORS.muted);
            this.statusItem.setAnchorPoint(0, 0.5);
            this.statusItem.setPosition(40, parts.common.NAV_HEIGHT + 24);
            this.content.addChild(this.statusItem, 10);
        }
    };
}(window));
