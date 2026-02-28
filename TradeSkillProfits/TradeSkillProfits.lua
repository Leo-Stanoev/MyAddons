--[[
    TradeSkillProfits
    Calculates and displays Auction House profit margins directly within the TradeSkill UI.
    Features custom sorting, favorites, filtering, and profession quick-switching.

    Requires: Auctionator
    Target Client: TBC Classic (2.5.5)
]]--

local ADDON_NAME = "TradeSkillProfits"
local CALLER_ID  = "TradeSkillProfits"

-- The maximum number of recipe buttons Blizzard creates in the default UI
local NUM_BUTTONS = TRADE_SKILLS_DISPLAYED or 27  

-- ============================================================================
-- Database & Configuration
-- ============================================================================

local DEFAULTS = {
    enableAddon      = true,
    showProfit       = true,
    showPercent      = true,
    colorize         = true,
    showSortButton   = true,
    favorites        = {},
    filtered         = {},  
    useCoins         = false, 
    showMinus        = true,  
    abbreviatePct    = true,
    
    -- Tooltip Settings
    showTooltip      = true,
    tooltipSeparator = true,
    tooltipTitle     = true,
    tooltipCost      = true,
    tooltipValue     = true,
    tooltipProfit    = true,
    tooltipOffset    = 0,
    
    -- UI Enhancements
    showProfTabs     = true,
    showEquipLevel   = true,
}

local function InitDB()
    TradeSkillProfits_DB = TradeSkillProfits_DB or {}
    for key, defaultValue in pairs(DEFAULTS) do
        if TradeSkillProfits_DB[key] == nil then
            if type(defaultValue) == "table" then
                TradeSkillProfits_DB[key] = {}
            else
                TradeSkillProfits_DB[key] = defaultValue
            end
        end
    end
end

-- Helper to quickly grab a setting value
local function Cfg(key) 
    return TradeSkillProfits_DB[key] 
end


-- ============================================================================
-- Pricing & Calculation Engine
-- ============================================================================

local AH_CUT = 0.95
local ProfitCache = {}

local function ClearCache()
    wipe(ProfitCache)
end

-- Safely request pricing data from Auctionator's API
local function GetAuctionPrice(link)
    if not Auctionator or not Auctionator.API or not link then return nil end
    local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, CALLER_ID, link)
    return ok and price or nil
end

local function GetVendorPrice(link)
    if not Auctionator or not Auctionator.API or not link then return nil end
    local ok, price = pcall(Auctionator.API.v1.GetVendorPriceByItemLink, CALLER_ID, link)
    return ok and price or nil
end

-- Calculates the total cost of all required reagents for a specific recipe
local function GetReagentsCost(recipeIndex)
    local total = 0
    local numReagents = GetTradeSkillNumReagents(recipeIndex) or 0
    
    for i = 1, numReagents do
        local _, _, qty = GetTradeSkillReagentInfo(recipeIndex, i)
        local link = GetTradeSkillReagentItemLink(recipeIndex, i)
        if qty and link then
            local price = GetVendorPrice(link) or GetAuctionPrice(link)
            if price then total = total + (qty * price) end
        end
    end
    return total
end

-- Returns profit, cost, and raw AH price. Uses a cache to prevent lag spikes while scrolling.
local function GetProfitAndCost(recipeIndex)
    local itemLink = GetTradeSkillItemLink(recipeIndex)
    local recipeName = GetTradeSkillInfo(recipeIndex)
    
    if not itemLink or not recipeName then return nil, nil, nil end

    -- Return cached calculation if it exists
    if ProfitCache[recipeName] then
        return ProfitCache[recipeName].profit, ProfitCache[recipeName].cost, ProfitCache[recipeName].ahPrice
    end

    local ahPrice = GetAuctionPrice(itemLink)
    if not ahPrice then return nil, nil, nil end
    
    -- Account for recipes that craft multiples (e.g., 5x arrows)
    local count = GetTradeSkillNumMade(recipeIndex)
    if not count or count == 0 then count = 1 end
    
    local cost = GetReagentsCost(recipeIndex)
    local profit = math.floor((ahPrice * count * AH_CUT) - cost)
    
    ProfitCache[recipeName] = { profit = profit, cost = cost, ahPrice = ahPrice }
    
    return profit, cost, ahPrice
end


-- ============================================================================
-- Formatting Utilities
-- ============================================================================

