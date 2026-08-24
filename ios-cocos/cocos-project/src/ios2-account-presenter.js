/* Coordinates the account view with persistence and authentication services. */
(function (global) {
    'use strict';

    function IOS2AccountPresenter(options) {
        this.repository = options.repository;
        this.loginService = options.loginService;
        this.onOpenPage = options.onOpenPage;
        var self = this;
        this.view = new global.IOS2AccountView({
            importAccounts: function () { self.importAccounts(); },
            login: function (name) { self.login(name); },
            remove: function (name) { self.remove(name); },
            openScripts: function () { self.onOpenPage(1); },
            openConfig: function () { self.onOpenPage(2); }
        });
        this.view.setAccounts(this.repository.cached());
    }

    IOS2AccountPresenter.prototype.show = function () {
        this.view.show();
        this.view.setAccounts(this.repository.cached());
        this.view.setStatus('账号文件仅保存在本机。');
        try { this.repository.refresh(); }
        catch (error) { this.view.setStatus(error.message || '无法读取账号列表', 'warning'); }
    };

    IOS2AccountPresenter.prototype.hide = function () { this.view.hide(); };

    IOS2AccountPresenter.prototype.importAccounts = function () {
        this.view.setStatus('正在打开文件选择器…');
        try { this.repository.importFiles(); }
        catch (error) { this.view.setStatus(error.message || '无法导入账号', 'warning'); }
    };

    IOS2AccountPresenter.prototype.login = function (name) {
        this.view.setBusy(name);
        this.view.setStatus('正在认证 ' + String(name || '') + '…');
        try { this.loginService.login(name); }
        catch (error) {
            this.view.setBusy('');
            this.view.setStatus(error.message || '认证启动失败', 'warning');
        }
    };

    IOS2AccountPresenter.prototype.remove = function (name) {
        this.view.setStatus('正在删除 ' + String(name || '') + '…');
        try { this.repository.remove(name); }
        catch (error) { this.view.setStatus(error.message || '删除失败', 'warning'); }
    };

    IOS2AccountPresenter.prototype.onAccounts = function (json) {
        this.view.setAccounts(this.repository.acceptNativeList(json));
    };

    IOS2AccountPresenter.prototype.onImported = function (name) {
        this.view.setStatus('已导入 ' + String(name || ''), 'success');
        try { this.repository.refresh(); } catch (ignored) {}
    };

    IOS2AccountPresenter.prototype.onDeleted = function (name) {
        this.view.setStatus('已删除 ' + String(name || '').replace(/\.bin$/i, ''), 'success');
        try { this.repository.refresh(); } catch (ignored) {}
    };

    IOS2AccountPresenter.prototype.onDeleteFailed = function (message) {
        this.view.setStatus('删除失败：' + String(message || '未知错误'), 'warning');
    };

    IOS2AccountPresenter.prototype.onLoginReady = function () {
        this.view.setBusy('');
        this.view.setStatus('认证成功，正在进入游戏…', 'success');
    };

    IOS2AccountPresenter.prototype.onLoginFailed = function (message) {
        this.view.setBusy('');
        this.view.setStatus('登录失败：' + String(message || '未知错误'), 'warning');
    };

    global.IOS2AccountPresenter = IOS2AccountPresenter;
}(window));