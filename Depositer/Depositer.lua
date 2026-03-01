--[[
    Depositer
    Automates the transfer of items from player bags to the bank.
    Includes custom Stack Compressor and Live-Polling Bank Sorter.
    Includes StackSplitter for scroll-wheel splitting and auto-dropping.
    Includes Configurable Ignore List with Tooltip injection.
    Includes 'Force Deposit' for granular item subtypes.
    Includes API wrappers for modern C_Container compatibility.
]]--

local ADDON_NAME = "Depositer"
local Depositer = CreateFrame("Frame")

-- Queues and States
local transferQueue = {} 
local compressQueue = {}
local isWorking     = false
local sortTicker    = nil

-- ============================================================================
-- Database & Defaults
-- ============================================================================

local DEFAULT_SETTINGS = {
    enable_StackSplitter = true,
    show_summary         = true,
    
    tooltip_show         = 1, 
    tooltip_padding      = 1,
    
    ignore_button        = "MiddleButton",
    mod_shift            = true,
    mod_ctrl             = false,
    mod_alt              = false,

    type_Weapon          = true,
    type_Armor           = true,
    type_Recipe          = true,
    type_Quest           = true,
    type_Misc            = true,
    
    -- Consumable Subtypes & Force Toggles
    type_Consumable      = true,
    cons_Potion          = true,  all_cons_Potion          = false,
    cons_Food            = true,  all_cons_Food            = false,
    cons_Bandage         = true,  all_cons_Bandage         = false,
    cons_Enhancement     = true,  all_cons_Enhancement     = false,
    cons_Other           = true,  all_cons_Other           = false,
    
    -- Tradeskill Subtypes & Force Toggles
    type_Tradeskill      = true,
    trade_MetalStone     = true,  all_trade_MetalStone     = false,
    trade_Cloth          = true,  all_trade_Cloth          = false,
    trade_Leather        = true,  all_trade_Leather        = false,
    trade_Herb           = true,  all_trade_Herb           = false,
    trade_Meat           = true,  all_trade_Meat           = false,
    trade_Elemental      = true,  all_trade_Elemental      = false,
    trade_Enchanting     = true,  all_trade_Enchanting     = false,
    trade_GemsJC         = true,  all_trade_GemsJC         = false,
    trade_Engineering    = true,  all_trade_Engineering    = false,
    trade_Reagent        = true,  all_trade_Reagent        = false,
    trade_Other          = true,  all_trade_Other          = false,
}

local function GetCfg(key) return DepositerDB[key] end

local CLASS_PRIORITY = {
    [2] = 1, [4] = 2, [0] = 3, [3] = 4, [7] = 5,
    [5] = 6, [9] = 7, [12] = 8, [1] = 9, [15] = 10
}

local function PrintMsg(msg)
    if GetCfg("show_summary") then print("|cff00ff00Depositer:|r " .. msg) end
end

-- ============================================================================
-- API Compatibility Wrappers
-- ============================================================================

local function GetNumSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
    return GetContainerNumSlots(bag)
end

local function GetItemLink(bag, slot)
    if C_Container and C_Container.GetContainerItemLink then return C_Container.GetContainerItemLink(bag, slot) end
    return GetContainerItemLink(bag, slot)
end

local function UseItem(bag, slot)
    if C_Container and C_Container.UseContainerItem then C_Container.UseContainerItem(bag, slot)
    else UseContainerItem(bag, slot) end
end

local function PickupItem(bag, slot)
    if C_Container and C_Container.PickupContainerItem then C_Container.PickupContainerItem(bag, slot)
    else PickupContainerItem(bag, slot) end
end