local function FormatMoney(copper)
    local absVal = math.abs(copper)
    local g = math.floor(absVal / 10000)
    local s = math.floor((absVal % 10000) / 100)
    local c = absVal % 100
    local parts = {}
    
    -- Swap between plain text and native Blizzard coin textures based on settings
    local gStr = Cfg("useCoins") and "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t" or "g"
    local sStr = Cfg("useCoins") and "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t" or "s"
    local cStr = Cfg("useCoins") and "|TInterface\\MoneyFrame\\UI-CopperIcon:0|t" or "c"

    if g > 0 then parts[#parts+1] = g .. gStr end
    if s > 0 then parts[#parts+1] = s .. sStr end
    if c > 0 or #parts == 0 then parts[#parts+1] = c .. cStr end
    
    local str = table.concat(parts, " ")
    
    if copper < 0 and Cfg("showMinus") then
        return "-" .. str
    end
    return str
end

local function WrapColor(text, profit)
    if not Cfg("colorize") then
        return WHITE_FONT_COLOR:WrapTextInColorCode(text)
    end
    return profit >= 0 and GREEN_FONT_COLOR:WrapTextInColorCode(text) or RED_FONT_COLOR:WrapTextInColorCode(text)
end

local function FormatProfit(profit, cost)
    local parts = {}

    if Cfg("showProfit") then
        parts[#parts+1] = WrapColor(FormatMoney(profit), profit)
    end

    if Cfg("showPercent") and cost and cost > 0 then
        local pct = math.floor(math.abs((profit / cost) * 100))
        local pctStr = tostring(pct)
        
        -- Compress wildly high margins caused by bad AH data
        if Cfg("abbreviatePct") then
            if pct >= 1000000 then
                pctStr = string.format("%.1fm", pct / 1000000)
            elseif pct >= 1000 then
                pctStr = string.format("%.1fk", pct / 1000)
            end
            pctStr = string.gsub(pctStr, "%.0([km])$", "%1") -- Strip trailing ".0"
        end

        parts[#parts+1] = WrapColor("(" .. pctStr .. "%)", profit)
    end

    return #parts > 0 and table.concat(parts, " ") or nil
end


-- ============================================================================
-- Tooltip Integration
-- ============================================================================

-- Extracts our custom lines and re-inserts them higher up in the tooltip
local function MoveTooltipLinesUp(tooltip, numLinesAdded, offsetUp)
    local totalLines = tooltip:NumLines()
    if offsetUp <= 0 or totalLines <= numLinesAdded then return end
    
    -- Prevent moving lines above the item name itself
    offsetUp = math.min(offsetUp, totalLines - numLinesAdded - 1)
    if offsetUp <= 0 then return end
    
    local startIndex = totalLines - numLinesAdded - offsetUp + 1
    local extracted = {}
    
    -- Capture text and color data for all lines involved in the swap
    for i = startIndex, totalLines do
        local left = _G[tooltip:GetName().."TextLeft"..i]
        local right = _G[tooltip:GetName().."TextRight"..i]
        
        table.insert(extracted, {
            leftText   = left and left:GetText() or "",
            rightText  = right and right:GetText() or "",
            rightShown = right and right:IsShown(),
            lr = left and select(1, left:GetTextColor()) or 1,
            lg = left and select(2, left:GetTextColor()) or 1,
            lb = left and select(3, left:GetTextColor()) or 1,
            rr = right and select(1, right:GetTextColor()) or 1,
            rg = right and select(2, right:GetTextColor()) or 1,
            rb = right and select(3, right:GetTextColor()) or 1,
        })
    end
    
    -- Shift the array
    local rearranged = {}
    for i = offsetUp + 1, #extracted do table.insert(rearranged, extracted[i]) end
    for i = 1, offsetUp do table.insert(rearranged, extracted[i]) end
    
    -- Reapply the shifted data back to the tooltip elements
    for i = 1, #rearranged do
        local lineIdx = startIndex + i - 1
        local data = rearranged[i]
        local left = _G[tooltip:GetName().."TextLeft"..lineIdx]
        local right = _G[tooltip:GetName().."TextRight"..lineIdx]
        
        if left then
            left:SetText(data.leftText)
            left:SetTextColor(data.lr, data.lg, data.lb)
        end
        if right then
            right:SetText(data.rightText)
            right:SetTextColor(data.rr, data.rg, data.rb)
            if data.rightShown then right:Show() else right:Hide() end
        end
    end
end

hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(self, recipeIndex, reagentIndex)
    if not Cfg("enableAddon") or not Cfg("showTooltip") then return end
    
    -- Ignore material hovers at the bottom of the craft window
    if not recipeIndex or reagentIndex then return end

    local profit, cost, ahPrice = GetProfitAndCost(recipeIndex)
    if profit and cost and ahPrice then
        local linesAdded = 0
        
        if Cfg("tooltipSeparator") then 
            self:AddLine(" ") 
            linesAdded = linesAdded + 1
        end
        
        if Cfg("tooltipTitle") then 
            self:AddLine("TradeSkill Profits", 1, 0.82, 0) 
            linesAdded = linesAdded + 1
        end
        
        if Cfg("tooltipCost") then
            self:AddDoubleLine("Crafting Cost", FormatMoney(cost), 1, 0.82, 0, 1, 1, 1)
            linesAdded = linesAdded + 1
        end
        
        if Cfg("tooltipValue") then
            local count = GetTradeSkillNumMade(recipeIndex)
            local countStr = (count and count > 1) and (" (x"..count..")") or ""
            self:AddDoubleLine("AH Value"..countStr, FormatMoney(ahPrice * (count or 1)), 1, 0.82, 0, 1, 1, 1)
            linesAdded = linesAdded + 1
        end
        
        if Cfg("tooltipProfit") then
            local r, g, b = 1, 1, 1
            if Cfg("colorize") then
                if profit >= 0 then r, g, b = 0.1, 1, 0.1 else r, g, b = 1, 0.1, 0.1 end
            end
            self:AddDoubleLine("Total Profit", FormatMoney(profit), 1, 0.82, 0, r, g, b)
            linesAdded = linesAdded + 1
        end
        
        local offset = Cfg("tooltipOffset") or 0
        if offset > 0 and linesAdded > 0 then
            MoveTooltipLinesUp(self, linesAdded, offset)
        end
        
        self:Show()
    end
end)


-- ============================================================================
-- UI Components: Profession Tabs
-- ============================================================================

local function UpdateProfessionTabs()
    if not TradeSkillFrame then return end

    local index = 1
    if not Cfg("showProfTabs") then
        while _G["TSPProfTab"..index] do
            _G["TSPProfTab"..index]:Hide()
            index = index + 1
        end
        return
    end

    -- Core crafting professions using localized spell IDs
    local PROF_SPELLS = {
        (GetSpellInfo(2259)),  -- Alchemy
        (GetSpellInfo(2018)),  -- Blacksmithing
        (GetSpellInfo(7411)),  -- Enchanting
        (GetSpellInfo(4036)),  -- Engineering
        (GetSpellInfo(25229)), -- Jewelcrafting
        (GetSpellInfo(2149)),  -- Leatherworking
        (GetSpellInfo(3908)),  -- Tailoring
        (GetSpellInfo(2656)),  -- Smelting (Mining)
        (GetSpellInfo(2550)),  -- Cooking
        (GetSpellInfo(3273)),  -- First Aid
    }

    -- Scan the player's spellbook to find known professions
    local knownProfs = {}
    for i = 1, GetNumSpellTabs() do
        local _, _, offset, numSpells = GetSpellTabInfo(i)
        for j = 1, numSpells do
            local spellName = GetSpellBookItemName(offset + j, BOOKTYPE_SPELL)
            for _, profName in ipairs(PROF_SPELLS) do
                if spellName == profName then
                    local icon = GetSpellTexture(offset + j, BOOKTYPE_SPELL)
                    table.insert(knownProfs, {name = spellName, icon = icon})
                end
            end
        end
    end

    -- Create and anchor tabs to the right side of the TradeSkill frame
    for i, data in ipairs(knownProfs) do
        local tab = _G["TSPProfTab"..i]
        if not tab then
            tab = CreateFrame("Button", "TSPProfTab"..i, TradeSkillFrame, "SpellBookSkillLineTabTemplate")
            tab:SetScript("OnClick", function() CastSpellByName(data.name) end)
            tab:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(data.name)
                GameTooltip:Show()
            end)
            tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        tab:SetNormalTexture(data.icon)
        tab:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", -32, -100 - ((i-1) * 44))
        tab:Show()
    end

    -- Hide unused tabs if professions were dropped
    index = #knownProfs + 1
    while _G["TSPProfTab"..index] do
        _G["TSPProfTab"..index]:Hide()
        index = index + 1
    end
end


-- ============================================================================
-- List Data & Sorting Engine
-- ============================================================================

local isSortedByProfit    = false
local sortedList          = nil
local isFavoritesExpanded = true
local isFilteredExpanded  = false
local currentSortMode     = "Profit"  
local isSortDescending    = true

-- Builds a virtual list of recipes, separating favorites and filters, and applying the current sort metric
local function BuildSortedList()
    local total = GetNumTradeSkills() or 0
    if total == 0 then return end

    local list      = {}
    local favorites = {}
    local filtered  = {}
    local others    = {}

    TradeSkillProfits_DB.favorites = TradeSkillProfits_DB.favorites or {}
    TradeSkillProfits_DB.filtered  = TradeSkillProfits_DB.filtered or {}
    local favs = TradeSkillProfits_DB.favorites
    local flts = TradeSkillProfits_DB.filtered

    for i = 1, total do
        local ok, err = pcall(function()
            local name, typeInfo = GetTradeSkillInfo(i)
            if typeInfo ~= "header" and name then
                local profit, cost = GetProfitAndCost(i)
                local entry = { index = i, name = name, profit = profit, cost = cost, isHeader = false }
                
                if favs[name] then
                    table.insert(favorites, entry)
                elseif flts[name] then
                    table.insert(filtered, entry)
                else
                    table.insert(others, entry)
                end
            end
        end)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444TradeSkillProfits:|r BuildSortedList error at index " .. i .. ": " .. tostring(err))
        end
    end

    local sortFn = function(a, b)
        local nameA = tostring(a.name or "")
        local nameB = tostring(b.name or "")
        
        local valA, valB
        if currentSortMode == "Cost" then
            valA, valB = a.cost, b.cost
        else
            valA, valB = a.profit, b.profit
        end

        -- Fallbacks for unpriced items
        if valA == nil and valB == nil then return nameA < nameB end
        if valA == nil then return false end
        if valB == nil then return true  end
        if valA == valB  then return nameA < nameB end
        
        -- Safely handle the sorting direction
        if isSortDescending then
            return valA > valB
        else
            return valA < valB
        end
    end

    pcall(table.sort, favorites, sortFn)
    pcall(table.sort, others,    sortFn)
    pcall(table.sort, filtered,  sortFn)

    -- 1. Assemble Favorites Block
    if #favorites > 0 then
        table.insert(list, { name = "Favorites", isHeader = true })
        if isFavoritesExpanded then
            for _, v in ipairs(favorites) do table.insert(list, v) end
            table.insert(list, { name = "  --------------------------------------", isDivider = true })
        end
    end

    -- 2. Assemble Normal Recipes
    for _, v in ipairs(others) do table.insert(list, v) end

    -- 3. Assemble Filtered Block
    if #filtered > 0 then
        if #others > 0 or (#favorites > 0 and isFavoritesExpanded) then
            table.insert(list, { name = "  --------------------------------------", isDivider = true })
        end
        table.insert(list, { name = "Filtered", isHeader = true })
        if isFilteredExpanded then
            for _, v in ipairs(filtered) do table.insert(list, v) end
        end
    end

    sortedList = list
end

local function ToggleState(recipeName, isFilterAction)
    if not recipeName then return end
    TradeSkillProfits_DB.favorites = TradeSkillProfits_DB.favorites or {}
    TradeSkillProfits_DB.filtered  = TradeSkillProfits_DB.filtered or {}

    if isFilterAction then
        if TradeSkillProfits_DB.filtered[recipeName] then
            TradeSkillProfits_DB.filtered[recipeName] = nil
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TradeSkillProfits:|r Removed " .. recipeName .. " from Filtered.")
        else
            TradeSkillProfits_DB.filtered[recipeName] = true
            TradeSkillProfits_DB.favorites[recipeName] = nil -- Enforce mutual exclusion
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TradeSkillProfits:|r Added " .. recipeName .. " to Filtered.")
        end
    else
        if TradeSkillProfits_DB.favorites[recipeName] then
            TradeSkillProfits_DB.favorites[recipeName] = nil
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TradeSkillProfits:|r Removed " .. recipeName .. " from Favorites.")
        else
            TradeSkillProfits_DB.favorites[recipeName] = true
            TradeSkillProfits_DB.filtered[recipeName] = nil -- Enforce mutual exclusion
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TradeSkillProfits:|r Added " .. recipeName .. " to Favorites.")
        end
    end

    if isSortedByProfit then
        BuildSortedList()
        -- PaintOverlay is defined lower down, called dynamically
        if TSPOverlayFrame and TSPOverlayFrame:IsShown() then TradeSkillFrame_Update() end
    else
        if TradeSkillFrame_Update then TradeSkillFrame_Update() end
    end
end


-- ============================================================================
-- UI Components: Custom List Overlay & Default Hooks
-- ============================================================================

local overlayFrame   = nil
local overlayScroll  = nil
local overlayButtons = {}
local selectedRecipe = nil

local profitLabels = {}
local levelLabels  = {}

-- Helpers to inject text strings into the standard Blizzard list
local function GetOrCreateLabel(button)
    if not profitLabels[button] then
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("RIGHT")
        profitLabels[button] = fs
    end
    return profitLabels[button]
end

local function GetOrCreateLevelLabel(button, textObj)
    if not levelLabels[button] then
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("RIGHT", textObj, "LEFT", -2, 0)
        levelLabels[button] = fs
    end
    return levelLabels[button]
end

local function RefreshLabels()
    if not TradeSkillFrame or not TradeSkillFrame:IsShown() then return end
    if not Cfg("enableAddon") then
        for _, label in pairs(profitLabels) do label:Hide() end
        for _, label in pairs(levelLabels)  do label:Hide() end
        return
    end

    TradeSkillProfits_DB.favorites = TradeSkillProfits_DB.favorites or {}
    TradeSkillProfits_DB.filtered  = TradeSkillProfits_DB.filtered or {}

    for i = 1, NUM_BUTTONS do
        local button = _G["TradeSkillSkill"..i]
        if not button then break end
        
        local label = GetOrCreateLabel(button)
        label:ClearAllPoints()
        label:SetPoint("RIGHT", button, "LEFT", 295, 0)

        local showAny = Cfg("showProfit") or Cfg("showPercent")

        if not button:IsShown() then
            label:Hide()
            if levelLabels[button] then levelLabels[button]:Hide() end
        else
            local idx = button:GetID()
            if idx and idx > 0 then
                local name, typeInfo = GetTradeSkillInfo(idx)
                local textObj = _G["TradeSkillSkill"..i.."Text"]
                
                local lvlLabel = nil
                if textObj then
                    lvlLabel = GetOrCreateLevelLabel(button, textObj)
                    lvlLabel:Hide()
                end

                if typeInfo ~= "header" and name then
                    if textObj then
                        local currentText = textObj:GetText() or ""
                        currentText = string.gsub(currentText, "|TInterface.-|t %s?", "")
                        
                        local prefix = ""
                        if TradeSkillProfits_DB.favorites[name] then
                            prefix = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t "
                        elseif TradeSkillProfits_DB.filtered[name] then
                            prefix = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:12|t "
                        end

                        textObj:SetText(prefix .. currentText)
                        
                        if Cfg("showEquipLevel") and lvlLabel then
                            local itemLink = GetTradeSkillItemLink(idx)
                            if itemLink then
                                local _, _, _, _, itemMinLevel = GetItemInfo(itemLink)
                                if itemMinLevel and itemMinLevel > 1 then
                                    lvlLabel:SetText("|cffaaaaaa"..itemMinLevel.."|r")
                                    lvlLabel:Show()
                                end
                            end
                        end
                    end
                end

                if typeInfo == "header" or not showAny then
                    label:SetText("")
                    label:Hide()
                    if lvlLabel then lvlLabel:Hide() end
                else
                    label:Show()
                    local ok, profit, cost = pcall(GetProfitAndCost, idx)
                    if ok and profit ~= nil then
                        label:SetText(FormatProfit(profit, cost))
                    else
                        label:SetText(GRAY_FONT_COLOR:WrapTextInColorCode("—"))
                    end
                end
            else
                label:SetText("")
                label:Hide()
                if levelLabels[button] then levelLabels[button]:Hide() end
            end
        end
    end
end

local function GetVisibleCount()
    local count = 0
    for i = 1, 50 do
        if _G["TradeSkillSkill"..i] then
            count = i
        else
            break
        end
    end
    return math.max(1, count)
end

-- Renders the sorted virtual list using our custom overlay frame
local function PaintOverlay()
    if not sortedList or not overlayScroll then return end
    TradeSkillHighlightFrame:Hide()

    local total        = #sortedList
    local visibleCount = GetVisibleCount()
    local offset       = FauxScrollFrame_GetOffset(overlayScroll)
    local showAny      = Cfg("showProfit") or Cfg("showPercent")

    local realBtnHeight = 16
    if _G["TradeSkillSkill1"] then
        realBtnHeight = math.floor(_G["TradeSkillSkill1"]:GetHeight() + 0.5)
    end

    FauxScrollFrame_Update(overlayScroll, total, visibleCount, realBtnHeight)

    for i = 1, NUM_BUTTONS do
        local btn   = overlayButtons[i]
        local entry = sortedList[offset + i]

        if entry and i <= visibleCount then
            btn.recipeIndex = entry.index
            btn.recipeName  = entry.name
            btn.isHeader    = entry.isHeader
            btn.isDivider   = entry.isDivider

            btn.profitText:SetPoint("RIGHT", btn, "LEFT", 295, 0)
            btn.nameText:SetPoint("RIGHT", btn, "RIGHT", -87, 0)
            btn.levelText:SetText("")

            if entry.isDivider then
                btn.nameText:SetText(entry.name)
                btn.nameText:SetTextColor(0.4, 0.4, 0.4)
                btn.nameText._r, btn.nameText._g, btn.nameText._b = 0.4, 0.4, 0.4
                btn.nameText:SetPoint("LEFT", btn, "LEFT", 24, 0)
                btn.profitText:SetText("")
                btn.bg:SetColorTexture(0, 0, 0, 0)
                btn.expandIcon:Hide()
                
            elseif entry.isHeader then
                btn.nameText:SetText(entry.name)
                btn.nameText:SetTextColor(1, 0.82, 0)
                btn.nameText._r, btn.nameText._g, btn.nameText._b = 1, 0.82, 0
                btn.nameText:SetPoint("LEFT", btn, "LEFT", 24, 0)
                btn.profitText:SetText("")
                btn.bg:SetColorTexture(0, 0, 0, 0)
                
                btn.expandIcon:Show()
                local isExpanded = (entry.name == "Favorites" and isFavoritesExpanded) or (entry.name == "Filtered" and isFilteredExpanded)
                if isExpanded then
                    btn.expandIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
                else
                    btn.expandIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
                end
                
            else
                btn.bg:SetColorTexture(0, 0, 0, 0)
                btn.expandIcon:Hide()
                btn.nameText:SetPoint("LEFT", btn, "LEFT", 24, 0)
                
                local _, typeInfo = GetTradeSkillInfo(entry.index)
                local color = TradeSkillTypeColor[typeInfo]
                local r, g, b = 1, 1, 1
                if color then r, g, b = color.r, color.g, color.b end

                local prefix = ""
                if TradeSkillProfits_DB.favorites[entry.name] then
                    prefix = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t "
                elseif TradeSkillProfits_DB.filtered[entry.name] then
                    prefix = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:12|t "
                end

                if Cfg("showEquipLevel") then
                    local itemLink = GetTradeSkillItemLink(entry.index)
                    if itemLink then
                        local _, _, _, _, itemMinLevel = GetItemInfo(itemLink)
                        if itemMinLevel and itemMinLevel > 1 then
                            btn.levelText:SetText("|cffaaaaaa"..itemMinLevel.."|r")
                        end
                    end
                end

                btn.nameText:SetText(prefix .. (entry.name or ""))
                btn.nameText:SetTextColor(r, g, b)
                btn.nameText._r, btn.nameText._g, btn.nameText._b = r, g, b

                if showAny and entry.profit ~= nil then
                    btn.profitText:SetText(FormatProfit(entry.profit, entry.cost))
                elseif showAny then
                    btn.profitText:SetText(GRAY_FONT_COLOR:WrapTextInColorCode("—"))
                else
                    btn.profitText:SetText("")
                end
                
                -- Hijack Blizzard's native highlight texture
                if entry.index == selectedRecipe then
                    TradeSkillHighlightFrame:ClearAllPoints()
                    TradeSkillHighlightFrame:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
                    TradeSkillHighlightFrame:Show()
                end
            end
            btn:Show()
        else
            btn.recipeIndex = nil
            btn.recipeName  = nil
            btn.isHeader    = false
            btn.isDivider   = false
            btn.nameText:SetText("")
            btn.profitText:SetText("")
            btn.levelText:SetText("")
            btn:Hide()
            btn.bg:SetColorTexture(0, 0, 0, 0)
        end
    end
end

local function CreateOverlayFrame()
    if overlayFrame then return end

    -- Overlay Frame acts as a skin that perfectly covers the Blizzard list
    overlayFrame = CreateFrame("Frame", "TSPOverlayFrame", TradeSkillFrame)
    overlayFrame:SetAllPoints(TradeSkillListScrollFrame)
    overlayFrame:SetFrameStrata("MEDIUM")
    overlayFrame:SetFrameLevel(TradeSkillListScrollFrame:GetFrameLevel() + 10)
    overlayFrame:Hide()

    overlayScroll = CreateFrame("ScrollFrame", "TSPOverlayScroll", overlayFrame, "FauxScrollFrameTemplate")
    overlayScroll:SetAllPoints(overlayFrame)

    local realBtnHeight = 16
    if _G["TradeSkillSkill1"] then
        realBtnHeight = math.floor(_G["TradeSkillSkill1"]:GetHeight() + 0.5)
    end

    overlayScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, realBtnHeight, PaintOverlay)
    end)

    local refFont, refSize, refFlags
    local refText = _G["TradeSkillSkill1Text"]
    if refText then
        refFont, refSize, refFlags = refText:GetFont()
    end

    for i = 1, NUM_BUTTONS do
        local btn = CreateFrame("Button", "TSPBtn"..i, overlayFrame)
        
        -- Glue directly to the Blizzard buttons to inherit exact scaling and layout
        local refBtn = _G["TradeSkillSkill"..i]
        if refBtn then
            btn:SetAllPoints(refBtn)
        else
            btn:SetHeight(realBtnHeight)
            btn:SetPoint("TOPLEFT", overlayButtons[i-1], "BOTTOMLEFT", 0, 0)
            btn:SetPoint("RIGHT", overlayFrame, "RIGHT", -27, 0)
        end

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(btn)
        bg:SetColorTexture(0, 0, 0, 0)
        btn.bg = bg

        local expandIcon = btn:CreateTexture(nil, "ARTWORK")
        expandIcon:SetSize(14, 14)
        expandIcon:SetPoint("LEFT", btn, "LEFT", 5, 0)
        btn.expandIcon = expandIcon

        local nameText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", btn, "LEFT", 24, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        btn.nameText = nameText

        local levelText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        levelText:SetPoint("RIGHT", nameText, "LEFT", -4, 0)
        levelText:SetJustifyH("RIGHT")
        btn.levelText = levelText

        local profitText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        profitText:SetJustifyH("RIGHT")
        btn.profitText = profitText

        if refFont then
            nameText:SetFont(refFont, refSize, refFlags)
            profitText:SetFont(refFont, refSize, refFlags)
            levelText:SetFont(refFont, refSize, refFlags)
        end

        btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        btn:EnableMouse(true)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Text shifting to mimic native Blizzard click physics
        btn:SetScript("OnMouseDown", function(self)
            if self.isHeader or self.isDivider then return end
            self.nameText:SetPoint( "LEFT",  self, "LEFT",  25, -1)
            self.profitText:SetPoint("RIGHT", self, "LEFT", 296, -1)
        end)
        btn:SetScript("OnMouseUp", function(self)
            if self.isHeader or self.isDivider then return end
            self.nameText:SetPoint( "LEFT",  self, "LEFT",  24, 0)
            self.profitText:SetPoint("RIGHT", self, "LEFT", 295, 0)
        end)

        btn:SetScript("OnClick", function(self, button)
            if self.isHeader or self.isDivider then 
                if self.isHeader and self.recipeName == "Favorites" then
                    isFavoritesExpanded = not isFavoritesExpanded
                elseif self.isHeader and self.recipeName == "Filtered" then
                    isFilteredExpanded = not isFilteredExpanded
                end
                if self.isHeader then
                    BuildSortedList()
                    PaintOverlay()
                end
                return 
            end

            -- Allow linking to chat / searching Auctionator
            if IsModifiedClick() and self.recipeIndex then
                local link = GetTradeSkillItemLink(self.recipeIndex) or GetTradeSkillRecipeLink(self.recipeIndex)
                if link and HandleModifiedItemClick(link) then return end
            end
            
            if button == "RightButton" then
                ToggleState(self.recipeName, IsShiftKeyDown()) 
            else
                if self.recipeIndex then
                    selectedRecipe = self.recipeIndex
                    TradeSkillFrame_SetSelection(self.recipeIndex)
                    TradeSkillHighlightFrame:Hide()
                    PaintOverlay()
                end
            end
        end)
        
        btn:SetScript("OnEnter", function(self)
            if not self.isDivider then self.nameText:SetTextColor(1, 1, 1) end
            if self.recipeIndex then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetTradeSkillItem(self.recipeIndex)
                CursorUpdate(self)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            local r = self.nameText._r
            if r then self.nameText:SetTextColor(r, self.nameText._g, self.nameText._b) end
            GameTooltip:Hide()
            ResetCursor()
        end)

        overlayButtons[i] = btn
    end
