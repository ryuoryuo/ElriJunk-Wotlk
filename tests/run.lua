-- Behavioral tests for the 3.3.5a API. Run: lua5.1 tests/run.lua ElriJunk.lua
local source = arg[1] or "ElriJunk.lua"
local passed = 0

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function copySavedVariables(value)
    local function serialize(entry)
        local kind = type(entry)
        if kind == "string" then return string.format("%q", entry) end
        if kind == "number" or kind == "boolean" or kind == "nil" then return tostring(entry) end
        assert(kind == "table", "unsupported SavedVariables value: " .. kind)
        local parts = {}
        for key, item in pairs(entry) do
            table.insert(parts, "[" .. serialize(key) .. "]=" .. serialize(item))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local chunk = assert(loadstring("return " .. serialize(value)))
    setfenv(chunk, {})
    return chunk()
end

local function world(saved)
    local w = { time = 0, money = 10000, frames = {}, bags = {}, info = {}, messages = {},
        sales = {}, deleted = {}, used = {}, timers = {}, bagSizes = {}, originalClicks = 0 }
    local env = setmetatable({}, { __index = _G })
    env._G, env.SlashCmdList, env.StaticPopupDialogs = env, {}, {}
    env.ElriJunkDB = saved
    local methods = {}
    function methods:GetName() return self.name end
    function methods:GetParent() return self.parent end
    function methods:GetID() return self.id or 0 end
    function methods:SetID(value) self.id = value end
    function methods:GetObjectType() return self.kind end
    function methods:GetFrameLevel() return self.level or 1 end
    function methods:SetFrameLevel(value) self.level = value end
    function methods:SetScript(event, callback)
        self.scripts[event] = callback
        self.scriptTaint[event] = callback and getfenv(callback) == env or false
    end
    function methods:GetScript(event) return self.scripts[event] end
    function methods:HookScript(event, callback)
        self.hooks[event] = self.hooks[event] or {}
        table.insert(self.hooks[event], callback)
    end
    function methods:RunScript(event, ...)
        local previous = w.tainted
        w.tainted = previous or self.scriptTaint[event]
        if self.scripts[event] then self.scripts[event](self, ...) end
        for _, callback in ipairs(self.hooks[event] or {}) do
            w.tainted = true
            callback(self, ...)
        end
        w.tainted = previous
    end
    function methods:IsShown() return self.shown and (not self.parent or self.parent:IsShown()) end
    function methods:Show()
        local old = self.shown
        self.shown = true
        if not old then self:RunScript("OnShow") end
    end
    function methods:Hide()
        local old = self.shown
        self.shown = false
        if old then self:RunScript("OnHide") end
    end
    function methods:IsProtected() return self.protected, self.protected end
    function methods:GetAttribute(name) return self.attributes[name] end
    function methods:SetAttribute(name, value)
        assert(not (self.protected and w.combat), "protected attributes changed in combat")
        self.attributes[name] = value
    end
    function methods:SetAllPoints() end
    function methods:EnableMouse() end
    function methods:RegisterEvent(event)
        self.events = self.events or {}
        self.events[event] = true
    end
    function methods:SetPoint() end
    function methods:SetTexture(value) self.texture = value end
    function methods:SetWidth(value) self.width = value end
    function methods:SetHeight(value) self.height = value end
    function methods:CreateTexture()
        return setmetatable({ scripts = {}, shown = true }, { __index = methods })
    end
    function env.CreateFrame(kind, name, parent, template)
        local object = setmetatable({ kind = kind, name = name, parent = parent, shown = true,
            scripts = {}, hooks = {}, scriptTaint = {}, attributes = {},
            protected = template == "SecureFrameTemplate" }, { __index = methods })
        table.insert(w.frames, object)
        if name then env[name] = object end
        return object
    end
    function env.EnumerateFrames(previous)
        if not previous then return w.frames[1] end
        for i, object in ipairs(w.frames) do if object == previous then return w.frames[i + 1] end end
    end
    function env.hooksecurefunc(target, key, callback)
        if type(target) == "string" then callback, key, target = key, target, env end
        local original = target[key]
        target[key] = function(...)
            if original then original(...) end
            callback(...)
        end
    end
    function env.SecureHandlerWrapScript(button, script, header, body)
        assert(not w.combat, "secure scripts cannot be wrapped in combat")
        assert(header:IsProtected(), "secure wrapper requires a protected owner")
        local restricted = {
            IsControlKeyDown = env.IsControlKeyDown,
            IsShiftKeyDown = env.IsShiftKeyDown,
            IsAltKeyDown = env.IsAltKeyDown,
        }
        local pre = assert(loadstring("return function(self, button, down) " .. body .. "\nend"))()
        setfenv(pre, restricted)
        local original, originalTaint = button.scripts[script], button.scriptTaint[script]
        button.scripts[script] = function(self, mouseButton, down, ...)
            if not w.combat or self:IsProtected() then
                local replacement = pre(self, mouseButton, down)
                if replacement == false then return end
                if replacement then mouseButton = tostring(replacement) end
            end
            local previous = w.tainted
            w.tainted = originalTaint
            if original then original(self, mouseButton, down, ...) end
            w.tainted = previous
        end
        button.scriptTaint[script] = false
        button.secureWraps = (button.secureWraps or 0) + 1
    end
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) table.insert(w.messages, message) end }
    function env.GetTime() return w.time end
    function env.GetMoney() return w.money end
    function env.InCombatLockdown() return w.combat end
    function env.InRepairMode() return w.repair end
    function env.UnitIsDeadOrGhost() return w.dead end
    function env.IsControlKeyDown() return w.ctrl end
    function env.IsShiftKeyDown() return w.shift end
    function env.IsAltKeyDown() return w.alt end
    function env.GetContainerNumSlots(bag) return w.bagSizes[bag] or 0 end
    function env.GetContainerItemLink(bag, slot)
        local item = w.bags[bag] and w.bags[bag][slot]
        return item and item.link
    end
    function env.GetContainerItemInfo(bag, slot)
        local item = w.bags[bag] and w.bags[bag][slot]
        if item then return "icon", item.count, item.locked, item.bagQuality end
    end
    function env.GetItemInfo(query)
        local id = type(query) == "number" and query or tonumber(string.match(query or "", "item:(%d+)"))
        local info = w.info[id]
        if not info or info.uncached then return end
        return "Item " .. id, info.link, info.quality, 1, 1, "Misc", "Junk", 20, "", "icon", info.price
    end
    function env.GetCursorInfo()
        if w.cursor then return w.cursor.kind or "item", w.cursor.id, w.cursor.link end
    end
    function env.ClearCursor()
        if w.cursor and w.cursor.origin then
            local origin = w.cursor.origin
            w.bags[origin.bag][origin.slot] = w.cursor
        end
        w.cursor = nil
    end
    function env.PickupContainerItem(bag, slot)
        assert(not w.cursor, "pickup must never replace a foreign cursor")
        local item = w.bags[bag][slot]
        if w.pickupFails or item.locked then return end
        w.bags[bag][slot] = nil
        item.origin = { bag = bag, slot = slot }
        w.cursor = item
        if w.wrongPickup then w.cursor.id = 99999 end
    end
    function env.DeleteCursorItem()
        if w.deleteFails then return end
        assert(w.cursor, "delete requires an owned cursor item")
        table.insert(w.deleted, w.cursor)
        w.cursor = nil
    end
    function env.UseContainerItem(bag, slot)
        local item = w.bags[bag][slot]
        if not env.MerchantFrame:IsShown() then
            assert(not w.tainted, "protected item use reached from an addon-tainted handler")
            table.insert(w.used, item.id)
            return
        end
        table.insert(w.sales, { bag = bag, slot = slot, id = item.id })
        if w.sellFails or (w.failedSaleItems and w.failedSaleItems[item.id]) then return end
        local function acknowledge()
            w.bags[bag][slot] = nil
            w.money = w.money + w.info[item.id].price * item.count
        end
        local delay = (w.saleDelays and w.saleDelays[item.id]) or w.saleDelay
        if delay then table.insert(w.timers, { at = w.time + delay, run = acknowledge })
        else acknowledge() end
        if w.onSaleSubmitted then w.onSaleSubmitted(item) end
    end
    function env.StaticPopup_Show(which, text, _, data)
        w.popupAttempts = (w.popupAttempts or 0) + 1
        if w.popupUnavailable then return end
        w.popup = { which = which, text = text, data = data }
        return w.popup
    end
    function env.StaticPopup_Visible(which) return w.popup and w.popup.which == which end
    function env.StaticPopup_Hide(which)
        if w.popup and w.popup.which == which then w.popup = nil end
    end
    function env.ContainerFrameItemButton_OnLoad() end
    env.NUM_CONTAINER_FRAMES = 2
    env.MerchantFrame = env.CreateFrame("Frame", "MerchantFrame")
    env.MerchantFrame.selectedTab = 1
    env.MerchantFrame:Hide()
    for index = 1, 2 do
        local bag = env.CreateFrame("Frame", "ContainerFrame" .. index)
        bag:SetID(index - 1)
        bag:Hide()
    end
    function w:put(bag, slot, id, quality, price, count)
        self.bags[bag] = self.bags[bag] or {}
        self.bagSizes[bag] = math.max(self.bagSizes[bag] or 0, slot)
        local link = "|cffaaaaaa|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[Item " .. id .. "]|h|r"
        self.info[id] = { quality = quality, price = price, link = link }
        self.bags[bag][slot] = { id = id, link = link, count = count or 1, bagQuality = quality }
        return self.bags[bag][slot]
    end
    function w:button(bag, slot)
        local parent = env["ContainerFrame" .. (bag + 1)]
        parent:Show()
        local button = env.CreateFrame("Button", parent:GetName() .. "Item" .. slot, parent)
        button:SetID(slot)
        button:SetScript("OnClick", function(clicked, mouseButton)
            self.originalClicks = self.originalClicks + 1
            if self.useItemsOnClick and mouseButton == "RightButton"
                and not self.ctrl and not self.shift and not self.alt then
                env.UseContainerItem(clicked:GetParent():GetID(), clicked:GetID())
            end
        end)
        env.ContainerFrameItemButton_OnLoad(button)
        return button
    end
    function w:click(button, ctrl, mouseButton)
        self.ctrl = ctrl
        mouseButton = mouseButton or "RightButton"
        button:RunScript("PreClick", mouseButton)
        button:RunScript("OnClick", mouseButton)
        button:RunScript("PostClick", mouseButton)
        self.ctrl = false
    end
    function w:event(event, ...)
        assert(env.ElriJunkFrame.events[event], "event not registered: " .. event)
        env.ElriJunkFrame:GetScript("OnEvent")(env.ElriJunkFrame, event, ...)
    end
    function w:tick(seconds)
        for i = 1, math.ceil((seconds or 1) / 0.16) do
            self.time = self.time + 0.16
            for index = #self.timers, 1, -1 do
                if self.time >= self.timers[index].at then
                    self.timers[index].run()
                    table.remove(self.timers, index)
                end
            end
            env.ElriJunkFrame:GetScript("OnUpdate")(env.ElriJunkFrame, 0.16)
        end
    end
    function w:openMerchant()
        env.MerchantFrame:Show()
        self:event("MERCHANT_SHOW")
    end
    function w:closeMerchant()
        env.MerchantFrame:Hide()
        self:event("MERCHANT_CLOSED")
    end
    function w:clean() env.SlashCmdList.ELRIJUNK("clean") end
    function w:accept()
        assert(self.popup, "confirmation expected")
        local popup = self.popup
        self.popup = nil
        env.StaticPopupDialogs[popup.which].OnAccept(popup, popup.data)
    end
    function w:cancel(reason)
        local popup = assert(self.popup, "confirmation expected")
        self.popup = nil
        local cancel = env.StaticPopupDialogs[popup.which].OnCancel
        if cancel then cancel(popup, popup.data, reason or "clicked") end
    end
    function w:hasMessage(text)
        for _, message in ipairs(self.messages) do if string.find(message, text, 1, true) then return true end end
        return false
    end
    local chunk = assert(loadfile(source))
    setfenv(chunk, env)
    chunk()
    w.env = env
    function w:init() self:event("ADDON_LOADED", "ElriJunk") end
    return w
