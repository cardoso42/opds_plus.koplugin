local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local Screen = require("device").screen
local Menu = require("ui/widget/menu")
local OPDSBrowser = require("ui.browser")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local logger = require("logger")
local _ = require("gettext")

local CalibreWebLayout = InputContainer:extend{
    is_popout = false,
    is_borderless = true,
    covers_fullscreen = true,
    update_mode = "ui",
}

function CalibreWebLayout:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.show_sidebar = (screen_w > screen_h)
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    
    local initial_sidebar_w = 0
    local initial_browser_w = screen_w
    if screen_w <= screen_h then
        initial_sidebar_w = screen_w
    else
        if self.show_sidebar then
            initial_sidebar_w = math.floor(screen_w * 0.30)
            initial_sidebar_w = math.max(initial_sidebar_w, Screen:scaleBySize(250))
            initial_sidebar_w = math.min(initial_sidebar_w, math.floor(screen_w * 0.8))
            initial_browser_w = screen_w - initial_sidebar_w
        end
    end
    
    self.base_url = self.base_url or ""
    self.base_url = self.base_url:gsub("/$", "")
    
    self.sidebar = Menu:new{
        dimen = Geom:new{ x = 0, y = 0, w = initial_sidebar_w > 0 and initial_sidebar_w or Screen:scaleBySize(250), h = screen_h },
        title_bar_left_icon = nil,
        title = _("Categories"),
        show_parent = self,
        is_popout = false,
        is_borderless = true,
        item_table = {
            { text = _("Loading categories..."), url = self.base_url .. "/opds/" },
            { text = _("⚙ Settings"), is_settings = true }
        },
        onMenuSelect = function(_, item)
            if item.is_settings then
                local TouchMenu = require("ui/widget/touchmenu")
                local SettingsMenu = require("config.settings_menu")
                local menu = TouchMenu:new{
                    title = _("Calibre-Web Settings"),
                    item_table = SettingsMenu.create(self._manager),
                }
                UIManager:show(menu)
                return true
            end
            if self.browser then
                self.browser.paths = {}
                self.browser.catalog_title = item.text
                self.browser:updateCatalog(item.url, true)
                -- Auto-hide sidebar after selection if in portrait orientation
                if Screen:getWidth() <= Screen:getHeight() and self.show_sidebar then
                    self:toggleSidebar()
                end
            end
            return true
        end,
    }

    self.browser = OPDSBrowser:new{
        dimen = Geom:new{ x = initial_sidebar_w, y = 0, w = initial_browser_w, h = screen_h },
        toggle_sidebar_callback = function()
            self:toggleSidebar()
        end,
        servers = {},
        root_catalog_username = self.username,
        root_catalog_password = self.password,
        downloads = self.downloads,
        settings = self.settings,
        pending_syncs = self.pending_syncs,
        show_parent = self,
        title = _("Calibre-Web"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        show_covers = true,
        _manager = self._manager,
        file_downloaded_callback = self.file_downloaded_callback,
        close_callback = function()
            if self[1] then
                self[1]:free()
            end
            if self.sidebar and self.sidebar.free then
                self.sidebar:free()
            end
            UIManager:close(self)
        end,
    }

    if self.sidebar then
        self.sidebar.close_callback = function()
            self.show_sidebar = false
            self:rebuildLayout()
            UIManager:setDirty(nil, "ui")
            return true
        end
    end

    -- Prevent stray taps from closing the entire application!
    if self.browser.ges_events and self.browser.ges_events.TapCloseAllMenus then
        self.browser.ges_events.TapCloseAllMenus = nil
    end
    if self.sidebar and self.sidebar.ges_events and self.sidebar.ges_events.TapCloseAllMenus then
        self.sidebar.ges_events.TapCloseAllMenus = nil
    end
    
    self.browser.onReturn = function(b)
        table.remove(b.paths)
        local path = b.paths[#b.paths]
        if path then
            b.catalog_title = path.title
            b:updateCatalog(path.url, true)
        else
            UIManager:close(self)
        end
        return true
    end

    self:registerTouchZones({
        {
            id = "opds_plus_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.10,
            },
            overrides = { "filemanager_swipe", "filemanager_ext_swipe", "reader_swipe", "reader_ext_swipe" },
            handler = function(ges)
                local direction = require("ui/bidi").flipDirectionIfMirroredUILayout(ges.direction)
                if direction == "south" then
                    self:onShowMenu()
                    return true
                end
                return false
            end
        },
        {
            id = "opds_plus_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.10,
            },
            overrides = { "filemanager_tap", "filemanager_ext_tap", "reader_tap", "reader_ext_tap" },
            handler = function(ges)
                self:onShowMenu()
                return true
            end
        }
    })

    self:rebuildLayout()
    
    -- Dynamically fetch sidebar categories from OPDS root
    local root_url = self.base_url .. "/opds"
    local NetworkMgr = require("ui/network/manager")
    local FeedFetcher = require("core.feed_fetcher")
    
    NetworkMgr:runWhenConnected(function()
        UIManager:scheduleIn(0, function()
            local catalog = FeedFetcher.parseFeed(root_url, self.username, self.password, function(...) logger.info("OPDS_PLUS FeedParser:", ...) end)
            
            local feed = catalog and (catalog.feed or catalog)
            if not feed or not feed.entry or #feed.entry == 0 then
                return
            end

            local new_items = {}
            local first_url = nil

            for _, entry in ipairs(feed.entry) do
                local target_url
                -- Find the navigation link
                if entry.link then
                    for _, link in ipairs(entry.link) do
                        if link.href then
                            local UrlUtils = require("utils.url_utils")
                            target_url = UrlUtils.buildAbsolute(root_url, link.href)
                            break
                        end
                    end
                end
                
                local entry_title = entry.title
                if type(entry_title) == "table" then
                    entry_title = entry_title[1]
                end
                
                if entry_title and target_url then
                    table.insert(new_items, { text = entry_title, url = target_url })
                    if not first_url then
                        first_url = target_url
                    end
                end
            end
            
            table.insert(new_items, { text = _("Settings"), is_settings = true })
            
            if self.sidebar then
                self.sidebar:switchItemTable(_("Categories"), new_items)
            end
            
            -- Load the first dynamically fetched catalog as the default view
            if first_url and self.browser then
                logger.info("OPDS_PLUS: Loading default catalog view from:", first_url)
                self.browser.catalog_title = new_items[1].text
                self.browser:updateCatalog(first_url, true)
            end
        end)
    end)