local function GetItemCount(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        return info and info.stackCount or 0
    end
    local _, count = GetContainerItemInfo(bag, slot)
    return count or 0
end

local function GetItemKey(link)
    if not link then return nil end
    local itemString = string.match(link, "item:([%-?%d:]+)")
    if not itemString then return nil end
    local parts = {strsplit(":", itemString)}
    return (parts[1] or "") .. ":" .. (parts[2] or "") .. ":" .. (parts[7] or "")
end

local function GetMouseTarget()
    if GetMouseFoci then return GetMouseFoci()[1] end
    if GetMouseFocus then return GetMouseFocus() end
    return nil
end

-- ============================================================================
-- Item Logic Check (Subtype & Force Deposit Filtering)
-- ============================================================================

local function ShouldDepositItem(classID, subclassID)
    if classID == 2 then return GetCfg("type_Weapon") end
    if classID == 4 then return GetCfg("type_Armor") end
    if classID == 9 then return GetCfg("type_Recipe") end
    if classID == 12 then return GetCfg("type_Quest") end
    
    if classID == 5 then return GetCfg("type_Tradeskill") and GetCfg("trade_Reagent") end
    if classID == 3 then return GetCfg("type_Tradeskill") and GetCfg("trade_GemsJC") end
    
    if classID == 0 then 
        if not GetCfg("type_Consumable") then return false end
        if subclassID == 1 or subclassID == 2 or subclassID == 3 then return GetCfg("cons_Potion") end
        if subclassID == 5 then return GetCfg("cons_Food") end
        if subclassID == 7 then return GetCfg("cons_Bandage") end
        return GetCfg("cons_Other")
    end
    
    if classID == 7 then 
        if subclassID == 14 or subclassID == 15 then return GetCfg("type_Consumable") and GetCfg("cons_Enhancement") end
        if not GetCfg("type_Tradeskill") then return false end
        if subclassID == 5 then return GetCfg("trade_Cloth") end
        if subclassID == 6 then return GetCfg("trade_Leather") end
        if subclassID == 9 then return GetCfg("trade_Herb") end
        if subclassID == 7 then return GetCfg("trade_MetalStone") end
        if subclassID == 8 then return GetCfg("trade_Meat") end
        if subclassID == 10 then return GetCfg("trade_Elemental") end
        if subclassID == 12 then return GetCfg("trade_Enchanting") end
        if subclassID == 4 then return GetCfg("trade_GemsJC") end 
        if subclassID == 1 or subclassID == 2 or subclassID == 3 then return GetCfg("trade_Engineering") end 
        return GetCfg("trade_Other")
    end
    
    return GetCfg("type_Misc")
end

local function ShouldForceDeposit(classID, subclassID)
    if classID == 5 then return GetCfg("all_trade_Reagent") end
    if classID == 3 then return GetCfg("all_trade_GemsJC") end

    if classID == 0 then
        if subclassID == 1 or subclassID == 2 or subclassID == 3 then return GetCfg("all_cons_Potion") end
        if subclassID == 5 then return GetCfg("all_cons_Food") end
        if subclassID == 7 then return GetCfg("all_cons_Bandage") end
        return GetCfg("all_cons_Other")
    elseif classID == 7 then
        if subclassID == 14 or subclassID == 15 then return GetCfg("all_cons_Enhancement") end
        if subclassID == 5 then return GetCfg("all_trade_Cloth") end
        if subclassID == 6 then return GetCfg("all_trade_Leather") end
        if subclassID == 9 then return GetCfg("all_trade_Herb") end
        if subclassID == 7 then return GetCfg("all_trade_MetalStone") end
        if subclassID == 8 then return GetCfg("all_trade_Meat") end
        if subclassID == 10 then return GetCfg("all_trade_Elemental") end
        if subclassID == 12 then return GetCfg("all_trade_Enchanting") end
        if subclassID == 4 then return GetCfg("all_trade_GemsJC") end
        if subclassID == 1 or subclassID == 2 or subclassID == 3 then return GetCfg("all_trade_Engineering") end
        return GetCfg("all_trade_Other")
    end
    return false
end

-- ============================================================================
-- Dynamic Ignore List Management
-- ============================================================================

local function HandleIgnoreClick(self, button)
    if button == GetCfg("ignore_button") then
        local reqShift = GetCfg("mod_shift")
        local reqCtrl  = GetCfg("mod_ctrl")
        local reqAlt   = GetCfg("mod_alt")

        if not reqShift and not reqCtrl and not reqAlt then return end

        if IsShiftKeyDown() == reqShift and IsControlKeyDown() == reqCtrl and IsAltKeyDown() == reqAlt then
            local _, link = GameTooltip:GetItem()
            if link then
                local key = GetItemKey(link)
                if key then
                    if DepositerDB.ignoreList[key] then
                        DepositerDB.ignoreList[key] = nil
                        PrintMsg("Removed from ignore list: " .. link)
                    else
                        DepositerDB.ignoreList[key] = true
                        PrintMsg("Added to ignore list: " .. link)
                    end
                    GameTooltip:Hide()
                end
            end
        end
    end
end

local function DynamicallyHookFrameClick()
    local focus = GetMouseTarget()
    if focus and focus.RegisterForClicks and not focus.DepositerClickHooked and not InCombatLockdown() then
        local _, link = GameTooltip:GetItem()
        if link then
            focus:RegisterForClicks("AnyUp")
            focus:HookScript("OnClick", HandleIgnoreClick)
            focus.DepositerClickHooked = true
        end
    end
end

local function OnTooltipSetItem(tooltip)
    DynamicallyHookFrameClick()

    local pref = GetCfg("tooltip_show")
    if pref == 3 then return end
    if pref == 2 and not BankFrame:IsShown() then return end

    local _, link = tooltip:GetItem()
    if link then
        local key = GetItemKey(link)
        if key and DepositerDB.ignoreList and DepositerDB.ignoreList[key] then
            for i = 1, GetCfg("tooltip_padding") do tooltip:AddLine(" ") end
            tooltip:AddLine("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:14|t |cffff0000Depositer - Ignored|r")
            tooltip:Show()
        end
    end
end

-- ============================================================================
-- Core Logic: Deposit
-- ============================================================================

local function ProcessTransferQueue()
    if #transferQueue == 0 then isWorking = false; return end
    local item = table.remove(transferQueue, 1)
    UseItem(item.bag, item.slot)
    C_Timer.After(0.05, ProcessTransferQueue)
end

function Depositer:RunDeposit()
    if not BankFrame:IsShown() or isWorking then return end
    wipe(transferQueue)
    local bankInventory, uniqueItems = {}, {}

    for bag = -1, 11 do
        if bag == -1 or (bag >= 5 and bag <= 11) then
            for slot = 1, GetNumSlots(bag) do
                local link = GetItemLink(bag, slot)
                if link then
                    local key = GetItemKey(link)
                    if key then
                        local count = GetItemCount(bag, slot)
                        local _, _, _, _, _, _, _, maxStack = GetItemInfo(link)
                        bankInventory[key] = bankInventory[key] or { partials = {} }
                        if count < (maxStack or 1) then table.insert(bankInventory[key].partials, { bag = bag, slot = slot, space = (maxStack or 1) - count }) end
                    end
                end
            end
        end
    end

    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local link = GetItemLink(bag, slot)
            if link then
                local key = GetItemKey(link)
                if key and not DepositerDB.ignoreList[key] then
                    local _, _, _, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfo(link)
                    
                    if ShouldDepositItem(classID, subclassID) then
                        local inBank = bankInventory[key] ~= nil
                        local forceAll = ShouldForceDeposit(classID, subclassID)
                        
                        if inBank or forceAll then
                            table.insert(transferQueue, {bag = bag, slot = slot})
                            uniqueItems[GetItemInfo(link)] = true
                        end
                    end
                end
            end
        end
    end

    if #transferQueue > 0 then
        isWorking = true
        local total, distinct = #transferQueue, 0
        for _ in pairs(uniqueItems) do distinct = distinct + 1 end
        PrintMsg(string.format("Moving %d items (%d types)...", total, distinct))
        ProcessTransferQueue()
    else
        PrintMsg("No matches found.")
    end
end

-- ============================================================================
-- Core Logic: Compress
-- ============================================================================

local function ProcessCompressQueue()
    if #compressQueue == 0 then isWorking = false; return end
    local move = table.remove(compressQueue, 1)
    ClearCursor() 
    PickupItem(move.sourceBag, move.sourceSlot)
    PickupItem(move.targetBag, move.targetSlot)
    C_Timer.After(0.1, ProcessCompressQueue)
end

function Depositer:RunCompress()
    if not BankFrame:IsShown() or isWorking then return end
    wipe(compressQueue)
    
    local function QueueMerges(bagList)
        local partials = {}
        for _, bag in ipairs(bagList) do
            for slot = 1, GetNumSlots(bag) do
                local link = GetItemLink(bag, slot)
                if link then
                    local key = GetItemKey(link)
                    if key and not DepositerDB.ignoreList[key] then
                        local count = GetItemCount(bag, slot)
                        local _, _, _, _, _, _, _, maxStack = GetItemInfo(link)
                        maxStack = maxStack or 1
                        
                        if count < maxStack then
                            if not partials[key] then partials[key] = {bag = bag, slot = slot, count = count, maxStack = maxStack}
                            else
                                local target = partials[key]
                                table.insert(compressQueue, { sourceBag = bag, sourceSlot = slot, targetBag = target.bag, targetSlot = target.slot })
                                local newCount = target.count + count
                                if newCount < maxStack then target.count = newCount
                                else
                                    partials[key] = nil
                                    if newCount > maxStack then partials[key] = {bag = bag, slot = slot, count = newCount - maxStack, maxStack = maxStack} end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    QueueMerges({-1, 5, 6, 7, 8, 9, 10, 11})
    QueueMerges({0, 1, 2, 3, 4})

    if #compressQueue > 0 then
        isWorking = true
        PrintMsg("Compressing partial stacks...")
        ProcessCompressQueue()
    else
        PrintMsg("All stacks are already compressed.")
    end
end

-- ============================================================================
-- Core Logic: Live Polling Bank Sorter
-- ============================================================================

function Depositer:RunSort()
    if not BankFrame:IsShown() or isWorking then return end
    isWorking = true
    PrintMsg("Sorting bank items...")

    -- Use a live ticker to calculate 1 step at a time, preventing desyncs
    sortTicker = C_Timer.NewTicker(0.15, function()
        if not BankFrame:IsShown() then
            sortTicker:Cancel()
            isWorking = false
            return
        end

        ClearCursor()
        local slots, items = {}, {}

        -- 1. Scan Bank & Ignore Container Items (Bags) entirely to prevent swallow-bugs
        for _, bag in ipairs({-1, 5, 6, 7, 8, 9, 10, 11}) do
            for slot = 1, GetNumSlots(bag) do
                local link = GetItemLink(bag, slot)
                if link then
                    local name, _, quality, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfo(link)
                    if classID ~= 1 then -- If NOT a bag
                        table.insert(slots, {bag = bag, slot = slot})
                        table.insert(items, {
                            bag = bag, slot = slot, name = name, quality = quality, 
                            classID = classID, subclassID = subclassID, count = GetItemCount(bag, slot)
                        })
                    end
                else
                    table.insert(slots, {bag = bag, slot = slot})
                end
            end
        end

        -- 2. Sort the list with strict Tie-Breakers to prevent infinite swap loops
        table.sort(items, function(a, b)
            local pA = CLASS_PRIORITY[a.classID] or 99
            local pB = CLASS_PRIORITY[b.classID] or 99
            if pA ~= pB then return pA < pB end
            if a.subclassID ~= b.subclassID then return a.subclassID < b.subclassID end
            if a.quality ~= b.quality then return a.quality > b.quality end
            if a.name ~= b.name then return a.name < b.name end
            if a.count ~= b.count then return a.count > b.count end
            -- TIE BREAKERS: Ensures identical stacks don't swap endlessly
            if a.bag ~= b.bag then return a.bag < b.bag end
            return a.slot < b.slot
        end)

        -- 3. Find the first out-of-place item and move it
        local moveMade = false
        for i = 1, #items do
            local targetPos = slots[i]
            local desiredItem = items[i]

            if desiredItem.bag ~= targetPos.bag or desiredItem.slot ~= targetPos.slot then
                local targetLink = GetItemLink(targetPos.bag, targetPos.slot)
                
                -- Execute physical 3-way swap
                PickupItem(desiredItem.bag, desiredItem.slot)
                PickupItem(targetPos.bag, targetPos.slot)
                if targetLink then
                    PickupItem(desiredItem.bag, desiredItem.slot)
                end
                
                moveMade = true
                break -- Wait for next tick to verify the swap succeeded
            end
        end

        if not moveMade then
            sortTicker:Cancel()
            isWorking = false
            PrintMsg("Bank sorting complete.")
        end
    end)
end

-- ============================================================================
-- StackSplitter Module
-- ============================================================================

local function DropCursorItemContextually()
    if not CursorHasItem() then return end
    if SendMailFrame and SendMailFrame:IsShown() then for i = 1, (ATTACHMENTS_MAX_SEND or 7) do if not GetSendMailItem(i) then ClickSendMailItemButton(i); return end end end
    if TradeFrame and TradeFrame:IsShown() then for i = 1, 6 do if not GetTradePlayerItemInfo(i) then ClickTradeButton(i); return end end end
    if BankFrame and BankFrame:IsShown() then
        for bag = -1, 11 do if bag == -1 or (bag >= 5 and bag <= 11) then
            for slot = 1, GetNumSlots(bag) do if not GetItemLink(bag, slot) then PickupItem(bag, slot); return end end
        end end
    end
    for bag = 0, 4 do for slot = 1, GetNumSlots(bag) do if not GetItemLink(bag, slot) then PickupItem(bag, slot); return end end end
end

local function HookStackSplitter()
    if not StackSplitFrame then return end
    StackSplitFrame:EnableMouseWheel(true)
    StackSplitFrame:HookScript("OnMouseWheel", function(self, delta)
        if not GetCfg("enable_StackSplitter") or not self.split or not self.maxStack then return end
        local newSplit = self.split + delta
        if newSplit < 1 then newSplit = 1 end
        if newSplit > self.maxStack then newSplit = self.maxStack end
        self.split = newSplit
        StackSplitText:SetText(newSplit)
        if self.LeftButton then self.LeftButton:SetEnabled(newSplit > 1) end
        if self.RightButton then self.RightButton:SetEnabled(newSplit < self.maxStack) end
    end)

    local function MarkSplitRequest()
        if not GetCfg("enable_StackSplitter") then return end
        Depositer.awaitingSplitDrop = true
        local ticks = 0
        local ticker
        ticker = C_Timer.NewTicker(0.05, function()
            ticks = ticks + 1
            if ticks > 20 or not Depositer.awaitingSplitDrop then ticker:Cancel(); return end
            if CursorHasItem() then
                Depositer.awaitingSplitDrop = false
                ticker:Cancel()
                C_Timer.After(0.1, DropCursorItemContextually)
            end
        end)
    end

    if C_Container and C_Container.SplitContainerItem then hooksecurefunc(C_Container, "SplitContainerItem", MarkSplitRequest)
    elseif SplitContainerItem then hooksecurefunc("SplitContainerItem", MarkSplitRequest) end
end

-- ============================================================================
-- Options UI (2-Column Dynamic Layout)
-- ============================================================================

function Depositer:OpenSettings()
    if Settings and Settings.OpenToCategory then
        if Depositer_SettingsCategory then Settings.OpenToCategory(Depositer_SettingsCategory.ID) end
    else
        InterfaceOptionsFrame_OpenToCategory("Depositer")
        InterfaceOptionsFrame_OpenToCategory("Depositer")
    end
end

function Depositer:SetupOptions()
    local panel = CreateFrame("Frame", "DepositerOptionsPanel", UIParent)
    panel.name = "Depositer"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Depositer Settings")

    local function CreateToggle(key, label, x, y)
        local cb = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        cb.Text:SetText(label)
        cb:SetChecked(GetCfg(key))
        cb:SetScript("OnClick", function(self) DepositerDB[key] = self:GetChecked() end)
        return cb
    end
    
    local function CreateCategoryRow(baseKey, allKey, label, x, y)
        local cb = CreateToggle(baseKey, label, x, y)
        local cbAll = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        cbAll:SetPoint("TOPLEFT", x + 180, y)
        cbAll.Text:SetText("Force Deposit (Even if not in Bank)")
        cbAll.Text:SetFontObject("GameFontNormalSmall")
        cbAll.Text:SetTextColor(0.6, 0.6, 0.6)
        cbAll:SetChecked(GetCfg(allKey))
        cbAll:SetScript("OnClick", function(self) DepositerDB[allKey] = self:GetChecked() end)
        return cb, cbAll
    end

    -- COLUMN 1: General & Ignore Settings (X = 16)
    local col1Y = -40
    CreateToggle("show_summary", "Show Chat Summaries", 16, col1Y); col1Y = col1Y - 30
    CreateToggle("enable_StackSplitter", "Enable Scroll-Wheel Splitting", 16, col1Y); col1Y = col1Y - 40
    
    local ttLabels = { [1] = "Always Show", [2] = "Only Show at Bank", [3] = "Never Show" }
    local btnTT = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnTT:SetPoint("TOPLEFT", 16, col1Y)
    btnTT:SetSize(200, 24)
    btnTT:SetText("Ignore Tooltip: " .. ttLabels[GetCfg("tooltip_show")])
    btnTT:SetScript("OnClick", function(self)
        local val = GetCfg("tooltip_show") + 1
        if val > 3 then val = 1 end
        DepositerDB["tooltip_show"] = val
        self:SetText("Ignore Tooltip: " .. ttLabels[val])
    end); col1Y = col1Y - 35
    
    local sliderTT = CreateFrame("Slider", "DepositerPaddingSlider", panel, "OptionsSliderTemplate")
    sliderTT:SetPoint("TOPLEFT", 16, col1Y - 10)
    sliderTT:SetMinMaxValues(0, 5)
    sliderTT:SetValueStep(1)
    sliderTT:SetObeyStepOnDrag(true)
    sliderTT:SetValue(GetCfg("tooltip_padding"))
    _G[sliderTT:GetName().."Low"]:SetText("0")
    _G[sliderTT:GetName().."High"]:SetText("5")
    _G[sliderTT:GetName().."Text"]:SetText("Tooltip Padding Lines: " .. GetCfg("tooltip_padding"))
    sliderTT:SetScript("OnValueChanged", function(self, value)
        DepositerDB["tooltip_padding"] = value
        _G[self:GetName().."Text"]:SetText("Tooltip Padding Lines: " .. value)
    end); col1Y = col1Y - 60

    local btnMap = {["LeftButton"] = "Left", ["RightButton"] = "Right", ["MiddleButton"] = "Middle"}
    local nextBtn = {["LeftButton"] = "RightButton", ["RightButton"] = "MiddleButton", ["MiddleButton"] = "LeftButton"}
    
    local btnClick = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnClick:SetPoint("TOPLEFT", 16, col1Y)
    btnClick:SetSize(160, 24)
    btnClick:SetText("Ignore Click: " .. btnMap[GetCfg("ignore_button")])
    btnClick:SetScript("OnClick", function(self)
        local val = nextBtn[GetCfg("ignore_button")] or "LeftButton"
        DepositerDB["ignore_button"] = val
        self:SetText("Ignore Click: " .. btnMap[val])
    end); col1Y = col1Y - 35
    
    CreateToggle("mod_shift", "Require Shift Key", 16, col1Y); col1Y = col1Y - 25
    CreateToggle("mod_ctrl", "Require Ctrl Key", 16, col1Y); col1Y = col1Y - 25
    CreateToggle("mod_alt", "Require Alt Key", 16, col1Y); col1Y = col1Y - 40

    CreateToggle("type_Weapon", "Deposit Weapons", 16, col1Y); col1Y = col1Y - 25
    CreateToggle("type_Armor", "Deposit Armor", 16, col1Y); col1Y = col1Y - 25
    CreateToggle("type_Misc", "Deposit Miscellaneous", 16, col1Y)

    -- COLUMN 2: Subcategories & Force Rules (X = 230)
    local col2Y = -40
    
    CreateToggle("type_Consumable", "|cffFFFF00Deposit Consumables|r", 230, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("cons_Potion", "all_cons_Potion", "Potions/Elixirs", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("cons_Food", "all_cons_Food", "Food & Drink", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("cons_Bandage", "all_cons_Bandage", "Bandages", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("cons_Enhancement", "all_cons_Enhancement", "Item Enhancements", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("cons_Other", "all_cons_Other", "Other Consumables", 250, col2Y); col2Y = col2Y - 30
    
    CreateToggle("type_Tradeskill", "|cffFFFF00Deposit Trade Goods|r", 230, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_MetalStone", "all_trade_MetalStone", "Metal & Stone", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Cloth", "all_trade_Cloth", "Cloth", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Leather", "all_trade_Leather", "Leather & Scales", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Herb", "all_trade_Herb", "Herbs", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Meat", "all_trade_Meat", "Meat", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Elemental", "all_trade_Elemental", "Primals/Elemental", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Enchanting", "all_trade_Enchanting", "Enchanting Mats", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_GemsJC", "all_trade_GemsJC", "Gems & JC", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Engineering", "all_trade_Engineering", "Eng. Parts/Explosives", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Reagent", "all_trade_Reagent", "Spell Reagents", 250, col2Y); col2Y = col2Y - 22
    CreateCategoryRow("trade_Other", "all_trade_Other", "Other Trade Goods", 250, col2Y)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        category.ID = panel.name
        Settings.RegisterAddOnCategory(category)
        Depositer_SettingsCategory = category
    else
        InterfaceOptions_AddCategory(panel)
    end
end

-- ============================================================================
-- UI Construction & Initialization
-- ============================================================================

local function GenericButton_OnClick(self, button)
    if button == "RightButton" and IsControlKeyDown() then
        Depositer:OpenSettings()
    else
        if self.action == "deposit" then Depositer:RunDeposit()
        elseif self.action == "compress" then Depositer:RunCompress()
        elseif self.action == "sort" then Depositer:RunSort() end
    end
end

function Depositer:CreateButtons()
    if self.btnDeposit then return end

    local dep = CreateFrame("Button", nil, BankFrame, "UIPanelButtonTemplate")
    dep:SetSize(70, 22)
    dep:SetText("Deposit")
    dep:SetPoint("TOPRIGHT", BankFrame, "TOPRIGHT", -25, -14)
    dep:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    dep.action = "deposit"
    dep:SetScript("OnClick", GenericButton_OnClick)
    dep:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine("Depositer", 1, 0.82, 0); GameTooltip:AddLine("Left-Click: Deposit items", 1, 1, 1); GameTooltip:AddLine("Ctrl + Right-Click: Settings", 0.5, 0.5, 0.5); GameTooltip:Show() end)
    dep:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.btnDeposit = dep

    local comp = CreateFrame("Button", nil, BankFrame, "UIPanelButtonTemplate")
    comp:SetSize(80, 22)
    comp:SetText("Compress")
    comp:SetPoint("RIGHT", dep, "LEFT", -2, 0)
    comp:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    comp.action = "compress"
    comp:SetScript("OnClick", GenericButton_OnClick)
    comp:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine("Stack Compressor", 1, 0.82, 0); GameTooltip:AddLine("Left-Click: Merge partial stacks", 1, 1, 1); GameTooltip:AddLine("Ctrl + Right-Click: Settings", 0.5, 0.5, 0.5); GameTooltip:Show() end)
    comp:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.btnCompress = comp

    local sort = CreateFrame("Button", nil, BankFrame, "UIPanelButtonTemplate")
    sort:SetSize(60, 22)
    sort:SetText("Sort")
    sort:SetPoint("RIGHT", comp, "LEFT", -2, 0)
    sort:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    sort.action = "sort"
    sort:SetScript("OnClick", GenericButton_OnClick)
    sort:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine("Bank Sorter", 1, 0.82, 0); GameTooltip:AddLine("Left-Click: Sort by Type/Quality/Name", 1, 1, 1); GameTooltip:AddLine("Ctrl + Right-Click: Settings", 0.5, 0.5, 0.5); GameTooltip:Show() end)
    sort:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.btnSort = sort
end

Depositer:RegisterEvent("ADDON_LOADED")
Depositer:RegisterEvent("BANKFRAME_OPENED")
Depositer:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        DepositerDB = DepositerDB or {}
        DepositerDB.ignoreList = DepositerDB.ignoreList or {}
        for k, v in pairs(DEFAULT_SETTINGS) do if DepositerDB[k] == nil then DepositerDB[k] = v end end
        
        self:SetupOptions()
        HookStackSplitter()
        
        GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        
    elseif event == "BANKFRAME_OPENED" then
        self:CreateButtons()
    end
end)