end

local function test(name, run)
    local ok, reason = pcall(run)
    if not ok then io.stderr:write("FAIL: " .. name .. "\n" .. tostring(reason) .. "\n"); os.exit(1) end
    passed = passed + 1
    print("PASS: " .. name)
end

test("automatic grey sale, stack revenue, unsellable and normal items", function()
    local w = world(); w:init()
    w:put(0, 1, 1, 0, 123, 4); w:put(0, 2, 2, 1, 100); w:put(0, 3, 3, 0, 0)
    w:openMerchant(); w:tick()
    equal(#w.sales, 1); equal(w.money, 10492)
    equal(w:hasMessage("Продано: 4 шт. Выручка: 0 з. 4 с. 92 м."), true)
end)

test("explicit epic sale and delete priority over default grey sale", function()
    local w = world({ items = { [1] = "sell", [2] = "delete" } }); w:init()
    w:put(0, 1, 1, 4, 100, 2); w:put(0, 2, 2, 0, 20)
    w:openMerchant(); w:tick(); equal(#w.sales, 1); equal(w.sales[1].id, 1)
end)

test("more than twelve stacks and all five carried bags", function()
    local w = world(); w:init()
    for bag = 0, 4 do for slot = 1, 4 do w:put(bag, slot, 100 + bag * 4 + slot, 0, 10) end end
    w:openMerchant(); w:tick(6); equal(#w.sales, 20); equal(w.money, 10200)
end)

test("sales submit twelve stacks per update and count batch income only once", function()
    local w = world(); w:init()
    local count, income = 0, 0
    for slot = 1, 25 do
        local quantity = slot % 3 + 1
        w:put(0, slot, slot, 0, slot * 10, quantity)
        count = count + quantity
        income = income + slot * 10 * quantity
    end
    w:openMerchant(); w:tick(0.16); equal(#w.sales, 12)
    w:tick(0.16); equal(#w.sales, 24)
    w:tick(0.16); equal(#w.sales, 25)
    w:tick(0.16)
    equal(w.money, 10000 + income)
    equal(w:hasMessage("Продано: " .. count .. " шт."), true)
    local summaries = 0
    for _, message in ipairs(w.messages) do
        if string.find(message, "Выручка:", 1, true) then summaries = summaries + 1 end
    end
    equal(summaries, 1)
end)

test("the next batch waits for delayed acknowledgements of the current batch", function()
    local w = world(); w:init(); w.saleDelay = 0.5
    for slot = 1, 25 do w:put(0, slot, slot, 0, 10) end
    w:openMerchant(); w:tick(0.16); equal(#w.sales, 12)
    w:tick(0.32); equal(#w.sales, 12)
    equal(w:hasMessage("Выручка:"), false)
    w:tick(2)
    equal(#w.sales, 25); equal(w.money, 10250)
    equal(w:hasMessage("Продано: 25 шт. Выручка: 0 з. 2 с. 50 м."), true)
end)

test("out-of-order acknowledgements do not duplicate income", function()
    local w = world(); w:init()
    w:put(0, 1, 1, 0, 10); w:put(0, 2, 2, 0, 30); w:put(0, 3, 3, 0, 50)
    w.saleDelays = { [1] = 0.8, [2] = 0.2, [3] = 0.5 }
    w:openMerchant(); w:tick(0.5)
    equal(w:hasMessage("Выручка:"), false)
    w:tick(1)
    equal(w.money, 10090)
    equal(w:hasMessage("Продано: 3 шт. Выручка: 0 з. 0 с. 90 м."), true)
end)

test("partial batch failure reports successful quantities and actual income", function()
    local w = world(); w:init()
    w:put(0, 1, 1, 0, 10, 2); w:put(0, 2, 2, 0, 100, 7); w:put(0, 3, 3, 0, 30, 3)
    w.failedSaleItems = { [2] = true }
    w:openMerchant(); w:tick(3)
    equal(#w.sales, 3); equal(w.money, 10110)
    equal(w.bags[0][2].count, 7)
    equal(w:hasMessage("Продано: 5 шт. Выручка: 0 з. 1 с. 10 м."), true)
    equal(w:hasMessage("Не удалось продать стаков: 1"), true)
end)

test("a rejected batch does not invent sales or income", function()
    local w = world(); w:init(); w.sellFails = true
    for slot = 1, 12 do w:put(0, slot, slot, 0, 10) end
    w:openMerchant(); w:tick(3)
    equal(w.money, 10000)
    equal(w:hasMessage("Выручка:"), false)
    equal(w:hasMessage("Не удалось продать стаков: 12"), true)
end)

test("a locked stack does not lose an already submitted partial batch", function()
    local w = world(); w:init()
    w:put(0, 1, 1, 0, 10)
    local locked = w:put(0, 2, 2, 0, 20); locked.locked = true
    w:put(0, 3, 3, 0, 30)
    w:openMerchant(); w:tick(0.5); equal(#w.sales, 1)
    locked.locked = false; w:tick(0.5)
    equal(#w.sales, 3); equal(w.money, 10060)
    equal(w:hasMessage("Продано: 3 шт. Выручка: 0 з. 0 с. 60 м."), true)
end)

test("a merchant close dispatched during a batch stops further submissions", function()
    local w = world(); w:init()
    for slot = 1, 20 do w:put(0, slot, slot, 0, 10) end
    w.onSaleSubmitted = function() w:closeMerchant() end
    w:openMerchant(); w:tick(1)
    equal(#w.sales, 1); equal(w.money, 10010)
    equal(w:hasMessage("Продано: 1 шт. Выручка: 0 з. 0 с. 10 м."), true)
end)

test("Ctrl-right cycle is consumed and applies to every copy", function()
    local w = world(); w:init(); w:put(0, 1, 1, 2, 50); w:put(0, 2, 1, 2, 50)
    local a, b = w:button(0, 1), w:button(0, 2)
    w:click(a, true); equal(w.env.ElriJunkDB.items[1], "sell")
    equal(b.ElriJunkOverlay:IsShown(), true)
    equal(b.ElriJunkOverlay.icon.texture, "Interface\\MoneyFrame\\UI-GoldIcon")
    w:click(a, true); equal(w.env.ElriJunkDB.items[1], "delete")
    w:click(a, true); equal(w.env.ElriJunkDB.items[1], nil)
    equal(b.ElriJunkOverlay:IsShown(), false); equal(w.originalClicks, 0)
end)

test("ordinary clicks and other modifiers preserve original behavior", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 50)
    local button = w:button(0, 1)
    w:click(button, false); w:click(button, true, "LeftButton")
    w.shift = true; w:click(button, true); w.shift = false
    w.alt = true; w:click(button, true)
    equal(w.originalClicks, 4); equal(w.env.ElriJunkDB.items[1], nil)
end)

test("uncached items wait for item data before choosing a mark", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    w.info[1].uncached = true; w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], nil); equal(w.originalClicks, 0)
    w.info[1].uncached = false; w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], "sell")
end)

test("unsellable items cycle directly between deletion and no mark", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 0)
    local button = w:button(0, 1)
    local before = #w.messages
    w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], "delete")
    equal(button.ElriJunkOverlay.icon.texture, "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], nil)
    equal(button.ElriJunkOverlay:IsShown(), false)
    w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], "delete")
    equal(#w.messages, before); equal(w.originalClicks, 0)
end)

test("unsellable items stay at the merchant and delete after confirmation", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 0, 2)
    w:click(w:button(0, 1), true)
    w:openMerchant(); w:tick()
    equal(#w.sales, 0); equal(w.bags[0][1].count, 2)
    w:closeMerchant(); w:clean()
    equal(type(w.popup), "table"); equal(#w.deleted, 0)
    w:accept(); w:tick()
    equal(#w.deleted, 1); equal(w.deleted[1].count, 2)
    equal(w.env.ElriJunkDB.items[1], "delete")
end)

test("unsellable deletion rules survive reload and apply to new drops", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 0)
    w:click(w:button(0, 1), true)
    local nextWorld = world(w.env.ElriJunkDB); nextWorld:init()
    nextWorld:put(0, 1, 1, 1, 0)
    equal(nextWorld:button(0, 1).ElriJunkOverlay:IsShown(), true)
    nextWorld:clean(); nextWorld:accept(); nextWorld:tick()
    equal(#nextWorld.deleted, 1)
end)

test("saved rules survive reload and apply to a new drop", function()
    local w = world(); w:init(); w:put(0, 1, 1, 2, 10)
    w:click(w:button(0, 1), true)
    local nextWorld = world(w.env.ElriJunkDB); nextWorld:init()
    nextWorld:put(0, 1, 1, 2, 10)
    equal(nextWorld:button(0, 1).ElriJunkOverlay:IsShown(), true)
    nextWorld:openMerchant(); nextWorld:tick(); equal(#nextWorld.sales, 1)
end)

test("saved rule keys are normalized without discarding valid marks", function()
    local w = world({ items = {
        ["123"] = "sell", [456] = "delete", [true] = "sell",
        bad = "delete", [-1] = "sell", ["0"] = "sell", [1.5] = "delete", [789] = "invalid",
    } }); w:init()
    equal(w.env.ElriJunkDB.items[123], "sell")
    equal(w.env.ElriJunkDB.items[456], "delete")
    equal(w.env.ElriJunkDB.items["123"], nil)
    local count = 0
    for _ in pairs(w.env.ElriJunkDB.items) do count = count + 1 end
    equal(count, 2)
end)

test("marks survive a serialized logout and login after the items are sold", function()
    local w = world(); w:init()
    w:put(0, 1, 1, 1, 10); w:put(0, 2, 2, 1, 0)
    w:click(w:button(0, 1), true); w:click(w:button(0, 2), true)
    w:openMerchant(); w:tick(); equal(#w.sales, 1)
    w:event("PLAYER_LOGOUT")
    local restored = world(copySavedVariables(w.env.ElriJunkDB)); restored:init()
    restored:event("PLAYER_LOGIN")
    equal(restored.env.ElriJunkDB.items[1], "sell")
    equal(restored.env.ElriJunkDB.items[2], "delete")
    restored:put(0, 1, 1, 1, 10)
    equal(restored:button(0, 1).ElriJunkOverlay:IsShown(), true)
    restored:openMerchant(); restored:tick(); equal(#restored.sales, 1)
end)

test("SavedVariables restored after initialization are rebound to the working database", function()
    local w = world(); w:init()
    local working = w.env.ElriJunkDB
    w.env.ElriJunkDB = { version = 1, items = { [1] = "sell", [2] = "delete" } }
    w:event("VARIABLES_LOADED")
    equal(w.env.ElriJunkDB, working)
    w:put(0, 1, 1, 1, 10)
    equal(w:button(0, 1).ElriJunkOverlay:IsShown(), true)
    w:openMerchant(); w:tick(); equal(#w.sales, 1)
    equal(w.env.ElriJunkDB.items[2], "delete")
end)

test("logout preserves local edits and removals when the global database is replaced", function()
    local w = world({ items = { [3] = "sell", [5] = "sell" } }); w:init()
    w:put(0, 1, 1, 1, 10); w:put(0, 2, 2, 1, 0)
    w:click(w:button(0, 1), true); w:click(w:button(0, 2), true)
    w.env.SlashCmdList.ELRIJUNK("unmark 3")
    w.env.ElriJunkDB = { items = { [1] = "delete", [2] = "sell", [3] = "sell", [4] = "sell" } }
    w:event("PLAYER_LOGOUT")
    local saved = copySavedVariables(w.env.ElriJunkDB)
    equal(saved.items[1], "sell"); equal(saved.items[2], "delete")
    equal(saved.items[3], nil); equal(saved.items[4], "sell"); equal(saved.items[5], "sell")
end)

test("a cleared SavedVariables global is restored before logout", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    w:click(w:button(0, 1), true)
    w.env.ElriJunkDB = nil
    w:event("PLAYER_LOGOUT")
    equal(copySavedVariables(w.env.ElriJunkDB).items[1], "sell")
end)

test("removing a mark through its cycle is not undone by a stale database restore", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    w:click(button, true)
    local old = copySavedVariables(w.env.ElriJunkDB)
    w:click(button, true); w:click(button, true)
    w.env.ElriJunkDB = old
    w:event("PLAYER_LOGOUT")
    equal(w.env.ElriJunkDB.items[1], nil)
end)

test("removing a grey rule restores automatic sale", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 10)
    local button = w:button(0, 1)
    for i = 1, 3 do w:click(button, true) end
    w:openMerchant(); w:tick(); equal(#w.sales, 1)
end)

test("passive cleanup prompts without opening or closing bags", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w.env.ContainerFrame1:Show(); w.env.ContainerFrame2:Show()
    w:tick(0.5); equal(w.popup, nil)
    w:tick(22); equal(type(w.popup), "table"); equal(#w.deleted, 0)
    equal(w.env.ContainerFrame1:IsShown(), true)
    equal(w.env.ContainerFrame2:IsShown(), true)
end)

test("the first marked item starts a twenty-second timer that later loot does not extend", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(19); equal(w.popup, nil)
    w:put(0, 2, 2, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(1.3)
    equal(type(w.popup), "table"); equal(#w.popup.data, 2)
    equal(#w.deleted, 0)
end)

test("confirmation waits for loot to close even after the timer expires", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:event("LOOT_OPENED")
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(22); equal(w.popup, nil)
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "открыто окно добычи", 1, true) ~= nil, true)
    w:event("LOOT_CLOSED"); w:tick(1.2)
    equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("the visible default loot window also blocks confirmation", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    local loot = w.env.CreateFrame("Frame", "LootFrame")
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(22); equal(w.popup, nil)
    loot:Hide(); w:tick(1.2)
    equal(type(w.popup), "table")
end)

test("an empty pending batch resets the timer for the next acquisition", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(10)
    w.bags[0][1] = nil; w:event("BAG_UPDATE", 0); w:tick(2)
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(19); equal(w.popup, nil)
    w:tick(1.5); equal(type(w.popup), "table")
end)

test("unmarked loot does not start the deletion collection timer", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 2, 1, 0); w:event("BAG_UPDATE", 0); w:tick(19)
    w:put(0, 2, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(1.2); equal(w.popup, nil)
    w:tick(19.2); equal(type(w.popup), "table")
end)

test("a new drop after completing a batch gets its own twenty-second delay", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0); w:tick(20.2)
    w:accept(); w:tick(0.5); equal(#w.deleted, 1)
    w:event("BAG_UPDATE", 0)
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(19); equal(w.popup, nil)
    w:tick(1.5); equal(type(w.popup), "table"); equal(#w.deleted, 1)
end)

test("items received during confirmation are delayed without joining the accepted batch", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0); w:tick(20.2)
    equal(#w.popup.data, 1)
    w:put(0, 2, 2, 1, 0); w:event("BAG_UPDATE", 0)
    w:accept(); w:tick(19)
    equal(#w.deleted, 1); equal(w.deleted[1].id, 1); equal(w.popup, nil)
    w:tick(1.5)
    equal(type(w.popup), "table"); equal(#w.popup.data, 1); equal(w.popup.data[1].id, 2)
end)

test("manual cleanup bypasses the collection delay", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:event("BAG_UPDATE", 0)
    w:tick(1); equal(w.popup, nil)
    w:clean(); equal(type(w.popup), "table")
    w:accept(); w:tick(0.5); equal(#w.deleted, 1)
end)

test("opening loot hides an existing reminder until looting finishes", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 0); w:clean(); equal(type(w.popup), "table")
    w:event("LOOT_OPENED"); equal(w.popup, nil)
    w:tick(2); equal(w.popup, nil)
    w:event("LOOT_CLOSED"); w:tick(1.2)
    equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("a new deletion mark triggers passive confirmation after the batch collection delay", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 0)
    w:click(w:button(0, 1), true)
    equal(w.popup, nil)
    w:tick(0.5); equal(w.popup, nil)
    w:tick(20); equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("passive cleanup retries after blocked conditions clear without bag events", function()
    for _, state in ipairs({ "cursor", "combat", "dead", "merchant", "BankFrame", "GuildBankFrame",
        "MailFrame", "TradeFrame", "AuctionFrame" }) do
        local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
        local clear
        if state == "cursor" then
            w.cursor = { id = 99 }; clear = function() w.cursor = nil end
        elseif state == "merchant" then
            w:openMerchant(); clear = function() w:closeMerchant() end
        elseif state == "combat" or state == "dead" then
            w[state] = true; clear = function() w[state] = false end
        else
            local window = w.env.CreateFrame("Frame", state)
            clear = function() window:Hide() end
        end
        w:tick(22); equal(w.popup, nil, state .. " should block cleanup")
        clear(); w:tick(1.5)
        equal(type(w.popup), "table", state .. " should resume cleanup")
        equal(#w.deleted, 0)
    end
end)

test("locked items are offered after unlocking without another bag event", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    local item = w:put(0, 1, 1, 1, 10); item.locked = true
    w:tick(22); equal(w.popup, nil)
    item.locked = false; w:tick(1.5)
    equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("a locked stack does not block confirmation for unlocked deletion items", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    local locked = w:put(0, 1, 1, 1, 0, 2); locked.locked = true
    w:put(0, 2, 2, 1, 0)
    w:tick(22)
    equal(type(w.popup), "table")
    equal(#w.popup.data, 1); equal(w.popup.data[1].id, 2)
    w:accept(); w:tick(0.5)
    equal(#w.deleted, 1); equal(w.deleted[1].id, 2)
    equal(w.bags[0][1].count, 2)
    locked.locked = false; w:tick(1.5)
    equal(type(w.popup), "table"); equal(w.popup.data[1].id, 1)
    w:accept(); w:tick(0.5); equal(#w.deleted, 2)
end)

test("closing a full batch delays reminders briefly without disabling its unlocked subset", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    local locked = w:put(0, 1, 1, 1, 0); locked.locked = true
    w:put(0, 2, 2, 1, 0)
    w:clean(); equal(#w.popup.data, 2); w:cancel()
    w:tick(2); equal(w.popup, nil)
    locked.locked = false; w:tick(2); equal(w.popup, nil)
    w:tick(7); equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("passive cleanup waits for other dialogs and held modifiers", function()
    for _, state in ipairs({ "dialog", "ctrl", "shift", "alt" }) do
        local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
        local dialog
        if state == "dialog" then dialog = w.env.CreateFrame("Frame", "StaticPopup1")
        else w[state] = true end
        w:tick(22); equal(w.popup, nil)
        if dialog then dialog:Hide() else w[state] = false end
        w:tick(1.5); equal(type(w.popup), "table")
    end
end)

test("an unavailable popup slot is retried instead of losing the request", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w.popupUnavailable = true; w:tick(22)
    equal(w.popup, nil); equal(w.popupAttempts, 1)
    w.popupUnavailable = false; w:tick(1.2)
    equal(type(w.popup), "table"); equal(w.popupAttempts, 2)
end)

test("a closed reminder returns after ten seconds without inventory changes", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 10, 2); w:put(0, 2, 1, 1, 10, 3)
    w:tick(22); w:cancel()
    w:tick(3); equal(w.popup, nil)
    w:tick(8); equal(type(w.popup), "table")
    equal(#w.deleted, 0)
end)

test("manual cleanup and a new cross can reopen a dismissed batch", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 0)
    local button = w:button(0, 1)
    w:click(button, true); w:tick(22); w:cancel()
    w:clean(); equal(type(w.popup), "table"); w:cancel()
    w:click(button, true); w:click(button, true)
    w:tick(20.2); equal(type(w.popup), "table")
end)

test("an overridden dialog does not suppress later reminders", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:tick(22); w:cancel("override"); w:tick(1.2)
    equal(type(w.popup), "table")
end)

test("cleanup resumes after entering the world again", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:event("PLAYER_LEAVING_WORLD"); w:tick(3); equal(w.popup, nil)
    w:event("PLAYER_ENTERING_WORLD"); w:tick(20.2)
    equal(type(w.popup), "table")
end)

test("rejected deletion does not nag and can be retried manually", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:tick(22); w.deleteFails = true; w:accept(); w:tick(3)
    equal(w.popup, nil); equal(#w.deleted, 0)
    w.deleteFails = false; w:clean(); w:accept(); w:tick(1)
    equal(#w.deleted, 1)
end)

test("a transient deletion failure retries after a delay and still requires confirmation", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:tick(22); w.deleteFails = true; w:accept(); w:tick(0.16)
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(w:hasMessage("повтор после ошибки через 5 с"), true)
    w.deleteFails = false
    w:tick(3); equal(w.popup, nil); equal(#w.deleted, 0)
    w:tick(3); equal(type(w.popup), "table"); equal(#w.deleted, 0)
    w:accept(); w:tick(0.5); equal(#w.deleted, 1)
end)

test("cancelling confirmation never deletes", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:clean(); w:cancel(); w:tick(3)
    equal(#w.deleted, 0); equal(w.popup, nil)
end)

test("confirmation deletes all marked stacks and retains rules", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 10, 3); w:put(4, 1, 1, 1, 10, 2); w:put(0, 2, 2, 1, 20)
    w:clean(); equal(#w.deleted, 0); w:accept(); w:tick()
    equal(#w.deleted, 2); equal(w.env.ElriJunkDB.items[1], "delete")
    equal(w:hasMessage("Удалено: 5 шт."), true)
end)

test("moved items and replacement slot occupants are skipped", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:clean(); w.bags[0][2] = w.bags[0][1]; w:put(0, 1, 2, 1, 10)
    w:accept(); w:tick(); equal(#w.deleted, 0)
end)

test("changed stack count is skipped", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); local item = w:put(0, 1, 1, 1, 10, 2)
    w:clean(); item.count = 3; w:accept(); w:tick(); equal(#w.deleted, 0)
end)

test("changed rules and newly acquired stacks are not deleted", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:clean(); w.env.ElriJunkDB.items[1] = "sell"; w:put(0, 2, 1, 1, 10)
    w:accept(); w:tick(); equal(#w.deleted, 0)
end)

test("new stacks added after confirmation are excluded from the batch", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:clean(); w:put(0, 2, 1, 1, 10); w:accept(); w:tick()
    equal(#w.deleted, 1); equal(w.bags[0][2].id, 1)
end)

test("locked items are not deleted", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); local item = w:put(0, 1, 1, 1, 10)
    w:clean(); item.locked = true; w:accept(); w:tick(); equal(#w.deleted, 0)
end)

test("busy cursor, combat, death and merchant suppress cleanup", function()
    for _, state in ipairs({ "cursor", "combat", "dead", "merchant" }) do
        local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
        if state == "cursor" then w.cursor = { id = 99 }
        elseif state == "merchant" then w.env.MerchantFrame:Show()
        else w[state] = true end
        w:clean(); equal(w.popup, nil); equal(#w.deleted, 0)
    end
end)

test("bank, mail, trade and auction windows suppress cleanup", function()
    for _, name in ipairs({ "BankFrame", "GuildBankFrame", "MailFrame", "TradeFrame", "AuctionFrame" }) do
        local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
        w.env[name] = w.env.CreateFrame("Frame", name)
        w:clean(); equal(w.popup, nil)
    end
end)

test("combat during deletion stops the remaining batch", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 10); w:put(0, 2, 1, 1, 10)
    w:clean(); w:accept(); w:tick(0.16); equal(#w.deleted, 1)
    w.combat = true; w:event("PLAYER_REGEN_DISABLED"); w:tick(); equal(#w.deleted, 1)
end)

test("cursor becoming busy after acceptance prevents deletion", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
    w:clean(); w:accept(); w.cursor = { id = 99 }; w:tick()
    equal(#w.deleted, 0); equal(w.cursor.id, 99)
end)

test("failed pickup and rejected delete preserve items", function()
    for _, failure in ipairs({ "pickupFails", "deleteFails" }) do
        local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 10)
        w[failure] = true; w:clean(); w:accept(); w:tick()
        equal(#w.deleted, 0); equal(w.bags[0][1].id, 1); equal(w.cursor, nil)
    end
end)

test("sale waits for server acknowledgement before reporting revenue", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42, 3); w.saleDelay = 0.8
    w:openMerchant(); w:tick(0.4); equal(w:hasMessage("Выручка:"), false)
    w:tick(1); equal(w:hasMessage("Выручка: 0 з. 1 с. 26 м."), true)
end)

test("late sale acknowledgement after merchant close is counted", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42); w.saleDelay = 0.5
    w:openMerchant(); w:tick(0.16); w:closeMerchant(); w:tick(1)
    equal(w:hasMessage("Выручка: 0 з. 0 с. 42 м."), true)
end)

test("rapid merchant reopen never resubmits an unacknowledged stack", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42); w:put(0, 2, 2, 0, 60)
    w.saleDelay = 0.5
    w:openMerchant(); w:tick(0.16); w:closeMerchant(); w:openMerchant(); w:tick(2)
    equal(#w.sales, 2); equal(w.money, 10102)
end)

test("opening merchant during deletion interrupts it and starts selling", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 42); w:put(0, 2, 1, 1, 42); w:put(0, 3, 2, 0, 60)
    w:clean(); w:accept(); w:tick(0.16); equal(#w.deleted, 1)
    w:openMerchant(); w:tick()
    equal(#w.deleted, 1); equal(#w.sales, 1); equal(w.sales[1].id, 2)
end)

test("failed sale does not report imaginary income", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42); w.sellFails = true
    w:openMerchant(); w:tick(3); equal(w:hasMessage("Выручка:"), false)
    equal(w:hasMessage("Не удалось продать стаков: 1"), true)
end)

test("moving a pending stack without income is not a sale", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42); w.sellFails = true
    w:openMerchant(); w:tick(0.16); w.bags[0][2] = w.bags[0][1]; w.bags[0][1] = nil
    w:tick(3); equal(w:hasMessage("Выручка:"), false)
end)

test("merchant close stops the unsent part of the queue", function()
    local w = world(); w:init()
    for slot = 1, 20 do w:put(0, slot, slot, 0, 42) end
    w:openMerchant(); w:tick(0.16); w:closeMerchant(); w:tick()
    equal(#w.sales, 12); equal(w.money, 10000 + 12 * 42)
end)

test("changed sale slot is revalidated", function()
    local w = world(); w:init(); w:put(0, 1, 1, 0, 42)
    w:openMerchant(); w:put(0, 1, 2, 4, 10000); w:tick(); equal(#w.sales, 0)
end)

test("uncached item data and temporary locks are retried", function()
    local w = world(); w:init(); local item = w:put(0, 1, 1, 0, 42)
    w.info[1].uncached = true; item.locked = true
    w:openMerchant(); w:tick(0.5); equal(#w.sales, 0)
    w.info[1].uncached = false; item.locked = false; w:tick(); equal(#w.sales, 1)
end)

test("repair mode and combat do not sell", function()
    for _, state in ipairs({ "repair", "combat" }) do
        local w = world(); w:init(); w:put(0, 1, 1, 0, 42); w[state] = true
        w:openMerchant(); w:tick(); equal(#w.sales, 0)
    end
end)

test("bank and keyring contents are excluded", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    w:put(5, 1, 1, 0, 42); w:put(-2, 1, 1, 0, 42)
    w:openMerchant(); w:tick(); w:closeMerchant(); w:clean()
    equal(#w.sales, 0); equal(w.popup, nil)
end)

test("ArkInventory live bag marks, offline exclusion and passive cleanup", function()
    local w = world()
    local env = w.env
    env.ArkInventory = { Const = { Location = { Bag = 1 }, Frame = { Main = { Name = "ARKINV_Frame" } } },
        Global = { Location = { [1] = {}, [2] = {} }, Mode = {} } }
    local ark = env.ArkInventory
    function ark.BagID_Blizzard(_, bag) return bag - 1 end
    function ark.Frame_Item_OnLoad() end
    function ark.Frame_Main_OnShow() end
    local window = env.CreateFrame("Frame", "ARKINV_Frame1")
    window.ARK_Data = { loc_id = 1 }; window:Hide()
    w:init(); w:put(0, 1, 1, 1, 42)
    window:Show(); ark.Frame_Main_OnShow(window)
    local button = env.CreateFrame("Button", "ArkItem", window)
    button.ARK_Data = { loc_id = 1, bag_id = 1, slot_id = 1 }
    button:SetScript("OnClick", function(_, mouseButton)
        w.originalClicks = w.originalClicks + 1
        if mouseButton == "RightButton" and not w.ctrl then env.UseContainerItem(0, 1) end
    end)
    ark.Frame_Item_OnLoad(button)
    w:click(button, false); equal(#w.used, 1)
    w:click(button, true); equal(env.ElriJunkDB.items[1], "sell")
    ark.Global.Location[1].isOffline = true
    w:click(button, true); equal(env.ElriJunkDB.items[1], "sell")
    ark.Global.Location[1].isOffline = false
    w:click(button, true); equal(env.ElriJunkDB.items[1], "delete")
    w:tick(20.2); equal(type(w.popup), "table")
    equal(window:IsShown(), true)
end)

test("preexisting buttons are discovered without duplicate click wrapping", function()
    local w = world(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1); w:init(); w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], "sell")
    w.env.ContainerFrameItemButton_OnLoad(button); w:click(button, true)
    equal(w.env.ElriJunkDB.items[1], "delete")
end)

test("unmark command works without the item in bags", function()
    local w = world({ items = { [42] = "delete" } }); w:init()
    w.env.SlashCmdList.ELRIJUNK("unmark 42"); equal(w.env.ElriJunkDB.items[42], nil)
end)

test("version command reports the running code even if TOC metadata is stale", function()
    local w = world(); w:init()
    w.env.GetAddOnMetadata = function() return "1.0.0" end
    for _, command in ipairs({ "version", "ver", " VERSION " }) do
        local before = #w.messages
        w.env.SlashCmdList.ELRIJUNK(command)
        equal(#w.messages, before + 1)
        equal(string.find(w.messages[#w.messages], "Загруженная версия: 1.0.8.", 1, true) ~= nil, true)
    end
end)

test("status command reports ready items, locks and active blockers", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    local locked = w:put(0, 1, 1, 1, 0, 2); locked.locked = true
    w:put(0, 2, 2, 1, 0)
    w:event("BAG_UPDATE", 0)
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(w:hasMessage("К удалению: 3 шт. (2 стаков); заблокировано стаков: 1."), true)
    equal(w:hasMessage("сбор добычи; подтверждение через 20 с"), true)
    w.combat = true; w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "идёт бой", 1, true) ~= nil, true)
    w.combat = false; w.cursor = { id = 99 }
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "курсор занят", 1, true) ~= nil, true)
    equal(w.popup, nil); equal(#w.deleted, 0)
end)

test("status command explains all-locked items and an already shown confirmation", function()
    local w = world({ items = { [1] = "delete" } }); w:init()
    local item = w:put(0, 1, 1, 1, 0); item.locked = true
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "ожидание разблокировки предметов", 1, true) ~= nil, true)
    item.locked = false; w:clean()
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "подтверждение уже показано", 1, true) ~= nil, true)
end)

test("status command shows the next reminder time without a cancelled-batch state", function()
    local w = world({ items = { [1] = "delete" } }); w:init(); w:put(0, 1, 1, 1, 0)
    w:clean(); w:cancel()
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "следующее напоминание через 10 с", 1, true) ~= nil, true)
    equal(w:hasMessage("партия отменена"), false)
    w:tick(3); equal(w.popup, nil); equal(#w.deleted, 0)
    w:tick(8); equal(type(w.popup), "table"); equal(#w.deleted, 0)
end)

test("status command reports no marked items and a paused world timer", function()
    local w = world(); w:init()
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "нет вещей с крестиком", 1, true) ~= nil, true)
    w:event("PLAYER_LEAVING_WORLD")
    w.env.SlashCmdList.ELRIJUNK("status")
    equal(string.find(w.messages[#w.messages], "автопроверка приостановлена", 1, true) ~= nil, true)
end)

test("marking and unmarking items do not write to chat", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    local before = #w.messages
    for i = 1, 3 do w:click(button, true) end
    equal(#w.messages, before)
    w:click(button, true)
    w.env.SlashCmdList.ELRIJUNK("unmark 1")
    equal(#w.messages, before)
end)

test("compact deletion prompt retains quantities, items and vendor value", function()
    local w = world({ items = { [1] = "delete", [2] = "delete" } }); w:init()
    w:put(0, 1, 1, 1, 10, 2); w:put(0, 2, 2, 1, 30)
    w:clean()
    local text = assert(w.popup).text
    equal(string.find(text, "3 шт. (2 стаков)", 1, true) ~= nil, true)
    equal(string.find(text, w.info[1].link, 1, true) ~= nil, true)
    equal(string.find(text, w.info[2].link, 1, true) ~= nil, true)
    equal(string.find(text, "0 з. 0 с. 50 м.", 1, true) ~= nil, true)
    equal(string.find(text, "\n\n", 1, true), nil)
    equal(string.find(text, "Метки сохранятся", 1, true), nil)
end)

test("ordinary item use keeps a secure execution path in and out of combat", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    w.useItemsOnClick = true
    w:click(button, false); equal(#w.used, 1)
    w.combat = true; w:event("PLAYER_REGEN_DISABLED")
    w:click(button, false); equal(#w.used, 2)
    w:click(button, true); equal(w.env.ElriJunkDB.items[1], "sell")
    equal(#w.used, 2)
end)

test("post-click addon hooks run after protected item use", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    w.useItemsOnClick = true
    local callbacks = 0
    button:HookScript("PostClick", function()
        equal(#w.used, 1)
        equal(w.tainted, true)
        callbacks = callbacks + 1
    end)
    w:click(button, false)
    equal(callbacks, 1)
end)

test("buttons created in combat defer wrapping and remain usable", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    w.combat = true
    local button = w:button(0, 1)
    equal(button.secureWraps, nil)
    w.useItemsOnClick = true
    w:click(button, false); equal(#w.used, 1)
    w:click(button, true); equal(w.env.ElriJunkDB.items[1], "sell")
    w.combat = false; w:event("PLAYER_REGEN_ENABLED")
    equal(button.secureWraps, 1)
    w:click(button, true); equal(w.env.ElriJunkDB.items[1], "delete")
    w:click(button, false); equal(#w.used, 2)
    w:event("PLAYER_REGEN_ENABLED"); equal(button.secureWraps, 1)
end)

test("protected buttons do not receive attribute writes in combat", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    button.protected = true
    w.combat = true
    w:tick(0.5)
    w:click(button, true); equal(w.env.ElriJunkDB.items[1], "sell")
    equal(w.originalClicks, 0)
    w.useItemsOnClick = true
    w:click(button, false); equal(#w.used, 1)
end)

test("bank buttons retain their original modified-click behavior", function()
    local w = world(); w:init(); w:put(0, 1, 1, 1, 10)
    local button = w:button(0, 1)
    button:GetParent():SetID(5)
    button:RunScript("OnShow")
    w:click(button, true)
    equal(w.originalClicks, 1)
    equal(w.env.ElriJunkDB.items[1], nil)
end)

print(string.format("%d behavioral tests passed (Lua %s).", passed, _VERSION))
