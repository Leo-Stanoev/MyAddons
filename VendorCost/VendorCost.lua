--[[
    VendorCost
    Displays vendor buy prices directly within item tooltips.
    Records live vendor data and supports static database fallbacks.

    Slash Commands: /vendorcost or /vc
]]--

local ADDON_NAME = "VendorCost"

-- ============================================================================
-- Database & Configuration
-- ============================================================================

-- Default user preferences (overridden by VendorCostDB.settings if saved)
local DEFAULT_SETTINGS = {
    enabled       = true,   -- Master on/off toggle
    showCount     = true,   -- Append vendor count, e.g., "(N vendors)"
    showEach      = true,   -- Append "x1" suffix when item is sold in stacks
    position      = 0,      -- 0 = Bottom; N = Insert after line N from top (1-based)
}

local db       -- VendorCostDB.items    (Live scanned data)
local settings -- VendorCostDB.settings (User preferences)

-- ============================================================================
-- Formatting Utilities
-- ============================================================================

-- Converts copper into Blizzard's native inline coin textures.
-- Safely falls back to plain colored text if the modern API is unavailable.
local function FormatMoney(copper)
    if not copper or copper <= 0 then return "Free" end
    if GetCoinTextureString then
        return GetCoinTextureString(copper, 12)
    end
    
    -- Legacy Fallback
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop    = copper % 100
    local parts  = {}
    if gold   > 0 then parts[#parts+1] = gold   .. "|cffffcc00g|r" end
    if silver > 0 then parts[#parts+1] = silver .. "|cffc0c0c0s|r" end
    if cop    > 0 then parts[#parts+1] = cop    .. "|cffb87333c|r" end
    return table.concat(parts, " ")
end

-- Extracts the numeric item ID from a standard WoW item hyperlink
local function GetItemIDFromLink(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- ============================================================================
-- Data Retrieval & Caching
-- ============================================================================

-- Queries the price, known vendor count, and purchase stack size for an item.
-- Priority: Live scanned database > Static pre-built fallback database.
local function Lookup(itemID)
    local entry = db[itemID]
    if entry then
        return entry.p, entry.c, entry.q or 1
    end
    
    if VendorCostData then
        local s = VendorCostData[itemID]
        if s then
            return s.p, s.c, s.q or 1
        end
    end
    return nil
end

-- ============================================================================
-- Tooltip Manipulation
-- ============================================================================

-- Extracts all existing left/right text and color data from a tooltip into a table.
-- Necessary for safely injecting custom lines into the middle of a tooltip.
local function ReadTooltipLines(tooltip)
    local name  = tooltip:GetName()
    local lines = {}
    for i = 1, tooltip:NumLines() do
        local leftObj  = _G[name .. "TextLeft"  .. i]
        local rightObj = _G[name .. "TextRight" .. i]
        local lr, lg, lb = 1, 1, 1
        local rr, rg, rb = 1, 1, 1
        local leftText, rightText = "", nil
        
        if leftObj then
            leftText          = leftObj:GetText() or ""
            lr, lg, lb        = leftObj:GetTextColor()
        end
        
        if rightObj then
            local rt = rightObj:GetText()
            if rt and rt ~= "" then
                rightText  = rt
                rr, rg, rb = rightObj:GetTextColor()
            end
        end
        
        lines[i] = { 
            lt=leftText, lr=lr, lg=lg, lb=lb,
            rt=rightText, rr=rr, rg=rg, rb=rb 
        }
    end
    return lines
end

-- Injects the vendor cost line into the tooltip.
-- Appends to the bottom if pos == 0, otherwise rebuilds the tooltip to insert at pos.
local function AddVendorLine(tooltip, leftText, rightText, pos)
    local totalLines = tooltip:NumLines()

    if pos == 0 or pos >= totalLines then
        tooltip:AddDoubleLine(
            leftText,  rightText,
            1, 0.82, 0,   -- left: WoW gold (matches standard labels)
            1, 1,    1    -- right: white base (inline codes handle coins)
        )
        tooltip:Show()
        return
    end

    -- Capture existing data before wiping the tooltip
    local lines       = ReadTooltipLines(tooltip)
    local insertAfter = math.max(1, math.min(pos, totalLines))

    tooltip:ClearLines()

    for i, ln in ipairs(lines) do
        if ln.rt then
            tooltip:AddDoubleLine(ln.lt, ln.rt,  ln.lr, ln.lg, ln.lb,  ln.rr, ln.rg, ln.rb)
        else
            tooltip:AddLine(ln.lt, ln.lr, ln.lg, ln.lb)
        end
        if i == insertAfter then
            tooltip:AddDoubleLine(
                leftText,  rightText,
                1, 0.82, 0,
                1, 1,    1
            )
        end
    end

    tooltip:Show()
end

-- Tooltip hook: Fires immediately after the tooltip has been populated with an item.
local function OnTooltipSetItem(tooltip)
    if not settings.enabled then return end

    local _name, link = tooltip:GetItem()
    if not link then return end
    
    local itemID = GetItemIDFromLink(link)
    if not itemID then return end

    local price, count, qty = Lookup(itemID)
    if not price then return end

    -- Construct the pricing string (e.g., "4s  x1  (259)")
    local rightParts = { FormatMoney(price) }

    if settings.showEach and qty and qty > 1 then
        rightParts[#rightParts+1] = "|cff888888x1|r"
    end

    if settings.showCount and count and count > 1 then
        rightParts[#rightParts+1] = "|cff888888(" .. count .. ")|r"
    end

    AddVendorLine(tooltip, "Vendor Cost", table.concat(rightParts, " "), settings.position)
end

-- ============================================================================
-- Live Vendor Scanning
-- ============================================================================

-- Silently scans the active merchant window to record per-unit item prices.
-- Updates the live database to ensure tooltip accuracy.
local function ScanMerchant()
    local numItems = GetMerchantNumItems()
    if not numItems or numItems == 0 then return end

    for i = 1, numItems do
        local _nm, _tx, price, qty, _avail, _use, _extCost = GetMerchantItemInfo(i)
        
        -- Items with extended costs can still have a supplementary copper price
        if price and price > 0 then  
            local link   = GetMerchantItemLink(i)
            local itemID = GetItemIDFromLink(link)
            
            if itemID then
                qty = (qty and qty > 0) and qty or 1
                local perUnit = math.floor(price / qty)
                local entry   = db[itemID]
                
                if not entry then
                    db[itemID] = { p=perUnit, c=1, q=qty>1 and qty or nil }
                else
                    if perUnit < entry.p then entry.p = perUnit end
                    if qty > 1 then entry.q = qty end
                    entry.c = entry.c + 1
                end
            end
        end
    end
end

-- Secures hooks into all relevant global tooltips
local function HookTooltips()
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
        if tt then
            tt:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        end
    end
end

-- ============================================================================
-- Options Panel Generation
-- ============================================================================

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame", "VendorCostOptionsPanel", UIParent)
    panel.name = "VendorCost"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("VendorCost")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Shows vendor buy price in item tooltips.")

    -- Maintain references to checkboxes to update their state OnShow
    local checkboxes = {}
    local y = -62

    local function MakeCheckbox(optKey, label, desc)
        local cb = CreateFrame("CheckButton", "VendorCostCB_"..optKey, panel, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, y)
        cb.Text:SetText(label)
        if desc then cb.tooltipText = desc end
        cb:SetChecked(settings[optKey])
        
        cb:SetScript("OnClick", function(self)
            settings[optKey] = self:GetChecked()
        end)
        
        checkboxes[optKey] = cb
        y = y - 30
        return cb
    end

    MakeCheckbox("enabled",   "Enable VendorCost",
        "Show vendor buy price in item tooltips.")

    MakeCheckbox("showCount", "Show vendor count",
        'Append the number of known vendors that sell the item, e.g. "(45)".')

    MakeCheckbox("showEach",  'Show "x1" for stacked purchases',
        'When a vendor sells items in bulk (e.g. food sold 5 at a time),\nadd "x1" to clarify the price shown is per individual item.')

    y = y - 6

    -- Tooltip Line Position Slider
    local posHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    posHeader:SetPoint("TOPLEFT", 16, y)
    posHeader:SetText("Tooltip Line Position")
    y = y - 18

    local posDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    posDesc:SetPoint("TOPLEFT", 22, y)
    posDesc:SetWidth(380)
    posDesc:SetText(
        "Controls which line the vendor price is inserted after.\n" ..
        "0 = always at the bottom.  1 = right after the item name.  " ..
        "2 = after the 2nd line, etc."
    )
    y = y - 48

    local sliderName = "VendorCostPositionSlider"
    local slider = CreateFrame("Slider", sliderName, panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 22, y)
    slider:SetWidth(240)
    slider:SetMinMaxValues(0, 10)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(settings.position)
    
    _G[sliderName .. "Low"]:SetText("0")
    _G[sliderName .. "High"]:SetText("10")
    _G[sliderName .. "Text"]:SetText("After line: " .. settings.position ..
        (settings.position == 0 and "  (bottom)" or ""))
        
    slider:SetScript("OnValueChanged", function(self, val)
        local v = math.floor(val + 0.5)
        settings.position = v
        _G[sliderName .. "Text"]:SetText("After line: " .. v ..
            (v == 0 and "  (bottom)" or ""))
    end)

    -- Synchronize UI with database when panel is opened
    panel:SetScript("OnShow", function()
        for key, cb in pairs(checkboxes) do
            cb:SetChecked(settings[key])
        end
        slider:SetValue(settings.position)
        _G[sliderName .. "Text"]:SetText("After line: " .. settings.position ..
            (settings.position == 0 and "  (bottom)" or ""))
    end)

    -- Footer Commands Hint
    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 16, 16)
    hint:SetText("Slash commands:  /vc  |  /vc on|off  |  /vc scan  |  /vc debug [itemID]")

    -- Compatibility handling for modern Classic client APIs
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
        category.ID = panel.name
        Settings.RegisterAddOnCategory(category)
        VendorCost_SettingsCategory = category
    else
        InterfaceOptions_AddCategory(panel)
    end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_VENDORCOST1 = "/vendorcost"
SLASH_VENDORCOST2 = "/vc"
SlashCmdList["VENDORCOST"] = function(msg)
    msg = strtrim(msg):lower()
    
    if msg == "on" then
        settings.enabled = true
        print("|cffffcc00[VendorCost]|r Enabled.")
        
    elseif msg == "off" then
        settings.enabled = false
        print("|cffffcc00[VendorCost]|r Disabled.")
        
    elseif msg == "scan" then
        -- Force an immediate re-scan of the active merchant window
        local n = GetMerchantNumItems and GetMerchantNumItems() or 0
        if n > 0 then
            ScanMerchant()
            print("|cffffcc00[VendorCost]|r Scanned " .. n .. " merchant items.")
        else
            print("|cffffcc00[VendorCost]|r No merchant window is open.")
        end
        
    elseif msg:match("^debug%s*%d*$") then
        local idStr = msg:match("(%d+)")
        if idStr then
            -- /vc debug 12345 → Look up item ID 12345
            local itemID = tonumber(idStr)
            local p, c, q = Lookup(itemID)
            if p then
                print(string.format("|cffffcc00[VendorCost]|r Item %d → price=%dcp, count=%s, qty=%s",
                    itemID, p, tostring(c), tostring(q)))
            else
                local inStatic = VendorCostData and VendorCostData[itemID] and "yes (static only)" or "NOT FOUND"
                print(string.format("|cffffcc00[VendorCost]|r Item %d → %s", itemID, inStatic))
            end
        else
            -- /vc debug → Print global DB statistics
            local liveCount   = 0
            for _ in pairs(db) do liveCount = liveCount + 1 end
            
            local staticCount = 0
            if VendorCostData then
                for _ in pairs(VendorCostData) do staticCount = staticCount + 1 end
            end
            
            print(string.format(
                "|cffffcc00[VendorCost]|r DB: %d live scanned  |  %d static pre-loaded",
                liveCount, staticCount))
            local n = GetMerchantNumItems and GetMerchantNumItems() or 0
            print(string.format("|cffffcc00[VendorCost]|r Merchant items visible: %d", n))
        end
    else
        if Settings and Settings.OpenToCategory then
            if VendorCost_SettingsCategory then
                Settings.OpenToCategory(VendorCost_SettingsCategory.ID)
            end
        else
            InterfaceOptionsFrame_OpenToCategory("VendorCost")
            InterfaceOptionsFrame_OpenToCategory("VendorCost")
        end
    end
end

-- ============================================================================
-- Event Handlers & Core Logic
-- ============================================================================

-- Safely executes a function after a specified delay.
-- Uses C_Timer if available, gracefully falling back to an OnUpdate frame.
local function After(delay, func)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, func)
        return
    end
    
    local elapsed = 0
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            func()
        end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_UPDATE") 

-- Debounce: Prevents redundant scans when SHOW and UPDATE fire simultaneously.
local pendingScan = false  

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then

        -- Initialize the SavedVariable structure
        if type(VendorCostDB) ~= "table" then VendorCostDB = {} end
        if type(VendorCostDB.items) ~= "table" then VendorCostDB.items = {} end
        if type(VendorCostDB.settings) ~= "table" then VendorCostDB.settings = {} end

        db       = VendorCostDB.items
        settings = VendorCostDB.settings

        -- Merge missing defaults into the user's saved settings
        for k, v in pairs(DEFAULT_SETTINGS) do
            if settings[k] == nil then settings[k] = v end
        end

        HookTooltips()
        BuildOptionsPanel()

    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        if not pendingScan then
            pendingScan = true
            After(0.25, function()
                pendingScan = false
                ScanMerchant()
            end)
        end
    end
end)