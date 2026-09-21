(function () {
    'use strict';

    var IOS2_WEB_RUNTIME_REVISION = '20260910-webgl-pvr-recovery-1';
    window.__IOS2_WEB_RUNTIME_REVISION__ = IOS2_WEB_RUNTIME_REVISION;

    // Keep serial startup responsive while still allowing the previous page's
    // final resource callbacks and GL uploads to drain before the next page.
    // A few game requests can remain open for the whole session, so they must
    // not hold the next account behind the full startup timeout.
    var IOS2_STARTUP_SETTLE_INTERVAL = 100;
    var IOS2_STARTUP_STABLE_SAMPLES = 1;
    var IOS2_STARTUP_QUIET_MS = 250;
    var IOS2_STARTUP_MIN_SETTLE_MS = 400;
    var IOS2_STARTUP_MAX_SETTLE_MS = 1200;
    var IOS2_PVR_RECOVERY_CONCURRENCY = 2;
    var IOS2_PVR_RECOVERY_RESUME_DELAY_MS = 250;

    // A WebGL context loss invalidates GPU texture contents, while keeping
    // JavaScript Texture2D assets alive. PVR source bytes are intentionally
    // not retained after their initial upload, so the recovery path fetches
    // them from the app's native CDN cache only when the context returns.
    var astcPVRRecoveryState = {
        installed: false,
        contextLost: false,
        documentWasHidden: false,
        scheduled: false,
        recovering: false,
        rerunRequested: false,
        pendingReason: '',
        sequence: 0
    };

    function showFatal(message) {
        var panel = document.getElementById('ios2WebError');
        if (!panel) {
            panel = document.createElement('div');
            panel.id = 'ios2WebError';
            panel.style.cssText = 'position:fixed;inset:0;z-index:99999;padding:72px 24px 24px;' +
                'box-sizing:border-box;background:#101318;color:#f1f5f9;font:15px/1.55 -apple-system,sans-serif;' +
                'white-space:pre-wrap;overflow:auto;';
            document.body.appendChild(panel);
        }
        panel.textContent = String(message || 'WebKit 游戏启动失败');
    }

    // 帧率白名单必须与 macOS 端 `MacFrameRate` 的档位集合严格一致，
    // 不在名单里的注入值会被丢弃并回退到 60。
    // 注意：实际能跑多高受显示器刷新率上限约束——引擎对非 30/60 档位用
    // `_stTimeWithRAF`（setTimeout 计时后再对齐 rAF），rAF 最快就是一次 vsync，
    // 所以 120 档在 60Hz/100Hz 屏上实测只会到 60/100，不会更高。
    function preferredFrameRate() {
        var frameRate = Number(window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.frameRate) || 60;
        return [15, 24, 30, 45, 60, 90, 120].indexOf(frameRate) >= 0 ? frameRate : 60;
    }

    function renderQuality() {
        var instance = window.__IOS2_GAME_INSTANCE__ || {};
        var value = instance.multiOpen ? instance.qualityMulti : instance.qualitySingle;
        return value === 'low' || value === 'medium' || value === 'high' ? value :
            (instance.multiOpen ? 'medium' : 'high');
    }

    function renderPixelRatio(quality, devicePixelRatio, multiOpen) {
        var device = Math.max(1, Number(devicePixelRatio) || 1);
        if (multiOpen) {
            // 不再用 device 封顶：dpr=1 的显示器上 min(倍率, device) 会让
            // 低/中/高三档全部落回 1x，画质设置形同虚设。改为固定倍率——
            // 低=1x 最省 GPU；中=1.5x、高=2x 超采样（画布像素多于物理像素，
            // 下屏后更锐利）。档位在实例启动时读取，改档需重启实例。
            if (quality === 'low') return 1;
            if (quality === 'high') return 2;
            return 1.5;
        }
        if (quality === 'low') return 1;
        if (quality === 'medium') return Math.min(2, device);
        return Math.min(3, device);
    }

    // 运行时画质切换：原生在设置页改档后，对存活实例调用
    // `window.__LOBBY_QUALITY__.set('low'|'medium'|'high')`。
    // 原理与 boot 一致——更新注入对象的档位 + 重设 cc.view._maxPixelRatio +
    // enableRetina 触发 _resizeEvent 重算画布 backing store（与窗口 resize
    // 同一条重算路径，不重建 WebGL 上下文，游戏不必重启）。
    // 引擎未就绪时只更新注入对象（boot 时自己会读），返回 'deferred'。
    window.__LOBBY_QUALITY__ = {
        set: function (quality) {
            if (['low', 'medium', 'high'].indexOf(quality) < 0) return 'invalid:' + quality;
            var instance = window.__IOS2_GAME_INSTANCE__ || (window.__IOS2_GAME_INSTANCE__ = {});
            instance.qualitySingle = quality;
            instance.qualityMulti = quality;
            if (!(window.cc && window.cc.view)) return 'deferred:' + quality;
            var devicePixelRatio = Number(window.devicePixelRatio) || 1;
            var multiOpen = !!instance.multiOpen;
            var webPixelRatio = renderPixelRatio(quality, devicePixelRatio, multiOpen);
            var view = window.cc.view;
            view._maxPixelRatio = webPixelRatio;
            // enableRetina 只改标志位；必须再调 _resizeEvent(!0) 强制重算——
            // 无参调用时引擎只在 frame 尺寸变化时才重设画布，恒等尺寸会被
            // 直接跳过（这就是运行时切画质"不生效"的原因）。
            view.enableRetina(webPixelRatio > 1);
            if (typeof view._resizeEvent === 'function') view._resizeEvent(!0);
            console.log('[ios2-web] pixel ratio runtime set',
                'quality=' + quality, 'selected=' + webPixelRatio,
                'backing=' + (window.cc.game.canvas
                    ? window.cc.game.canvas.width + 'x' + window.cc.game.canvas.height
                    : '?'));
            return 'ok:' + webPixelRatio;
        }
    };

    // Cocos' release manager only knows about references tracked by Cocos.
    // WebKit pages also retain assets through FGUI/Spine, remote bundle
    // caches and native bridges, so releasing during normal gameplay can
    // destroy resources that the next scene still needs. Keep the state and
    // entry point for native compatibility, but only permit it once the game
    // is already shutting down.
    var assetReleaseState = {
        busy: false,
        sequence: 0,
        shuttingDown: false,
        startupReadySent: false,
        startupTrackingOpen: true,
        startupDownloadCount: 0,
        startupLastActivityAt: 0
    };

    // WebKit runs the actual game in this shared boot path. Keep the normal
    // cleanup conservative: deferred Cocos destruction and JavaScript GC are
    // safe at a page transition, while releaseUnusedAssets() is not because
    // FGUI/Spine and bridge code can retain resources outside Cocos' counter.
    var IOS2_RUNTIME_CLEANUP_DELAY_MS = 5000;
    var IOS2_RUNTIME_CLEANUP_MIN_INTERVAL_MS = 15000;
    var IOS2_RUNTIME_MEMORY_SAMPLE_MIN_INTERVAL_MS = 2500;
    // Automatic sampling and cleanup are OFF by default. Both run synchronously
    // on the game's JS thread: sceneNodeProfile() walks the whole scene graph
    // and calls cc.isValid twice per node (a 5.8k-node scene is ~12k calls),
    // and garbageCollect() is a stop-the-world full GC. With the 2.5s sample
    // and 15s cleanup intervals that shows up as a periodic hitch while playing
    // — most visible right after a button press, which is why it looked like a
    // click latency problem. Flip this to true (or call
    // window.__ios2RuntimeMemorySnapshot / __ios2RuntimeSoftCleanup by hand)
    // when actually hunting a memory issue.
    var IOS2_RUNTIME_MEMORY_AUTOMATIC = false;
    var IOS2_RUNTIME_MEMORY_ROOT_LIMIT = 6;
    var IOS2_RUNTIME_MEMORY_BRANCH_DEPTH = 3;
    var IOS2_RUNTIME_MEMORY_PAGE_NAMES = {
        Home: true,
        MainPanel: true,
        LegionRoomPanel: true,
        LegionScene: true,
        legion: true,
        NormalLoadingPanel: true
    };
    var runtimeMemoryState = {
        cleanupTimer: null,
        sampleTimer: null,
        cleanupBusy: false,
        lastCleanup: 0,
        lastSample: 0,
        pendingCleanupReason: '',
        pendingSampleReason: '',
        switchCount: 0,
        lastSnapshot: null
    };
    var runtimeLoadingState = {
        configured: false,
        relaxed: false,
        presets: null,
        downloader: null
    };

    function managedAssetCount() {
        var manager = window.cc && window.cc.assetManager;
        var assets = manager && manager.assets;
        return assets && typeof assets.count === 'number' ? assets.count : -1;
    }

    function nodeMemoryLabel(node) {
        var name = node && (node.name || node._name);
        if (!name && node && node.constructor) name = node.constructor.name;
        name = String(name || '<unnamed>');
        return name.length > 48 ? name.slice(0, 45) + '...' : name;
    }

    function incrementNodeMemoryCount(counts, key) {
        counts[key] = (counts[key] || 0) + 1;
    }

    function sceneNodeProfile() {
        try {
            var scene = window.cc && cc.director && cc.director.getScene && cc.director.getScene();
            if (!scene) return { nodes: -1, activeNodes: -1, inactiveNodes: -1, pendingDestroyNodes: -1 };
            var profile = {
                nodes: 0,
                activeNodes: 0,
                inactiveNodes: 0,
                pendingDestroyNodes: 0,
                rootCounts: {},
                branchCounts: {}
            };
            var stack = [{ node: scene, depth: 0, root: '', branch: '' }];
            while (stack.length) {
                var entry = stack.pop();
                var node = entry.node;
                if (!node) continue;
                profile.nodes++;
                if (node.activeInHierarchy !== false && node.active !== false) profile.activeNodes++;
                else profile.inactiveNodes++;
                try {
                    if (cc.isValid && cc.isValid(node) && !cc.isValid(node, true)) {
                        profile.pendingDestroyNodes++;
                    }
                } catch (ignored) {}

                var depth = entry.depth;
                var root = entry.root;
                var branch = entry.branch;
                if (depth === 1) {
                    root = nodeMemoryLabel(node);
                    branch = root;
                    incrementNodeMemoryCount(profile.rootCounts, root);
                } else if (depth > 1) {
                    if (depth <= IOS2_RUNTIME_MEMORY_BRANCH_DEPTH) {
                        branch += '/' + nodeMemoryLabel(node);
                    }
                    incrementNodeMemoryCount(profile.rootCounts, root || '<scene>');
                    incrementNodeMemoryCount(profile.branchCounts, branch || root || '<scene>');
                }
                var children = node._children || node.children || [];
                for (var index = 0; index < children.length; index++) {
                    stack.push({ node: children[index], depth: depth + 1, root: root, branch: branch });
                }
            }
            return profile;
        } catch (error) {
            return { nodes: -1, activeNodes: -1, inactiveNodes: -1, pendingDestroyNodes: -1 };
        }
    }

    function sortedNodeMemoryCounts(counts, limit) {
        if (!counts) return [];
        return Object.keys(counts).sort(function (left, right) {
            var difference = counts[right] - counts[left];
            return difference || (left < right ? -1 : left > right ? 1 : 0);
        }).slice(0, limit || IOS2_RUNTIME_MEMORY_ROOT_LIMIT).map(function (key) {
            return key + ':' + counts[key];
        });
    }

    function nodeMemoryGrowth(counts, previousCounts) {
        if (!counts || !previousCounts) return [];
        var keys = {};
        Object.keys(counts).forEach(function (key) { keys[key] = true; });
        Object.keys(previousCounts).forEach(function (key) { keys[key] = true; });
        return Object.keys(keys).map(function (key) {
            return { key: key, value: (counts[key] || 0) - (previousCounts[key] || 0) };
        }).filter(function (item) {
            return item.value !== 0;
        }).sort(function (left, right) {
            var difference = Math.abs(right.value) - Math.abs(left.value);
            return difference || (left.key < right.key ? -1 : left.key > right.key ? 1 : 0);
        }).slice(0, IOS2_RUNTIME_MEMORY_ROOT_LIMIT).map(function (item) {
            return item.key + (item.value > 0 ? ':+' : ':') + item.value;
        });
    }

    function runtimeMemorySnapshot() {
        var profile = sceneNodeProfile();
        return {
            assets: managedAssetCount(),
            nodes: profile.nodes,
            activeNodes: profile.activeNodes,
            inactiveNodes: profile.inactiveNodes,
            pendingDestroyNodes: profile.pendingDestroyNodes,
            rootCounts: profile.rootCounts,
            branchCounts: profile.branchCounts
        };
    }

    function formatRuntimeMemorySnapshot(snapshot, previousSnapshot) {
        var parts = [
            'assets=' + snapshot.assets,
            'nodes=' + snapshot.nodes,
            'active=' + snapshot.activeNodes,
            'inactive=' + snapshot.inactiveNodes,
            'pendingDestroy=' + snapshot.pendingDestroyNodes
        ];
        var roots = sortedNodeMemoryCounts(snapshot.rootCounts);
        var branches = sortedNodeMemoryCounts(snapshot.branchCounts);
        var growth = nodeMemoryGrowth(snapshot.branchCounts, previousSnapshot && previousSnapshot.branchCounts);
        if (roots.length) parts.push('roots=[' + roots.join(', ') + ']');
        if (branches.length) parts.push('branches=[' + branches.join(', ') + ']');
        if (growth.length) parts.push('growth=[' + growth.join(', ') + ']');
        return parts.join(', ');
    }

    function postRuntimeMemorySnapshot(reason, phase, snapshot) {
        snapshot = snapshot || runtimeMemorySnapshot();
        var previousSnapshot = runtimeMemoryState.lastSnapshot;
        var formatted = formatRuntimeMemorySnapshot(snapshot, previousSnapshot);
        console.log('[ios2-web] runtime memory (' + (reason || 'sample') + ')' +
            (phase ? ' ' + phase : '') + ' ' + formatted);
        runtimeMemoryState.lastSnapshot = snapshot;
        var handlers = window.webkit && window.webkit.messageHandlers;
        var handler = handlers && handlers.ios2Game;
        if (handler && typeof handler.postMessage === 'function') {
            try {
                handler.postMessage({
                    type: 'memory',
                    instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                    reason: reason || 'sample',
                    phase: phase || 'sample',
                    assets: snapshot.assets,
                    nodes: snapshot.nodes,
                    activeNodes: snapshot.activeNodes,
                    inactiveNodes: snapshot.inactiveNodes,
                    pendingDestroyNodes: snapshot.pendingDestroyNodes,
                    nodeDetails: formatted
                });
            } catch (ignored) {}
        }
        return snapshot;
    }

    function runRuntimeSoftCleanup(reason) {
        if (runtimeMemoryState.cleanupBusy || !window.cc) return false;
        runtimeMemoryState.cleanupBusy = true;
        runtimeMemoryState.lastCleanup = Date.now();
        reason = reason || 'page transition';
        var before = postRuntimeMemorySnapshot(reason, 'before');
        // Node destruction is the engine's job: the director already calls
        // cc.Object._deferredDestroy() at the end of every frame. Forcing it
        // at a page transition only destroys earlier than the engine decided,
        // which is exactly how nodes still referenced by the incoming page got
        // destroyed mid-handover. Nothing but GC is safe to trigger here.
        window.setTimeout(function () {
            try {
                if (cc.sys && typeof cc.sys.garbageCollect === 'function') {
                    cc.sys.garbageCollect();
                }
            } catch (error) {
                console.warn('[ios2-web] JavaScript garbageCollect failed', reason, error);
            }
            window.setTimeout(function () {
                runtimeMemoryState.cleanupBusy = false;
                var after = postRuntimeMemorySnapshot(reason, 'after');
                console.log('[ios2-web] runtime soft cleanup complete (' + reason + ') ' +
                    formatRuntimeMemorySnapshot(before) + ' -> ' + formatRuntimeMemorySnapshot(after));
            }, 0);
        }, 0);
        return true;
    }

    function scheduleRuntimeSoftCleanup(reason, delayMs) {
        if (!window.cc || !IOS2_RUNTIME_MEMORY_AUTOMATIC) return false;
        reason = reason || 'page transition';
        runtimeMemoryState.pendingCleanupReason = reason;
        if (runtimeMemoryState.cleanupTimer) {
            window.clearTimeout(runtimeMemoryState.cleanupTimer);
            runtimeMemoryState.cleanupTimer = null;
        }
        var delay = delayMs === undefined ? IOS2_RUNTIME_CLEANUP_DELAY_MS : Number(delayMs) || 0;
        var elapsed = runtimeMemoryState.lastCleanup ? Date.now() - runtimeMemoryState.lastCleanup : Infinity;
        if (elapsed < IOS2_RUNTIME_CLEANUP_MIN_INTERVAL_MS) {
            delay = Math.max(delay, IOS2_RUNTIME_CLEANUP_MIN_INTERVAL_MS - elapsed);
        }
        runtimeMemoryState.cleanupTimer = window.setTimeout(function () {
            runtimeMemoryState.cleanupTimer = null;
            var pendingReason = runtimeMemoryState.pendingCleanupReason || reason;
            runtimeMemoryState.pendingCleanupReason = '';
            runRuntimeSoftCleanup(pendingReason);
        }, delay);
        return true;
    }

    function scheduleRuntimeMemorySample(reason, delayMs) {
        if (!window.cc || !IOS2_RUNTIME_MEMORY_AUTOMATIC) return false;
        reason = reason || 'page transition';
        runtimeMemoryState.pendingSampleReason = reason;
        if (runtimeMemoryState.sampleTimer) return true;
        var now = Date.now();
        var elapsed = runtimeMemoryState.lastSample ? now - runtimeMemoryState.lastSample : Infinity;
        var delay = delayMs === undefined ? 1000 : Number(delayMs) || 0;
        if (elapsed < IOS2_RUNTIME_MEMORY_SAMPLE_MIN_INTERVAL_MS) {
            delay = Math.max(delay, IOS2_RUNTIME_MEMORY_SAMPLE_MIN_INTERVAL_MS - elapsed);
        }
        runtimeMemoryState.sampleTimer = window.setTimeout(function () {
            runtimeMemoryState.sampleTimer = null;
            runtimeMemoryState.lastSample = Date.now();
            var pendingReason = runtimeMemoryState.pendingSampleReason || reason;
            runtimeMemoryState.pendingSampleReason = '';
            postRuntimeMemorySnapshot(pendingReason, 'sample');
        }, delay);
        return true;
    }

    function isTrackedRuntimePage(name) {
        if (typeof name !== 'string' || !name) return false;
        if (IOS2_RUNTIME_MEMORY_PAGE_NAMES[name]) return true;
        return /^(Home|Main|Legion).*(Panel|Scene)$/.test(name);
    }

    function installRuntimeMemoryHooks() {
        if (window.__ios2RuntimeMemoryHooksInstalled) return;
        window.__ios2RuntimeMemoryHooksInstalled = true;

        // The remote launcher reports page transitions through console.log.
        // Observe those messages without changing their original output.
        if (window.console && typeof console.log === 'function' && !console.__ios2RuntimeMemoryHook) {
            var originalLog = console.log;
            console.__ios2RuntimeMemoryHook = true;
            console.log = function () {
                // Guarded as well: the game logs a lot, and doing two regex
                // passes plus an arguments walk on every single line is pure
                // overhead once sampling is off anyway.
                try {
                    if (IOS2_RUNTIME_MEMORY_AUTOMATIC) {
                        var parts = [];
                        for (var index = 0; index < arguments.length && index < 4; index++) {
                            var value = arguments[index];
                            if (typeof value === 'string' || typeof value === 'number') parts.push(String(value));
                        }
                        var message = parts.join(' ');
                        var pageMatch = /^(hide|show)\s+([^\s]+)/.exec(message);
                        if (pageMatch && isTrackedRuntimePage(pageMatch[2])) {
                            runtimeMemoryState.switchCount++;
                            scheduleRuntimeMemorySample(pageMatch[1] + ' ' + pageMatch[2]);
                            if (pageMatch[1] === 'hide' && runtimeMemoryState.switchCount >= 4) {
                                scheduleRuntimeSoftCleanup('page switches=' + runtimeMemoryState.switchCount);
                            }
                        } else if (/\bc_battle(Pause|Resume)\b/.test(message)) {
                            scheduleRuntimeMemorySample('battle transition');
                        }
                    }
                } catch (ignored) {}
                return originalLog.apply(this, arguments);
            };
        }

        if (window.document && typeof document.addEventListener === 'function') {
            document.addEventListener('visibilitychange', function () {
                if (document.hidden) scheduleRuntimeSoftCleanup('document hidden', 0);
                scheduleRuntimeMemorySample(document.hidden ? 'document hidden' : 'document visible', 0);
            });
        }

        try {
            if (cc.game && cc.game.EVENT_HIDE && typeof cc.game.on === 'function') {
                cc.game.on(cc.game.EVENT_HIDE, function () {
                    scheduleRuntimeSoftCleanup('game hidden', 0);
                });
            }
        } catch (error) {
            console.warn('[ios2-web] runtime memory lifecycle hook unavailable', error);
        }

        window.__ios2RuntimeMemorySnapshot = function (reason) {
            return postRuntimeMemorySnapshot(reason || 'manual', 'sample');
        };
        window.__ios2RuntimeSoftCleanup = runRuntimeSoftCleanup;
    }

    function releaseUnusedAssets(reason) {
        var manager = window.cc && window.cc.assetManager;
        if (!manager || typeof manager.releaseUnusedAssets !== 'function') return false;
        if (!assetReleaseState.shuttingDown) {
            console.warn('[ios2-web] ignored normal asset release request', reason || 'unknown');
            return false;
        }
        if (assetReleaseState.busy) return false;

        assetReleaseState.busy = true;
        var sequence = ++assetReleaseState.sequence;
        var before = managedAssetCount();
        try {
            manager.releaseUnusedAssets();
        } catch (error) {
            assetReleaseState.busy = false;
            console.warn('[ios2-web] Cocos releaseUnusedAssets failed', reason || 'unknown', error);
            return false;
        }

        // ReleaseManager defers destruction to the next tick. Log after that
        // tick so the count reflects the actual cleanup when available.
        window.setTimeout(function () {
            if (sequence !== assetReleaseState.sequence) return;
            assetReleaseState.busy = false;
            console.log('[ios2-web] Cocos unused assets released', reason || 'unknown',
                'assets=' + before + '->' + managedAssetCount());
        }, 0);
        return true;
    }
    window.__ios2ReleaseUnusedAssets = releaseUnusedAssets;

    function installStartupDownloadTracker() {
        var manager = window.cc && window.cc.assetManager;
        var downloader = manager && manager.downloader;
        if (!downloader || downloader.__ios2StartupDownloadTrackerInstalled) return;
        downloader.__ios2StartupDownloadTrackerInstalled = true;
        var originalDownload = downloader.download;
        if (typeof originalDownload !== 'function') return;
        downloader.download = function () {
            var args = Array.prototype.slice.call(arguments);
            var callbackIndex = args.length - 1;
            var callback = args[callbackIndex];
            if (typeof callback !== 'function' || !assetReleaseState.startupTrackingOpen) {
                return originalDownload.apply(this, args);
            }
            var finished = false;
            assetReleaseState.startupLastActivityAt = Date.now();
            assetReleaseState.startupDownloadCount++;
            args[callbackIndex] = function () {
                if (!finished) {
                    finished = true;
                    assetReleaseState.startupDownloadCount = Math.max(0,
                        assetReleaseState.startupDownloadCount - 1);
                    assetReleaseState.startupLastActivityAt = Date.now();
                }
                return callback.apply(this, arguments);
            };
            try {
                return originalDownload.apply(this, args);
            } catch (error) {
                if (!finished) {
                    finished = true;
                    assetReleaseState.startupDownloadCount = Math.max(0,
                        assetReleaseState.startupDownloadCount - 1);
                    assetReleaseState.startupLastActivityAt = Date.now();
                }
                throw error;
            }
        };
    }

    function isTrackedStartupURL(url) {
        return /^ios2-game:|xxz-xyzw-res\.hortorgames\.com/.test(String(url || ''));
    }

    // The encrypted bundle and PVR helpers use fetch directly in addition to
    // Cocos' downloader/XHR. Fetch resolves before arrayBuffer() has consumed
    // the body, so finish tracking when the body reader actually resolves.
    // API traffic is excluded; only local WebKit resources are tracked.
    function installStartupFetchTracker() {
        if (window.__ios2StartupFetchTrackerInstalled || typeof window.fetch !== 'function') return;
        window.__ios2StartupFetchTrackerInstalled = true;
        var originalFetch = window.fetch;
        window.fetch = function (input, init) {
            var url = typeof input === 'string' ? input : input && input.url;
            var tracked = assetReleaseState.startupTrackingOpen && isTrackedStartupURL(url);
            if (!tracked) return originalFetch.call(this, input, init);
            var finished = false;
            assetReleaseState.startupDownloadCount++;
            assetReleaseState.startupLastActivityAt = Date.now();
            var finish = function () {
                if (finished) return;
                finished = true;
                assetReleaseState.startupDownloadCount = Math.max(0,
                    assetReleaseState.startupDownloadCount - 1);
                assetReleaseState.startupLastActivityAt = Date.now();
            };
            var request;
            try {
                request = originalFetch.call(this, input, init);
            } catch (error) {
                finish();
                throw error;
            }
            return Promise.resolve(request).then(function (response) {
                var bodyMethods = ['arrayBuffer', 'blob', 'text', 'json', 'formData'];
                var wrapped = false;
                for (var i = 0; i < bodyMethods.length; i++) {
                    var method = bodyMethods[i];
                    if (!response || typeof response[method] !== 'function') continue;
                    var originalBodyMethod = response[method];
                    try {
                        (function (bodyMethod, originalMethod) {
                            response[bodyMethod] = function () {
                                var body;
                                try {
                                    body = originalMethod.apply(this, arguments);
                                } catch (error) {
                                    finish();
                                    throw error;
                                }
                                return Promise.resolve(body).then(function (value) {
                                    finish();
                                    return value;
                                }, function (error) {
                                    finish();
                                    throw error;
                                });
                            };
                        }(method, originalBodyMethod));
                        wrapped = true;
                    } catch (ignored) {}
                }
                if (!wrapped) finish();
                return response;
            }, function (error) {
                finish();
                throw error;
            });
        };
    }

    function installStartupXHRTracker() {
        if (window.__ios2StartupXHRTrackerInstalled || !window.XMLHttpRequest) return;
        var XHR = window.XMLHttpRequest;
        var prototype = XHR.prototype;
        if (!prototype || typeof prototype.open !== 'function' || typeof prototype.send !== 'function') return;
        window.__ios2StartupXHRTrackerInstalled = true;
        var originalOpen = prototype.open;
        var originalSend = prototype.send;
        prototype.open = function (method, url) {
            this.__ios2StartupURL = String(url || '');
            return originalOpen.apply(this, arguments);
        };
        prototype.send = function () {
            var xhr = this;
            if (!assetReleaseState.startupTrackingOpen || !isTrackedStartupURL(xhr.__ios2StartupURL)) {
                return originalSend.apply(this, arguments);
            }
            var finished = false;
            var finish = function () {
                if (finished) return;
                finished = true;
                if (typeof xhr.removeEventListener === 'function') xhr.removeEventListener('loadend', finish);
                assetReleaseState.startupDownloadCount = Math.max(0,
                    assetReleaseState.startupDownloadCount - 1);
                assetReleaseState.startupLastActivityAt = Date.now();
            };
            assetReleaseState.startupDownloadCount++;
            assetReleaseState.startupLastActivityAt = Date.now();
            if (typeof xhr.addEventListener === 'function') xhr.addEventListener('loadend', finish);
            try {
                return originalSend.apply(this, arguments);
            } catch (error) {
                finish();
                throw error;
            }
        };
    }

    function configureMultiOpenLoading(multiOpen, startupMode) {
        if (!multiOpen) return;
        var manager = window.cc && window.cc.assetManager;
        if (!manager) return;

        // Cocos 2.4 defaults scene/bundle loads to eight concurrent requests
        // and script loads to 1024. That is acceptable for one page, but four
        // independent WebContent heaps turn those queues into a large burst of
        // encrypted bytes, decoded source, image buffers and GPU uploads.
        var presets = manager.presets || {};
        runtimeLoadingState.configured = true;
        runtimeLoadingState.presets = {};
        function limitPreset(name, concurrency, requestsPerFrame) {
            if (!presets[name]) return;
            runtimeLoadingState.presets[name] = {
                maxConcurrency: presets[name].maxConcurrency,
                maxRequestsPerFrame: presets[name].maxRequestsPerFrame
            };
            presets[name].maxConcurrency = concurrency;
            presets[name].maxRequestsPerFrame = requestsPerFrame;
        }
        var serial = startupMode !== 'parallel';
        limitPreset('preload', 1, 1);
        limitPreset('scene', serial ? 1 : 2, 1);
        limitPreset('bundle', serial ? 1 : 2, 1);
        limitPreset('script', 1, 1);

        var downloader = manager.downloader;
        if (downloader) {
            runtimeLoadingState.downloader = {
                maxConcurrency: downloader.maxConcurrency,
                maxRequestsPerFrame: downloader.maxRequestsPerFrame
            };
            downloader.maxConcurrency = Math.min(Number(downloader.maxConcurrency) || 6, 2);
            downloader.maxRequestsPerFrame = Math.min(Number(downloader.maxRequestsPerFrame) || 6, 1);
        }
        console.log('[ios2-web] multi-open loading limits applied',
            'mode=' + (serial ? 'serial' : 'parallel'),
            'scene=' + (serial ? 1 : 2),
            'bundle=' + (serial ? 1 : 2), 'script=1');
    }

    function relaxInteractiveLoadingLimits() {
        if (!runtimeLoadingState.configured || runtimeLoadingState.relaxed) return;
        runtimeLoadingState.relaxed = true;
        var presets = window.cc && cc.assetManager && cc.assetManager.presets;
        var interactiveLimits = {
            preload: [2, 2],
            scene: [4, 4],
            bundle: [4, 4],
            script: [16, 16]
        };
        if (presets) {
            Object.keys(interactiveLimits).forEach(function (name) {
                var preset = presets[name];
                if (!preset) return;
                var limits = interactiveLimits[name];
                var original = runtimeLoadingState.presets && runtimeLoadingState.presets[name];
                var originalConcurrency = Number(original && original.maxConcurrency);
                var originalRequests = Number(original && original.maxRequestsPerFrame);
                preset.maxConcurrency = Math.min(originalConcurrency || limits[0], limits[0]);
                preset.maxRequestsPerFrame = Math.min(originalRequests || limits[1], limits[1]);
            });
        }
        var downloader = window.cc && cc.assetManager && cc.assetManager.downloader;
        var originalDownloader = runtimeLoadingState.downloader;
        if (downloader) {
            var originalConcurrency = Number(originalDownloader && originalDownloader.maxConcurrency);
            var originalRequests = Number(originalDownloader && originalDownloader.maxRequestsPerFrame);
            downloader.maxConcurrency = Math.min(originalConcurrency || 4, 4);
            downloader.maxRequestsPerFrame = Math.min(originalRequests || 4, 4);
        }
        console.log('[ios2-web] interactive loading limits restored',
            'scene=' + (presets && presets.scene && presets.scene.maxRequestsPerFrame || 0),
            'bundle=' + (presets && presets.bundle && presets.bundle.maxRequestsPerFrame || 0),
            'downloader=' + (downloader && downloader.maxRequestsPerFrame || 0));
    }

    function notifyStartupReadyAfterSettling(sceneError) {
        if (assetReleaseState.startupReadySent) return;
        // The scene callback means all scene dependencies are available. Any
        // request that remains open after this point is background traffic and
        // must not hold the next serial instance behind a long-lived CDN
        // connection.
        assetReleaseState.startupTrackingOpen = false;
        var startedAt = Date.now();
        var previousCount = managedAssetCount();
        var stableSamples = 0;
        if (!assetReleaseState.startupLastActivityAt) {
            assetReleaseState.startupLastActivityAt = startedAt;
        }

        function sendReady(forced) {
            if (assetReleaseState.startupReadySent) return;
            assetReleaseState.startupReadySent = true;
            // Startup is now complete. Relax the multi-open safety throttle so
            // interactive bundle loads do not process only one request/frame.
            relaxInteractiveLoadingLimits();
            var elapsedMs = Date.now() - startedAt;
            var message = {
                type: 'ready',
                instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                multiOpen: !!(window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.multiOpen),
                stable: !forced && !sceneError,
                assets: managedAssetCount(),
                pendingDownloads: assetReleaseState.startupDownloadCount,
                elapsedMs: elapsedMs
            };
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game) {
                window.webkit.messageHandlers.ios2Game.postMessage(message);
            }
            console.log('[ios2-web] startup settled',
                'assets=' + message.assets,
                'pendingDownloads=' + message.pendingDownloads,
                'elapsedMs=' + message.elapsedMs,
                'stable=' + message.stable);
            // 启动沉降完成 = 该到的资源都到了。从这一刻起，场景里还有画不出来的
            // 节点就是真的「缺块」，不再是加载中。自检看门狗在这里接管。
            installRenderIntegrityWatchdog();
        }

        function check() {
            var now = Date.now();
            var count = managedAssetCount();
            var pending = assetReleaseState.startupDownloadCount;
            var quiet = now - assetReleaseState.startupLastActivityAt >= IOS2_STARTUP_QUIET_MS;
            if (pending === 0 && quiet && count >= 0 && count === previousCount) {
                stableSamples++;
            } else {
                stableSamples = 0;
            }
            previousCount = count;
            if ((now - startedAt >= IOS2_STARTUP_MIN_SETTLE_MS &&
                 stableSamples >= IOS2_STARTUP_STABLE_SAMPLES) ||
                now - startedAt >= IOS2_STARTUP_MAX_SETTLE_MS) {
                sendReady(now - startedAt >= IOS2_STARTUP_MAX_SETTLE_MS);
                return;
            }
            window.setTimeout(check, IOS2_STARTUP_SETTLE_INTERVAL);
        }

        window.setTimeout(check, IOS2_STARTUP_SETTLE_INTERVAL);
    }

    // Logout closes the whole game instance, so it is safe to tear down the
    // director and release every Cocos asset before the native WKWebView is
    // removed. This is intentionally separate from normal scene cleanup.
    function shutdownGame() {
        var manager = window.cc && window.cc.assetManager;
        if (!manager || assetReleaseState.shuttingDown) return !!manager;
        assetReleaseState.shuttingDown = true;
        try {
            if (window.cc.game && typeof window.cc.game.pause === 'function') window.cc.game.pause();
            var director = window.cc.director;
            if (director && typeof director.purgeDirector === 'function') {
                director.purgeDirector();
            }
            // cc.assetManager.releaseAll() frees every tracked asset no matter
            // what its reference count is. Cocos documents it as a blunt
            // instrument for tearing a game down, and it is the direct cause of
            // "textures vanish after switching back" whenever it is reached
            // while anything still holds a reference.
            //
            // cc.assetManager.releaseUnusedAssets() is the only safe form: it
            // walks the asset table and frees just the assets whose reference
            // count already reached zero (unreferenced / orphaned resources).
            // Everything still referenced by FGUI, Spine or the native bridge
            // is kept, so a resumed page still has its textures.
            //
            // https://docs.cocos.com/creator/2.4/manual/zh/asset-manager/release-manager.html
            releaseUnusedAssets('shutdown');
            console.log('[ios2-web] Cocos game instance shut down',
                'assets=' + managedAssetCount());
        } catch (error) {
            console.warn('[ios2-web] Cocos game shutdown failed', error);
        }
        return true;
    }
    window.__ios2ShutdownGame = shutdownGame;

    function installAssetReleaseHooks() {
        if (window.__ios2AssetReleaseHooksInstalled) return;
        window.__ios2AssetReleaseHooksInstalled = true;
        installRuntimeMemoryHooks();
        // Do not release assets when a WebView is backgrounded or hidden.
        // The instance can resume with the same scene and resource graph.
    }

    // 场景切换期间的资源释放闸门 —— 「来回切几次后某个场景元素不全」的根因。
    //
    // Cocos 的资源释放是**引用计数驱动**的：`Asset.decRef()` 一旦把计数减到 0，
    // 就会 `tryRelease()` 进去，下一帧 `_free()` 真正 `destroy()` —— 纹理的 GL
    // 句柄一起删掉，而且会**递归释放它的依赖**（见引擎 release-manager 的
    // `_free`：`o.decRef(!1), m._free(o, !1)`）。
    //
    // 引用计数是**全局共享**的，不认场景归属。所以：
    //   切走 A → A 的依赖 decRef → 公共图标 / 图集 / FairyGUI 包的计数掉到 0
    //   → 下一帧被 destroy → B 随后加载时拿到一个已销毁的 asset
    //   → Sprite 的纹理 isValid 为 false → assembler 静默跳过 → 画面少一块
    //
    // 时序上它天然是竞态：切走得早一点就撞上，晚一点就没事，所以「来回切几
    // 次」才会概率复现，而且是随机缺不同的块。
    //
    // 之前只门控了 `releaseUnusedAssets()` 这一个出口，引用计数这条自动释放
    // 路径完全没堵，所以问题反复出现。
    var sceneTransitionState = {
        releaseBlockedUntil: 0,
        /// 闸门开启的起点，用来算总时长上限。
        armedAt: 0,
        blocked: 0,
        transitions: 0,
        /// 被拦下的释放请求。不是丢弃，是**延后**——见 flushDeferredReleases。
        deferred: []
    };
    /// 切换窗口长度。要盖住「旧场景销毁 → 新场景资源异步加载完成」整段，
    /// 切场景往往跟几批 bundle 加载，给 5s 比较稳。
    var IOS2_SCENE_TRANSITION_GUARD_MS = 5000;
    /// 闸门期内每拦到一次释放就往后顺延的时长：还有释放请求涌进来，说明
    /// 切换与随之而来的加载仍在进行，不能急着放行。
    var IOS2_SCENE_RELEASE_EXTEND_MS = 1500;
    /// 闸门总时长上限。多开时资源回来得慢（共享 CDN 队列 + 主线程排队），
    /// 顺延可能一直续下去，这里兜个底，避免资源永远不被回收。
    var IOS2_SCENE_RELEASE_MAX_MS = 30000;
    /// 延后队列上限，防止整包卸载时无限堆积。
    var IOS2_SCENE_RELEASE_QUEUE_LIMIT = 4096;

    function markSceneTransition(reason) {
        sceneTransitionState.transitions++;
        sceneTransitionState.armedAt = Date.now();
        sceneTransitionState.releaseBlockedUntil = Date.now() + IOS2_SCENE_TRANSITION_GUARD_MS;
        console.log('[ios2-web] scene transition armed (' + reason + ')',
            'transitions=' + sceneTransitionState.transitions);
    }

    // 闸门关闭后再补执行被拦下的释放。
    //
    // 这里**不能**简单地丢掉被拦截的释放请求，否则这些资源永远不会被回收。
    // 延后执行是安全的：引擎的 `_free()` 在非强制模式下会先看 `refCount`，
    // 若新场景已经重新引用了这个资源（refCount > 0），它会跳过销毁 ——
    // 这正好是我们要的语义：切换期间误判的释放，会在窗口结束时自动作废。
    function flushDeferredReleases() {
        var releaseManager = window.cc && cc.assetManager && cc.assetManager._releaseManager;
        if (!releaseManager || !releaseManager.__ios2OriginalTryRelease) return;
        var queued = sceneTransitionState.deferred;
        sceneTransitionState.deferred = [];
        if (!queued.length) return;
        var freed = 0;
        for (var index = 0; index < queued.length; index++) {
            var asset = queued[index];
            try {
                // refCount 已恢复的会被引擎自己跳过，无需在这里判断。
                releaseManager.__ios2OriginalTryRelease.call(releaseManager, asset);
                freed++;
            } catch (error) {
                console.warn('[ios2-web] deferred release failed', error);
            }
        }
        console.log('[ios2-web] deferred asset releases flushed',
            'queued=' + queued.length, 'passed=' + freed);
    }

    function installAssetReleaseGate() {
        var manager = window.cc && window.cc.assetManager;
        var releaseManager = manager && manager._releaseManager;
        if (!releaseManager || releaseManager.__ios2ReleaseGateInstalled) return;
        if (typeof releaseManager.tryRelease !== 'function') return;
        releaseManager.__ios2ReleaseGateInstalled = true;
        var original = releaseManager.tryRelease;
        releaseManager.__ios2OriginalTryRelease = original;
        releaseManager.tryRelease = function (asset, force) {
            // 显式强制释放（releaseAsset(asset, true) 这类）与实例真正关闭，
            // 都保持原样不拦——那是明确的销毁意图。
            if (force || assetReleaseState.shuttingDown) {
                return original.apply(this, arguments);
            }
            var now = Date.now();
            // 闸门期内但队列已经过长：说明这次切换释放面极大（整包卸载），
            // 再囤下去只会白占内存，直接放行交给引擎原逻辑。
            if (now < sceneTransitionState.releaseBlockedUntil &&
                sceneTransitionState.deferred.length < IOS2_SCENE_RELEASE_QUEUE_LIMIT) {
                sceneTransitionState.blocked++;
                sceneTransitionState.deferred.push(asset);
                // 顺延，但不超过总上限。
                if (sceneTransitionState.armedAt) {
                    sceneTransitionState.releaseBlockedUntil = Math.min(
                        Math.max(sceneTransitionState.releaseBlockedUntil,
                            now + IOS2_SCENE_RELEASE_EXTEND_MS),
                        sceneTransitionState.armedAt + IOS2_SCENE_RELEASE_MAX_MS);
                }
                if (sceneTransitionState.blocked <= 3 || sceneTransitionState.blocked % 200 === 0) {
                    console.log('[ios2-web] deferred asset release during scene transition',
                        sceneTransitionState.blocked,
                        asset && (asset._name || asset.nativeUrl || asset.uuid));
                }
                return;
            }
            return original.apply(this, arguments);
        };
        console.log('[ios2-web] asset release gate installed');
    }

    // 等闸门真正关闭再收尾：先补执行被拦下的释放，再验一次渲染完整性。
    // 这时还画不出来的节点就是真缺块，不是「资源还在路上」。
    //
    // 防重入标记必须在函数外：写在函数里的话每次调用都重新置 false，
    // 连续两次切场景会起两条并行的检查链，flush 和自检都会重复跑。
    var postTransitionCheckScheduled = false;

    function schedulePostTransitionCheck() {
        function check() {
            if (Date.now() < sceneTransitionState.releaseBlockedUntil) {
                // 闸门被顺延了（多开时资源回来得慢，切换期间还有释放请求在涌入）。
                window.setTimeout(check, 1000);
                return;
            }
            postTransitionCheckScheduled = false;
            flushDeferredReleases();
            reportRenderIntegrity('scene transition');
        }
        if (postTransitionCheckScheduled) return;
        postTransitionCheckScheduled = true;
        var delay = Math.max(500, sceneTransitionState.releaseBlockedUntil - Date.now() + 500);
        window.setTimeout(check, delay);
    }

    function installDirectorAssetReleaseHook() {
        var director = window.cc && window.cc.director;
        var Director = window.cc && window.cc.Director;
        if (!director || !Director || director.__ios2AssetReleaseHookInstalled) return;
        director.__ios2AssetReleaseHookInstalled = true;
        installAssetReleaseGate();

        // 场景切换的入口不止一个，三处一起武装：loadScene / runScene /
        // preloadScene 覆盖代码调用，BEFORE/AFTER_SCENE_LAUNCH 覆盖引擎内部
        // 与常驻节点路径。
        ['loadScene', 'runScene', 'preloadScene'].forEach(function (name) {
            if (typeof director[name] !== 'function') return;
            var original = director[name];
            director[name] = function () {
                markSceneTransition(name);
                return original.apply(this, arguments);
            };
        });
        if (typeof director.on === 'function') {
            if (Director.EVENT_BEFORE_SCENE_LAUNCH) {
                director.on(Director.EVENT_BEFORE_SCENE_LAUNCH, function () {
                    markSceneTransition('before scene launch');
                });
            }
            if (Director.EVENT_AFTER_SCENE_LAUNCH) {
                director.on(Director.EVENT_AFTER_SCENE_LAUNCH, function () {
                    markSceneTransition('after scene launch');
                    schedulePostTransitionCheck();
                });
            }
        }
    }

    function decryptJSC(data, keyText) {
        var bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
        var keyBytes = new TextEncoder().encode(keyText);
        var key = new Uint8Array(16);
        key.set(keyBytes.subarray(0, 16));

        function uint32(source, includeLength) {
            var length = source.length;
            var count = Math.ceil(length / 4);
            var values = new Uint32Array(count + (includeLength ? 1 : 0));
            for (var index = 0; index < length; index++) {
                values[index >>> 2] |= source[index] << ((index & 3) << 3);
            }
            if (includeLength) values[count] = length;
            return values;
        }

        var values = uint32(bytes, false);
        var keyValues = uint32(key, false);
        var last = values.length - 1;
        if (last < 1) return bytes;
        var rounds = Math.floor(6 + 52 / values.length);
        var sum = rounds * 0x9E3779B9;
        var y = values[0];
        while (sum !== 0) {
            var e = sum >>> 2 & 3;
            for (var position = last; position > 0; position--) {
                var z = values[position - 1];
                var mix = ((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
                    ((sum ^ y) + (keyValues[position & 3 ^ e] ^ z));
                y = values[position] = values[position] - mix >>> 0;
            }
            z = values[last];
            mix = ((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
                ((sum ^ y) + (keyValues[e] ^ z));
            y = values[0] = values[0] - mix >>> 0;
            sum = sum - 0x9E3779B9 >>> 0;
        }

        var decodedLength = values[last];
        var maximumLength = last << 2;
        if (decodedLength < maximumLength - 3 || decodedLength > maximumLength) {
            throw new Error('Invalid XXTEA payload length');
        }
        var output = new Uint8Array(decodedLength);
        for (var outputIndex = 0; outputIndex < decodedLength; outputIndex++) {
            output[outputIndex] = values[outputIndex >>> 2] >>> ((outputIndex & 3) << 3) & 0xFF;
        }
        return output;
    }
    window.__ios2DecryptJSC = decryptJSC;

    function installTypeScriptRuntimeHelpers() {
        var extendStatics = Object.setPrototypeOf ||
            ({ __proto__: [] } instanceof Array && function (target, source) { target.__proto__ = source; }) ||
            function (target, source) {
                for (var key in source) {
                    if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
                }
            };

        if (typeof window.__extends !== 'function') {
            window.__extends = function (derived, base) {
                if (typeof base !== 'function' && base !== null) {
                    throw new TypeError('Class extends value ' + String(base) + ' is not a constructor or null');
                }
                extendStatics(derived, base);
                function TemporaryConstructor() { this.constructor = derived; }
                derived.prototype = base === null ? Object.create(base) :
                    (TemporaryConstructor.prototype = base.prototype, new TemporaryConstructor());
            };
        }
        if (typeof window.__assign !== 'function') {
            window.__assign = Object.assign || function (target) {
                for (var source, index = 1, length = arguments.length; index < length; index++) {
                    source = arguments[index];
                    for (var key in source) {
                        if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
                    }
                }
                return target;
            };
        }
        if (typeof window.__rest !== 'function') {
            window.__rest = function (source, exclude) {
                var target = {};
                for (var key in source) {
                    if (Object.prototype.hasOwnProperty.call(source, key) && exclude.indexOf(key) < 0) target[key] = source[key];
                }
                if (source !== null && typeof Object.getOwnPropertySymbols === 'function') {
                    var symbols = Object.getOwnPropertySymbols(source);
                    for (var index = 0; index < symbols.length; index++) {
                        if (exclude.indexOf(symbols[index]) < 0 && Object.prototype.propertyIsEnumerable.call(source, symbols[index])) {
                            target[symbols[index]] = source[symbols[index]];
                        }
                    }
                }
                return target;
            };
        }
        if (typeof window.__decorate !== 'function') {
            window.__decorate = function (decorators, target, key, descriptor) {
                var result, count = arguments.length;
                var value = count < 3 ? target : descriptor === null ? descriptor = Object.getOwnPropertyDescriptor(target, key) : descriptor;
                if (typeof Reflect === 'object' && typeof Reflect.decorate === 'function') {
                    value = Reflect.decorate(decorators, target, key, descriptor);
                } else {
                    for (var index = decorators.length - 1; index >= 0; index--) {
                        if ((result = decorators[index])) {
                            value = (count < 3 ? result(value) : count > 3 ? result(target, key, value) : result(target, key)) || value;
                        }
                    }
                }
                return count > 3 && value && Object.defineProperty(target, key, value), value;
            };
        }
        if (typeof window.__param !== 'function') {
            window.__param = function (paramIndex, decorator) {
                return function (target, key) { decorator(target, key, paramIndex); };
            };
        }
        if (typeof window.__metadata !== 'function') {
            window.__metadata = function (metadataKey, metadataValue) {
                if (typeof Reflect === 'object' && typeof Reflect.metadata === 'function') {
                    return Reflect.metadata(metadataKey, metadataValue);
                }
            };
        }
        if (typeof window.__awaiter !== 'function') {
            window.__awaiter = function (thisArg, args, PromiseCtor, generator) {
                function adopt(value) {
                    return value instanceof PromiseCtor ? value : new PromiseCtor(function (resolve) { resolve(value); });
                }
                return new (PromiseCtor || (PromiseCtor = Promise))(function (resolve, reject) {
                    function fulfilled(value) { try { step(generator.next(value)); } catch (error) { reject(error); } }
                    function rejected(value) { try { step(generator.throw(value)); } catch (error) { reject(error); } }
                    function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
                    step((generator = generator.apply(thisArg, args || [])).next());
                });
            };
        }
        if (typeof window.__generator !== 'function') {
            window.__generator = function (thisArg, body) {
                var state = { label: 0, sent: sent, trys: [], ops: [] };
                var iterator, result, operation, generator = { next: verb(0), throw: verb(1), return: verb(2) };
                if (typeof Symbol === 'function') generator[Symbol.iterator] = function () { return this; };
                return generator;

                function sent() {
                    if (result[0] & 1) throw result[1];
                    return result[1];
                }
                function verb(type) { return function (value) { return step([type, value]); }; }
                function step(op) {
                    if (iterator) throw new TypeError('Generator is already executing.');
                    while (state) {
                        try {
                            iterator = 1;
                            if (result && (operation = op[0] & 2 ? result.return : op[0] ? result.throw || ((operation = result.return) && operation.call(result), 0) : result.next) && !(operation = operation.call(result, op[1])).done) return operation;
                            result = 0;
                            if (operation) op = [op[0] & 2, operation.value];
                            switch (op[0]) {
                            case 0:
                            case 1:
                                operation = op;
                                break;
                            case 4:
                                state.label++;
                                return { value: op[1], done: false };
                            case 5:
                                state.label++;
                                result = op[1];
                                op = [0];
                                continue;
                            case 7:
                                op = state.ops.pop();
                                state.trys.pop();
                                continue;
                            default:
                                operation = state.trys;
                                operation = operation.length > 0 && operation[operation.length - 1];
                                if (!operation && (op[0] === 6 || op[0] === 2)) { state = 0; continue; }
                                if (op[0] === 3 && (!operation || (op[1] > operation[0] && op[1] < operation[3]))) { state.label = op[1]; break; }
                                if (op[0] === 6 && state.label < operation[1]) { state.label = operation[1]; operation = op; break; }
                                if (operation && state.label < operation[2]) { state.label = operation[2]; state.ops.push(op); break; }
                                if (operation[2]) state.ops.pop();
                                state.trys.pop();
                                continue;
                            }
                            op = body.call(thisArg, state);
                        } catch (error) {
                            op = [6, error];
                            result = 0;
                        } finally {
                            iterator = operation = 0;
                        }
                    }
                    if (op[0] & 5) throw op[1];
                    return { value: op[0] ? op[1] : void 0, done: true };
                }
            };
        }
        if (typeof window.__createBinding !== 'function') {
            window.__createBinding = Object.create ? function (target, module, key, alias) {
                if (alias === undefined) alias = key;
                Object.defineProperty(target, alias, { enumerable: true, get: function () { return module[key]; } });
            } : function (target, module, key, alias) {
                if (alias === undefined) alias = key;
                target[alias] = module[key];
            };
        }
        if (typeof window.__exportStar !== 'function') {
            window.__exportStar = function (module, exports) {
                for (var key in module) {
                    if (key !== 'default' && !Object.prototype.hasOwnProperty.call(exports, key)) window.__createBinding(exports, module, key);
                }
            };
        }
        if (typeof window.__values !== 'function') {
            window.__values = function (value) {
                var iteratorSymbol = typeof Symbol === 'function' && Symbol.iterator;
                var iterator = iteratorSymbol && value[iteratorSymbol];
                var index = 0;
                if (iterator) return iterator.call(value);
                if (value && typeof value.length === 'number') {
                    return { next: function () {
                        if (value && index >= value.length) value = void 0;
                        return { value: value && value[index++], done: !value };
                    } };
                }
                throw new TypeError(iteratorSymbol ? 'Object is not iterable.' : 'Symbol.iterator is not defined.');
            };
        }
        if (typeof window.__read !== 'function') {
            window.__read = function (value, count) {
                var iteratorSymbol = typeof Symbol === 'function' && value[Symbol.iterator];
                if (!iteratorSymbol) return value;
                var iterator = iteratorSymbol.call(value), item, error, result = [];
                try {
                    while ((count === undefined || count-- > 0) && !(item = iterator.next()).done) result.push(item.value);
                } catch (exception) {
                    error = { error: exception };
                } finally {
                    try {
                        if (item && !item.done && (iteratorSymbol = iterator.return)) iteratorSymbol.call(iterator);
                    } finally {
                        if (error) throw error.error;
                    }
                }
                return result;
            };
        }
        if (typeof window.__spread !== 'function') {
            window.__spread = function () {
                var result = [];
                for (var index = 0; index < arguments.length; index++) result = result.concat(window.__read(arguments[index]));
                return result;
            };
        }
        if (typeof window.__spreadArrays !== 'function') {
            window.__spreadArrays = function () {
                var total = 0;
                for (var index = 0; index < arguments.length; index++) total += arguments[index].length;
                var result = Array(total), offset = 0;
                for (index = 0; index < arguments.length; index++) {
                    var source = arguments[index];
                    for (var itemIndex = 0; itemIndex < source.length; itemIndex++, offset++) result[offset] = source[itemIndex];
                }
                return result;
            };
        }
        if (typeof window.__spreadArray !== 'function') {
            window.__spreadArray = function (target, source, pack) {
                if (pack || arguments.length === 2) {
                    for (var index = 0, length = source.length, copy; index < length; index++) {
                        if (copy || !(index in source)) {
                            if (!copy) copy = Array.prototype.slice.call(source, 0, index);
                            copy[index] = source[index];
                        }
                    }
                    source = copy || Array.prototype.slice.call(source);
                }
                return target.concat(source);
            };
        }
        if (typeof window.__await !== 'function') {
            window.__await = function (value) {
                return this instanceof window.__await ? (this.v = value, this) : new window.__await(value);
            };
        }
        if (typeof window.__asyncGenerator !== 'function') {
            window.__asyncGenerator = function (thisArg, args, generator) {
                if (!Symbol.asyncIterator) throw new TypeError('Symbol.asyncIterator is not defined.');
                var method, gen = generator.apply(thisArg, args || []), queue = [];
                var asyncIterator = {};
                resume('next');
                resume('throw', function (value) { throw value; });
                resume('return');
                asyncIterator[Symbol.asyncIterator] = function () { return this; };
                return asyncIterator;

                function resume(name, fallback) {
                    if (gen[name]) asyncIterator[name] = function (value) {
                        return new Promise(function (resolve, reject) {
                            queue.push([name, value, resolve, reject]) > 1 || step(name, value);
                        });
                    };
                    else if (fallback) asyncIterator[name] = fallback;
                }
                function step(name, value) {
                    try {
                        method = gen[name](value);
                        method.value instanceof window.__await ? Promise.resolve(method.value.v).then(next, fail) : settle(queue[0][2], method);
                    } catch (error) {
                        settle(queue[0][3], error);
                    }
                }
                function next(value) { step('next', value); }
                function fail(value) { step('throw', value); }
                function settle(resolve, value) {
                    resolve(value);
                    queue.shift();
                    if (queue.length) step(queue[0][0], queue[0][1]);
                }
            };
        }
        if (typeof window.__asyncDelegator !== 'function') {
            window.__asyncDelegator = function (iterator) {
                var pending, delegator = {};
                verb('next');
                verb('throw', function (value) { throw value; });
                verb('return');
                delegator[Symbol.iterator] = function () { return this; };
                return delegator;

                function verb(name, fallback) {
                    delegator[name] = iterator[name] ? function (value) {
                        return (pending = !pending) ? { value: window.__await(iterator[name](value)), done: name === 'return' } :
                            fallback ? fallback(value) : value;
                    } : fallback;
                }
            };
        }
        if (typeof window.__asyncValues !== 'function') {
            window.__asyncValues = function (value) {
                if (!Symbol.asyncIterator) throw new TypeError('Symbol.asyncIterator is not defined.');
                var iterator = value[Symbol.asyncIterator];
                var asyncIterator;
                if (iterator) return iterator.call(value);
                value = typeof window.__values === 'function' ? window.__values(value) : value[Symbol.iterator]();
                asyncIterator = {};
                verb('next');
                verb('throw');
                verb('return');
                asyncIterator[Symbol.asyncIterator] = function () { return this; };
                return asyncIterator;

                function verb(name) {
                    asyncIterator[name] = value[name] && function (arg) {
                        return new Promise(function (resolve, reject) {
                            settle(resolve, reject, (arg = value[name](arg)).done, arg.value);
                        });
                    };
                }
                function settle(resolve, reject, done, value) {
                    Promise.resolve(value).then(function (value) { resolve({ value: value, done: done }); }, reject);
                }
            };
        }
        if (typeof window.__makeTemplateObject !== 'function') {
            window.__makeTemplateObject = function (cooked, raw) {
                if (Object.defineProperty) Object.defineProperty(cooked, 'raw', { value: raw });
                else cooked.raw = raw;
                return cooked;
            };
        }
        if (typeof window.__importStar !== 'function') {
            window.__importStar = function (module) {
                if (module && module.__esModule) return module;
                var result = {};
                if (module != null) {
                    for (var key in module) {
                        if (key !== 'default' && Object.prototype.hasOwnProperty.call(module, key)) window.__createBinding(result, module, key);
                    }
                }
                Object.defineProperty(result, 'default', { enumerable: true, value: module });
                return result;
            };
        }
        if (typeof window.__importDefault !== 'function') {
            window.__importDefault = function (module) {
                return module && module.__esModule ? module : { default: module };
            };
        }
        if (typeof window.__classPrivateFieldGet !== 'function') {
            window.__classPrivateFieldGet = function (receiver, privateMap) {
                if (!privateMap.has(receiver)) throw new TypeError('attempted to get private field on non-instance');
                return privateMap.get(receiver);
            };
        }
        if (typeof window.__classPrivateFieldSet !== 'function') {
            window.__classPrivateFieldSet = function (receiver, privateMap, value) {
                if (!privateMap.has(receiver)) throw new TypeError('attempted to set private field on non-instance');
                privateMap.set(receiver, value);
                return value;
            };
        }
    }

    function installEncryptedBundleLoader() {
        var downloader = cc.assetManager && cc.assetManager.downloader;
        if (!downloader || downloader.__ios2EncryptedBundles) return;
        downloader.__ios2EncryptedBundles = true;
        var originalScripts = downloader._downloaders || {};
        var originalJSONDownloader = originalScripts['.json'];
        var originalScriptDownloader = originalScripts['.js'];
        // Remote bundles can arrive as ios2-game://app/remote/<name>/... or
        // ios2-game://app/<name>/... depending on which loader requested them.
        var encryptedBundle = /(?:^|\/)(?:remote\/)?(?:game|launcher|TEST_REMOTE_MODULE)\/index\.[^/]+\.js(?:\?|$)/;
        var loaded = Object.create(null);

        function execute(code, url) {
            installTypeScriptRuntimeHelpers();
            code = code.replace(/cc\.assetManager\.loadAny=function\(\)\{\},?/g, '');
            code = code.replace(/[a-zA-Z]\.PlatformManager\.instance\.isH5&&\(cc\.assetManager\.loadBundle=function\(\)\{\}\),?/g, '');
            // Keep Cocos in its WebKit runtime, but expose the native iOS
            // business profile to the remote game's PlatformManager.
            var nativeProfileApplied = false;
            code = code.replace(/get _isH5\(\)\{return [^{}]*\},get isH5\(\)\{/,
                function () {
                    nativeProfileApplied = true;
                    return 'get _isH5(){return!1},get isH5(){';
                });
            if (nativeProfileApplied) {
                console.log('[ios2-web] native iOS platform profile applied', url);
            }
            (0, eval)(code + '\n//# sourceURL=' + url);
            // launcher installs a JSB-only PVR parser while applying its ASTC
            // patch. Restore the WebKit parser after each remote bundle runs.
            installASTCTextureSupport();
        }

        downloader.register('.js', function (url, options, onComplete) {
            if (!encryptedBundle.test(url)) {
                return originalScriptDownloader(url, options, onComplete);
            }
            var encryptedURL = url + 'c';
            if (loaded[encryptedURL]) {
                onComplete(null);
                return;
            }
            fetch(encryptedURL, { cache: 'force-cache' })
                .then(function (response) {
                    if (!response.ok) throw new Error('download failed: ' + encryptedURL + ', status: ' + response.status);
                    return response.arrayBuffer();
                })
                .then(function (buffer) {
                    var bytes = decryptJSC(buffer, '0Aed5E79bbEa69f8');
                    var code = new TextDecoder().decode(bytes);
                    execute(code, encryptedURL);
                    loaded[encryptedURL] = true;
                    console.log('[ios2-web] decrypted bundle', encryptedURL, bytes.length);
                    // Do not keep the encrypted/decrypted copies alive after
                    // eval. Four WebKit instances otherwise retain several
                    // extra bundle-sized buffers during the startup burst.
                    bytes = null;
                    code = null;
                    buffer = null;
                    onComplete(null);
                })
                .catch(function (error) { onComplete(error); });
        });

        function downloadJSON(url, options, onComplete) {
            if (typeof originalJSONDownloader === 'function') {
                return originalJSONDownloader(url, options, onComplete);
            }
            fetch(url, { cache: 'force-cache' })
                .then(function (response) {
                    if (!response.ok) throw new Error('download failed: ' + url + ', status: ' + response.status);
                    return response.json();
                })
                .then(function (json) { onComplete(null, json); })
                .catch(function (error) { onComplete(error); });
        }

        function downloadBundle(url, options, onComplete) {
            var bundleName = cc.path.basename(url);
            var version = options.version || downloader.bundleVers && downloader.bundleVers[bundleName];
            var versionPart = version ? version + '.' : '';
            var completeCount = 0;
            var failure = null;
            var config = null;

            function done(error) {
                if (error && !failure) failure = error;
                completeCount++;
                if (completeCount === 2) onComplete(failure, config);
            }

            downloadJSON(url + '/config.' + versionPart + 'json', options, function (error, data) {
                if (data) {
                    data.base = url + '/';
                    config = data;
                }
                done(error);
            });
            downloader._downloaders['.js'](url + '/index.' + versionPart + 'js', options, done);
        }

        downloader.register('bundle', downloadBundle);
        console.log('[ios2-web] custom bundle loader installed');
    }
    window.__ios2InstallEncryptedBundleLoader = installEncryptedBundleLoader;

    function postWebGraphicsLog(event, message, details) {
        console.log('[ios2-web] ' + message);
        var handlers = window.webkit && window.webkit.messageHandlers;
        var handler = handlers && handlers.ios2Game;
        if (!handler || typeof handler.postMessage !== 'function') return;
        try {
            var payload = {
                type: 'graphics',
                instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                event: event,
                message: message
            };
            if (details) {
                Object.keys(details).forEach(function (key) {
                    var value = details[key];
                    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
                        payload[key] = value;
                    }
                });
            }
            handler.postMessage(payload);
        } catch (ignored) {}
    }

    function parseASTCPVRBuffer(file) {
        var bytes;
        if (file instanceof ArrayBuffer) {
            bytes = new Uint8Array(file);
        } else if (file && file.buffer instanceof ArrayBuffer) {
            bytes = new Uint8Array(file.buffer, file.byteOffset || 0,
                file.byteLength === undefined ? file.length : file.byteLength);
        }
        if (!bytes || bytes.length < 16 || bytes[0] !== 0x13 || bytes[1] !== 0xAB ||
            bytes[2] !== 0xA1 || bytes[3] !== 0x5C) {
            throw new Error('Unsupported PVR texture header');
        }
        var blockX = bytes[4];
        var blockY = bytes[5];
        var blockZ = bytes[6];
        var width = bytes[7] | bytes[8] << 8 | bytes[9] << 16;
        var height = bytes[10] | bytes[11] << 8 | bytes[12] << 16;
        var formats = {
            '4x4': 0x93B0, '5x4': 0x93B1, '5x5': 0x93B2,
            '6x5': 0x93B3, '6x6': 0x93B4, '8x5': 0x93B5,
            '8x6': 0x93B6, '8x8': 0x93B7, '10x5': 0x93B8,
            '10x6': 0x93B9, '10x8': 0x93BA, '10x10': 0x93BB,
            '12x10': 0x93BC, '12x12': 0x93BD
        };
        var internalFormat = formats[blockX + 'x' + blockY];
        if (blockZ !== 1 || !width || !height || !internalFormat) {
            throw new Error('Unsupported ASTC texture header');
        }
        var payloadLength = Math.ceil(width / blockX) * Math.ceil(height / blockY) * 16;
        if (16 + payloadLength > bytes.length) {
            throw new Error('Truncated ASTC texture payload');
        }
        return {
            _compressed: true,
            _data: new Uint8Array(bytes.buffer, bytes.byteOffset + 16, payloadLength),
            width: width,
            height: height,
            __ios2ASTCFormat: internalFormat
        };
    }

    // `gl.getExtension()` 是一次到 GPU 进程的同步往返。纹理上传是热路径（一个
    // 场景几百张 PVR），每次都查一遍既慢，又会在 GPU 进程繁忙时偶发返回 null
    // ——返回 null 就抛错，抛错就等于这张贴图永久不画（引擎不报错，只是不画）。
    // 缓存到 gl 对象上；上下文丢失时由 resetASTCExtensionCache() 主动作废。
    var astcExtensionCache = { gl: null, value: undefined };

    function astcExtensionFor(gl) {
        if (astcExtensionCache.gl !== gl || astcExtensionCache.value === undefined) {
            astcExtensionCache.gl = gl;
            astcExtensionCache.value = gl.getExtension('WEBGL_compressed_texture_astc') || null;
        }
        return astcExtensionCache.value;
    }

    function resetASTCExtensionCache() {
        astcExtensionCache.gl = null;
        astcExtensionCache.value = undefined;
    }

    function isRecoverableASTCPVRTexture(texture) {
        // 注意：这里**不能**要求 texture.loaded。
        //
        // loaded 为 false 恰恰是最需要救的那批：它们首次上传就失败了
        // （device 未就绪 / context 已丢失 / 扩展查询落空），引擎因此永远
        // 跳过渲染，画面上就是「少一块」。原来的判定把它们全排除了，
        // 恢复机制只救得回「曾经画出来过」的纹理。
        if (!texture || !texture.__ios2ASTCPVRRecovery) return false;
        try {
            if (window.cc && cc.isValid && !cc.isValid(texture)) return false;
        } catch (ignored) {
            return false;
        }
        var url = texture.__ios2ASTCPVRRecovery.url;
        return typeof url === 'string' && url.indexOf('ios2-game://') === 0;
    }

    function collectRecoverableASTCPVRTextures() {
        var manager = window.cc && cc.assetManager;
        var assets = manager && manager.assets;
        if (!assets || typeof assets.forEach !== 'function') return [];
        var textures = [];
        assets.forEach(function (asset) {
            if (isRecoverableASTCPVRTexture(asset)) textures.push(asset);
        });
        return textures;
    }

    function uploadASTCPVRTexture(textureAsset, data, preserveTextureIdentity) {
        var renderer = cc.renderer;
        var device = renderer && renderer.device;
        var gl = device && device._gl;
        if (!renderer || !device || !gl) throw new Error('WebGL device is unavailable');
        if (typeof gl.isContextLost === 'function' && gl.isContextLost()) {
            resetASTCExtensionCache();
            throw new Error('WebGL context is lost');
        }
        var extension = astcExtensionFor(gl);
        if (!extension) throw new Error('ASTC WebGL extension is unavailable');

        var previous = textureAsset._texture;
        var reusedTextureIdentity = preserveTextureIdentity && previous && previous._device === device;
        var replacement = reusedTextureIdentity ? previous : null;
        if (replacement) {
            // Materials retain the renderer Texture2D, not the Cocos asset.
            // Keep that object stable so active Sprite/FGUI/Spine material
            // properties automatically see the recreated WebGL handle.
            try {
                if (replacement._glID) gl.deleteTexture(replacement._glID);
            } catch (ignored) {}
            replacement._glID = gl.createTexture();
            if (!replacement._glID) throw new Error('Unable to recreate WebGL texture');
            replacement._width = data.width;
            replacement._height = data.height;
            replacement._genMipmap = false;
        } else {
            replacement = new renderer.Texture2D(device, {
                images: [],
                width: data.width,
                height: data.height,
                format: cc.Texture2D.PixelFormat.RGBA8888,
                genMipmaps: false
            });
        }
        try {
            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, replacement._glID);
            gl.compressedTexImage2D(gl.TEXTURE_2D, 0, data.__ios2ASTCFormat,
                data.width, data.height, 0, data._data);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            device._restoreTexture(0);
        } catch (error) {
            if (!reusedTextureIdentity) replacement.destroy();
            throw error;
        }

        if (previous && previous !== replacement) previous.destroy();
        textureAsset._texture = replacement;
        // Do not retain data._data here. This image marker keeps the existing
        // Cocos Texture2D contract without pinning the PVR ArrayBuffer.
        textureAsset._image = { width: data.width, height: data.height, __ios2Compressed: true };
        textureAsset.width = data.width;
        textureAsset.height = data.height;
        textureAsset._packable = false;
        textureAsset.loaded = true;
        textureAsset.emit('load');
    }

    // 上传失败统计。「元素画不出来」在 Cocos 里没有任何错误输出——assembler
    // 只是 `if (!texture.loaded) return;` 跳过这个节点。所以这里必须自己记账，
    // 否则线上表现为「某个实例随机缺几块 UI」，日志里一条痕迹都没有。
    var textureUploadState = { failed: 0, succeeded: 0, reported: [] };

    function noteTextureUploadSuccess() {
        textureUploadState.succeeded++;
    }

    function noteTextureUploadFailure(textureAsset, error) {
        textureUploadState.failed++;
        var url = textureAsset && (textureAsset._nativeUrl || textureAsset.nativeUrl) || '<unknown>';
        if (textureUploadState.reported.length < 8) {
            textureUploadState.reported.push(url.split('/').pop() + ': ' +
                (error && (error.message || error) || 'unknown'));
        }
        postWebGraphicsLog('texture-upload-failed',
            'PVR upload failed, texture will not render (url=' + url.split('/').pop() +
            ', error=' + (error && (error.message || error) || 'unknown') + ')',
            { url: url, total: textureUploadState.failed });
    }

    function rememberASTCPVRRecoverySource(textureAsset, data) {
        var url = textureAsset && (textureAsset._nativeUrl || textureAsset.nativeUrl);
        if (typeof url !== 'string' || url.indexOf('ios2-game://') !== 0) return;
        // Deliberately retain metadata only. PVR bytes are refetched from the
        // native CDN cache after a context loss instead of remaining in JS.
        textureAsset.__ios2ASTCPVRRecovery = {
            url: url,
            width: data.width,
            height: data.height
        };
    }

    function recoverASTCPVRTexture(texture) {
        if (!isRecoverableASTCPVRTexture(texture)) return Promise.resolve({ skipped: true });
        var url = texture.__ios2ASTCPVRRecovery.url;
        return fetch(url, { cache: 'force-cache' })
            .then(function (response) {
                if (!response || !response.ok) {
                    throw new Error('PVR recovery request failed: ' + (response && response.status || 'unknown'));
                }
                return response.arrayBuffer();
            })
            .then(function (buffer) {
                var data = null;
                try {
                    if (!isRecoverableASTCPVRTexture(texture)) return { skipped: true };
                    data = parseASTCPVRBuffer(buffer);
                    uploadASTCPVRTexture(texture, data, true);
                    return { restored: true };
                } finally {
                    // The temporary view is the final reference to the PVR
                    // bytes once this callback returns.
                    if (data) data._data = null;
                    data = null;
                    buffer = null;
                }
            });
    }

    function scheduleASTCPVRRecovery(reason) {
        var state = astcPVRRecoveryState;
        reason = reason || 'manual';
        state.pendingReason = reason;
        if (state.recovering) {
            state.rerunRequested = true;
            return true;
        }
        if (state.contextLost || (window.document && document.hidden)) {
            return false;
        }
        if (state.scheduled) return true;
        state.scheduled = true;
        postWebGraphicsLog('pvr-recovery-scheduled',
            'PVR recovery scheduled (reason=' + reason + ')', { reason: reason });
        window.setTimeout(function () {
            state.scheduled = false;
            runASTCPVRRecovery(state.pendingReason || reason);
        }, IOS2_PVR_RECOVERY_RESUME_DELAY_MS);
        return true;
    }

    function runASTCPVRRecovery(reason) {
        var state = astcPVRRecoveryState;
        reason = reason || 'manual';
        state.pendingReason = '';
        if (state.recovering) {
            state.rerunRequested = true;
            return;
        }
        if (state.contextLost || (window.document && document.hidden)) {
            state.pendingReason = reason;
            postWebGraphicsLog('pvr-recovery-deferred',
                'PVR recovery deferred (reason=' + reason + ', contextLost=' + state.contextLost + ')', {
                    reason: reason,
                    contextLost: state.contextLost
                });
            return;
        }

        var textures = collectRecoverableASTCPVRTextures();
        var startedAt = Date.now();
        var restored = 0;
        var failed = 0;
        var skipped = 0;
        var cursor = 0;
        var examples = [];
        state.recovering = true;
        state.rerunRequested = false;
        var sequence = ++state.sequence;
        postWebGraphicsLog('pvr-recovery-start',
            'PVR recovery started (reason=' + reason + ', targets=' + textures.length + ')', {
                reason: reason,
                targets: textures.length
            });

        function finish() {
            state.recovering = false;
            var elapsedMs = Date.now() - startedAt;
            var message = 'PVR recovery complete (reason=' + reason + ', targets=' + textures.length +
                ', restored=' + restored + ', failed=' + failed + ', skipped=' + skipped +
                ', elapsedMs=' + elapsedMs + ')';
            if (examples.length) message += ' failures=[' + examples.join(' | ') + ']';
            postWebGraphicsLog('pvr-recovery-complete', message, {
                reason: reason,
                targets: textures.length,
                restored: restored,
                failed: failed,
                skipped: skipped,
                elapsedMs: elapsedMs
            });
            if (state.rerunRequested && !state.contextLost && !(window.document && document.hidden)) {
                state.rerunRequested = false;
                scheduleASTCPVRRecovery('queued after recovery ' + sequence);
            }
        }

        function next() {
            if (cursor >= textures.length) return Promise.resolve();
            var texture = textures[cursor++];
            return recoverASTCPVRTexture(texture).then(function (result) {
                if (result && result.restored) restored++;
                else skipped++;
            }, function (error) {
                failed++;
                if (examples.length < 3) {
                    examples.push(String(error && (error.message || error) || 'unknown'));
                }
            }).then(next);
        }

        var workers = [];
        var workerCount = Math.min(IOS2_PVR_RECOVERY_CONCURRENCY, textures.length);
        for (var index = 0; index < workerCount; index++) workers.push(next());
        Promise.all(workers).then(finish, function (error) {
            failed++;
            if (examples.length < 3) examples.push(String(error && (error.message || error) || 'unknown'));
            finish();
        });
    }

    // ------------------------------------------------------------------
    // 渲染完整性自检
    //
    // Cocos 里没有「渲染失败」这个概念。一个节点画不出来时，assembler 只是
    // `if (!texture.loaded) return;` 静默跳过 —— 不抛错、不告警、不重试。
    // 所以「画面元素不全」无法通过错误日志发现，只能主动遍历场景树去问：
    // 有多少**本该画出来**的节点，此刻其实画不出来？
    //
    // 判定「本该画」的四条（全部成立才计入分母）：
    //   ① 节点在层级里激活（activeInHierarchy）
    //   ② 节点自身可见（opacity > 0）
    //   ③ 挂载了带 spriteFrame 的渲染组件
    //   ④ 该组件的纹理已 loaded —— 这一条不成立，就是画面上缺的那一块
    // ------------------------------------------------------------------
    var renderIntegrityState = {
        installed: false,
        timer: null,
        samples: 0,
        badSamples: 0
    };

    function collectRenderIntegrity() {
        var result = { visible: 0, missingTexture: 0, missingMaterial: 0, samples: [] };
        var scene = window.cc && cc.director && cc.director.getScene && cc.director.getScene();
        if (!scene) return result;
        var stack = [scene];
        while (stack.length) {
            var node = stack.pop();
            if (!node) continue;
            var children = node._children || [];
            for (var index = 0; index < children.length; index++) stack.push(children[index]);
            if (node.activeInHierarchy === false || node.active === false) continue;
            if (typeof node.opacity === 'number' && node.opacity <= 0) continue;
            var components = node._components || [];
            for (var cursor = 0; cursor < components.length; cursor++) {
                var component = components[cursor];
                var frame = component && component.spriteFrame;
                if (!frame || typeof frame.getTexture !== 'function') continue;
                result.visible++;
                var texture = frame.getTexture();
                if (!texture || texture.loaded === false) {
                    result.missingTexture++;
                    if (result.samples.length < 6) {
                        var label = (texture && (texture._nativeUrl || texture.nativeUrl)) || node.name || '?';
                        result.samples.push(String(label).split('/').pop());
                    }
                } else if (component._materials && component._materials.length === 0) {
                    // 纹理在、材质没了：通常发生在上下文/device 重建之后。
                    result.missingMaterial++;
                }
            }
        }
        return result;
    }

    // 纹理**后到**时 assembler 不会自己重算：它那一帧已经因为
    // `!texture.loaded` 提前 return 了，之后没有新的脏标记就再也不进来。
    // 所以补完纹理必须手动把整棵树标脏，否则贴图补上了、画面还是缺的。
    function markSceneRenderDataDirty() {
        try {
            var scene = window.cc && cc.director && cc.director.getScene && cc.director.getScene();
            var Flow = window.cc && cc.RenderFlow;
            if (!scene || !Flow) return;
            var flag = Flow.FLAG_UPDATE_RENDER_DATA || Flow.FLAG_RENDER || 0;
            if (!flag) return;
            var stack = [scene];
            while (stack.length) {
                var node = stack.pop();
                if (!node) continue;
                node._renderFlag |= flag;
                var children = node._children || [];
                for (var index = 0; index < children.length; index++) stack.push(children[index]);
            }
        } catch (ignored) {}
    }

    function reportRenderIntegrity(reason) {
        var snapshot = collectRenderIntegrity();
        var missing = snapshot.missingTexture + snapshot.missingMaterial;
        renderIntegrityState.samples++;
        if (missing > 0) renderIntegrityState.badSamples++;
        else renderIntegrityState.badSamples = 0;

        var device = window.cc && cc.renderer && cc.renderer.device;
        var gl = device && device._gl;
        var contextLost = !!(gl && typeof gl.isContextLost === 'function' && gl.isContextLost());

        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game;
        if (handler && typeof handler.postMessage === 'function' &&
            (missing > 0 || reason === 'manual')) {
            try {
                handler.postMessage({
                    type: 'render',
                    instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                    reason: reason,
                    visible: snapshot.visible,
                    missingTexture: snapshot.missingTexture,
                    missingMaterial: snapshot.missingMaterial,
                    contextLost: contextLost,
                    samples: snapshot.samples.join(',')
                });
            } catch (ignored) {}
        }
        // 正常时别刷：10 个实例 × 每 12 秒一条，日志会被自检自己淹掉。
        // 只在真的缺块时打，正常采样走上面的 render 消息（原生侧按等级过滤）。
        if (missing > 0) {
            console.warn('[ios2-web] render integrity degraded', reason,
                'visible=' + snapshot.visible,
                'missingTexture=' + snapshot.missingTexture,
                'missingMaterial=' + snapshot.missingMaterial,
                'samples=' + snapshot.samples.join(','));
        }
        // 上下文已经丢了就别瞎补：那种情况只能整页重载（见下方 webgl-fatal）。
        if (missing > 0 && !contextLost) {
            scheduleASTCPVRRecovery('render integrity: ' + missing + ' unrenderable');
            markSceneRenderDataDirty();
        }
        return snapshot;
    }

    // ------------------------------------------------------------------
    // 缺口账本（事件驱动）——把引擎的「静默 disableRender」变成可计时的事件
    // ------------------------------------------------------------------
    //
    // 为什么必须事件驱动：`collectRenderIntegrity()` 是**定时**采样（+4s 首采、此后每 12s），
    // 而"元素不全"是**几百毫秒到几秒的瞬态** —— 三次实测日志里
    // `render integrity degraded` 一条都没出现过，不是没缺，是采样永远错过。
    //
    // 引擎在贴图未就绪时走的是 `cc.Sprite._applySpriteFrame` 里的
    //   `r && r.loaded ? this._applySpriteSize() : (this.disableRender(), ...)`
    // 而 `disableRender()` 只清 `_renderFlag`，不 log / 不 emit / 不 throw ——
    // 「这块画不出来」在日志里零痕迹（见 `ios2-web-cocos2d.js` 里 Sprite 的定义）。
    //
    // 这里在 `_applySpriteFrame` / `_validateRender` 外面包一层：
    //   走到未就绪那一支 → 记进账本（带起始时刻）；贴图 `load` 回来 → 销账、累计存活时长。
    // 于是任何时刻都能回答「现在缺几张、缺了多久、缺的是哪几张图」，
    // 而且零遍历成本、100% 覆盖，不靠采样运气。
    var GAP_REPORT_MIN_INTERVAL_MS = 5000;
    /// 同一批缺口持续超过这个时长 ⇒ 降频上报。
    ///
    /// 为什么要有：新加的 `sprite-empty`（节点在、图还没赋）在 FairyGUI 里可能是
    /// **设计上就空着的占位**。若一批缺口永不闭合还每 5s 报一次，几分钟就能把
    /// `diagnostics.log`（256 KB 上限）刷穿，把真正的证据挤掉。
    /// "缺了 3 秒"和"缺了 5 分钟"本来就是两种病，降频顺带把这件事区分开。
    var GAP_REPORT_LONG_INTERVAL_MS = 60000;
    var GAP_LONG_LIVED_AFTER_MS = 60000;
    /// 账本容量上限：只为防病态场景无限增长，正常远到不了。
    var GAP_LEDGER_LIMIT = 512;

    var gapLedger = {
        installed: false,
        hooks: [],         // 实际包上了哪几个钩子（自述用；空 = 装不上，必须能看见）
        open: {},          // compId -> { node, nodeName, texture, kind, since, url, recheck }
        openCount: 0,
        total: 0,
        worstMs: 0,
        dirtyMarks: 0,
        lastReportAt: 0,
        wasOpen: false,
        openSince: 0,      // 当前这批缺口的起点（空 → 非空时置位）
        seq: 0
    };

    /// 清掉节点已经销毁的条目。
    ///
    /// 为什么必须清：贴图若**始终没到**（资源 404、实例被停），那条记录会永远留着，
    /// `openCount` 就永远 > 0，上报会每 5s 一条无限刷下去。节点销毁 = 这个缺口
    /// 已经不存在了（不是"还在缺"），按存在性销账才是诚实记账。
    function closeGapEntry(id) {
        var entry = gapLedger.open[id];
        if (!entry) return false;
        var dwell = Date.now() - entry.since;
        if (dwell > gapLedger.worstMs) gapLedger.worstMs = dwell;
        delete gapLedger.open[id];
        return true;
    }

    /// 逐条复查并清掉已经不该在账上的条目。
    ///
    /// 两条复查依据：
    ///   ① 节点已销毁 ⇒ 这个缺口已经不存在了（不是"还在缺"）。
    ///   ② `recheck()` 返回 false ⇒ 它已经不缺了。
    /// 为什么要 ②：有些缺口**没有贴图可以挂 `load` 监听**（例如 BMFont 的 `.fnt`
    /// 配置没解析出来）。只靠事件销账的话，这类条目会永远留在账上，
    /// `openCount` 永不归零、上报无限刷——那是假账。
    function pruneGapLedger() {
        var ids = Object.keys(gapLedger.open);
        var removed = false;
        for (var index = 0; index < ids.length; index++) {
            var entry = gapLedger.open[ids[index]];
            var gone = false;
            if (entry.node && entry.node.isValid === false) gone = true;
            else if (typeof entry.recheck === 'function') {
                try { gone = !entry.recheck(); } catch (error) { gone = true; }
            }
            if (gone && closeGapEntry(ids[index])) removed = true;
        }
        if (removed) gapLedger.openCount = Object.keys(gapLedger.open).length;
    }

    function gapShortName(texture) {
        var url = texture && (texture._nativeUrl || texture.nativeUrl);
        if (!url) return '?';
        var parts = String(url).split('/');
        return parts[parts.length - 1] || '?';
    }

    function gapUrls() {
        var ids = Object.keys(gapLedger.open);
        var out = [];
        var seen = {};
        for (var index = 0; index < ids.length && out.length < 6; index++) {
            var entry = gapLedger.open[ids[index]];
            // 去重：31 个 `sprite-empty` 会把 6 个名额全占满，等于什么都没说。
            var label = entry.texture ? entry.url : (entry.url + '@' + (entry.nodeName || '?'));
            if (seen[label]) continue;
            seen[label] = true;
            out.push(label);
        }
        return out.join(',');
    }

    /// 节流上报：只在「由空变非空」「由非空变空」两个跳变点立即报，
    /// 持续缺着的时候最多每 5s 一条 —— 既不丢关键瞬间，也不会把日志刷爆。
    function postGapReport(reason) {
        var now = Date.now();
        pruneGapLedger();
        var isOpen = gapLedger.openCount > 0;
        var transition = (isOpen !== gapLedger.wasOpen);
        if (transition) {
            gapLedger.wasOpen = isOpen;
            gapLedger.openSince = isOpen ? now : 0;
        }
        if (!transition && !isOpen) return;
        // 同一批缺口持续太久就降频（见 GAP_REPORT_LONG_INTERVAL_MS）
        var interval = (gapLedger.openSince && now - gapLedger.openSince > GAP_LONG_LIVED_AFTER_MS)
            ? GAP_REPORT_LONG_INTERVAL_MS : GAP_REPORT_MIN_INTERVAL_MS;
        if (!transition && now - gapLedger.lastReportAt < interval) return;
        gapLedger.lastReportAt = now;
        postGapPayload(reason, gapLedger.openCount, gapLedger.total,
                       Math.round(gapLedger.worstMs), gapUrls(), gapKinds());
    }

    /// 账本自述：安装结果、包上了哪几个钩子。
    ///
    /// 为什么必须发这条：上一次实测"一条 `[render-gap]` 都没有"，但**无法判断**
    /// 是"没缺"还是"账本压根没装上"——安装成功的 `console.log` 走的是 debug 级，
    /// 在默认日志档位下被丢掉了。诊断工具自己不可观测，就等于没有。
    /// 这条走 `render-gap` 通道，一定到得了原生并落盘。
    function reportLedgerState(reason, detail) {
        postGapPayload(reason, gapLedger.openCount, gapLedger.total,
                       Math.round(gapLedger.worstMs), detail, gapKinds());
    }

    function postGapPayload(reason, open, total, worstMs, urls, kinds) {
        var handlers = window.webkit && window.webkit.messageHandlers;
        var handler = handlers && handlers.ios2Game;
        if (!handler || typeof handler.postMessage !== 'function') return;
        try {
            handler.postMessage({
                type: 'render-gap',
                instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                reason: reason,
                open: open,
                total: total,
                worstMs: worstMs,
                dirtyMarks: gapLedger.dirtyMarks,
                kinds: kinds,
                urls: urls
            });
        } catch (ignored) {}
    }

    /// 缺口按 kind 计数（`sprite-empty=1,label-blocked=3`）。
    ///
    /// 为什么必须带计数：只报 kind 名字的话，`sprite-empty+label-empty` 看起来"两类都有"，
    /// 而真相可能是"1 个 Sprite + 500 个误报的 Label"。**主次必须一眼看得出来。**
    function gapKinds() {
        var ids = Object.keys(gapLedger.open);
        var counts = {};
        for (var index = 0; index < ids.length; index++) {
            var kind = gapLedger.open[ids[index]].kind || '?';
            counts[kind] = (counts[kind] || 0) + 1;
        }
        var parts = [];
        Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; })
            .forEach(function (kind) { parts.push(kind + '=' + counts[kind]); });
        return parts.join(',');
    }

    /// 推断"这个构件为什么没画"的类别 + 相关贴图（**只在确认它真的没画之后再调用**）。
    ///
    /// 注意职责划分：**"有没有画"由 `_renderFlag` 决定**（见 `noteRenderFlagGap`），
    /// 这里只负责给已确认的缺口贴一个可读标签。
    function describeGapAsset(component) {
        var nodeName = (component && component.node && component.node.name) || '?';
        try {
            // Sprite / Mask：靠 spriteFrame
            if (component.spriteFrame !== undefined) {
                var frame = component._spriteFrame;
                var texture = frame && typeof frame.getTexture === 'function' ? frame.getTexture() : null;
                if (!texture) return { kind: 'sprite-empty', texture: null, url: '<no-frame>@' + nodeName };
                return { kind: texture.loaded === false ? 'sprite-texture' : 'sprite-blocked',
                         texture: texture, url: gapShortName(texture) };
            }
            // Label：只有 BMFont 才依赖图集/配置；TTF（font 为 null）本来就能画
            if (component.font !== undefined || component.string !== undefined) {
                var font = component.font;
                var BitmapFont = window.cc && cc.BitmapFont;
                if (font && BitmapFont && font instanceof BitmapFont) {
                    var atlas = font.spriteFrame;
                    var atlasTexture = atlas && typeof atlas.getTexture === 'function'
                        ? atlas.getTexture() : null;
                    if (atlasTexture && atlasTexture.loaded === false) {
                        return { kind: 'font-atlas', texture: atlasTexture, url: gapShortName(atlasTexture) };
                    }
                    if (!font._fntConfig) {
                        return { kind: 'font-config', texture: null, url: '<no-fnt>@' + nodeName };
                    }
                }
                // 图集没问题却仍然没画 ⇒ 不是贴图链路，交给阻塞分支
                return { kind: 'label-blocked', texture: null, url: '<label>@' + nodeName };
            }
            if (component.skeletonData !== undefined) {
                return { kind: 'skeleton-blocked', texture: null, url: '<skeleton>@' + nodeName };
            }
        } catch (ignored) {}
        return { kind: 'blocked-' + classifyRenderer(component), texture: null, url: '<' + classifyRenderer(component) + '>@' + nodeName };
    }

    /// **唯一**的缺口判定入口 —— 依据是引擎的最终裁决：`node._renderFlag` 有没有 `FLAG_RENDER`。
    ///
    /// 为什么不用"逐个判分支条件"（第一版的做法）：
    /// `.39` 是按各自的条件记的 —— `_applySpriteFrame` 看 `!texture.loaded`、`Label._validateRender`
    /// 看 `!font` …… 结果 **TTF 的 `cc.Label`（`font` 本来就是 null，完全正常）被大批误记成
    /// `label-empty`**：账本 20 秒内涨到上限 **511**、`worst` 一路飙到 **57 秒**，
    /// 而同期 audit 的 `silencedByClass` **只有 `Sprite`，一个 `Label` 都没有**。
    /// **账本比现实多报了 500 倍，两个探针互相打架。**
    ///
    /// 改用 `_renderFlag` 之后：与"谁调了 `disableRender()`"无关，也与 audit 用的是**同一个信号**，
    /// 两边从此不会再给出不同的答案。
    function noteRenderFlagGap(component) {
        try {
            var node = component && component.node;
            if (!node || typeof node._renderFlag !== 'number') return;
            if (node.activeInHierarchy === false) return;
            var Flow = window.cc && cc.RenderFlow;
            var flag = Flow && (Flow.FLAG_RENDER || Flow.FLAG_UPDATE_RENDER_DATA);
            if (!flag) return;
            var id = component.__ios2GapId || (component.__ios2GapId = 'c' + (++gapLedger.seq));
            if (node._renderFlag & flag) {
                // 在画 → 销账（这是唯一可信的"好了"）
                if (gapLedger.open[id] && closeGapEntry(id)) {
                    gapLedger.openCount = Object.keys(gapLedger.open).length;
                    postGapReport('gap-close');
                }
                return;
            }
            if (gapLedger.open[id]) return;                   // 已在账上，别重复
            if (gapLedger.openCount >= GAP_LEDGER_LIMIT) return;
            var info = describeGapAsset(component);
            gapLedger.open[id] = {
                node: node, nodeName: node.name, texture: info.texture, kind: info.kind,
                since: Date.now(), url: info.url,
                recheck: function () {
                    return !(typeof node._renderFlag === 'number' && !(node._renderFlag & flag));
                }
            };
            gapLedger.openCount = Object.keys(gapLedger.open).length;
            gapLedger.total++;
            if (info.texture && !info.texture.__ios2GapWatch && typeof info.texture.once === 'function') {
                info.texture.__ios2GapWatch = true;
                info.texture.once('load', function () { settleRenderGap(info.texture); });
            }
            postGapReport('gap-open');
        } catch (ignored) {}
    }

    function settleRenderGap(texture) {
        var ids = Object.keys(gapLedger.open);
        var changed = false;
        for (var index = 0; index < ids.length; index++) {
            if (gapLedger.open[ids[index]].texture !== texture) continue;
            if (closeGapEntry(ids[index])) changed = true;
        }
        if (!changed) return;
        gapLedger.openCount = Object.keys(gapLedger.open).length;
        postGapReport('gap-close');
    }

    /// 给某个类的 `method` 包一层：调完原方法后跑 `probe(this)`。
    /// 返回 true 表示真的包上了（方法不存在就什么都不做，不抛）。
    function wrapRenderHook(className, method, probe) {
        var klass = window.cc && cc[className];
        var proto = klass && klass.prototype;
        if (!proto || typeof proto[method] !== 'function') return false;
        if (proto[method].__ios2GapWrapped) return false;
        var original = proto[method];
        var wrapper = function () {
            var result = original.apply(this, arguments);
            try { probe(this); } catch (ignored) {}
            return result;
        };
        wrapper.__ios2GapWrapped = true;
        proto[method] = wrapper;
        return true;
    }

    /// 装缺口账本。覆盖面**逐类挂**，并把"实际挂上了哪几个"回报给宿主——
    /// 上一次实测"一条缺口都没有"时，我们连账本装没装上都判断不了（安装日志是 debug 级，
    /// 默认档位被丢掉）。诊断工具自己不可观测，等于没有。
    function installRenderGapLedger() {
        if (gapLedger.installed) return false;
        var hooks = [];

        // 全部走同一个判定入口 `noteRenderFlagGap`（依据 `node._renderFlag`）。
        // 挂钩子的作用只是"给我一个**时机**"，判定与具体的引擎分支条件无关 ——
        // 这样"某类构件的分支条件被我写错了"不会再污染账本。
        if (wrapRenderHook('Sprite', '_applySpriteFrame', noteRenderFlagGap)) hooks.push('Sprite._applySpriteFrame');
        if (wrapRenderHook('Sprite', '_validateRender', noteRenderFlagGap)) hooks.push('Sprite._validateRender');
        if (wrapRenderHook('Label', '_validateRender', noteRenderFlagGap)) hooks.push('Label._validateRender');
        if (wrapRenderHook('Mask', '_validateRender', noteRenderFlagGap)) hooks.push('Mask._validateRender');
        if (wrapRenderHook('Skeleton', '_validateRender', noteRenderFlagGap)) hooks.push('Skeleton._validateRender');

        if (!hooks.length) {
            reportLedgerState('ledger-unavailable',
                'no hook point (cc.Sprite=' + !!(window.cc && cc.Sprite) + ')');
            return false;
        }
        // 脏标记计数：**这是区分两种病的唯一判据** ——
        // 缺口存在却从未补过脏标记 ⇒ 贴图到了但 assembler 不再进来（"补不上"）；
        // 补过且缺口随后消失 ⇒ 只是"后到"。
        var originalDirty = markSceneRenderDataDirty;
        markSceneRenderDataDirty = function () {
            gapLedger.dirtyMarks++;
            return originalDirty.apply(this, arguments);
        };

        gapLedger.installed = true;
        gapLedger.hooks = hooks;
        // 心跳：只在账上还有缺口时才干活。
        // 为什么必须有：有些缺口没有贴图可挂 `load`（如 `.fnt` 配置），只能靠
        // 定期 `pruneGapLedger()` 复查销账；没有心跳的话 `openCount` 会永远卡在 >0。
        // 健康时这个 tick 是空转（两次属性读取后 return），代价可忽略。
        window.setInterval(function () {
            if (!gapLedger.installed) return;
            if (gapLedger.openCount === 0 && !gapLedger.wasOpen) return;
            postGapReport('tick');
        }, GAP_REPORT_MIN_INTERVAL_MS);
        reportLedgerState('ledger-installed', hooks.join('+'));
        return true;
    }
    window.__ios2InstallRenderGapLedger = installRenderGapLedger;

    /// 只读快照：**没有副作用**，可以趁"正缺着"反复按。
    /// （对比 `window.__ios2RenderIntegrityCheck()`：那个会触发恢复+标脏，当场把缺块补上。）
    window.__ios2RenderGapDump = function () {
        var now = Date.now();
        pruneGapLedger();
        var ids = Object.keys(gapLedger.open);
        var list = [];
        for (var index = 0; index < ids.length; index++) {
            var entry = gapLedger.open[ids[index]];
            list.push({ url: entry.url, kind: entry.kind, node: entry.nodeName,
                        aliveMs: now - entry.since });
        }
        return {
            installed: gapLedger.installed,
            hooks: gapLedger.hooks,
            open: gapLedger.openCount,
            total: gapLedger.total,
            worstMs: Math.round(gapLedger.worstMs),
            dirtyMarks: gapLedger.dirtyMarks,
            kinds: gapKinds(),
            openGaps: list
        };
    };

    /// 引擎是压缩过的，`comp.constructor.name` 只会给出 `Qi` / `zi` / `CCClass` 这种
    /// 无意义的名字（`.38` 实测：`classes:{"CCClass":180,"Qi":132,"zi":56}`，完全读不出来）。
    /// 用 `instanceof` 反查真名——`cc` 上的构造器是好的，这一步零成本。
    function classifyRenderer(comp) {
        var c = window.cc;
        if (c) {
            try {
                if (c.Mask && comp instanceof c.Mask) return 'Mask';
                if (c.Sprite && comp instanceof c.Sprite) return 'Sprite';
                if (c.Label && comp instanceof c.Label) return 'Label';
                if (c.RichText && comp instanceof c.RichText) return 'RichText';
                if (c.Graphics && comp instanceof c.Graphics) return 'Graphics';
                if (c.ParticleSystem && comp instanceof c.ParticleSystem) return 'ParticleSystem';
                if (c.MotionStreak && comp instanceof c.MotionStreak) return 'MotionStreak';
                if (c.TiledLayer && comp instanceof c.TiledLayer) return 'TiledLayer';
            } catch (ignored) {}
        }
        return (comp.constructor && comp.constructor.name) || '?';
    }

    /// 节点在树里的短路径（`A/B/C`），最多向上 4 层。
    /// 光有 `Image` 这个名字定位不到任何东西——FairyGUI 里满树都是 `Image`/`GImage`。
    function nodePath(node, maxDepth) {
        var parts = [];
        var cursor = node;
        var limit = maxDepth || 4;
        while (cursor && parts.length < limit) {
            parts.unshift(cursor.name || '?');
            cursor = cursor.parent;
        }
        return parts.join('/');
    }

    /// 类无关的「被静默构件」审计 —— **不问是谁调的 `disableRender()`，直接看结果**。
    ///
    /// 为什么需要它：逐类挂钩总有漏网的（引擎里 `disableRender()` 的定义散落在
    /// Sprite / Label / Mask / Skeleton / ParticleSystem / TiledLayer / ArmatureDisplay …
    /// 每一处都是静默的）。而所有路径的**共同结果**只有一个：
    /// `node._renderFlag` 少了 `FLAG_RENDER` 位。查这个位就与"谁干的"无关了。
    ///
    /// 同时给出**渲染组件类直方图** —— 这直接回答"这套 UI 到底由什么构成"，
    /// 决定了还有哪些类是必须挂钩的。**只读，无副作用。**
    window.__ios2RenderAudit = function (sampleLimit) {
        var out = { ok: false, reason: 'not-installed', scanned: 0, withRenderer: 0,
                    silenced: [], classes: {}, silencedByClass: {} };
        try {
            var Flow = window.cc && cc.RenderFlow;
            var flag = Flow && (Flow.FLAG_RENDER || Flow.FLAG_UPDATE_RENDER_DATA);
            var scene = window.cc && cc.director && cc.director.getScene && cc.director.getScene();
            if (!scene) { out.reason = 'no-scene'; return out; }
            if (!flag) { out.reason = 'no-renderflag-const'; return out; }
            out.ok = true;
            out.reason = 'ok';
            var limit = sampleLimit || 40;
            // 第二次遍历用的「带渲染组件的子树轮廓」，用来一眼看出**有没有两套 UI 同时活着**
            // （例如"大厅上还叠着玩具的页面"这种层叠）。
            out.outline = [];
            // 40 条：这份结果会被落盘（单条封顶 6 KB），列太长会把其它字段挤掉。
            var outlineLimit = 40;
            var stack = [[scene, 0]];
            while (stack.length) {
                var item = stack.pop();
                var node = item[0];
                var depth = item[1];
                if (!node) continue;
                var children = node._children || [];
                for (var c = 0; c < children.length; c++) stack.push([children[c], depth + 1]);
                if (node.activeInHierarchy === false) continue;
                if (typeof node.opacity === 'number' && node.opacity <= 0) continue;
                out.scanned++;
                var renderers = 0;
                var offRenderers = 0;
                var comps = node._components || [];
                for (var i = 0; i < comps.length; i++) {
                    var comp = comps[i];
                    if (!comp || comp.node !== node) continue;
                    // 渲染类组件：靠 _renderFlag 表达"要不要画"
                    if (typeof comp.markForRender !== 'function' &&
                        typeof comp.disableRender !== 'function') continue;
                    var name = classifyRenderer(comp);
                    renderers++;
                    out.withRenderer++;
                    out.classes[name] = (out.classes[name] || 0) + 1;
                    if (typeof node._renderFlag !== 'number') continue;
                    if (!(node._renderFlag & flag)) {
                        offRenderers++;
                        out.silencedByClass[name] = (out.silencedByClass[name] || 0) + 1;
                        if (out.silenced.length < limit) {
                            var frame = comp.spriteFrame || (comp.font && comp.font.spriteFrame);
                            var texture = frame && typeof frame.getTexture === 'function' ? frame.getTexture() : null;
                            out.silenced.push({
                                node: nodePath(node, 3), comp: name,
                                textureState: texture ? (texture.loaded === false ? 'not-loaded' : 'loaded')
                                                       : 'no-texture',
                                url: texture ? gapShortName(texture) : undefined
                            });
                        }
                    }
                }
                if (renderers > 0 && out.outline.length < outlineLimit) {
                    out.outline.push({
                        depth: depth, node: node.name,
                        parent: (node.parent && node.parent.name) || '',
                        children: children.length, renderers: renderers, off: offRenderers
                    });
                }
            }
        } catch (error) {
            out.ok = false;
            out.reason = 'error:' + (error && error.message);
        }
        return out;
    };

    /// 上报本窗口的「视口指纹」。
    ///
    /// 为什么必须记：多开时同一次点击按**归一化坐标（0..1）**广播，
    /// 各窗口换算回自己的绝对像素。**前提是各窗口的 UI 布局随宽高比等比变化**——
    /// 一旦游戏的适配策略让可见尺寸/设计分辨率随窗口变化（Widget 自适应、非 EXACT_FIT），
    /// **同一个归一化位置就会落到不同的按钮上**。实测已出现：同一次点击
    /// 5 个窗口进了「军团战抽奖」、另外 2 个进了「邮件」，而报缺块的正是那 2 个。
    /// 这条指纹就是用来坐实"窗口尺寸 → 布局"这一环的。
    function reportViewportFingerprint(reason) {
        try {
            var canvas = document.getElementById('GameCanvas');
            var view = window.cc && cc.view;
            // ⚠️ 必须用闭包绑定 `this`：`cc.view.getFrameSize` 是**方法**，
            // 抽出来当裸函数调用会丢 `this` → 抛错 → 整列都变成 `?`（.35 实测就是这么废掉的）。
            function size(call) {
                try {
                    var v = call();
                    return v ? { w: Math.round(v.width), h: Math.round(v.height) } : null;
                } catch (ignored) { return null; }
            }
            function text(o) { return o ? o.w + 'x' + o.h : '?'; }
            var visible = size(function () { return view.getVisibleSize(); });
            var design = size(function () { return view.getDesignResolutionSize(); });
            // 适配策略直接推导：比 `view._resolutionPolicy.name`（私有、且实测拿不到）可靠。
            //   visible == design          → EXACT_FIT（设计分辨率被拉伸填满）
            //   visible.w == design.w      → FIXED_WIDTH（**高度随窗口比例变**）
            //   visible.h == design.h      → FIXED_HEIGHT（宽度随窗口比例变）
            //   两者都更小                  → SHOW_ALL（留黑边）
            var fit = '?';
            if (visible && design) {
                if (visible.w === design.w && visible.h === design.h) fit = 'EXACT_FIT';
                else if (visible.w === design.w) fit = 'FIXED_WIDTH';
                else if (visible.h === design.h) fit = 'FIXED_HEIGHT';
                else if (visible.w < design.w && visible.h < design.h) fit = 'SHOW_ALL';
                else fit = 'other';
            }
            var winW = Math.round(window.innerWidth);
            var winH = Math.round(window.innerHeight);
            var text1 = 'reason=' + reason +
                // 引擎版本：换引擎（Debug 未压缩 / Release min / legacy 回退）之后，
                // 「跑的是哪一个」必须有据可查 —— 否则又会掉进"改了但没生效"那类坑。
                ' engine=' + ((window.cc && cc.ENGINE_VERSION) || '?') +
                ' win=' + winW + 'x' + winH +
                ' aspect=' + (winW ? (winH / winW).toFixed(4) : '?') +
                ' canvasAttr=' + (canvas ? canvas.width + 'x' + canvas.height : '?') +
                ' canvasCSS=' + (canvas ? Math.round(canvas.clientWidth) + 'x' + Math.round(canvas.clientHeight) : '?') +
                ' dpr=' + (window.devicePixelRatio || 1) +
                ' frame=' + text(size(function () { return view.getFrameSize(); })) +
                ' visible=' + text(visible) +
                ' design=' + text(design) +
                ' fit=' + fit +
                ' multOpen=' + !!(window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.multiOpen);
            postWebGraphicsLog('viewport', text1);
        } catch (ignored) {}
    }
    window.__ios2ViewportFingerprint = reportViewportFingerprint;

    function installRenderIntegrityWatchdog() {
        if (renderIntegrityState.installed) return;
        renderIntegrityState.installed = true;
        var intervalMs = 12000;
        function scheduleNext() {
            renderIntegrityState.timer = window.setTimeout(function () {
                reportRenderIntegrity('watchdog');
                scheduleNext();
            }, intervalMs);
        }
        // 首次采样要晚：刚 launch 完的一两秒里大批资源还在路上，那是正常的
        // 「加载中」，不是「缺块」，早采只会误报。
        window.setTimeout(function () {
            reportRenderIntegrity('startup');
            scheduleNext();
        }, 4000);
    }
    window.__ios2RenderIntegrityCheck = function () {
        return reportRenderIntegrity('manual');
    };

    // 上下文丢失后的兜底：给 WebKit 一点时间自己恢复，恢复不了就报
    // `webgl-fatal` 让原生重载实例。留这个窗口是因为 macOS 上上下文丢失
    // 有时只是 GPU 进程短暂重启，restored 事件会晚几百毫秒到。
    var contextLostFallback = { timer: null, waitMs: 3000 };

    function clearContextLostFallback() {
        if (contextLostFallback.timer) {
            window.clearTimeout(contextLostFallback.timer);
            contextLostFallback.timer = null;
        }
    }

    function scheduleContextLostFallback() {
        if (contextLostFallback.timer) return;
        contextLostFallback.timer = window.setTimeout(function () {
            contextLostFallback.timer = null;
            if (!astcPVRRecoveryState.contextLost) return;
            var handler = window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.ios2Game;
            if (!handler || typeof handler.postMessage !== 'function') return;
            try {
                handler.postMessage({
                    type: 'webgl-fatal',
                    instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
                    reason: 'context lost without restore'
                });
            } catch (ignored) {}
        }, contextLostFallback.waitMs);
    }

    function installWebGLContextRecovery() {
        var state = astcPVRRecoveryState;
        var canvas = window.cc && cc.game && cc.game.canvas || document.getElementById('GameCanvas');
        if (!canvas || state.installed) return;
        state.installed = true;
        state.documentWasHidden = !!(window.document && document.hidden);
        canvas.addEventListener('webglcontextlost', function (event) {
            if (event && typeof event.preventDefault === 'function') event.preventDefault();
            state.contextLost = true;
            state.rerunRequested = true;
            resetASTCExtensionCache();
            var status = event && event.statusMessage || 'unknown';
            postWebGraphicsLog('webgl-context-lost', 'WebGL context lost (status=' + status + ')', {
                status: status
            });
            // Cocos 2.4 的 gfx 后端**不支持**上下文恢复：program、buffer、VAO、
            // framebuffer 全部失效，而引擎没有任何重建路径。PVR 恢复只能把贴图
            // 内容补回去，补不回渲染管线 —— 画面必然残缺。所以这里不做无谓的
            // 局部修复，直接通知原生整页重载（重新登录），这是唯一可靠出路。
            scheduleContextLostFallback();
        }, false);
        canvas.addEventListener('webglcontextrestored', function () {
            state.contextLost = false;
            resetASTCExtensionCache();
            clearContextLostFallback();
            postWebGraphicsLog('webgl-context-restored', 'WebGL context restored');
            scheduleASTCPVRRecovery('webgl context restored');
        }, false);
        canvas.addEventListener('webglcontextcreationerror', function (event) {
            var status = event && event.statusMessage || 'unknown';
            postWebGraphicsLog('webgl-context-creation-error',
                'WebGL context creation error (status=' + status + ')', { status: status });
            // 创建失败不是「丢失」，等不到 restored 事件，但有可能是可恢复的
            // 资源竞争（WebKit 的 maxActiveContexts 驱逐）。给一次兜底机会。
            scheduleContextLostFallback();
        }, false);
        if (window.document && typeof document.addEventListener === 'function') {
            document.addEventListener('visibilitychange', function () {
                if (document.hidden) {
                    state.documentWasHidden = true;
                    return;
                }
                if (state.documentWasHidden) {
                    state.documentWasHidden = false;
                    scheduleASTCPVRRecovery('document visible after hidden');
                }
            });
        }
        window.__ios2RecoverPVRTextures = function (reason) {
            return scheduleASTCPVRRecovery(reason || 'manual');
        };
        postWebGraphicsLog('webgl-context-recovery-installed', 'WebGL context recovery installed');
    }

    function installASTCTextureSupport() {
        var downloader = cc.assetManager && cc.assetManager.downloader;
        var parser = cc.assetManager && cc.assetManager.parser;
        var texturePrototype = cc.Texture2D && cc.Texture2D.prototype;
        if (!parser || !texturePrototype) return;
        if (parser.__ios2ASTCInstalled) {
            // A remote bundle can replace this parser with a JSB variant that
            // reads from window.fsUtils. WebKit must parse the downloaded data.
            if (parser.__ios2ASTCPVRParser) {
                parser.register('.pvr', parser.__ios2ASTCPVRParser);
            }
            installWebGLContextRecovery();
            return;
        }
        parser.__ios2ASTCInstalled = true;

        // Creator serializes this project's texture alternatives as "0_5@...".
        // The supplied Web engine omits index 5, so it used PNG (index 0) even
        // when the device can upload the ASTC payload carried by the PVR file.
        var textureExtnames = cc.Texture2D.extnames;
        if (textureExtnames) textureExtnames[5] = '.pvr';

        if (downloader && !downloader.__ios2PVRDownloaderInstalled) {
            downloader.__ios2PVRDownloaderInstalled = true;
            downloader.register('.pvr', function (url, options, onComplete) {
                var binaryOptions = Object.assign({}, options, { responseType: 'arraybuffer' });
                downloader.downloadFile(url, binaryOptions, function (error, buffer) {
                    if (!error) {
                        console.log('[ios2-web] PVR texture loaded', url,
                            buffer && buffer.byteLength || 0, 'bytes');
                    }
                    onComplete(error, buffer);
                });
            });
        }

        var originalPVRParser = parser.parsePVRTex;
        var astcPVRParser = function (file, options, onComplete) {
            var isASTC = false;
            try {
                var bytes = file instanceof ArrayBuffer ? new Uint8Array(file) :
                    file && file.buffer instanceof ArrayBuffer && new Uint8Array(file.buffer,
                        file.byteOffset || 0, file.byteLength === undefined ? file.length : file.byteLength);
                isASTC = !!(bytes && bytes.length >= 4 && bytes[0] === 0x13 && bytes[1] === 0xAB &&
                    bytes[2] === 0xA1 && bytes[3] === 0x5C);
            } catch (ignored) {}
            if (!isASTC) {
                if (typeof originalPVRParser === 'function') {
                    originalPVRParser(file, options, onComplete);
                } else {
                    onComplete(new Error('Unsupported PVR texture header'));
                }
                return;
            }
            try {
                onComplete(null, parseASTCPVRBuffer(file));
            } catch (error) {
                onComplete(error);
            }
        };
        parser.__ios2ASTCPVRParser = astcPVRParser;
        parser.register('.pvr', astcPVRParser);

        var descriptor = null;
        // 沿原型链向上找**真正定义 accessor 的那一层**。
        //
        // 为什么不直接 `getOwnPropertyDescriptor(cc.Texture2D.prototype, …)`：
        // 引擎里 `_nativeAsset` 是从基类 `cc.Asset` **override** 过来的
        // （`_nativeAsset: { get, set, override: true }`）。老引擎恰好把它落在
        // `cc.Texture2D.prototype` 自己身上，所以直接取得到；但换引擎时只要
        // 定义位置挪一层，这里就会拿到 `undefined` —— 而下面的 `return` 是
        // **静默**的：ASTC 解析/上传整条链失效、贴图全空、日志一条都没有。
        // 这个坑比它看起来值钱，所以这里宁可多走一遍原型链。
        for (var owner = texturePrototype; owner; owner = Object.getPrototypeOf(owner)) {
            var candidate = Object.getOwnPropertyDescriptor(owner, '_nativeAsset');
            if (candidate && typeof candidate.set === 'function') { descriptor = candidate; break; }
        }
        if (!descriptor) {
            postWebGraphicsLog('texture-patch-missing',
                'cc.Texture2D._nativeAsset 没有 accessor setter —— ASTC 管线已停用（贴图会全空）');
            return;
        }
        Object.defineProperty(texturePrototype, '_nativeAsset', {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: descriptor.get,
            set: function (data) {
                if (!(data && data.__ios2ASTCFormat)) {
                    descriptor.set.call(this, data);
                    return;
                }
                // 先登记来源，再上传：上传失败时恢复队列需要靠这条记录
                // 重新 fetch 并重试（否则这张贴图就永远停在 loaded=false）。
                rememberASTCPVRRecoverySource(this, data);
                try {
                    uploadASTCPVRTexture(this, data);
                    noteTextureUploadSuccess();
                } catch (error) {
                    // 绝不向上抛：抛出会被 Cocos 的 deserialize 当成整包解析失败，
                    // 连带同一批资源一起废掉，比「缺一块」严重得多。
                    // 改为记账 + 排进恢复队列，等 device / 上下文回来后自动补齐。
                    noteTextureUploadFailure(this, error);
                    scheduleASTCPVRRecovery('texture upload failed');
                }
                // The uploader stores dimensions only. Drop the temporary
                // parser view promptly so the source ArrayBuffer can be GCed.
                data._data = null;
            }
        });
        // 装在成功也要留一行：换引擎之后「ASTC 管线到底有没有生效」必须一眼可查，
        // 否则上面那条静默 return 会让我们又回到"改了但没生效"的老坑里。
        postWebGraphicsLog('texture-patch-ready',
            'ASTC/PVR 管线已接管 cc.Texture2D._nativeAsset（engine=' +
            ((window.cc && cc.ENGINE_VERSION) || '?') + '）');
        installWebGLContextRecovery();
    }

    function reportCapabilities(gl) {
        if (!gl || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.ios2Game) return;
        var support = window.IOS2PVR && window.IOS2PVR.extensions ? window.IOS2PVR.extensions(gl) : {};
        window.webkit.messageHandlers.ios2Game.postMessage({
            type: 'capabilities',
            instance: window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.id,
            pvrtc: !!support.pvrtc,
            astc: !!support.astc
        });
    }

    // 原生入口（main.js）取到 manifest 之后会把原始 body 挂到
    // `cc.sys.manifestResult.rawData`，并额外导出 codeVersion / resourceVersion /
    // battleVersion（`cc.sys.ios2ResourceVersion`）。AppController.mm 里也写明：
    // 「battleVersion and other manifest metadata are consumed by game scripts
    //   through cc.sys.manifestResult.rawData」。
    // WebKit 路径原先只把 bundleVers 并进 settings，manifest 本体随即被丢掉，
    // 远端 launcher / 活动代码拿到的版本状态是空的，只能回落到包内旧常量
    // —— 表现为活动判定「版本不对」。这里与原生路径对齐。
    function installManifestVersionState(manifest, bundleVers) {
        try {
            var rawData = manifest || {};
            cc.sys.manifestResult = { code: 0, error: null, rawData: rawData };
            var codeVersion = (bundleVers && bundleVers.codeVersion) || '';
            var resourceVersion = (bundleVers && bundleVers.COMMIT_ID) || '';
            var battleVersion = rawData.battleVersion || '';
            cc.sys.ios2ResourceVersion = {
                codeVersion: codeVersion,
                resourceVersion: resourceVersion,
                battleVersion: battleVersion
            };
            console.log('[ios2-web] manifest state: code=' + codeVersion +
                ', resource=' + resourceVersion + ', battle=' + battleVersion);
            if (!battleVersion) return;
            // 远端代码既直接读 window.BATTLE_VERSION，也读 PlatformManager
            // 的返回值，而包内 / 远端 bundle 里可能带着旧的兜底值。跟原生
            // main.js 一样用 getter 钉死成清单里的值，避免被旧值覆盖。
            var descriptor = Object.getOwnPropertyDescriptor(window, 'BATTLE_VERSION');
            if (!descriptor || descriptor.configurable) {
                Object.defineProperty(window, 'BATTLE_VERSION', {
                    configurable: true,
                    enumerable: true,
                    get: function () { return battleVersion; },
                    set: function (value) {
                        if (value !== battleVersion) {
                            console.warn('[ios2-web] ignored stale BATTLE_VERSION=' + value +
                                ', manifest=' + battleVersion);
                        }
                    }
                });
            } else {
                window.BATTLE_VERSION = battleVersion;
            }
        } catch (error) {
            console.warn('[ios2-web] manifest state unavailable: ' +
                ((error && (error.stack || error.message)) || error));
        }
    }

    function boot() {
        console.log('[ios2-web] boot revision', IOS2_WEB_RUNTIME_REVISION);
        installAssetReleaseHooks();
        var settings = window._CCSettings;
        if (!settings || !window.cc) {
            showFatal('WebKit 游戏启动失败\n\n缺少 Web runtime settings 或 Cocos Web 引擎。');
            throw new Error('Web runtime settings or Cocos engine is missing');
        }
        var manifest = window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.manifest || {};
        var bundledVers = settings.bundleVers || {};
        var liveBundleVers = manifest.bundleVers;
        if (typeof liveBundleVers === 'string') liveBundleVers = JSON.parse(liveBundleVers);
        if (liveBundleVers && typeof liveBundleVers === 'object') {
            settings.bundleVers = Object.assign({}, bundledVers, liveBundleVers);
        }
        installManifestVersionState(manifest, settings.bundleVers);
        settings.platform = 'web-mobile';
        settings.server = 'ios2-game://app/cdn';
        settings.remoteBundles = settings.remoteBundles || [];
        Object.keys(settings.bundleVers || {}).forEach(function (name) {
            if (name !== 'internal' && name !== 'codeVersion' && name !== 'COMMIT_ID' &&
                settings.remoteBundles.indexOf(name) < 0) settings.remoteBundles.push(name);
        });
        // The native bootstrap manifest is only needed to merge versions and
        // the battle version. Drop the object before large bundle loads begin.
        if (window.__IOS2_GAME_INSTANCE__) window.__IOS2_GAME_INSTANCE__.manifest = null;
        var canvas = document.getElementById('GameCanvas');
        installTypeScriptRuntimeHelpers();
        installASTCTextureSupport();
        cc.macro.SUPPORT_TEXTURE_FORMATS = ['.pvr'];
        var targetFrameRate = preferredFrameRate();
        var multiOpen = !!(window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.multiOpen);
        var startupMode = String(window.__IOS2_GAME_INSTANCE__ &&
            window.__IOS2_GAME_INSTANCE__.startupMode || 'serial');
        console.log('[ios2-web] target frame rate', targetFrameRate);
        var option = {
            id: canvas,
            debugMode: cc.debug.DebugMode.ERROR,
            showFPS: false,
            frameRate: targetFrameRate,
            groupList: settings.groupList,
            collisionMatrix: settings.collisionMatrix
        };
        cc.assetManager.init({
            bundleVers: settings.bundleVers,
            remoteBundles: settings.remoteBundles,
            server: settings.server
        });
        configureMultiOpenLoading(multiOpen, startupMode);
        installStartupDownloadTracker();
        installStartupFetchTracker();
        installStartupXHRTracker();
        installEncryptedBundleLoader();
        var bundles = [{
            name: cc.AssetManager.BuiltinBundleName.INTERNAL,
            url: 'ios2-game://app/assets/internal'
        }];
        if (settings.hasResourcesBundle) {
            bundles.push({
                name: cc.AssetManager.BuiltinBundleName.RESOURCES,
                url: 'ios2-game://app/assets/resources'
            });
        }
        bundles.push({
            name: 'launcher',
            url: 'ios2-game://app/cdn/remote/launcher'
        });
        var scripts = settings.jsList || [];
        var pending = bundles.length + (scripts.length ? 1 : 0);
        var failed = false;
        function complete(error, name) {
            if (failed) return;
            if (error) {
                failed = true;
                console.error('[ios2-web] load failed', name, error);
                var detail = error && (error.stack || error.message) || String(error || '未知错误');
                if (name === 'launcher') {
                    var version = settings.bundleVers && settings.bundleVers.launcher || '<unknown>';
                    showFatal('WebKit 游戏代码加载失败\n\n无法下载或解密：\n' +
                        'remote/launcher/index.' + version + '.jsc\n\n' + detail);
                } else {
                    showFatal('WebKit 游戏启动失败\n\n加载 ' + name + ' 失败：\n' + detail);
                }
                return;
            }
            pending--;
            if (!pending) {
                cc.game.run(option, function () {
                    // The launcher registers its JSB-only ASTC parser from
                    // EVENT_ENGINE_INITED. Restore the WebKit parser after
                    // that event has completed and before loading the scene.
                    installASTCTextureSupport();
                    console.log('[ios2-web] WebKit PVR parser restored after engine init');
                    installDirectorAssetReleaseHook();
                    // 缺口账本要在第一个场景加载**之前**装好，否则启动期那一批
                    // 「贴图后到」就全落在观测之外了——而那正是最容易复现的场景。
                    // 装没装上由 `render-gap` 通道自述（`ledger-installed` /
                    // `ledger-unavailable`），不依赖 console——debug 级在默认档位会被丢掉。
                    installRenderGapLedger();
                    // 视口指纹：立刻一条 + 8s 一条。晚的那条是等游戏自己把
                    // 设计分辨率 / 适配策略设完之后再采——那才是实际生效的值。
                    reportViewportFingerprint('engine-init');
                    window.setTimeout(function () { reportViewportFingerprint('settled'); }, 8000);
                    // 兜底：自检看门狗正常由启动沉降（sendReady）接手。万一沉降
                    // 因故没上报（页面卡在加载中等），这里 20s 后也必须把它拉起来，
                    // 否则「元素不全」又回到无人观测的状态。
                    window.setTimeout(installRenderIntegrityWatchdog, 20000);
                    var device = cc.renderer && cc.renderer.device;
                    var gl = device && device._gl;
                    var pvrtc = device && device.ext('WEBGL_compressed_texture_pvrtc');
                    var astc = gl && gl.getExtension('WEBGL_compressed_texture_astc');
                    reportCapabilities(gl);
                    if (!pvrtc && !astc) {
                        throw new Error('PVRTC or ASTC is required; PNG/WebP fallback is disabled');
                    }
                    // Cocos 2.4.9 only considers .pvr when it sees the PVRTC
                    // extension. This project's .pvr files contain ASTC data,
                    // parsed and uploaded by installASTCTextureSupport above.
                    if (!pvrtc && astc) {
                        device._extensions.WEBGL_compressed_texture_pvrtc = astc;
                        console.log('[ios2-web] ASTC enabled for PVR texture selection');
                    }
                    // Native Cocos uses UIScreen.scale (usually 3x on a real
                    // iPhone), while Cocos Web defaults to a 2x pixel-ratio
                    // cap. Match the native backing-store density for a
                    // single WebKit game. Multi-open uses a capped scale per
                    // quality level because each extra retina canvas
                    // multiplies GPU and IOSurface memory.
                    var devicePixelRatio = Number(window.devicePixelRatio) || 1;
                    var quality = renderQuality();
                    var webPixelRatio = renderPixelRatio(quality, devicePixelRatio, multiOpen);
                    if (typeof cc.view._maxPixelRatio === 'number') {
                        cc.view._maxPixelRatio = webPixelRatio;
                    }
                    cc.view.enableRetina(webPixelRatio > 1);
                    // Desktop matrix cells are resizable surfaces. Use
                    // EXACT_FIT in multi-open mode so the game canvas fills
                    // the whole cell instead of preserving a phone ratio and
                    // showing black bars at the sides.
                    if (multiOpen && cc.ResolutionPolicy &&
                        typeof cc.view.setResolutionPolicy === 'function') {
                        cc.view.setResolutionPolicy(cc.ResolutionPolicy.EXACT_FIT);
                    }
                    cc.view.resizeWithBrowserSize(true);
                    console.log('[ios2-web] pixel ratio',
                        'device=' + devicePixelRatio,
                        'quality=' + quality,
                        'instances=' + ((window.__IOS2_GAME_INSTANCE__ || {}).instanceCount || 1),
                        'selected=' + webPixelRatio,
                        'retina=' + cc.view.isRetinaEnabled());
                    cc.director.loadScene(settings.launchScene, function (sceneError) {
                        if (sceneError) console.error('[ios2-web] scene failed', sceneError);
                        var gameCanvas = document.getElementById('GameCanvas');
                        if (gameCanvas) {
                            console.log('[ios2-web] canvas backing size',
                                gameCanvas.width + 'x' + gameCanvas.height,
                                'css=' + gameCanvas.clientWidth + 'x' + gameCanvas.clientHeight);
                        }
                        notifyStartupReadyAfterSettling(sceneError);
                    });
                });
            }
        }
        if (scripts.length) {
            cc.assetManager.loadScript(scripts.map(function (path) {
                return 'ios2-game://app/src/' + path;
            }), function (error) { complete(error, 'scripts'); });
        }
        bundles.forEach(function (bundle) {
            cc.assetManager.loadBundle(bundle.url, {
                version: settings.bundleVers && settings.bundleVers[bundle.name]
            }, function (error) {
                complete(error, bundle.name);
            });
        });
    }

    window.addEventListener('load', boot);
}());
