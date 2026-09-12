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

    function preferredFrameRate() {
        var frameRate = Number(window.__IOS2_GAME_INSTANCE__ && window.__IOS2_GAME_INSTANCE__.frameRate) || 60;
        return [15, 24, 30, 45, 60].indexOf(frameRate) >= 0 ? frameRate : 60;
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
            if (quality === 'low') return 1;
            if (quality === 'high') return Math.min(2, device);
            return Math.min(1.5, device);
        }
        if (quality === 'low') return 1;
        if (quality === 'medium') return Math.min(2, device);
        return Math.min(3, device);
    }

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
        if (!window.cc) return false;
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
        if (!window.cc) return false;
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
                try {
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

    function installDirectorAssetReleaseHook() {
        var director = window.cc && window.cc.director;
        var Director = window.cc && window.cc.Director;
        if (!director || !Director || !Director.EVENT_AFTER_SCENE_LAUNCH ||
            director.__ios2AssetReleaseHookInstalled) return;
        director.__ios2AssetReleaseHookInstalled = true;
        // Scene transitions are not destruction boundaries. Assets loaded by
        // the outgoing scene may still be shared by UI and future scenes.
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

    function isRecoverableASTCPVRTexture(texture) {
        if (!texture || !texture.loaded || !texture.__ios2ASTCPVRRecovery) return false;
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
            throw new Error('WebGL context is lost');
        }
        var extension = gl.getExtension('WEBGL_compressed_texture_astc');
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
            var status = event && event.statusMessage || 'unknown';
            postWebGraphicsLog('webgl-context-lost', 'WebGL context lost (status=' + status + ')', {
                status: status
            });
        }, false);
        canvas.addEventListener('webglcontextrestored', function () {
            state.contextLost = false;
            postWebGraphicsLog('webgl-context-restored', 'WebGL context restored');
            scheduleASTCPVRRecovery('webgl context restored');
        }, false);
        canvas.addEventListener('webglcontextcreationerror', function (event) {
            var status = event && event.statusMessage || 'unknown';
            postWebGraphicsLog('webgl-context-creation-error',
                'WebGL context creation error (status=' + status + ')', { status: status });
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

        var descriptor = Object.getOwnPropertyDescriptor(texturePrototype, '_nativeAsset');
        if (!descriptor || typeof descriptor.set !== 'function') return;
        Object.defineProperty(texturePrototype, '_nativeAsset', {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: descriptor.get,
            set: function (data) {
                if (!(data && data.__ios2ASTCFormat)) {
                    descriptor.set.call(this, data);
                    return;
                }
                uploadASTCPVRTexture(this, data);
                rememberASTCPVRRecoverySource(this, data);
                // The uploader stores dimensions only. Drop the temporary
                // parser view promptly so the source ArrayBuffer can be GCed.
                data._data = null;
            }
        });
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
        window.BATTLE_VERSION = manifest.battleVersion || window.BATTLE_VERSION;
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
