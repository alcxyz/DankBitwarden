import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "dankVault"
    property string trigger: "@"
    property string defaultAction: "password"
    property string backend: "auto"
    property string _resolvedBackend: ""
    property var _entries: []
    property bool _loading: false
    property bool _needsRefresh: false
    property string _error: ""

    signal itemsChanged

    property var _backends: ({
        "rbw": {
            name: "rbw (Bitwarden)",
            binary: "rbw",
            listCommand: function() {
                return ["rbw", "list", "--fields", "name,user,folder"];
            },
            parseListOutput: function(text) {
                var lines = text.trim().split("\n");
                var entries = [];
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line.length === 0) continue;
                    var parts = line.split("\t");
                    entries.push({
                        name: parts[0] || "",
                        user: parts[1] || "",
                        folder: parts[2] || ""
                    });
                }
                return entries;
            },
            getFieldCommand: function(entryName, entryUser, fieldName) {
                var cmd = ["rbw", "get"];
                if (fieldName === "username")
                    cmd = cmd.concat(["--field", "username"]);
                else if (fieldName === "totp")
                    cmd = cmd.concat(["--field", "totp"]);
                cmd.push(entryName);
                if (entryUser) cmd.push(entryUser);
                return cmd;
            },
            errorHint: "Is the vault unlocked? (rbw unlock)"
        },
        "pass": {
            name: "pass (Password Store)",
            binary: "pass",
            listCommand: function() {
                return ["sh", "-c", "find \"${PASSWORD_STORE_DIR:-$HOME/.password-store}\" -name '*.gpg' -printf '%P\\n' | sed 's/\\.gpg$//' | sort"];
            },
            parseListOutput: function(text) {
                var lines = text.trim().split("\n");
                var entries = [];
                for (var i = 0; i < lines.length; i++) {
                    var path = lines[i].trim();
                    if (path.length === 0) continue;
                    var parts = path.split("/");
                    var name = parts[parts.length - 1];
                    var folder = parts.length > 1 ? parts.slice(0, -1).join("/") : "";
                    entries.push({ id: path, name: name, user: "", folder: folder });
                }
                return entries;
            },
            getFieldCommand: function(entryName, entryUser, fieldName) {
                var path = entryName;
                if (fieldName === "password")
                    return ["sh", "-c", "pass show \"$1\" | head -1", "sh", path];
                else if (fieldName === "username")
                    return ["sh", "-c", "pass show \"$1\" | grep -iE '^(username|user|login)\\s*:' | head -1 | cut -d: -f2- | xargs", "sh", path];
                else if (fieldName === "totp")
                    return ["pass", "otp", path];
                return ["sh", "-c", "pass show \"$1\" | head -1", "sh", path];
            },
            errorHint: "Is GPG configured? (gpg --list-keys)"
        },
        "gopass": {
            name: "gopass",
            binary: "gopass",
            listCommand: function() {
                return ["gopass", "ls", "--flat"];
            },
            parseListOutput: function(text) {
                var lines = text.trim().split("\n");
                var entries = [];
                for (var i = 0; i < lines.length; i++) {
                    var path = lines[i].trim();
                    if (path.length === 0) continue;
                    var parts = path.split("/");
                    var name = parts[parts.length - 1];
                    var folder = parts.length > 1 ? parts.slice(0, -1).join("/") : "";
                    entries.push({ id: path, name: name, user: "", folder: folder });
                }
                return entries;
            },
            getFieldCommand: function(entryName, entryUser, fieldName) {
                if (fieldName === "password")
                    return ["gopass", "show", "-o", entryName];
                else if (fieldName === "username")
                    return ["gopass", "show", entryName, "username"];
                else if (fieldName === "totp")
                    return ["gopass", "otp", entryName];
                return ["gopass", "show", "-o", entryName];
            },
            errorHint: "Is gopass initialized? (gopass setup)"
        },
        "op": {
            name: "op (1Password)",
            binary: "op",
            listCommand: function() {
                return ["op", "item", "list", "--format=json"];
            },
            parseListOutput: function(text) {
                var entries = [];
                try {
                    var items = JSON.parse(text);
                    for (var i = 0; i < items.length; i++) {
                        var item = items[i];
                        var folder = "";
                        if (item.vault && item.vault.name)
                            folder = item.vault.name;
                        entries.push({
                            name: item.title || item.id,
                            user: "",
                            folder: folder
                        });
                    }
                } catch (e) {}
                return entries;
            },
            getFieldCommand: function(entryName, entryUser, fieldName) {
                if (fieldName === "totp")
                    return ["op", "item", "get", entryName, "--otp"];
                return ["op", "item", "get", entryName, "--fields", "label=" + fieldName];
            },
            errorHint: "Are you signed in? (op signin)"
        }
    })

    Component.onCompleted: {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "@");
        defaultAction = pluginService.loadPluginData(pluginId, "defaultAction", "password");
        backend = pluginService.loadPluginData(pluginId, "backend", "auto");
        _applyTriggerOnlyVisibilityDefault();
        _resolveBackend();
    }

    function _applyTriggerOnlyVisibilityDefault() {
        if (!pluginService)
            return;
        if (typeof SettingsData === "undefined"
            || typeof SettingsData.getPluginAllowWithoutTrigger !== "function"
            || typeof SettingsData.setPluginAllowWithoutTrigger !== "function")
            return;

        var applied = pluginService.loadPluginData(pluginId, "triggerOnlyVisibilityDefaultApplied", false);
        if (applied === true || applied === "true")
            return;

        var visibility = SettingsData.launcherPluginVisibility || ({});
        var hasVisibilityChoice = visibility[pluginId] !== undefined
            && visibility[pluginId].allowWithoutTrigger !== undefined;

        if (!hasVisibilityChoice && SettingsData.getPluginAllowWithoutTrigger(pluginId))
            SettingsData.setPluginAllowWithoutTrigger(pluginId, false);
        pluginService.savePluginData(pluginId, "triggerOnlyVisibilityDefaultApplied", true);
    }

    function _resolveBackend() {
        if (backend !== "auto") {
            _resolvedBackend = backend;
            _needsRefresh = true;
            return;
        }
        detectProcess.running = true;
    }

    property Process detectProcess: Process {
        command: ["sh", "-c", "for b in rbw pass gopass op; do command -v \"$b\" >/dev/null 2>&1 && echo \"$b\" && exit 0; done; echo none"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                var result = text.trim();
                if (result === "none" || !root._backends[result]) {
                    root._error = "No supported password manager found. Install rbw, pass, gopass, or op.";
                    root._resolvedBackend = "";
                    root.itemsChanged();
                } else {
                    root._resolvedBackend = result;
                    root._needsRefresh = true;
                }
            }
        }
    }

    function refreshEntries() {
        if (!_resolvedBackend || !_backends[_resolvedBackend])
            return;
        _loading = true;
        _error = "";
        var be = _backends[_resolvedBackend];
        listProcess.command = be.listCommand();
        listProcess.running = true;
    }

    property Process listProcess: Process {
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                root._loading = false;
                root._entries = [];
                var be = root._backends[root._resolvedBackend];
                if (be)
                    root._entries = be.parseListOutput(text);
                root.itemsChanged();
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                root._loading = false;
                var be = root._backends[root._resolvedBackend];
                var hint = be ? be.errorHint : "Unknown error";
                root._error = root._resolvedBackend + " failed (exit " + exitCode + "). " + hint;
                root.itemsChanged();
            }
        }
    }

    function getItems(query) {
        if (_needsRefresh && !_loading) {
            _needsRefresh = false;
            refreshEntries();
        }

        if (_error) {
            return [{
                name: _error,
                icon: "material:error",
                comment: "Press Enter to retry",
                action: "retry:",
                categories: ["Vault"],
                _preScored: 1000
            }];
        }

        if (_loading || !_resolvedBackend) {
            return [{
                name: _resolvedBackend ? "Loading vault..." : "Detecting backend...",
                icon: "material:hourglass_empty",
                comment: _resolvedBackend ? ("Fetching entries from " + _resolvedBackend) : "Checking for installed password managers",
                action: "none:",
                categories: ["Vault"],
                _preScored: 1000
            }];
        }

        var lowerQuery = query ? query.toLowerCase().trim() : "";
        var results = [];

        for (var i = 0; i < _entries.length; i++) {
            var entry = _entries[i];
            var nameLower = entry.name.toLowerCase();
            var userLower = entry.user.toLowerCase();
            var folderLower = entry.folder.toLowerCase();

            if (lowerQuery.length === 0
                || nameLower.includes(lowerQuery)
                || userLower.includes(lowerQuery)
                || folderLower.includes(lowerQuery)) {

                var display = entry.name;
                if (entry.folder)
                    display = entry.folder + "/" + entry.name;

                var comment = entry.user || "No username";
                var entryId = entry.id || entry.name;
                var entryRef = entryId + "\t" + entry.user;

                results.push({
                    name: display,
                    icon: "material:key",
                    comment: comment + " \u00b7 password",
                    action: "copy:password:" + entryRef,
                    categories: ["Vault"],
                    _preScored: 1000
                });

                results.push({
                    name: display,
                    icon: "material:person",
                    comment: comment + " \u00b7 username",
                    action: "copy:username:" + entryRef,
                    categories: ["Vault"],
                    _preScored: 950
                });

                results.push({
                    name: display,
                    icon: "material:pin",
                    comment: comment + " \u00b7 TOTP",
                    action: "copy:totp:" + entryRef,
                    categories: ["Vault"],
                    _preScored: 900
                });
            }

            if (results.length >= 150)
                break;
        }

        if (results.length === 0 && lowerQuery.length > 0) {
            return [{
                name: "No matching entries",
                icon: "material:search_off",
                comment: "Try a different query",
                action: "none:",
                categories: ["Vault"],
                _preScored: 1000
            }];
        }

        return results;
    }

    function executeItem(item) {
        if (!item?.action)
            return;
        var colonIdx = item.action.indexOf(":");
        if (colonIdx === -1)
            return;
        var actionType = item.action.substring(0, colonIdx);
        var rest = item.action.substring(colonIdx + 1);

        if (actionType === "retry") {
            _resolveBackend();
            return;
        }

        if (actionType !== "copy")
            return;

        var firstColon = rest.indexOf(":");
        var field = rest.substring(0, firstColon);
        var entryPart = rest.substring(firstColon + 1);
        var tabIdx = entryPart.indexOf("\t");
        var entryName = tabIdx !== -1 ? entryPart.substring(0, tabIdx) : entryPart;
        var entryUser = tabIdx !== -1 ? entryPart.substring(tabIdx + 1) : "";

        var be = _backends[_resolvedBackend];
        if (!be) return;

        copyFieldProcess.command = be.getFieldCommand(entryName, entryUser, field);
        copyFieldProcess._fieldName = field;
        copyFieldProcess.running = true;
    }

    property Process copyFieldProcess: Process {
        property string _fieldName: "password"
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                var value = text.trim();
                if (value.length > 0) {
                    Quickshell.execDetached(["sh", "-c",
                        "printf '%s' \"$1\" | wl-copy --paste-once --sensitive; " +
                        "(sleep 15 && wl-copy --clear) &",
                        "sh", value]);
                    if (typeof ToastService !== "undefined")
                        ToastService.showInfo("Vault", "Copied " + copyFieldProcess._fieldName + " (clears in 15s)");
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                if (typeof ToastService !== "undefined")
                    ToastService.showInfo("Vault", "Failed to get " + _fieldName);
            }
        }
    }

    function getContextMenuActions(item) {
        if (!item?.action || item.action.indexOf("copy:") !== 0)
            return [];

        var rest = item.action.substring(5);
        var firstColon = rest.indexOf(":");
        var entryRef = rest.substring(firstColon + 1);

        return [
            {
                icon: "key",
                text: "Copy Password",
                action: function() { executeItem({ action: "copy:password:" + entryRef }); }
            },
            {
                icon: "person",
                text: "Copy Username",
                action: function() { executeItem({ action: "copy:username:" + entryRef }); }
            },
            {
                icon: "pin",
                text: "Copy TOTP",
                action: function() { executeItem({ action: "copy:totp:" + entryRef }); }
            }
        ];
    }

    onTriggerChanged: {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "trigger", trigger);
    }

    onDefaultActionChanged: {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "defaultAction", defaultAction);
    }

    onBackendChanged: {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "backend", backend);
        _resolveBackend();
    }
}
