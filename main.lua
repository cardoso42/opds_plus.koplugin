local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local CalibreWebLayout = require("ui.calibre_web_layout")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Import constants
local Constants = require("models.constants")

-- Import settings manager
local Settings = require("config.settings")
local SettingsMenu = require("config.settings_menu")

-- Import settings dialogs
local SettingsDialogs = require("ui.dialogs.settings_dialogs")

-- Import state manager
local StateManager = require("core.state_manager")

local OPDS = WidgetContainer:extend {
    name = "opdsplus",
    opds_settings_file = DataStorage:getSettingsDir() .. "/opdsplus.lua",
    settings = nil,
    downloads = nil,
}

function OPDS:init()
    -- Initialize settings
    local settings_manager = Settings:new(self.opds_settings_file)
    self.opds_settings = settings_manager.storage
    self.settings = settings_manager.data

    -- Initialize defaults
    settings_manager:initializeDefaults()

    if settings_manager.is_first_run then
        self.updated = true -- first run, force flush
    end

    -- Initialize state manager singleton
    StateManager.getInstance(self)

    -- Load downloads and pending syncs
    self.downloads = self.opds_settings:readSetting("downloads", {})
    self.pending_syncs = self.opds_settings:readSetting("pending_syncs", {})

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function OPDS:getCoverHeightRatio()
    return self.settings.cover_height_ratio or Constants.DEFAULT_COVER_HEIGHT_RATIO
end

function OPDS:setCoverHeightRatio(ratio, preset_name)
    self.settings.cover_height_ratio = ratio
    self.settings.cover_size_preset = preset_name or "Custom"
    self.opds_settings:saveSetting("settings", self.settings)
    self.opds_settings:flush()
end

function OPDS:getCurrentPresetName()
    return self.settings.cover_size_preset or "Regular"
end

function OPDS:saveSetting(key, value)
    self.settings[key] = value
    self.opds_settings:saveSetting("settings", self.settings)
    self.opds_settings:flush()
end

function OPDS:getSetting(key)
    if self.settings[key] ~= nil then
        return self.settings[key]
    end
    return Constants.DEFAULT_FONT_SETTINGS[key]
end

function OPDS:getAvailableFonts()
    local fonts = {}

    -- Add KOReader's built-in UI fonts first
    table.insert(fonts, { name = "Default UI (Noto Sans)", value = "smallinfofont" })
    table.insert(fonts, { name = "Alternative UI", value = "infofont" })

    -- Scan font directories for available fonts
    local font_dirs = {
        "./fonts", -- KOReader's font directory
    }

    -- Add user's font directory if it exists
    local user_font_dir = DataStorage:getDataDir() .. "/fonts"
    if lfs.attributes(user_font_dir, "mode") == "directory" then
        table.insert(font_dirs, user_font_dir)
    end

    local font_extensions = {
        [".ttf"] = true,
        [".otf"] = true,
        [".ttc"] = true,
    }

    -- Scan directories for font files
    local seen_fonts = {}
    for i, font_dir in ipairs(font_dirs) do
        if lfs.attributes(font_dir, "mode") == "directory" then
            for entry in lfs.dir(font_dir) do
                if entry ~= "." and entry ~= ".." then
                    local path = font_dir .. "/" .. entry
                    local mode = lfs.attributes(path, "mode")

                    -- Check if it's a font file
                    if mode == "file" then
                        local ext = entry:match("%.([^.]+)$")
                        if ext then
                            ext = "." .. ext:lower()
                            if font_extensions[ext] then
                                local font_name = entry:match("^(.+)%.")
                                if font_name and not seen_fonts[font_name] then
                                    seen_fonts[font_name] = true
                                    local display_name = font_name:gsub("%-", " "):gsub("_", " ")
                                    table.insert(fonts, {
                                        name = display_name,
                                        value = font_name,
                                    })
                                end
                            end
                        end
                        -- Also check subdirectories
                    elseif mode == "directory" then
                        local subdir_path = path
                        for subentry in lfs.dir(subdir_path) do
                            if subentry ~= "." and subentry ~= ".." then
                                local subpath = subdir_path .. "/" .. subentry
                                if lfs.attributes(subpath, "mode") == "file" then
                                    local ext = subentry:match("%.([^.]+)$")
                                    if ext then
                                        ext = "." .. ext:lower()
                                        if font_extensions[ext] then
                                            local font_name = subentry:match("^(.+)%.")
                                            if font_name and not seen_fonts[font_name] then
                                                seen_fonts[font_name] = true
                                                local display_name = font_name:gsub("%-", " "):gsub("_", " ")
                                                table.insert(fonts, {
                                                    name = display_name,
                                                    value = font_name,
                                                })
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort alphabetically by display name
    table.sort(fonts, function(a, b) return a.name < b.name end)

    return fonts
end

function OPDS:onDispatcherRegisterActions()
    Dispatcher:registerAction("opdsplus_show_catalog",
        { category = "none", event = "ShowOPDSPlusCatalog", title = _("Calibre-Web OPDS"), filemanager = true, }
    )

    Dispatcher:registerAction("opdsplus_sync_all",
        { category = "none", event = "StartOPDSSyncAllCatalogs", title = _("OPDS Plus: Sync all catalogs"), filemanager = true, }
    )

    Dispatcher:registerAction("opdsplus_force_sync_all",
        { category = "none", event = "StartOPDSForceSyncAllCatalogs", title = _("OPDS Plus: Force sync all catalogs"), filemanager = true, }
    )
