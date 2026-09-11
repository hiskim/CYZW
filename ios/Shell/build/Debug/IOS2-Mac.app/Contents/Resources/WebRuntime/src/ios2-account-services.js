/* Native account persistence and authentication adapters. */
(function (global) {
    'use strict';

    function nativeCall(method) {
        if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) {
            throw new Error('native bridge is unavailable');
        }
        var args = Array.prototype.slice.call(arguments, 1);
        args.unshift('IOS2Native', method);
        return jsb.reflection.callStaticMethod.apply(jsb.reflection, args);
    }

    function safeParse(value, fallback) {
        try {
            var parsed = JSON.parse(String(value || ''));
            return parsed === null || parsed === undefined ? fallback : parsed;
        } catch (error) {
            return fallback;
        }
    }

    function IOS2AccountRepository(storage) {
        this.storage = storage || null;
        this.accounts = this._loadCached();
    }

    IOS2AccountRepository.prototype._loadCached = function () {
        if (!this.storage) return [];
        var records = safeParse(this.storage.getItem('ios2.bins'), []);
        return Array.isArray(records) ? records : [];
    };

    IOS2AccountRepository.prototype._save = function () {
        if (!this.storage) return;
        try { this.storage.setItem('ios2.bins', JSON.stringify(this.accounts)); } catch (ignored) {}
    };

    IOS2AccountRepository.prototype.cached = function () {
        return this.accounts.slice(0);
    };

    IOS2AccountRepository.prototype.refresh = function () {
        nativeCall('listBinFiles');
    };

    IOS2AccountRepository.prototype.importFiles = function () {
        nativeCall('selectBinFile');
    };

    IOS2AccountRepository.prototype.remove = function (name) {
        nativeCall('deleteBinFile:', name);
    };

    IOS2AccountRepository.prototype.acceptNativeList = function (json) {
        var fresh = safeParse(json, []);
        if (!Array.isArray(fresh)) fresh = [];
        var previous = Object.create(null);
        var order = Object.create(null);
        var index;
        for (index = 0; index < this.accounts.length; index++) {
            var oldRecord = this.accounts[index];
            if (!oldRecord || !oldRecord.name) continue;
            previous[oldRecord.name] = oldRecord;
            order[oldRecord.name] = index;
        }
        for (index = 0; index < fresh.length; index++) {
            var record = fresh[index];
            var old = record && previous[record.name];
            if (old && old.groupId && !record.groupId) record.groupId = old.groupId;
        }
        fresh.sort(function (left, right) {
            if (!!left.last !== !!right.last) return left.last ? -1 : 1;
            var leftOrder = order[left.name];
            var rightOrder = order[right.name];
            if (leftOrder !== undefined || rightOrder !== undefined) {
                return (leftOrder === undefined ? 9007199254740991 : leftOrder) -
                    (rightOrder === undefined ? 9007199254740991 : rightOrder);
            }
            return String(left.name || '').localeCompare(String(right.name || ''));
        });
        this.accounts = fresh;
        this._save();
        return this.cached();
    };

    function IOS2LoginService() {}

    function runtimeBackend() {
        try { return String(nativeCall('runtimeBackend') || 'native'); }
        catch (ignored) { return 'native'; }
    }

    IOS2LoginService.prototype.runtimeBackend = runtimeBackend;

    function currentManifestJSON() {
        try {
            var rawData = global.cc && cc.sys && cc.sys.manifestResult && cc.sys.manifestResult.rawData;
            return rawData ? JSON.stringify(rawData) : '{}';
        } catch (error) {
            return '{}';
        }
    }

    IOS2LoginService.prototype.login = function (accountName, scripts) {
        var backend = runtimeBackend();
        if (backend === 'webkit') {
            if (global.__ios2ScriptRuntime) global.__ios2ScriptRuntime.install();
            nativeCall('loginBinFiles:scriptsJSON:manifestJSON:', JSON.stringify([accountName]),
                JSON.stringify(scripts || []), currentManifestJSON());
            return;
        }
        nativeCall('loginBinFile:', accountName);
    };

    IOS2LoginService.prototype.multiLogin = function (accountNames, scripts) {
        if (!Array.isArray(accountNames) || accountNames.length < 2 || accountNames.length > 4) {
            throw new Error('请选择 2 到 4 个账号');
        }
        if (runtimeBackend() !== 'webkit') throw new Error('多开仅支持 WebKit 模式');
        if (global.__ios2ScriptRuntime) global.__ios2ScriptRuntime.install();
        nativeCall('loginBinFiles:scriptsJSON:manifestJSON:', JSON.stringify(accountNames),
            JSON.stringify(scripts || []), currentManifestJSON());
    };

    global.IOS2AccountRepository = IOS2AccountRepository;
    global.IOS2LoginService = IOS2LoginService;
}(window));