end

local function SetBlizzardButtonsShown(shown)
    for i = 1, NUM_BUTTONS do
        local b = _G["TradeSkillSkill"..i]
        if b then b:SetShown(shown) end
        if profitLabels[b] then profitLabels[b]:SetShown(shown and (Cfg("showProfit") or Cfg("showPercent"))) end
        if levelLabels[b] then levelLabels[b]:SetShown(shown and Cfg("showEquipLevel")) end
    end
end

local function ShowOverlay()
    if not overlayFrame then return end
    TradeSkillListScrollFrame:Hide()
    SetBlizzardButtonsShown(false)
    TradeSkillHighlightFrame:Hide()
    overlayScroll:ClearAllPoints()
    overlayScroll:SetAllPoints(overlayFrame)
    overlayFrame:Show()
    FauxScrollFrame_SetOffset(overlayScroll, 0)
    selectedRecipe = nil
    PaintOverlay()
end

local function HideOverlay()
    if not overlayFrame then return end
    overlayFrame:Hide()
    TradeSkillListScrollFrame:Show()
    SetBlizzardButtonsShown(true)
    TradeSkillHighlightFrame:ClearAllPoints()
    TradeSkillFrame_Update()
end


-- ============================================================================
-- UI Components: Master Sort Button
-- ============================================================================