end

function OPDS:_createBrowserInstance(url, username, password)
    return CalibreWebLayout:new {
        base_url = url,
        username = username,
        password = password,
        downloads = self.downloads,
        settings = self.settings,
        pending_syncs = self.pending_syncs,
        _manager = self,
        file_downloaded_callback = function(file)
            self:showFileDownloadedDialog(file)
        end,
        close_callback = function()
            self.opds_browser = nil
            if self.last_downloaded_file then
                if self.ui.file_chooser then
                    local pathname = util.splitFilePathName(self.last_downloaded_file)
                    self.ui.file_chooser:changeToPath(pathname, self.last_downloaded_file)
                end
                self.last_downloaded_file = nil
            end
        end,
    }
end

function OPDS:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.opdsplus = {
            text = _("Calibre-Web OPDS"),
            callback = function()
                self:onShowOPDSPlusCatalog()
            end
        }
    end
end

function OPDS:showCoverSizeMenu()
    SettingsDialogs.showCoverSizeMenu(self)
end

function OPDS:showCustomSizeDialog()
    SettingsDialogs.showCustomSizeDialog(self)
end

function OPDS:showFontSelectionMenu(setting_key, title)
    SettingsDialogs.showFontSelectionMenu(self, setting_key, title)
end

function OPDS:showSizeSelectionMenu(setting_key, title, min_size, max_size, default_size)
    SettingsDialogs.showSizeSelectionMenu(self, setting_key, title, min_size, max_size, default_size)
end

function OPDS:showGridLayoutMenu()
    SettingsDialogs.showGridLayoutMenu(self)
end

function OPDS:showGridColumnsMenu()
    SettingsDialogs.showGridColumnsMenu(self)
end

function OPDS:showGridBorderMenu()
    SettingsDialogs.showGridBorderMenu(self)
end

function OPDS:showGridBorderSizeMenu()
    SettingsDialogs.showGridBorderSizeMenu(self)
end

function OPDS:showGridBorderColorMenu()
    SettingsDialogs.showGridBorderColorMenu(self)
end

function OPDS:showCoverCacheSizeDialog()
    SettingsDialogs.showCoverCacheSizeDialog(self)
end

function OPDS:showCoverCacheTTLDialog()
    SettingsDialogs.showCoverCacheTTLDialog(self)
end

function OPDS:clearCoverCache()
    SettingsDialogs.clearCoverCache()
end

function OPDS:showConnectionSettingsDialog(on_success_callback)
    local url = self:getSetting("calibre_web_url")
    local username = self:getSetting("calibre_web_username")
    local password = self:getSetting("calibre_web_password")

    self.url_dialog = MultiInputDialog:new{
        title = _("Enter Calibre-Web Details"),
        fields = {
            { hint = _("Calibre-Web URL"), text = url or "http://" },
            { hint = _("Username (optional)"), text = username or "" },
            { hint = _("Password (optional)"), text = password or "", text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.url_dialog)
                    end
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = self.url_dialog:getFields()
                        local input_url = fields[1]
                        local input_user = fields[2]
                        local input_pass = fields[3]
                        if input_url and input_url ~= "" and input_url ~= "http://" then
                            UIManager:close(self.url_dialog)
                            self:saveSetting("calibre_web_url", input_url)
                            if input_user and input_user ~= "" then
                                self:saveSetting("calibre_web_username", input_user)
                            else
                                self:saveSetting("calibre_web_username", false)
                            end
                            if input_pass and input_pass ~= "" then
                                self:saveSetting("calibre_web_password", input_pass)
                            else
                                self:saveSetting("calibre_web_password", false)
                            end
                            if on_success_callback then
                                on_success_callback(input_url, input_user, input_pass)
                            end
                        end
                    end
                }
            }
        }
    }
    UIManager:show(self.url_dialog)
end

function OPDS:onShowOPDSPlusCatalog()
    local url = self:getSetting("calibre_web_url")
    local username = self:getSetting("calibre_web_username")
    local password = self:getSetting("calibre_web_password")
    
    if not url or url == "" then
        self:showConnectionSettingsDialog(function(new_url, new_user, new_pass)
            self.opds_browser = self:_createBrowserInstance(new_url, new_user, new_pass)
            UIManager:show(self.opds_browser)
        end)
    else
        self.opds_browser = self:_createBrowserInstance(url, username, password)
        UIManager:show(self.opds_browser)
    end
end

function OPDS:showFileDownloadedDialog(file)
    self.last_downloaded_file = file
    UIManager:show(ConfirmBox:new {
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), BD.filepath(file)),
        ok_text = _("Read now"),
        ok_callback = function()
            self.last_downloaded_file = nil
            self.opds_browser.close_callback()
            if self.ui.document then
                self.ui:switchDocument(file)
            else
                self.ui:openFile(file)
            end
        end,
    })
end

function OPDS:onFlushSettings()
    if self.updated then
        self.opds_settings:flush()
        self.updated = nil
    end
end

return OPDS
