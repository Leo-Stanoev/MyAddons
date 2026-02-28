--[[
    Graphinator
    Visualizes Auctionator historical price data using a dynamic bar graph.
    Hooks into the Auction House and tooltips to provide real-time price history.

    Requires: Auctionator
    Target Client: TBC Classic (2.5.5)
]]--

local ADDON_NAME = "Graphinator"
local Graphinator = {}
_G[ADDON_NAME] = Graphinator

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------
local MAX_BARS     = 60
local LABEL_H      = 14
local DEFAULT_W    = 240
local DEFAULT_H    = 380
local MIN_W        = 160
local MIN_H        = 200

-------------------------------------------------------------------------------
-- STATE
-------------------------------------------------------------------------------
Graphinator.db            = {}
Graphinator.panel         = nil
Graphinator.tabButton     = nil
Graphinator.bars          = {}
Graphinator.barLabels     = {}
Graphinator.dateLabels    = {}
Graphinator.titleFS       = nil
Graphinator.itemNameFS    = nil
Graphinator.statusFS      = nil
Graphinator.graphArea     = nil
Graphinator.settingsPopup = nil
Graphinator.marketLine    = nil
Graphinator.marketLineText= nil

Graphinator.isPanelVisible = true
Graphinator.lastItemID     = nil
Graphinator.lastItemName   = nil
Graphinator.lastItemLink   = nil
Graphinator.lastHistory    = nil
Graphinator.isHooked       = false
Graphinator.tooltipsHooked = false

-------------------------------------------------------------------------------
-- UTILITIES
-------------------------------------------------------------------------------

local function Trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function Graphinator:FormatGold(copper)
    if not copper or copper <= 0 then return "|cFF999999none|r" end
    local g = floor(copper / 10000)
    local s = floor((copper % 10000) / 100)
    local c = copper % 100
    local t = ""
    if g > 0 then t = t .. "|cFFFFD700" .. g .. "g|r " end
    if s > 0 or g > 0 then t = t .. "|cFFCCCCCC" .. s .. "s|r " end
    t = t .. "|cFFCC8800" .. c .. "c|r"
    return Trim(t)
end

local function ShortPrice(copper)
    if not copper or copper <= 0 then return "" end
    if copper >= 10000 then
        local g = copper / 10000
        return (g >= 10) and (floor(g) .. "g") or (string.format("%.1f", g) .. "g")
    elseif copper >= 100 then
        return floor(copper / 100) .. "s"
    else
        return copper .. "c"
    end
end

local function PriceColour(t)
    local r = 1.00 - t * 0.20
    local g = 0.84 * (1 - t) + 0.07 * t
    local b = 0.00 + t * 0.07
    return r, g, b
end

local function AuctionatorReady()
    return Auctionator
        and Auctionator.Database
        and Auctionator.State
        and Auctionator.State.Loaded
end

local function DBGet(key, default)
    local v = Graphinator.db[key]
    if v == nil then return default end
    return v
end

--- Extract day number safely
local function GetDay(dp, index)
    if dp.rawDay then return tonumber(dp.rawDay) end
    if dp.date then
        local n1, n2, n3 = dp.date:match("(%d+)%D+(%d+)%D+(%d+)")
        if n1 and n2 and n3 then
            local y, m, d = 2000, 1, 1
            if #n1 == 4 then 
                y, m, d = tonumber(n1), tonumber(n2), tonumber(n3) 
            elseif #n3 == 4 then 
                y, m, d = tonumber(n3), tonumber(n1), tonumber(n2) 
                if m > 12 then m, d = d, m end 
            end
            return math.floor(time({year=y, month=m, day=d}) / 86400)
        end
    end
    return 100000 - index 
end

-------------------------------------------------------------------------------
-- TOGGLE
-------------------------------------------------------------------------------

function Graphinator:TogglePanel()
    self.isPanelVisible     = not self.isPanelVisible
    self.db.isPanelVisible  = self.isPanelVisible

    if self.isPanelVisible then
        self.panel:Show()
        self.tabButton:SetText("<")
        self:UpdateGraph(self.lastItemID, self.lastItemName, self.lastItemLink)
    else
        self.panel:Hide()
        self.tabButton:SetText(">")
        if self.settingsPopup then self.settingsPopup:Hide() end
    end
end

-------------------------------------------------------------------------------
-- GRAPH DRAWING
-------------------------------------------------------------------------------

function Graphinator:Redraw()
    if self.lastHistory then self:DrawGraph(self.lastHistory) end
end