local sortButton

local function CreateSortButton()
    if sortButton then return end
    if not TradeSkillFrame then return end

    sortButton = CreateFrame("Button", "TradeSkillProfitsSortButton", TradeSkillFrame, "UIPanelButtonTemplate")
    sortButton:SetSize(70, 22)
    -- Vertical anchor changed to -22 to align nicely with default UI elements
    sortButton:SetPoint("BOTTOMRIGHT", TradeSkillListScrollFrame, "TOPRIGHT", 0, -22)
    sortButton:SetText("Default")
    sortButton:SetShown(Cfg("showSortButton"))

    sortButton:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")

    sortButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" and IsControlKeyDown() then
            -- Bypass legacy bug when opening options frame
            if Settings and Settings.OpenToCategory then
                if TradeSkillProfits_SettingsCategory then
                    Settings.OpenToCategory(TradeSkillProfits_SettingsCategory.ID)
                end
            else
                InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
                InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
            end
            return
        end

        -- Block manipulation if overlay is disabled
        if not isSortedByProfit and button ~= "LeftButton" then
            return
        end

        if button == "RightButton" then
            isSortDescending = not isSortDescending
            sortButton:SetText(currentSortMode .. (isSortDescending and " v" or " ^"))
            if isSortedByProfit then
                BuildSortedList()
                ShowOverlay()
            end
            
        elseif button == "MiddleButton" then
            currentSortMode = (currentSortMode == "Profit") and "Cost" or "Profit"
            sortButton:SetText(currentSortMode .. (isSortDescending and " v" or " ^"))
            if isSortedByProfit then
                BuildSortedList()
                ShowOverlay()
            end
            
        elseif button == "LeftButton" then
            isSortedByProfit = not isSortedByProfit
            if isSortedByProfit then
                sortButton:SetText(currentSortMode .. (isSortDescending and " v" or " ^"))
                BuildSortedList()
                ShowOverlay()
            else
                sortButton:SetText("Default")
                sortedList = nil
                HideOverlay()
                TradeSkillFrame_Update()
            end
        end
        
        if GameTooltip:IsOwned(self) then
            self:GetScript("OnEnter")(self)
        end
    end)

    sortButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("TradeSkill Profits")
        GameTooltip:AddLine("Left-Click: Toggle sorted view", 1, 1, 1)
        GameTooltip:AddLine("Middle-Click: Change sort method", 1, 1, 1)
        GameTooltip:AddLine("Right-Click: Toggle Asc/Desc", 1, 1, 1)
        GameTooltip:AddLine("Ctrl-Right-Click: Open Settings", 1, 1, 1)
        GameTooltip:AddLine("Current State: |cff00ff00" .. (isSortedByProfit and currentSortMode or "Default") .. "|r", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    sortButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end


-- ============================================================================
-- Options Panel Generation
-- ============================================================================

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "TradeSkillProfitsOptionsPanel")
    panel.name  = ADDON_NAME

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("TradeSkill Profits")

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetText("Settings apply immediately when the TradeSkill frame is open.")

    local function AddCheckbox(xOffset, yOffset, labelText, key, tip)
        local cb = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", xOffset, yOffset)
        cb.Text:SetText(labelText)
        cb:SetChecked(Cfg(key))
        if tip then cb.tooltipText = tip end
        
        cb:SetScript("OnClick", function(self)
            TradeSkillProfits_DB[key] = self:GetChecked()
            
            if TradeSkillFrame and TradeSkillFrame:IsShown() then
                if key == "enableAddon" then
                    if not TradeSkillProfits_DB.enableAddon then
                        if isSortedByProfit then
                            isSortedByProfit = false
                            if sortButton then sortButton:SetText("Default") end
                            HideOverlay()
                        end
                        if sortButton then sortButton:Hide() end
                        for b, label in pairs(profitLabels) do label:Hide() end
                        for b, label in pairs(levelLabels)  do label:Hide() end
                    else
                        if sortButton and Cfg("showSortButton") then sortButton:Show() end
                        RefreshLabels()
                    end
                elseif key == "showSortButton" and sortButton then
                    sortButton:SetShown(Cfg("enableAddon") and Cfg("showSortButton"))
                elseif key == "showProfTabs" then
                    UpdateProfessionTabs()
                end
                
                if Cfg("enableAddon") then
                    if isSortedByProfit then PaintOverlay() else RefreshLabels() end
                end
            end
        end)
        return cb
    end

    local function AddSlider(xOffset, yOffset, labelText, key, min, max, tip)
        local slider = CreateFrame("Slider", "TSPSlider_"..key, panel, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", xOffset, yOffset - 15)
        slider:SetMinMaxValues(min, max)
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        slider:SetValue(Cfg(key))
        
        _G[slider:GetName().."Low"]:SetText(min)
        _G[slider:GetName().."High"]:SetText(max)
        _G[slider:GetName().."Text"]:SetText(labelText .. ": " .. Cfg(key))
        
        slider.tooltipText = tip
        slider:SetScript("OnValueChanged", function(self, value)
            local val = math.floor(value + 0.5)
            TradeSkillProfits_DB[key] = val
            _G[self:GetName().."Text"]:SetText(labelText .. ": " .. val)
        end)
        return slider
    end

    -- Left Column (General Settings)
    AddCheckbox(16, -60,  "Enable TradeSkill Profits",      "enableAddon",    "Master toggle to turn the addon on or off.")
    AddCheckbox(16, -90,  "Show Sort button",               "showSortButton", "Show the Sort button above the recipe list.")
    AddCheckbox(16, -120, "Show profit amount",             "showProfit",     "Displays estimated AH profit per craft.")
    AddCheckbox(16, -150, "Show profit percentage",         "showPercent",    "Displays profit as a percentage of crafting cost.")
    AddCheckbox(16, -180, "Abbreviate large percentages",   "abbreviatePct",  "Shortens large percentages over 1000% (e.g., 12.5k%).")
    AddCheckbox(16, -210, "Show minus sign (-) on losses",  "showMinus",      "Prepends a minus sign to the value if the craft is a loss.")
    AddCheckbox(16, -240, "Use coin icons",                 "useCoins",       "Replaces g/s/c text with gold/silver/copper coin icons.")
    AddCheckbox(16, -270, "Colorize profit (green / red)",  "colorize",       "Green for positive profit, red for a loss.")

    -- Right Column (Tooltip & UI Settings)
    AddCheckbox(300, -60,  "Enable Tooltip Breakdown",      "showTooltip",    "Appends the profit breakdown to the recipe tooltip.")
    AddCheckbox(300, -90,  "Show Tooltip Separator",        "tooltipSeparator", "Adds a blank line before the breakdown.")
    AddCheckbox(300, -120, "Show Tooltip Title",            "tooltipTitle",   "Displays the 'TradeSkill Profits' header.")
    AddCheckbox(300, -150, "Show Crafting Cost",            "tooltipCost",    "Displays the material cost in the tooltip.")
    AddCheckbox(300, -180, "Show AH Value",                 "tooltipValue",   "Displays the total AH value in the tooltip.")
    AddCheckbox(300, -210, "Show Total Profit",             "tooltipProfit",  "Displays the calculated profit in the tooltip.")
    AddCheckbox(300, -240, "Show Profession Tabs",          "showProfTabs",   "Displays quick-switch tabs for other professions.")
    AddCheckbox(300, -270, "Show Equip Level",              "showEquipLevel", "Shows the required equip level next to crafted items.")
    
    AddSlider(305, -305, "Tooltip Line Offset",             "tooltipOffset", 0, 10, "Move the custom tooltip lines higher up by swapping them with other addon lines.")

    -- Compatibility handling for modern Classic client APIs
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
        category.ID = panel.name
        Settings.RegisterAddOnCategory(category)
        TradeSkillProfits_SettingsCategory = category
    else
        InterfaceOptions_AddCategory(panel)
    end
end


-- ============================================================================
-- Event Handlers & Core Loop
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_CLOSE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        CreateOptionsPanel()
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "TRADE_SKILL_SHOW" then
        ClearCache()
        UpdateProfessionTabs()
        CreateSortButton()
        CreateOverlayFrame()

        if not self.hooked then
            self.hooked = true
            hooksecurefunc("TradeSkillFrame_Update", function()
                if not Cfg("enableAddon") then 
                    for _, label in pairs(profitLabels) do label:Hide() end
                    for _, label in pairs(levelLabels)  do label:Hide() end
                    return 
                end
                if isSortedByProfit then
                    TradeSkillListScrollFrame:Hide()
                    SetBlizzardButtonsShown(false)
                    TradeSkillHighlightFrame:Hide()
                    PaintOverlay()
                else
                    RefreshLabels()
                end
            end)
        end

        if isSortedByProfit then ShowOverlay() else RefreshLabels() end

    elseif event == "TRADE_SKILL_UPDATE" then
        if isSortedByProfit then
            TradeSkillListScrollFrame:Hide()
            SetBlizzardButtonsShown(false)
            TradeSkillHighlightFrame:Hide()
            BuildSortedList()
            PaintOverlay()
        else
            RefreshLabels()
        end

    elseif event == "TRADE_SKILL_CLOSE" then
        isSortedByProfit = false
        sortedList       = nil
        selectedRecipe   = nil
        HideOverlay()

        if sortButton then sortButton:SetText("Default") end 
        for i = 1, NUM_BUTTONS do
            local b = _G["TradeSkillSkill"..i]
            if b and profitLabels[b] then profitLabels[b]:Hide() end
            if b and levelLabels[b]  then levelLabels[b]:Hide()  end
        end
    end
end)

-- Listener to wipe the calculation cache if Auctionator performs a fresh scan
local atrWatcher = CreateFrame("Frame")
atrWatcher:RegisterEvent("ADDON_LOADED")
atrWatcher:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == "Auctionator" then
        Auctionator.API.v1.RegisterForDBUpdate(CALLER_ID, function()
            ClearCache()
            if TradeSkillFrame and TradeSkillFrame:IsShown() then
                if isSortedByProfit then
                    BuildSortedList()
                    PaintOverlay()
                else
                    RefreshLabels()
                end
            end
        end)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)


-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_TRADESKILLPROFITS1 = "/tsp"
SlashCmdList["TRADESKILLPROFITS"] = function(msg)
    if Settings and Settings.OpenToCategory then
        if TradeSkillProfits_SettingsCategory then
            Settings.OpenToCategory(TradeSkillProfits_SettingsCategory.ID)
        end
    else
        InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
        InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
    end
end