end

function CalibreWebLayout:rebuildLayout()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    
    if self.show_sidebar then
        self.sidebar.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = FrameContainer:new{
            padding = 0,
            bordersize = Size.border.window,
            dimen = Geom:new{ w = screen_w, h = screen_h },
            self.sidebar,
        }
    else
        self.browser.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = FrameContainer:new{
            padding = 0,
            bordersize = Size.border.window,
            dimen = Geom:new{ w = screen_w, h = screen_h },
            self.browser,
        }
    end

    UIManager:setDirty(self, "ui")
end

function CalibreWebLayout:toggleSidebar()
    self.show_sidebar = not self.show_sidebar
    self:rebuildLayout()
end

function CalibreWebLayout:onCloseWidget()
    if self.browser.download_list then
        self.browser.download_list.close_callback()
    end
    if self.close_callback then
        self.close_callback()
    end
    self[1] = nil
    self.sidebar = nil
    self.browser = nil
end

function CalibreWebLayout:setupMenu()
    local MenuSorter = require("ui/menusorter")
    
    self.menu_items = {
        ["KOMenu:menu_buttons"] = {}
    }

    -- Define the top-level tab
    self.menu_items.setting = {
        icon = "appbar.settings",
        text = _("Settings"),
    }

    -- Define our custom exit button
    self.menu_items.exit_opds = {
        icon = "home",
        text = _("Exit Calibre-Web"),
        callback = function()
            if self.menu_container then
                local UIManager = require("ui/uimanager")
                UIManager:close(self.menu_container)
                self.menu_container = nil
            end
            local UIManager = require("ui/uimanager")
            UIManager:close(self)
        end
    }

    self.menu_items.connection_settings = {
        icon = "appbar.link",
        text = _("Connection Settings"),
        callback = function()
            if self.menu_container then
                local UIManager = require("ui/uimanager")
                UIManager:close(self.menu_container)
                self.menu_container = nil
            end
            self._manager:showConnectionSettingsDialog(function(new_url, new_user, new_pass)
                local UIManager = require("ui/uimanager")
                UIManager:close(self)
                self._manager:onShowOPDSPlusCatalog()
            end)
        end
    }

    self.menu_items.layout_settings = {
        text = _("Display Layout"),
        sub_item_table = {
            {
                text = _("Cover size"),
                callback = function() self._manager:showCoverSizeMenu() end,
            },
            {
                text = _("Grid layout"),
                callback = function() self._manager:showGridLayoutMenu() end,
            },
            {
                text = _("Title font"),
                callback = function() self._manager:showFontSelectionMenu("font_title", _("Title Font")) end,
            },
        }
    }

    self.menu_items.cache_settings = {
        text = _("Cache"),
        sub_item_table = {
            {
                text = _("Clear cover cache"),
                callback = function() self._manager:clearCoverCache() end,
            },
            {
                text = _("Cache size"),
                callback = function() self._manager:showCoverCacheSizeDialog() end,
            },
        }
    }

    local whitelist = {
        ["KOMenu:menu_buttons"] = true,
        exit_opds = true,
        setting = true,
        connection_settings = true,
        layout_settings = true,
        cache_settings = true,
    }

    -- Filter out all unused items so MenuSorter doesn't crash on orphans
    for k, _ in pairs(self.menu_items) do
        if not whitelist[k] then
            self.menu_items[k] = nil
        end
    end

    local my_order = {
        ["KOMenu:menu_buttons"] = {
            "exit_opds",
            "setting",
        },
        setting = {
            "connection_settings",
            "layout_settings",
            "cache_settings",
        }
    }

    self.tab_item_table = MenuSorter:mergeAndSort("opds_plus", self.menu_items, my_order)