function Graphinator:DrawGraph(history)
    self.lastHistory = history

    -- Clean slate
    for _, bar in ipairs(self.bars) do bar:Hide() end
    for _, lbl in ipairs(self.barLabels) do lbl:Hide() end
    for _, dLbl in ipairs(self.dateLabels) do dLbl:Hide() end
    if self.marketLine then self.marketLine:Hide() end
    if self.marketLineText then self.marketLineText:Hide() end

    if not history or #history == 0 then
        self.statusFS:SetText("No historical data found.")
        self.statusFS:Show()
        return
    end

    local daysToDisplay = math.floor(DBGet("daysToDisplay", 14))
    local showTimeGaps  = DBGet("showTimeGaps", true)
    
    local newestDay = GetDay(history[1], 1)
    local minDay = newestDay - daysToDisplay + 1
    local currentEpoch = time()

    local validPoints = {}
    local maxPrice, minPrice = 0, math.huge

    for i, dp in ipairs(history) do
        local day = GetDay(dp, i)
        if day >= minDay and day <= newestDay then
            -- Calculate actual timestamp for accurate dates
            local daysAgo = newestDay - day
            local pointEpoch = currentEpoch - (daysAgo * 86400)
            
            table.insert(validPoints, { 
                price = dp.minSeen, 
                date = dp.date, 
                day = day,
                epoch = pointEpoch
            })
            if dp.minSeen > maxPrice then maxPrice = dp.minSeen end
            if dp.minSeen < minPrice then minPrice = dp.minSeen end
        end
    end

    if #validPoints == 0 or maxPrice == 0 then
        self.statusFS:SetText("No price data within the selected timeframe.")
        self.statusFS:Show()
        return
    end
    if minPrice == math.huge then minPrice = 0 end
    self.statusFS:Hide()

    -- Layout Settings
    local showLabels = DBGet("showLabels", false)
    local labelPos   = DBGet("labelPosition", "above")
    local showDate   = DBGet("showDateLabels", false)
    local datePos    = DBGet("dateLabelPosition", "below")
    local dateFormat = DBGet("dateLabelFormat", "date")

    local topReserved, bottomReserved = 0, 0
    if showLabels and labelPos == "above" then topReserved = topReserved + LABEL_H end
    if showLabels and labelPos == "below" then bottomReserved = bottomReserved + LABEL_H end
    if showDate and datePos == "above"    then topReserved = topReserved + LABEL_H end
    if showDate and datePos == "below"    then bottomReserved = bottomReserved + LABEL_H end

    local graphHeight= self.graphArea:GetHeight()
    local graphWidth = self.graphArea:GetWidth()
    local effectiveH = math.max(10, graphHeight - topReserved - bottomReserved)
    local barBottom  = bottomReserved

    local totalBarW
    if showTimeGaps then
        totalBarW = graphWidth / daysToDisplay
    else
        totalBarW = graphWidth / math.max(1, #validPoints)
    end
    
    local barW       = totalBarW * 0.80
    local barGap     = totalBarW * 0.20
    local priceRange = maxPrice - minPrice
    local displayMax = maxPrice * 1.10
    local fontSize   = math.max(6, math.min(9, floor(barW * 0.55)))

    for i, dp in ipairs(validPoints) do
        if i <= MAX_BARS then
            local bar   = self.bars[i]
            local label = self.barLabels[i]
            local dLbl  = self.dateLabels[i]
            local price = dp.price or 0

            local barH = (price / displayMax) * effectiveH
            if barH < 1 then barH = 1 end

            local t = (priceRange > 0) and ((price - minPrice) / priceRange) or 0
            local r, g, b = PriceColour(t)
            bar.bg:SetColorTexture(r, g, b, 0.85)

            local xOffset
            if showTimeGaps then
                local dayOffset = dp.day - minDay
                xOffset = dayOffset * totalBarW + barGap / 2
            else
                -- Reverse index so oldest reads left-to-right
                local seqIndex = #validPoints - i + 1
                xOffset = (seqIndex - 1) * totalBarW + barGap / 2
            end
            
            local xCenter = xOffset + barW / 2

            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", self.graphArea, "BOTTOMLEFT", xOffset, barBottom)
            bar:SetSize(barW, barH)
            bar.price = dp.price
            bar.date  = dp.date
            bar:Show()

            -- Dynamic stacked offsets for far-side placement
            local currentAboveY = barBottom + barH + 2
            local currentBelowY = barBottom - 2

            -- 1. Price Label is rendered closest to the bar
            if showLabels and barW >= 10 then
                label:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
                label:SetText(ShortPrice(price))
                label:SetWidth(barW + 2)
                label:ClearAllPoints()

                if labelPos == "above" then
                    label:SetPoint("BOTTOM", self.graphArea, "BOTTOMLEFT", xCenter, currentAboveY)
                    currentAboveY = currentAboveY + LABEL_H
                else
                    label:SetPoint("TOP", self.graphArea, "BOTTOMLEFT", xCenter, currentBelowY)
                    currentBelowY = currentBelowY - LABEL_H
                end
                label:Show()
            end

            -- 2. Date Label is rendered next (pushing it to the far side out)
            if showDate and barW >= 10 then
                dLbl:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
                local dStr = (dateFormat == "date") and date("%d/%m", dp.epoch) or date("%a", dp.epoch)
                dLbl:SetText(dStr)
                dLbl:SetWidth(barW + 2)
                dLbl:ClearAllPoints()

                if datePos == "above" then
                    dLbl:SetPoint("BOTTOM", self.graphArea, "BOTTOMLEFT", xCenter, currentAboveY)
                    currentAboveY = currentAboveY + LABEL_H
                else
                    dLbl:SetPoint("TOP", self.graphArea, "BOTTOMLEFT", xCenter, currentBelowY)
                    currentBelowY = currentBelowY - LABEL_H
                end
                dLbl:Show()
            end
        end
    end

    local currentPrice = history[1].minSeen
    if currentPrice and self.marketLine then
        local lineH = (currentPrice / displayMax) * effectiveH
        self.marketLine:ClearAllPoints()
        self.marketLine:SetPoint("BOTTOMLEFT", self.graphArea, "BOTTOMLEFT", 0, barBottom + lineH)
        self.marketLine:SetPoint("BOTTOMRIGHT", self.graphArea, "BOTTOMRIGHT", 0, barBottom + lineH)
        
        self.marketLineText:SetText("Current: " .. ShortPrice(currentPrice))
        self.marketLine:Show()
        self.marketLineText:Show()
    end
end

function Graphinator:UpdateGraph(itemID, itemName, itemLink)
    if (not itemName or itemName == "Unknown Item") and itemLink then
        if Auctionator and Auctionator.Utilities then
            itemName = Auctionator.Utilities.GetNameFromLink(itemLink) or "Loading..."
        end
    end

    self.lastItemID   = itemID
    self.lastItemName = itemName
    self.lastItemLink = itemLink

    if not self.panel or not self.panel:IsShown() then return end

    for _, bar   in ipairs(self.bars)       do bar:Hide() end
    for _, lbl   in ipairs(self.barLabels)  do lbl:Hide() end
    for _, dLbl  in ipairs(self.dateLabels) do dLbl:Hide() end
    if self.marketLine then self.marketLine:Hide() end
    if self.marketLineText then self.marketLineText:Hide() end
    
    self.statusFS:Show()
    self.itemNameFS:SetText(itemName or "")

    if not itemLink then
        self.statusFS:SetText("Select an item to view its history.")
        return
    end

    if not AuctionatorReady() then
        self.statusFS:SetText("Auctionator not ready.")
        return
    end

    Auctionator.Utilities.DBKeyFromLink(itemLink, function(dbKeys)
        if not self.panel or not self.panel:IsShown() then return end
        if self.lastItemLink ~= itemLink then return end 

        if not dbKeys or #dbKeys == 0 then
            self.statusFS:SetText("Could not resolve item key.")
            return
        end

        local history
        for _, key in ipairs(dbKeys) do
            local h = Auctionator.Database:GetPriceHistory(key)
            if h and #h > 0 then
                history = h
                break
            end
        end

        if not history or #history == 0 then
            self.statusFS:SetText("No historical data found.")
            return
        end

        self:DrawGraph(history)
    end)
end

-------------------------------------------------------------------------------
-- SETTINGS POPUP
-------------------------------------------------------------------------------

function Graphinator:OpenSettings()
    if self.settingsPopup then
        if self.settingsPopup:IsShown() then
            self.settingsPopup:Hide()
        else
            -- Sync all visual states
            self.settingsChkLabels:SetChecked(DBGet("showLabels", false))
            self.settingsRadioPriceAbove:SetChecked(DBGet("labelPosition", "above") == "above")
            self.settingsRadioPriceBelow:SetChecked(DBGet("labelPosition", "above") == "below")
            
            self.settingsChkDateLabels:SetChecked(DBGet("showDateLabels", false))
            self.settingsRadioDateAbove:SetChecked(DBGet("dateLabelPosition", "below") == "above")
            self.settingsRadioDateBelow:SetChecked(DBGet("dateLabelPosition", "below") == "below")
            self.settingsRadioFormatDate:SetChecked(DBGet("dateLabelFormat", "date") == "date")
            self.settingsRadioFormatDay:SetChecked(DBGet("dateLabelFormat", "date") == "day")
            
            self.settingsChkGaps:SetChecked(DBGet("showTimeGaps", true))
            self.settingsChkHover:SetChecked(DBGet("hoverBags", false))
            self.settingsSliderDays:SetValue(DBGet("daysToDisplay", 14))
            
            self.settingsPopup:Show()
        end
        return
    end

    local pop = CreateFrame("Frame", "GraphinatorSettings", self.panel, "BackdropTemplate")
    pop:SetSize(220, 260) -- Wider & Taller for new nested options
    pop:SetPoint("TOPRIGHT", self.panel, "TOPRIGHT", -4, -32)
    pop:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    pop:SetFrameStrata("HIGH")
    pop:SetFrameLevel(self.panel:GetFrameLevel() + 20)
    pop:SetToplevel(true)
    self.settingsPopup = pop

    local hdr = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOP", pop, "TOP", 0, -9)
    hdr:SetText("|cFFFFD700Settings|r")

    local div = pop:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(1, 0.82, 0, 0.35)
    div:SetPoint("TOPLEFT",  pop, "TOPLEFT",  8, -22)
    div:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -8, -22)
    div:SetHeight(1)

    --- 1. PRICE LABELS
    local chkPrice = CreateFrame("CheckButton", "GraphinatorChkPrice", pop, "UICheckButtonTemplate")
    chkPrice:SetSize(24, 24)
    chkPrice:SetPoint("TOPLEFT", pop, "TOPLEFT", 8, -26)
    chkPrice:SetChecked(DBGet("showLabels", false))
    _G[chkPrice:GetName().."Text"]:SetText("Price labels")
    chkPrice:SetScript("OnClick", function(btn) Graphinator.db.showLabels = btn:GetChecked(); Graphinator:Redraw() end)
    self.settingsChkLabels = chkPrice

    local rPriceAbove = CreateFrame("CheckButton", "GraphinatorRadPriceAbove", pop, "UIRadioButtonTemplate")
    rPriceAbove:SetSize(16, 16)
    rPriceAbove:SetPoint("LEFT", chkPrice, "RIGHT", 70, 0)
    rPriceAbove:SetChecked(DBGet("labelPosition", "above") == "above")
    _G[rPriceAbove:GetName().."Text"]:SetText("Up")
    self.settingsRadioPriceAbove = rPriceAbove

    local rPriceBelow = CreateFrame("CheckButton", "GraphinatorRadPriceBelow", pop, "UIRadioButtonTemplate")
    rPriceBelow:SetSize(16, 16)
    rPriceBelow:SetPoint("LEFT", rPriceAbove, "RIGHT", 35, 0)
    rPriceBelow:SetChecked(DBGet("labelPosition", "above") == "below")
    _G[rPriceBelow:GetName().."Text"]:SetText("Dn")
    self.settingsRadioPriceBelow = rPriceBelow

    rPriceAbove:SetScript("OnClick", function() Graphinator.db.labelPosition = "above"; rPriceAbove:SetChecked(true); rPriceBelow:SetChecked(false); Graphinator:Redraw() end)
    rPriceBelow:SetScript("OnClick", function() Graphinator.db.labelPosition = "below"; rPriceAbove:SetChecked(false); rPriceBelow:SetChecked(true); Graphinator:Redraw() end)

    --- 2. DATE LABELS
    local chkDate = CreateFrame("CheckButton", "GraphinatorChkDate", pop, "UICheckButtonTemplate")
    chkDate:SetSize(24, 24)
    chkDate:SetPoint("TOPLEFT", chkPrice, "BOTTOMLEFT", 0, -2)
    chkDate:SetChecked(DBGet("showDateLabels", false))
    _G[chkDate:GetName().."Text"]:SetText("Date labels")
    chkDate:SetScript("OnClick", function(btn) Graphinator.db.showDateLabels = btn:GetChecked(); Graphinator:Redraw() end)
    self.settingsChkDateLabels = chkDate

    local rDateAbove = CreateFrame("CheckButton", "GraphinatorRadDateAbove", pop, "UIRadioButtonTemplate")
    rDateAbove:SetSize(16, 16)
    rDateAbove:SetPoint("LEFT", chkDate, "RIGHT", 70, 0)
    rDateAbove:SetChecked(DBGet("dateLabelPosition", "below") == "above")
    _G[rDateAbove:GetName().."Text"]:SetText("Up")
    self.settingsRadioDateAbove = rDateAbove

    local rDateBelow = CreateFrame("CheckButton", "GraphinatorRadDateBelow", pop, "UIRadioButtonTemplate")
    rDateBelow:SetSize(16, 16)
    rDateBelow:SetPoint("LEFT", rDateAbove, "RIGHT", 35, 0)
    rDateBelow:SetChecked(DBGet("dateLabelPosition", "below") == "below")
    _G[rDateBelow:GetName().."Text"]:SetText("Dn")
    self.settingsRadioDateBelow = rDateBelow

    rDateAbove:SetScript("OnClick", function() Graphinator.db.dateLabelPosition = "above"; rDateAbove:SetChecked(true); rDateBelow:SetChecked(false); Graphinator:Redraw() end)
    rDateBelow:SetScript("OnClick", function() Graphinator.db.dateLabelPosition = "below"; rDateAbove:SetChecked(false); rDateBelow:SetChecked(true); Graphinator:Redraw() end)

    -- Date Format (Sub-menu visual)
    local lblFormat = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblFormat:SetPoint("TOPLEFT", chkDate, "BOTTOMLEFT", 28, 2)
    lblFormat:SetTextColor(0.8, 0.8, 0.8)
    lblFormat:SetText("Format:")

    local rFormatDate = CreateFrame("CheckButton", "GraphinatorRadFormatDate", pop, "UIRadioButtonTemplate")
    rFormatDate:SetSize(16, 16)
    rFormatDate:SetPoint("LEFT", lblFormat, "RIGHT", 10, 0)
    rFormatDate:SetChecked(DBGet("dateLabelFormat", "date") == "date")
    _G[rFormatDate:GetName().."Text"]:SetText("26/02")
    self.settingsRadioFormatDate = rFormatDate

    local rFormatDay = CreateFrame("CheckButton", "GraphinatorRadFormatDay", pop, "UIRadioButtonTemplate")
    rFormatDay:SetSize(16, 16)
    rFormatDay:SetPoint("LEFT", rFormatDate, "RIGHT", 50, 0)
    rFormatDay:SetChecked(DBGet("dateLabelFormat", "date") == "day")
    _G[rFormatDay:GetName().."Text"]:SetText("Thu")
    self.settingsRadioFormatDay = rFormatDay

    rFormatDate:SetScript("OnClick", function() Graphinator.db.dateLabelFormat = "date"; rFormatDate:SetChecked(true); rFormatDay:SetChecked(false); Graphinator:Redraw() end)
    rFormatDay:SetScript("OnClick", function() Graphinator.db.dateLabelFormat = "day"; rFormatDate:SetChecked(false); rFormatDay:SetChecked(true); Graphinator:Redraw() end)

    --- 3. TIME GAPS
    local chkGaps = CreateFrame("CheckButton", "GraphinatorChkGaps", pop, "UICheckButtonTemplate")
    chkGaps:SetSize(24, 24)
    chkGaps:SetPoint("TOPLEFT", lblFormat, "BOTTOMLEFT", -28, -6)
    chkGaps:SetChecked(DBGet("showTimeGaps", true))
    _G[chkGaps:GetName().."Text"]:SetText("Show chronological gaps")
    chkGaps:SetScript("OnClick", function(btn) Graphinator.db.showTimeGaps = btn:GetChecked(); Graphinator:Redraw() end)
    self.settingsChkGaps = chkGaps

    --- 4. HOVER UPDATE
    local chkHover = CreateFrame("CheckButton", "GraphinatorChkHover", pop, "UICheckButtonTemplate")
    chkHover:SetSize(24, 24)
    chkHover:SetPoint("TOPLEFT", chkGaps, "BOTTOMLEFT", 0, -2)
    chkHover:SetChecked(DBGet("hoverBags", false))
    _G[chkHover:GetName().."Text"]:SetText("Update on bag hover")
    chkHover:SetScript("OnClick", function(btn) Graphinator.db.hoverBags = btn:GetChecked() end)
    self.settingsChkHover = chkHover

    --- 5. DAYS SLIDER
    local slider = CreateFrame("Slider", "GraphinatorSliderDays", pop, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", chkHover, "BOTTOMLEFT", 12, -18)
    slider:SetWidth(180)
    slider:SetMinMaxValues(3, 60)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(DBGet("daysToDisplay", 14))
    
    _G[slider:GetName().."Low"]:SetText("3")
    _G[slider:GetName().."High"]:SetText("60")
    _G[slider:GetName().."Text"]:SetText("Days to show: " .. slider:GetValue())
    
    slider:SetScript("OnValueChanged", function(self_slider, value)
        local val = math.floor(value)
        Graphinator.db.daysToDisplay = val
        _G[self_slider:GetName().."Text"]:SetText("Days to show: " .. val)
        Graphinator:Redraw()
    end)
    self.settingsSliderDays = slider

    pop:Show()
end

-------------------------------------------------------------------------------
-- UI CONSTRUCTION
-------------------------------------------------------------------------------

function Graphinator:BuildUI()
    if self.panel then return end

    local savedW = math.max(MIN_W, DBGet("panelWidth",  DEFAULT_W))
    local savedH = math.max(MIN_H, DBGet("panelHeight", DEFAULT_H))

    local panel = CreateFrame("Frame", "GraphinatorPanel", UIParent, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 4, -68)
    panel:SetSize(savedW, savedH)
    panel:EnableMouse(true)
    panel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetFrameStrata("MEDIUM")
    panel:SetFrameLevel(8)
    panel:SetResizable(true)
    if panel.SetResizeBounds then panel:SetResizeBounds(MIN_W, MIN_H)
    elseif panel.SetMinResize then panel:SetMinResize(MIN_W, MIN_H) end
    panel:Hide()
    self.panel = panel

    local tab = CreateFrame("Button", "GraphinatorTab", AuctionFrame, "UIPanelButtonTemplate")
    tab:SetSize(20, 60)
    tab:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 4, -100)
    tab:SetText(self.isPanelVisible and "<" or ">")
    tab:SetFrameStrata("MEDIUM")
    tab:SetFrameLevel(panel:GetFrameLevel() + 2)
    tab:SetScript("OnClick", function() Graphinator:TogglePanel() end)
    tab:SetScript("OnEnter", function(self_btn)
        GameTooltip:SetOwner(self_btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Graphinator", 1, 0.82, 0)
        GameTooltip:AddLine("Toggle price history panel", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tab:Hide()
    self.tabButton = tab

    local titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOP", panel, "TOP", -10, -12)
    titleFS:SetText("|cFFFFD700Price History|r")
    self.titleFS = titleFS

    local settingsBtn = CreateFrame("Button", "GraphinatorSettingsBtn", panel)
    settingsBtn:SetSize(18, 18)
    settingsBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -10)
    settingsBtn:SetFrameLevel(panel:GetFrameLevel() + 3)

    local settingsTex = settingsBtn:CreateTexture(nil, "ARTWORK")
    settingsTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    settingsTex:SetAllPoints()
    settingsTex:SetVertexColor(0.8, 0.8, 0.8)
    settingsBtn.tex = settingsTex

    settingsBtn:SetScript("OnMouseDown", function(self_btn) self_btn.tex:SetPoint("TOPLEFT", 1, -1) end)
    settingsBtn:SetScript("OnMouseUp", function(self_btn) self_btn.tex:SetPoint("TOPLEFT", 0, 0) end)
    settingsBtn:SetScript("OnClick", function() Graphinator:OpenSettings() end)
    settingsBtn:SetScript("OnEnter", function(self_btn)
        self_btn.tex:SetVertexColor(1, 1, 1)
        GameTooltip:SetOwner(self_btn, "ANCHOR_LEFT")
        GameTooltip:AddLine("Settings", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function(self_btn) self_btn.tex:SetVertexColor(0.8, 0.8, 0.8); GameTooltip:Hide() end)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.30)
    divider:SetPoint("TOPLEFT",  panel, "TOPLEFT",  10, -28)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -28)
    divider:SetHeight(1)

    local itemNameFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemNameFS:SetPoint("TOP", divider, "BOTTOM", 0, -4)
    itemNameFS:SetWidth(savedW - 20)
    itemNameFS:SetJustifyH("CENTER")
    self.itemNameFS = itemNameFS

    local statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusFS:SetPoint("CENTER", panel)
    statusFS:SetText("Select an item to view its history.")
    self.statusFS = statusFS

    local graphArea = CreateFrame("Frame", nil, panel)
    graphArea:SetPoint("TOPLEFT",     panel, "TOPLEFT",     10, -50)
    graphArea:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10,  10)
    self.graphArea = graphArea

    local marketLine = graphArea:CreateTexture(nil, "OVERLAY")
    marketLine:SetColorTexture(0, 0.8, 1, 0.5)
    marketLine:SetHeight(1)
    marketLine:Hide()
    self.marketLine = marketLine
    
    local marketLineText = graphArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    marketLineText:SetPoint("BOTTOMRIGHT", marketLine, "TOPRIGHT", 0, 2)
    marketLineText:SetTextColor(0, 0.8, 1)
    marketLineText:Hide()
    self.marketLineText = marketLineText

    local resizeBtn = CreateFrame("Button", nil, panel)
    resizeBtn:SetSize(16, 16)
    resizeBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 2)
    resizeBtn:SetFrameLevel(panel:GetFrameLevel() + 10)

    local resizeTex = resizeBtn:CreateTexture(nil, "OVERLAY")
    resizeTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeTex:SetAllPoints()
    resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

    resizeBtn:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOMRIGHT") end)
    resizeBtn:SetScript("OnMouseUp", function()
        panel:StopMovingOrSizing()
        Graphinator.db.panelWidth  = floor(panel:GetWidth())
        Graphinator.db.panelHeight = floor(panel:GetHeight())
        Graphinator.itemNameFS:SetWidth(floor(panel:GetWidth()) - 20)
        Graphinator:Redraw()
    end)

    local resizeTimer
    panel:SetScript("OnSizeChanged", function()
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.05, function() Graphinator:Redraw() end)
    end)

    self.bars       = {}
    self.barLabels  = {}
    self.dateLabels = {}

    for i = 1, MAX_BARS do
        local bar = CreateFrame("Button", nil, graphArea)
        bar:SetFrameLevel(graphArea:GetFrameLevel() + 1)

        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        bg:SetColorTexture(1, 0.84, 0, 0.85)
        bar.bg = bg

        local hi = bar:CreateTexture(nil, "HIGHLIGHT")
        hi:SetAllPoints(true)
        hi:SetColorTexture(1, 1, 1, 0.15)
        bar:SetHighlightTexture(hi)

        bar:SetScript("OnClick", function()
            if self.lastItemName then
                if Auctionator and Auctionator.API and Auctionator.API.Search then
                    Auctionator.API.Search("Graphinator", self.lastItemName)
                elseif BrowseName and AuctionFrameBrowse_Search then
                    BrowseName:SetText(self.lastItemName)
                    AuctionFrameBrowse_Search()
                end
            end
        end)

        bar:SetScript("OnEnter", function(self_bar)
            SetCursor("BUY_CURSOR")
            if self_bar.price then
                GameTooltip:SetOwner(self_bar, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Historical Price", 1, 0.82, 0)
                if self_bar.date then GameTooltip:AddLine(self_bar.date, 0.7, 0.7, 0.7) end
                GameTooltip:AddLine(Graphinator:FormatGold(self_bar.price), 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        bar:SetScript("OnLeave", function() ResetCursor(); GameTooltip:Hide() end)
        bar:Hide()
        tinsert(self.bars, bar)

        local lbl = graphArea:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        lbl:SetTextColor(1, 1, 1, 0.9)
        lbl:SetJustifyH("CENTER")
        lbl:Hide()
        tinsert(self.barLabels, lbl)

        local dLbl = graphArea:CreateFontString(nil, "OVERLAY")
        dLbl:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        dLbl:SetTextColor(0.8, 0.8, 0.8, 0.9)
        dLbl:SetJustifyH("CENTER")
        dLbl:Hide()
        tinsert(self.dateLabels, dLbl)
    end
end

-------------------------------------------------------------------------------
-- AH HOOKS
-------------------------------------------------------------------------------

function Graphinator:HookAH()
    if self.isHooked then return end

    hooksecurefunc("AuctionFrameBrowse_Update", function()
        local i = 1
        while true do
            local button = _G["BrowseButton" .. i]
            if not button then break end
            if not button.graphinatorHooked then
                button:HookScript("OnClick", function(clickedButton)
                    local offset = FauxScrollFrame_GetOffset(BrowseScrollFrame) or 0
                    local index  = clickedButton:GetID() + offset
                    local name   = GetAuctionItemInfo("list", index)
                    if name then
                        local itemLink = GetAuctionItemLink("list", index)
                        if itemLink then Graphinator:UpdateGraph(nil, name, itemLink) end
                    end
                end)
                button.graphinatorHooked = true
            end
            i = i + 1
        end
    end)

    local busListener = {}
    busListener.ReceiveEvent = function(_, eventName, eventData)
        if Auctionator.Buying and Auctionator.Buying.Events and eventName == Auctionator.Buying.Events.ShowForShopping then
            local itemLink = eventData and eventData.entries and eventData.entries[1] and eventData.entries[1].itemLink
            if itemLink then
                local itemName = Auctionator.Utilities.GetNameFromLink(itemLink)
                Graphinator:UpdateGraph(nil, itemName, itemLink)
            end
            return
        end

        if Auctionator.Selling and Auctionator.Selling.Events then
            local isSellingEvent = false
            for _, sEvent in pairs(Auctionator.Selling.Events) do
                if eventName == sEvent then
                    isSellingEvent = true
                    break
                end
            end

            if isSellingEvent and eventData then
                local itemLink = nil
                if type(eventData) == "string" and eventData:match("item:%d+") then
                    itemLink = eventData
                elseif type(eventData) == "table" then
                    if type(eventData.itemLink) == "string" then itemLink = eventData.itemLink
                    elseif eventData.itemInfo and type(eventData.itemInfo.itemLink) == "string" then itemLink = eventData.itemInfo.itemLink end
                end

                if itemLink and Graphinator.lastItemLink ~= itemLink then
                    local itemName = Auctionator.Utilities.GetNameFromLink(itemLink)
                    Graphinator:UpdateGraph(nil, itemName, itemLink)
                end
            end
        end
    end

    if Auctionator and Auctionator.EventBus then
        Auctionator.EventBus:RegisterSource(busListener, "GraphinatorAuctionatorHook")
        local eventsToListen = {}
        if Auctionator.Buying and Auctionator.Buying.Events and Auctionator.Buying.Events.ShowForShopping then
            table.insert(eventsToListen, Auctionator.Buying.Events.ShowForShopping)
        end
        if Auctionator.Selling and Auctionator.Selling.Events then
            for _, eventName in pairs(Auctionator.Selling.Events) do table.insert(eventsToListen, eventName) end
        end
        if #eventsToListen > 0 then Auctionator.EventBus:Register(busListener, eventsToListen) end
    end

    self.isHooked = true
end

-------------------------------------------------------------------------------
-- TOOLTIP HOVER HOOK (Direct Method Interception)
-------------------------------------------------------------------------------

function Graphinator:HookTooltips()
    if self.tooltipsHooked then return end

    local function ProcessLink(link)
        if not link then return end
        if not DBGet("hoverBags", false) then return end
        if not Graphinator.panel or not Graphinator.panel:IsShown() then return end

        if (link:match("item:%d+") or link:match("battlepet:%d+")) and Graphinator.lastItemLink ~= link then
            local name = GetItemInfo(link) or "Unknown Item"
            if Auctionator and Auctionator.Utilities then
                name = Auctionator.Utilities.GetNameFromLink(link) or name
            end
            Graphinator:UpdateGraph(nil, name, link)
        end
    end

    hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
        local link = nil
        if C_Container and C_Container.GetContainerItemInfo then
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then link = info.hyperlink end
        elseif GetContainerItemLink then
            link = GetContainerItemLink(bag, slot)
        end
        ProcessLink(link)
    end)

    hooksecurefunc(GameTooltip, "SetHyperlink", function(self, link) ProcessLink(link) end)
    hooksecurefunc(GameTooltip, "SetInventoryItem", function(self, unit, slot)
        local link = GetInventoryItemLink(unit, slot)
        ProcessLink(link)
    end)

    self.tooltipsHooked = true
end

-------------------------------------------------------------------------------
-- EVENT HANDLER
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "GraphinatorEvents")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then

        if GraphinatorDB and type(GraphinatorDB) == "table" then
            Graphinator.db = GraphinatorDB
        else
            GraphinatorDB = {}
            Graphinator.db = GraphinatorDB
        end
        Graphinator.isPanelVisible = DBGet("isPanelVisible", true)
        Graphinator:SetupBlizzardOptions()
        Graphinator:HookTooltips()

    elseif event == "AUCTION_HOUSE_SHOW" then
        if not DBGet("addonEnabled", true) then return end

        C_Timer.After(0.2, function()
            Graphinator:BuildUI()
            Graphinator:HookAH()
            if Graphinator.isPanelVisible then
                Graphinator.panel:Show()
                Graphinator.tabButton:SetText("<")
            else
                Graphinator.panel:Hide()
                Graphinator.tabButton:SetText(">")
            end
            Graphinator.tabButton:Show()
            Graphinator:UpdateGraph(nil, nil, nil)
        end)

    elseif event == "AUCTION_HOUSE_CLOSED" then
        if Graphinator.panel      then Graphinator.panel:Hide()           end
        if Graphinator.tabButton  then Graphinator.tabButton:Hide()       end
        if Graphinator.settingsPopup then Graphinator.settingsPopup:Hide() end
        Graphinator.lastItemID   = nil
        Graphinator.lastItemName = nil
        Graphinator.lastItemLink = nil
        Graphinator.lastHistory  = nil
    end
end)

-------------------------------------------------------------------------------
-- BLIZZARD OPTIONS MENU
-------------------------------------------------------------------------------

function Graphinator:SetupBlizzardOptions()
    local categoryName = "Graphinator"
    local frame = CreateFrame("Frame", "GraphinatorOptionsFrame", UIParent)
    frame.name = categoryName

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(categoryName)

    local cb = CreateFrame("CheckButton", "GraphinatorEnableCheck", frame, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    _G[cb:GetName() .. "Text"]:SetText("Enable Graphinator functionality")
    
    cb:SetScript("OnShow", function(self) self:SetChecked(DBGet("addonEnabled", true)) end)
    cb:SetScript("OnClick", function(self)
        local isEnabled = self:GetChecked()
        Graphinator.db.addonEnabled = isEnabled
        if not isEnabled and Graphinator.panel then
            Graphinator.panel:Hide()
            Graphinator.tabButton:Hide()
        end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(frame, categoryName)
        Settings.RegisterAddOnCategory(category)
    else
        InterfaceOptions_AddCategory(frame)
    end
end