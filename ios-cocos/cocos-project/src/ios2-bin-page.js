/* Bin file management page. */
(function (global) {
    'use strict';

    var parts = global.__ios2ManagerParts = global.__ios2ManagerParts || {};
    var common = parts.common;
    var COLORS = common.COLORS;
    var DEFAULT_GROUP_ID = 'default';
    var GROUP_COLORS = [
        { r: 47, g: 111, b: 237 },
        { r: 22, g: 163, b: 154 },
        { r: 232, g: 139, b: 38 },
        { r: 214, g: 75, b: 103 },
        { r: 126, g: 87, b: 194 },
        { r: 67, g: 117, b: 133 },
        { r: 130, g: 146, b: 78 },
        { r: 111, g: 122, b: 141 }
    ];

    function copyColor(value, fallback) {
        var color = value || fallback || GROUP_COLORS[0];
        return {
            r: Math.max(0, Math.min(255, Number(color.r) || 0)),
            g: Math.max(0, Math.min(255, Number(color.g) || 0)),
            b: Math.max(0, Math.min(255, Number(color.b) || 0))
        };
    }

    function ccColor(value, alpha) {
        var color = copyColor(value, GROUP_COLORS[0]);
        return cc.color(color.r, color.g, color.b, alpha === undefined ? 255 : alpha);
    }

    function softColor(value) {
        var color = copyColor(value, GROUP_COLORS[0]);
        return cc.color(
            Math.round(248 + (color.r - 248) * 0.16),
            Math.round(248 + (color.g - 248) * 0.16),
            Math.round(248 + (color.b - 248) * 0.16), 255);
    }

    function stop(event) {
        if (event && event.stopPropagation) event.stopPropagation();
    }

    function groupIconButton(text, callback, fillColor, textColor) {
        var item = new cc.Node();
        var width = 36;
        var height = 36;
        item.setAnchorPoint(0.5, 0.5);
        item.setContentSize(width, height);
        var background = common.surfaceNode(width, height, fillColor, 10);
        background.setPosition(-width / 2, -height / 2);
        item.addChild(background);
        var caption = common.label(text, 20, textColor || cc.color(255, 255, 255, 255));
        caption.setPosition(0, 0);
        item.addChild(caption, 1);
        item.on(cc.Node.EventType.TOUCH_START, function (event) {
            stop(event);
            item.setScale(0.94);
        });
        item.on(cc.Node.EventType.TOUCH_END, function (event) {
            item.setScale(1);
            stop(event);
            if (typeof callback === 'function') callback(event);
        });
        item.on(cc.Node.EventType.TOUCH_CANCEL, function (event) {
            item.setScale(1);
            stop(event);
        });
        return item;
    }

    parts.bin = {
        _loadBins: function () {
            var raw = this.storage && this.storage.getItem('ios2.bins');
            try {
                var records = raw ? JSON.parse(raw) : [];
                return Array.isArray(records) ? records : [];
            } catch (error) {
                return [];
            }
        },

        _saveBins: function () {
            if (this.storage) {
                try { this.storage.setItem('ios2.bins', JSON.stringify(this.binFiles || [])); } catch (ignored) {}
            }
        },

        _loadBinGroups: function () {
            var raw = this.storage && this.storage.getItem('ios2.binGroups');
            try {
                var groups = raw ? JSON.parse(raw) : [];
                return Array.isArray(groups) ? groups : [];
            } catch (error) {
                return [];
            }
        },

        _saveBinGroups: function () {
            if (this.storage) {
                try { this.storage.setItem('ios2.binGroups', JSON.stringify(this.binGroups || [])); } catch (ignored) {}
            }
        },

        _ensureBinGroups: function () {
            var groups = Array.isArray(this.binGroups) ? this.binGroups : [];
            var valid = Object.create(null);
            var normalized = [];
            var defaultColor = GROUP_COLORS[GROUP_COLORS.length - 1];
            var index;
            for (index = 0; index < groups.length; index++) {
                var source = groups[index] || {};
                var id = String(source.id || '');
                if (id === DEFAULT_GROUP_ID) {
                    defaultColor = copyColor(source.color, defaultColor);
                    continue;
                }
                if (!id || valid[id]) continue;
                valid[id] = true;
                normalized.push({
                    id: id,
                    name: String(source.name || '新分组').slice(0, 20),
                    color: copyColor(source.color, GROUP_COLORS[index % GROUP_COLORS.length])
                });
            }
            normalized.push({ id: DEFAULT_GROUP_ID, name: '默认分组', color: defaultColor });
            this.binGroups = normalized;
            var groupIds = Object.create(null);
            for (index = 0; index < normalized.length; index++) groupIds[normalized[index].id] = true;
            var bins = Array.isArray(this.binFiles) ? this.binFiles : [];
            for (index = 0; index < bins.length; index++) {
                if (!bins[index]) continue;
                if (!bins[index].groupId || !groupIds[bins[index].groupId]) bins[index].groupId = DEFAULT_GROUP_ID;
            }
            this._saveBinGroups();
            this._saveBins();
        },

        _groupById: function (id) {
            for (var index = 0; index < this.binGroups.length; index++) {
                if (this.binGroups[index].id === id) return this.binGroups[index];
            }
            return this.binGroups[this.binGroups.length - 1];
        },

        _orderedGroups: function () {
            this._ensureBinGroups();
            return this.binGroups.slice(0);
        },

        _mergeBinOrder: function (records) {
            var fresh = Array.isArray(records) ? records : [];
            var byName = Object.create(null);
            var previousByName = Object.create(null);
            var ordered = [];
            var index;
            var previous = Array.isArray(this.binFiles) ? this.binFiles : [];
            for (index = 0; index < previous.length; index++) {
                if (previous[index] && previous[index].name) previousByName[previous[index].name] = previous[index];
            }
            for (index = 0; index < fresh.length; index++) {
                if (fresh[index] && fresh[index].name) {
                    if (!fresh[index].groupId && previousByName[fresh[index].name]) {
                        fresh[index].groupId = previousByName[fresh[index].name].groupId;
                    }
                    byName[fresh[index].name] = fresh[index];
                }
            }
            for (index = 0; index < previous.length; index++) {
                var previousName = previous[index] && previous[index].name;
                if (previousName && byName[previousName]) {
                    ordered.push(byName[previousName]);
                    delete byName[previousName];
                }
            }
            for (index = 0; index < fresh.length; index++) {
                var freshName = fresh[index] && fresh[index].name;
                if (freshName && byName[freshName]) {
                    ordered.push(fresh[index]);
                    delete byName[freshName];
                }
            }
            return ordered;
        },

        _groupBins: function (groupId) {
            var result = [];
            for (var index = 0; index < this.binFiles.length; index++) {
                if (this.binFiles[index] && this.binFiles[index].groupId === groupId) result.push(this.binFiles[index]);
            }
            return result;
        },

        _createBinRow: function (file, width, y, reorderOwner) {
            var self = this;
            var displayName = String(file.name || '').replace(/\.bin$/i, '') || file.name;
            var row = common.swipeDeleteRow(self, '_binSwipeRow', {
                width: width,
                height: 62,
                color: file.last ? cc.color(235, 248, 245, 255) : COLORS.panel,
                fontSize: 20,
                reorderable: !!reorderOwner,
                title: (file.last ? '最近使用  ·  ' : '') + displayName,
                accessory: { text: '≡', size: 22, color: COLORS.muted },
                onActivate: function () { self._loginBin(file.name); },
                onDelete: function () { self._deleteBin(file.name, displayName); },
                onReorderStart: reorderOwner && reorderOwner.onReorderStart,
                onReorderMove: reorderOwner && reorderOwner.onReorderMove,
                onReorderEnd: reorderOwner && reorderOwner.onReorderEnd
            });
            row.setPosition(0, y - 31);
            return row;
        },

        _showBins: function () {
            var size = cc.winSize;
            var self = this;
            var groups = this._orderedGroups();
            this._binSwipeRow = null;
            this._binRows = [];
            this._header('Bin 文件组');
            var importButton = common.actionButton('+ 导入 bin', 18, this._importBin.bind(this), COLORS.accent, 132);
            importButton.setPosition(size.width - 38 - importButton.width / 2, size.height - 176);
            var newGroupButton = common.actionButton('+ 新建分组', 18, this._createGroup.bind(this), cc.color(22, 163, 154, 255), 142);
            newGroupButton.setPosition(38 + newGroupButton.width / 2, size.height - 176);
            this._menu([newGroupButton, importButton]);

            this.background.off(cc.Node.EventType.TOUCH_END);
            this.background.on(cc.Node.EventType.TOUCH_END, function () {
                if (self._binSwipeRow) self._binSwipeRow.closeSwipe();
            });

            var y = size.height - 238;
            var cardWidth = size.width - 64;
            var groupCardHeight = 96;
            var rowHeight = 62;
            for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
                var group = groups[groupIndex];
                var members = this._groupBins(group.id);
                var card = this._createGroupCard(group, members.length, cardWidth, groupCardHeight);
                card.setPosition(32, y - groupCardHeight);
                this.content.addChild(card, 6);
                y -= groupCardHeight + 14;
                if (this._expandedGroupId !== group.id) continue;
                if (!members.length) {
                    var noBins = common.label('暂无 bin，点击右侧 + 添加', 17, COLORS.muted);
                    noBins.setAnchorPoint(0, 0.5);
                    noBins.setPosition(56, y - 22);
                    this.content.addChild(noBins, 5);
                    y -= 48;
                } else {
                    y = (function (activeGroup, activeMembers, startY) {
                        var groupRows = [];
                        var rowStep = rowHeight + 10;
                        var firstRowY = startY - rowHeight - 3;
                        var slotY = function (rowIndex) { return firstRowY - rowIndex * rowStep; };
                        var localPoint = function (location) {
                            return location && self.content && self.content.convertToNodeSpace ?
                                self.content.convertToNodeSpace(location) : (location || { x: 0, y: 0 });
                        };
                        var findEntry = function (row) {
                            for (var entryIndex = 0; entryIndex < groupRows.length; entryIndex++) {
                                if (groupRows[entryIndex].row === row) return groupRows[entryIndex];
                            }
                            return null;
                        };
                        var moveRow = function (row, location) {
                            var entry = findEntry(row);
                            if (!entry) return;
                            var point = localPoint(location);
                            var originY = point.y - (self._binDragOffsetY || 0);
                            originY = Math.max(slotY(groupRows.length - 1), Math.min(slotY(0), originY));
                            row.setPosition(row.x, originY);
                            var centerY = originY + rowHeight / 2;
                            var targetIndex = 0;
                            for (var target = 0; target < groupRows.length; target++) {
                                if (groupRows[target] === entry) continue;
                                if (centerY <= slotY(target) + rowHeight / 2) targetIndex++;
                                else break;
                            }
                            var currentIndex = groupRows.indexOf(entry);
                            if (targetIndex === currentIndex) return;
                            groupRows.splice(currentIndex, 1);
                            groupRows.splice(targetIndex, 0, entry);
                            for (var rowIndex = 0; rowIndex < groupRows.length; rowIndex++) {
                                if (groupRows[rowIndex] !== entry) groupRows[rowIndex].row.setPosition(groupRows[rowIndex].row.x, slotY(rowIndex));
                            }
                        };
                        var resetAfterDrag = function () {
                            self._binDragRow = null;
                            setTimeout(function () {
                                if (self.page === 0) self.showPage(0);
                            }, 0);
                        };
                        var finishRow = function (row, cancelled) {
                            var entry = findEntry(row);
                            if (!entry) {
                                resetAfterDrag();
                                return;
                            }
                            if (!cancelled) {
                                var positions = [];
                                for (var fileIndex = 0; fileIndex < self.binFiles.length; fileIndex++) {
                                    if (self.binFiles[fileIndex] && self.binFiles[fileIndex].groupId === activeGroup.id) positions.push(fileIndex);
                                }
                                for (var positionIndex = 0; positionIndex < positions.length; positionIndex++) {
                                    if (groupRows[positionIndex]) self.binFiles[positions[positionIndex]] = groupRows[positionIndex].file;
                                }
                                self._saveBins();
                                self.status = '排序已保存';
                            }
                            resetAfterDrag();
                        };
                        var reorderOwner = {
                            onReorderStart: function (row, location) {
                                self._binDragRow = row;
                                self._binDragOffsetY = localPoint(location).y - row.y;
                            },
                            onReorderMove: moveRow,
                            onReorderEnd: finishRow
                        };
                        for (var binIndex = 0; binIndex < activeMembers.length; binIndex++) {
                            var binRow = self._createBinRow(activeMembers[binIndex], cardWidth - 28, startY - 3, reorderOwner);
                            binRow.setPosition(46, slotY(binIndex));
                            self.content.addChild(binRow, 5);
                            var rowEntry = { row: binRow, file: activeMembers[binIndex] };
                            groupRows.push(rowEntry);
                            self._binRows.push(rowEntry);
                        }
                        return startY - activeMembers.length * rowStep;
                    }(group, members, y));
                }
                y -= 8;
            }
            if (!this.binFiles.length) {
                var empty = common.label('暂无 bin 文件，请先导入账号文件', 23, COLORS.muted);
                empty.setPosition(size.width / 2, size.height / 2 - 6);
                this.content.addChild(empty, 4);
            }
            this._setStatus(this.status || '账号文件保存在本机，不会被上传到其他位置。');
        },

        _createGroupCard: function (group, count, width, height) {
            var self = this;
            height = height || 96;
            var card = new cc.Node();
            card.setAnchorPoint(0, 0);
            card.setContentSize(width, height);
            var surface = common.surfaceNode(width, height, softColor(group.color), 16, cc.color(214, 224, 236, 255));
            card.addChild(surface);
            var colorDot = common.surfaceNode(14, height - 28, ccColor(group.color), 7);
            colorDot.setPosition(14, 14);
            card.addChild(colorDot, 1);
            colorDot.on(cc.Node.EventType.TOUCH_END, function (event) {
                stop(event);
                self._showColorPicker(group);
            });
            var arrow = common.label(this._expandedGroupId === group.id ? '⌄' : '›', 32, COLORS.muted);
            arrow.setPosition(48, height / 2);
            card.addChild(arrow, 2);
            var hasMore = group.id !== DEFAULT_GROUP_ID;
            var title = common.label(group.name, 25, COLORS.text);
            title.setAnchorPoint(0, 0.5);
            title.setPosition(78, height - 32);
            title.setContentSize(Math.max(48, width - (hasMore ? 210 : 166)), 30);
            if (title.__ios2LabelComponent) title.__ios2LabelComponent.horizontalAlign = cc.Label.HorizontalAlign.LEFT;
            card.addChild(title, 2);
            var countLabel = common.label(count + ' 个 bin', 17, COLORS.muted);
            countLabel.setAnchorPoint(0, 0.5);
            countLabel.setPosition(80, 25);
            card.addChild(countLabel, 2);

            var add = groupIconButton('+', function (event) {
                stop(event);
                self._showBinPicker(group);
            }, ccColor(group.color));
            add.setPosition(width - (hasMore ? 116 : 72), height / 2);
            card.addChild(add, 3);
            var color = groupIconButton('●', function (event) {
                stop(event);
                self._showColorPicker(group);
            }, ccColor(group.color));
            color.setPosition(width - (hasMore ? 72 : 28), height / 2);
            card.addChild(color, 3);
            if (hasMore) {
                var more = groupIconButton('···', function (event) {
                    stop(event);
                    self._showGroupActions(group);
                }, cc.color(148, 163, 184, 104), COLORS.muted);
                more.setPosition(width - 28, height / 2);
                card.addChild(more, 3);
            }
            card.on(cc.Node.EventType.TOUCH_END, function (event) {
                stop(event);
                self._expandedGroupId = self._expandedGroupId === group.id ? null : group.id;
                self.showPage(0);
            });
            return card;
        },

        _showGroupActions: function (group) {
            var self = this;
            this._showChoiceDialog(group.name, [
                { text: '重命名', callback: function () { self._showGroupNameDialog(group, function (name) {
                    group.name = name;
                    self._saveBinGroups();
                    self.showPage(0);
                }); } },
                { text: '删除分组', callback: function () { self._deleteGroup(group); } }
            ]);
        },

        _showChoiceDialog: function (title, choices) {
            var size = cc.winSize;
            var overlay = common.rectNode(size.width, size.height, cc.color(20, 31, 49, 120));
            overlay.setPosition(0, 0);
            this.content.addChild(overlay, 100);
            var panelWidth = Math.min(size.width - 64, 480);
            var panel = common.surfaceNode(panelWidth, 112 + choices.length * 60, cc.color(255, 255, 255, 255), 18, COLORS.border);
            panel.setPosition((size.width - panelWidth) / 2, (size.height - panel.height) / 2);
            overlay.addChild(panel, 1);
            var heading = common.label(title, 21, COLORS.text);
            heading.setPosition(panelWidth / 2, panel.height - 30);
            panel.addChild(heading);
            for (var index = 0; index < choices.length; index++) {
                (function (choice, choiceIndex) {
                    var item = common.button(choice.text, 19, function (event) {
                        stop(event);
                        overlay.removeFromParent(true);
                        choice.callback();
                    }, choiceIndex === choices.length - 1 ? COLORS.danger : COLORS.accent, panelWidth - 48);
                    item.setPosition(panelWidth / 2, panel.height - 92 - choiceIndex * 60);
                    panel.addChild(item);
                }(choices[index], index));
            }
            overlay.on(cc.Node.EventType.TOUCH_END, function (event) { stop(event); overlay.removeFromParent(true); });
        },

        _createGroup: function () {
            var self = this;
            this._showGroupNameDialog(null, function (name) {
                var id = 'group-' + Date.now() + '-' + Math.floor(Math.random() * 1000);
                self.binGroups.splice(Math.max(0, self.binGroups.length - 1), 0, {
                    id: id,
                    name: name,
                    color: copyColor(GROUP_COLORS[self.binGroups.length % GROUP_COLORS.length])
                });
                self._saveBinGroups();
                self._expandedGroupId = id;
                self.showPage(0);
                self._setStatus('已创建分组“' + name + '”', COLORS.success);
            });
        },

        _deleteGroup: function (group) {
            if (!group || group.id === DEFAULT_GROUP_ID) return;
            var fallback = this._groupById(DEFAULT_GROUP_ID);
            for (var index = 0; index < this.binFiles.length; index++) {
                if (this.binFiles[index] && this.binFiles[index].groupId === group.id) this.binFiles[index].groupId = fallback.id;
            }
            this.binGroups = this.binGroups.filter(function (item) { return item.id !== group.id; });
            if (this._expandedGroupId === group.id) this._expandedGroupId = null;
            this._saveBinGroups();
            this._saveBins();
            this.showPage(0);
            this._setStatus('分组已删除，里面的 bin 已移入默认分组', COLORS.success);
        },

        _showGroupNameDialog: function (group, onConfirm) {
            var size = cc.winSize;
            var self = this;
            var overlay = common.rectNode(size.width, size.height, cc.color(20, 31, 49, 132));
            var panelWidth = Math.min(size.width - 64, 520);
            var panel = common.surfaceNode(panelWidth, 258, cc.color(255, 255, 255, 255), 18, COLORS.border);
            overlay.setPosition(0, 0);
            panel.setPosition((size.width - panelWidth) / 2, (size.height - panel.height) / 2);
            overlay.addChild(panel, 1);
            this.content.addChild(overlay, 100);
            var heading = common.label(group ? '重命名分组' : '新建分组', 23, COLORS.text);
            heading.setPosition(panelWidth / 2, 212);
            panel.addChild(heading);
            var inputNode = new cc.Node();
            inputNode.setAnchorPoint(0.5, 0.5);
            inputNode.setContentSize(panelWidth - 48, 62);
            inputNode.setPosition(panelWidth / 2, 143);
            var inputSurface = common.surfaceNode(panelWidth - 48, 62, COLORS.panel, 12, COLORS.border);
            inputSurface.setPosition(panelWidth / 2 - (panelWidth - 48) / 2, 112);
            panel.addChild(inputSurface, 1);
            var edit = inputNode.addComponent(cc.EditBox);
            edit.maxLength = 20;
            edit.inputMode = cc.EditBox.InputMode.SINGLE_LINE;
            edit.returnType = cc.EditBox.KeyboardReturnType.DONE;
            if (edit._updateTextLabel) edit._updateTextLabel();
            if (edit._updatePlaceholderLabel) edit._updatePlaceholderLabel();
            edit.placeholder = '输入分组名称';
            edit.placeholderFontSize = 19;
            edit.placeholderFontColor = COLORS.muted;
            edit.fontSize = 21;
            edit.fontColor = COLORS.text;
            edit.string = group ? group.name : '';
            panel.addChild(inputNode, 2);
            var close = function () { overlay.removeFromParent(true); };
            var confirm = function (event) {
                stop(event);
                var name = String(edit.string || '').replace(/^\s+|\s+$/g, '');
                if (!name) return;
                close();
                onConfirm(name);
            };
            inputNode.on('editing-return', confirm);
            var cancel = common.actionButton('取消', 18, function (event) { stop(event); close(); }, COLORS.muted, 140);
            var save = common.actionButton('保存', 18, confirm, COLORS.accent, 140);
            cancel.setPosition(panelWidth / 2 - 78, 64);
            save.setPosition(panelWidth / 2 + 78, 64);
            panel.addChild(cancel, 2);
            panel.addChild(save, 2);
            overlay.on(cc.Node.EventType.TOUCH_END, function (event) { stop(event); close(); });
            setTimeout(function () { if (inputNode.parent && edit && edit.focus) edit.focus(); }, 80);
        },

        _showColorPicker: function (group) {
            var size = cc.winSize;
            var self = this;
            var overlay = common.rectNode(size.width, size.height, cc.color(20, 31, 49, 132));
            var panelWidth = Math.min(size.width - 64, 480);
            var panel = common.surfaceNode(panelWidth, 228, cc.color(255, 255, 255, 255), 18, COLORS.border);
            overlay.setPosition(0, 0);
            panel.setPosition((size.width - panelWidth) / 2, (size.height - panel.height) / 2);
            overlay.addChild(panel, 1);
            this.content.addChild(overlay, 100);
            var heading = common.label('选择分组颜色', 22, COLORS.text);
            heading.setPosition(panelWidth / 2, 188);
            panel.addChild(heading);
            for (var index = 0; index < GROUP_COLORS.length; index++) {
                (function (color, colorIndex) {
                    var swatch = common.surfaceNode(40, 40, ccColor(color), 12, cc.color(255, 255, 255, 255));
                    var col = colorIndex % 4;
                    var row = Math.floor(colorIndex / 4);
                    swatch.setPosition(66 + col * 86, 106 - row * 62);
                    swatch.on(cc.Node.EventType.TOUCH_END, function (event) {
                        stop(event);
                        group.color = copyColor(color);
                        self._saveBinGroups();
                        overlay.removeFromParent(true);
                        self.showPage(0);
                    });
                    panel.addChild(swatch, 2);
                }(GROUP_COLORS[index], index));
            }
            overlay.on(cc.Node.EventType.TOUCH_END, function (event) { stop(event); overlay.removeFromParent(true); });
        },

        _showBinPicker: function (group) {
            var size = cc.winSize;
            var self = this;
            var overlay = common.rectNode(size.width, size.height, cc.color(20, 31, 49, 132));
            var panelWidth = Math.min(size.width - 64, 540);
            var panelHeight = 176;
            var panel = common.surfaceNode(panelWidth, panelHeight, cc.color(255, 255, 255, 255), 18, COLORS.border);
            overlay.setPosition(0, 0);
            panel.setPosition((size.width - panelWidth) / 2, (size.height - panelHeight) / 2);
            overlay.addChild(panel, 1);
            this.content.addChild(overlay, 100);
            var heading = common.label('添加到“' + group.name + '”', 22, COLORS.text);
            heading.setPosition(panelWidth / 2, panelHeight - 42);
            panel.addChild(heading);
            var importButton = common.actionButton('+ 导入新 bin', 17, function (event) {
                stop(event);
                overlay.removeFromParent(true);
                self._importBin(group);
            }, ccColor(group.color), panelWidth - 48);
            importButton.setPosition(panelWidth / 2, 58);
            panel.addChild(importButton, 2);
            overlay.on(cc.Node.EventType.TOUCH_END, function (event) { stop(event); overlay.removeFromParent(true); });
        },

        _refreshBins: function () {
            if (global.jsb && jsb.reflection && jsb.reflection.callStaticMethod) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'listBinFiles'); } catch (error) {}
            }
        },

        _importBin: function (targetGroup) {
            this._pendingImportGroupId = targetGroup && targetGroup.id ? targetGroup.id : null;
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) {
                this._setStatus('当前环境不支持文件选择', COLORS.warning);
                return;
            }
            this._setStatus('正在打开文件选择器…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'selectBinFile'); }
            catch (error) { this._setStatus('无法打开文件选择器', COLORS.warning); }
        },

        _loginBin: function (name) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            if (global.__ios2ScriptRuntime) global.__ios2ScriptRuntime.install();
            this._setStatus('正在认证 ' + name + '，登录成功后启动已启用脚本…', COLORS.accent);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'loginBinFile:', name); }
            catch (error) { this._setStatus('认证启动失败', COLORS.warning); }
        },

        _deleteBin: function (name, displayName) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            this._setStatus('正在删除 ' + displayName + '…', COLORS.muted);
            try { jsb.reflection.callStaticMethod('IOS2Native', 'deleteBinFile:', name); }
            catch (error) { this._setStatus('删除失败', COLORS.warning); }
        },

        onBinFiles: function (json) {
            var records = [];
            try { records = JSON.parse(String(json || '[]')) || []; } catch (error) {}
            var previousNames = Object.create(null);
            for (var previousIndex = 0; previousIndex < this.binFiles.length; previousIndex++) {
                if (this.binFiles[previousIndex] && this.binFiles[previousIndex].name) {
                    previousNames[this.binFiles[previousIndex].name] = true;
                }
            }
            this.binFiles = this._mergeBinOrder(records);
            if (this._pendingImportGroupId) {
                for (var recordIndex = 0; recordIndex < this.binFiles.length; recordIndex++) {
                    if (this.binFiles[recordIndex] && !previousNames[this.binFiles[recordIndex].name]) {
                        this.binFiles[recordIndex].groupId = this._pendingImportGroupId;
                    }
                }
                this._pendingImportGroupId = null;
                this._pendingImportName = null;
            }
            this._ensureBinGroups();
            this._saveBins();
            if (this.page === 0) this.showPage(0);
        },

        onBinImported: function (name) {
            if (this._pendingImportGroupId) this._pendingImportName = String(name || '');
            this.status = '已导入 ' + name;
            this._refreshBins();
        },

        onBinDeleted: function (name) {
            this.status = '已删除 ' + (String(name || '').replace(/\.bin$/i, '') || name);
            this._refreshBins();
        },

        onBinDeleteFailed: function (message) {
            this._setStatus('删除失败：' + String(message || '未知错误'), COLORS.warning);
        }
    };
}(window));