end

function CalibreWebLayout:onShowMenu()
    if not self.tab_item_table then
        self:setupMenu()
    end

    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Screen = Device.screen
    local TouchMenu = require("ui/widget/touchmenu")

    local menu_container = CenterContainer:new{
        ignore = "height",
        dimen = Screen:getSize(),
    }

    local main_menu = TouchMenu:new{
        width = Screen:getWidth(),
        last_index = 1,
        tab_item_table = self.tab_item_table,
        show_parent = menu_container,
        not_shown = false,
    }

    main_menu.close_callback = function()
        if self.menu_container then
            UIManager:close(self.menu_container)
            self.menu_container = nil
        end
    end

    menu_container[1] = main_menu
    self.menu_container = menu_container
    UIManager:show(menu_container)
    
    return true
end

function CalibreWebLayout:handleEvent(event)
    if event.name == "Gesture" then
        -- Check our own TouchZones before giving children a chance to intercept!
        -- This prevents OPDSBrowser's TapCloseAllMenus from closing the app
        -- when tapping the top menu zone.
        if self:onGesture(event.args[1]) then
            return true
        end
    end

    if self:propagateEvent(event) then
        return true
    end

    local Widget = require("ui/widget/widget")
    return Widget.handleEvent(self, event)
end

function CalibreWebLayout:onSwipe(arg, ges_ev) return true end
function CalibreWebLayout:onPan() return true end
function CalibreWebLayout:onHoldPan() return true end
function CalibreWebLayout:onPinch() return true end

return CalibreWebLayout
