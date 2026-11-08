-- ElriJunk: World of Warcraft 3.3.5a.
local ADDON_NAME = "ElriJunk"
local ADDON_VERSION = "1.0.8"
local DELETE_POPUP = "ELRIJUNK_CONFIRM_DELETE"
local SELL, DELETE = "sell", "delete"
local FIRST_BAG, LAST_BAG = 0, 4
local UPDATE_INTERVAL = 0.15
local CLEANUP_INTERVAL = 1
local CLEANUP_BATCH_DELAY = 20
local CLEANUP_RETRY_DELAY = 5
local CLEANUP_REMINDER_DELAY = 10
local SALE_TIMEOUT = 2
local SALE_BATCH_SIZE = 12
local ITEM_READY_TIMEOUT = 5
local CURSOR_TIMEOUT = 5
local PREVIEW_LIMIT = 6

local MARK_CLICK = [[
    if button == "RightButton" and IsControlKeyDown()
        and not IsShiftKeyDown() and not IsAltKeyDown()
        and self:GetAttribute("elrijunk-markable") then
        return false
    end
]]

local BLOCKING_WINDOWS = {
    { "BankFrame", "открыт банк" },
    { "GuildBankFrame", "открыт банк гильдии" },
    { "MailFrame", "открыта почта" },
    { "TradeFrame", "открыт обмен" },
    { "AuctionFrame", "открыт аукцион" },
}

local frame = CreateFrame("Frame", "ElriJunkFrame")
local buttons = {}
local db, sale, deletion, cleanupAt
local cleanupRetryAt
local cleanupReminderAt
local cleanupBatchReadyAt
local pendingDeletionCounts = {}
local looting = false
local changedRules = {}
local clickHandler
local updateElapsed = 0

local function printMessage(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ElriJunk:|r " .. message)
end

local function normalizeRules(items)
    local rules = {}
    if type(items) ~= "table" then return rules end

    for key, rule in pairs(items) do
        local id = (type(key) == "number" or type(key) == "string") and tonumber(key)
        if id and id > 0 and id == math.floor(id) and (rule == SELL or rule == DELETE) then
            if type(key) == "number" or rules[id] == nil then rules[id] = rule end
        end
    end
    return rules
end

local function synchronizeDatabase()
    if not db or ElriJunkDB == db then return end

    -- Keep local edits, including removals, if a late restore replaces the
    -- SavedVariables table. Publish the working table before logout.
    if type(ElriJunkDB) == "table" and ElriJunkDB ~= db then
        for id, rule in pairs(normalizeRules(ElriJunkDB.items)) do
            if changedRules[id] == nil then db.items[id] = rule end
        end
    end
    ElriJunkDB = db
end

local function setItemRule(id, rule)
    db.items[id] = rule
    changedRules[id] = rule or false
end

local function formatMoney(amount)
    amount = math.max(0, math.floor(amount or 0))
    local gold = math.floor(amount / 10000)
    local silver = math.floor(amount / 100) % 100
    local copper = amount % 100

    return string.format("%d з. %d с. %d м.", gold, silver, copper)
end

local function getItemID(link)
    return link and tonumber(string.match(link, "item:(%d+)"))
end

local function getBagItem(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    local id = getItemID(link)
    if not id then return end

    local _, count, locked, bagQuality = GetContainerItemInfo(bag, slot)
    local _, _, quality, _, _, _, _, _, _, _, price = GetItemInfo(link)

    return {
        bag = bag,
        slot = slot,
        link = link,
        id = id,
        count = count or 1,
        locked = locked,
        quality = quality or bagQuality,
        price = price,
    }
end

local function collectDeletionItems()
    local items, count, lockedStacks = {}, 0, 0
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, GetContainerNumSlots(bag) do
            local id = getItemID(GetContainerItemLink(bag, slot))
            local item = id and db.items[id] == DELETE and getBagItem(bag, slot)
            if item and db.items[item.id] == DELETE then
                table.insert(items, item)
                count = count + item.count
                if item.locked then lockedStacks = lockedStacks + 1 end
            end
        end
    end
    return items, count, lockedStacks
end

local function updateCleanupBatch()
    local items = collectDeletionItems()
    local counts = {}
    for _, item in ipairs(items) do
        counts[item.id] = (counts[item.id] or 0) + item.count
    end

    if #items == 0 then
        cleanupBatchReadyAt = nil
    elseif not cleanupBatchReadyAt then
        for id, count in pairs(counts) do
            if count > (pendingDeletionCounts[id] or 0) then
                cleanupBatchReadyAt = GetTime() + CLEANUP_BATCH_DELAY
                break
            end
        end
    end
    pendingDeletionCounts = counts
end

local function isSameStack(a, b)
    return a and b and a.link == b.link and a.count == b.count
end

local function shouldSell(item)
    local rule = db.items[item.id]
    return rule ~= DELETE and (rule == SELL or item.quality == 0)
end

local function isMerchantOpen()
    return MerchantFrame and MerchantFrame:IsShown()
end

local function canSell()
    return isMerchantOpen() and MerchantFrame.selectedTab ~= 2
        and not InRepairMode() and not InCombatLockdown()
        and not UnitIsDeadOrGhost("player")
end

local function getDeletionBlockReason()
    if isMerchantOpen() then return "открыт торговец" end
    if InCombatLockdown() then return "идёт бой" end
    if UnitIsDeadOrGhost("player") then return "персонаж мёртв" end
    if looting or (LootFrame and LootFrame:IsShown()) then return "открыто окно добычи" end

    for _, entry in ipairs(BLOCKING_WINDOWS) do
        local window = _G[entry[1]]
        if window and window:IsShown() then return entry[2] end
    end

    if GetCursorInfo() then return "курсор занят" end
end

local function canDelete()
    return getDeletionBlockReason() == nil
end

local function getButtonSlot(button)
    if button.ARK_Data then
        local ark, data = ArkInventory, button.ARK_Data
        if not ark or data.loc_id ~= ark.Const.Location.Bag then return end

        local location = ark.Global.Location[data.loc_id]
        if location.isOffline or ark.Global.Mode.Edit then return end

        local bag = ark.BagID_Blizzard(data.loc_id, data.bag_id)
        if bag and bag >= FIRST_BAG and bag <= LAST_BAG then
            return bag, data.slot_id
        end
        return
    end

    local parent = button:GetParent()
    local bag, slot = parent and parent:GetID(), button:GetID()
    if bag and bag >= FIRST_BAG and bag <= LAST_BAG and slot and slot > 0 then
        return bag, slot
    end
end

local function updateButtonMark(button)
    local overlay = button.ElriJunkOverlay
    if not db or not overlay then return end

    local bag, slot = getButtonSlot(button)
    if not InCombatLockdown() then
        local markable = bag ~= nil
        if button:GetAttribute("elrijunk-markable") ~= markable then
            button:SetAttribute("elrijunk-markable", markable)
        end
    end

    local id = bag and getItemID(GetContainerItemLink(bag, slot))
    local rule = id and db.items[id]
    if not rule then
        overlay:Hide()
        return
    end

    overlay:SetFrameLevel(button:GetFrameLevel() + 6)
    if rule == SELL then
        overlay.icon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
        overlay.icon:SetWidth(14)
        overlay.icon:SetHeight(14)
    else
        overlay.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        overlay.icon:SetWidth(18)
        overlay.icon:SetHeight(18)
    end
    overlay:Show()
end

local function refreshMarks()
    for button in pairs(buttons) do
        if button:IsShown() then updateButtonMark(button) end
    end
end

local function cycleItemRule(button, mouseButton)
    if not db or mouseButton ~= "RightButton" or not IsControlKeyDown()
        or IsShiftKeyDown() or IsAltKeyDown() then
        return false
    end

    local bag, slot = getButtonSlot(button)
    if not bag then return false end

    local item = getBagItem(bag, slot)
    if not item then return true end
    synchronizeDatabase()

    if not item.price then
        printMessage("Данные вещи ещё загружаются. Повторите Ctrl+ПКМ.")
        return true
    end

    local rule = db.items[item.id]
    if rule == DELETE then
        setItemRule(item.id, nil)
    elseif rule == SELL or item.price <= 0 then
        setItemRule(item.id, DELETE)
    else
        setItemRule(item.id, SELL)
    end

    if db.items[item.id] == DELETE then
        cleanupRetryAt = nil
        cleanupReminderAt = nil
    end
    updateCleanupBatch()
    cleanupAt = GetTime() + CLEANUP_INTERVAL
    refreshMarks()
    return true
end

local function wrapItemClick(button)
    if buttons[button].wrapped or InCombatLockdown() then return end

    if not clickHandler then
        clickHandler = CreateFrame("Frame", nil, nil, "SecureFrameTemplate")
    end

    -- Only Blizzard's secure wrapper may call the original item-use handler.
    -- Mark changes run separately in PostClick, after the protected action.
    SecureHandlerWrapScript(button, "OnClick", clickHandler, MARK_CLICK)
    buttons[button].wrapped = true
end

local function attachItemButton(button)
    if buttons[button] then return end
    buttons[button] = {}

    local overlay = CreateFrame("Frame", nil, button)
    overlay:SetAllPoints(button)
    overlay:EnableMouse(false)
    overlay.icon = overlay:CreateTexture(nil, "OVERLAY")
    overlay.icon:SetPoint("TOPLEFT", overlay, "TOPLEFT", 1, -1)
    button.ElriJunkOverlay = overlay
    overlay:Hide()

    button:HookScript("PostClick", cycleItemRule)
    button:HookScript("OnShow", updateButtonMark)
    updateButtonMark(button)
    wrapItemClick(button)
end

local function finishSale()
    if not sale then return end
    if sale.count > 0 then
        printMessage(string.format("Продано: %d шт. Выручка: %s.", sale.count, formatMoney(sale.profit)))
    end
    if sale.failed > 0 then
        printMessage(string.format("Не удалось продать стаков: %d. Повторите открытие торговца.", sale.failed))
    end
    sale = nil
end

local function confirmSale()
    local pending = sale and sale.pending
    if not pending then return true end

    local soldCount, soldStacks = 0, 0
    for _, item in ipairs(pending.items) do
        local current = getBagItem(item.bag, item.slot)
        local removed = item.count
        if current and current.link == item.link then
            removed = item.count - current.count
        end
        if removed > 0 then
            soldCount = soldCount + math.min(removed, item.count)
            soldStacks = soldStacks + 1
        end
    end
    local income = GetMoney() - pending.money
    local confirmed = soldCount > 0 and income > 0
    local complete = confirmed and soldStacks == #pending.items

    if not complete and GetTime() - pending.sent < SALE_TIMEOUT then return false end

    -- Money is shared by the whole batch; credit it once, after the bag updates.
    -- A missing stack without received money is not counted as a sale.
    if confirmed then
        sale.count = sale.count + soldCount
        sale.profit = sale.profit + income
        sale.failed = sale.failed + #pending.items - soldStacks
    else
        sale.failed = sale.failed + #pending.items
    end
    sale.pending = nil
    return true
end

local function startSale()
    if deletion then return end
    if sale then
        -- A quick close/reopen must not submit the same pending stack twice.
        if not confirmSale() then
            sale.restart = true
            return
        end
        finishSale()
    end
    sale = {
        queue = {},
        next = 1,
        count = 0,
        profit = 0,
        failed = 0,
    }

    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, GetContainerNumSlots(bag) do
            local item = getBagItem(bag, slot)
            if item and db.items[item.id] ~= DELETE
                and (shouldSell(item) or item.quality == nil) then
                item.expires = GetTime() + ITEM_READY_TIMEOUT
                table.insert(sale.queue, item)
            end
        end
    end
end

local function updateSale()
    if not sale then return end
    if not confirmSale() then return end
    if not canSell() then
        finishSale()
        return
    end
    if sale.restart then
        startSale()
        return
    end

    if GetCursorInfo() then
        sale.cursorAt = sale.cursorAt or GetTime()
        if GetTime() - sale.cursorAt >= CURSOR_TIMEOUT then finishSale() end
        return
    end
    sale.cursorAt = nil

    local activeSale = sale
    local batch = { items = {} }
    while sale.next <= #sale.queue and #batch.items < SALE_BATCH_SIZE do
        if not canSell() or GetCursorInfo() then break end

        local queued = sale.queue[sale.next]
        local current = getBagItem(queued.bag, queued.slot)
        local matches = isSameStack(queued, current) and db.items[current.id] ~= DELETE
        local ready = matches and current.quality ~= nil and current.price ~= nil and not current.locked
        if matches and not ready and GetTime() < queued.expires then break end
        sale.next = sale.next + 1

        if matches then
            if not ready then
                sale.failed = sale.failed + 1
            elseif shouldSell(current) and current.price > 0 then
                if #batch.items == 0 then
                    batch.money, batch.sent = GetMoney(), GetTime()
                    sale.pending = batch
                end
                table.insert(batch.items, current)
                -- UseContainerItem sells directly at the merchant; it never takes over the cursor.
                UseContainerItem(current.bag, current.slot)
                if sale ~= activeSale then return end
            end
        end
    end

    if sale.pending then return end
    if sale.next > #sale.queue or not canSell() then finishSale() end
end

local function finishDeletion(reason, retryLater)
    if not deletion then return end
    if retryLater then cleanupRetryAt = GetTime() + CLEANUP_RETRY_DELAY end
    if deletion.count > 0 then printMessage(string.format("Удалено: %d шт.", deletion.count)) end
    if deletion.skipped > 0 then
        printMessage(string.format("Пропущено изменённых или заблокированных стаков: %d.", deletion.skipped))
    end
    if reason then printMessage(reason) end
    deletion = nil
end

local function updateDeletion()
    if not deletion then return end

    if not canDelete() then
        finishDeletion("Удаление приостановлено. Подтверждение появится, когда условия позволят.")
        return
    end

    local entry = deletion.queue[deletion.next]
    if not entry then
        finishDeletion()
        return
    end
    deletion.next = deletion.next + 1

    local current = getBagItem(entry.bag, entry.slot)
    if not isSameStack(entry, current) or current.locked or db.items[entry.id] ~= DELETE then
        deletion.skipped = deletion.skipped + 1
        return
    end

    PickupContainerItem(entry.bag, entry.slot)
    local kind, id, link = GetCursorInfo()
    if kind ~= "item" or id ~= entry.id or (link and link ~= entry.link) then
        -- Only our own pickup can reach this branch: the cursor was empty above.
        if kind then ClearCursor() end
        finishDeletion("Не удалось безопасно взять вещь. Удаление остановлено.", true)
        return
    end

    DeleteCursorItem()
    if GetCursorInfo() then
        ClearCursor()
        finishDeletion("Клиент отклонил удаление. Вещь возвращена в сумку.", true)
        return
    end
    deletion.count = deletion.count + entry.count
end

local function hasOpenPopup()
    for index = 1, STATICPOPUP_NUMDIALOGS or 4 do
        local popup = _G["StaticPopup" .. index]
        if popup and popup:IsShown() then return true end
    end
    return false
end

local function getCleanupBlockReason(manual)
    if not db then return "аддон ещё загружается" end
    if deletion then return "удаление уже выполняется" end
    if sale then return "ожидание завершения продажи" end
    if StaticPopup_Visible(DELETE_POPUP) then return "подтверждение уже показано" end

    local reason = getDeletionBlockReason()
    if reason then return reason end
    if manual then return end

    if not cleanupAt then return "автопроверка приостановлена; выполните /reload" end
    if hasOpenPopup() then return "открыто другое окно подтверждения" end
    if IsControlKeyDown() or IsShiftKeyDown() or IsAltKeyDown() then
        return "зажата клавиша Ctrl, Shift или Alt"
    end
    local waitUntil = math.max(cleanupBatchReadyAt or 0, cleanupRetryAt or 0, cleanupReminderAt or 0)
    if waitUntil > GetTime() then
        local seconds = math.ceil(waitUntil - GetTime())
        if waitUntil == cleanupBatchReadyAt then
            return string.format("сбор добычи; подтверждение через %d с", seconds)
        elseif waitUntil == cleanupRetryAt then
            return string.format("повтор после ошибки через %d с", seconds)
        else
            return string.format("следующее напоминание через %d с", seconds)
        end
    end
end

local function getUnlockedItems(items)
    local ready = {}
    for _, item in ipairs(items) do
        if not item.locked then table.insert(ready, item) end
    end
    return ready
end

local function showDeleteConfirmation(manual)
    if manual then
        updateCleanupBatch()
        cleanupRetryAt = nil
        cleanupReminderAt = nil
        cleanupBatchReadyAt = nil
    end

    local reason = getCleanupBlockReason(manual)
    if reason then
        if manual then printMessage("Удаление отложено: " .. reason .. ".") end
        return
    end

    local items = collectDeletionItems()
    if #items == 0 then
        cleanupRetryAt = nil
        cleanupReminderAt = nil
        if manual then printMessage("В сумках нет вещей с крестиком.") end
        return
    end

    local queue = manual and items or getUnlockedItems(items)
    if #queue == 0 then return end

    local count, value, preview = 0, 0, {}
    for _, item in ipairs(queue) do
        count = count + item.count
        value = value + (item.price or 0) * item.count
        if #preview < PREVIEW_LIMIT then
            table.insert(preview, item.link .. " x" .. item.count)
        end
    end
    if #queue > PREVIEW_LIMIT then
        table.insert(preview, string.format("...ещё стаков: %d", #queue - PREVIEW_LIMIT))
    end

    local text = string.format("Безвозвратно удалить %d шт. (%d стаков)?\n%s\nЦена: %s.",
        count, #queue, table.concat(preview, "\n"), formatMoney(value))
    if StaticPopup_Show(DELETE_POPUP, text, nil, queue) then
        cleanupBatchReadyAt = nil
    end
end

StaticPopupDialogs[DELETE_POPUP] = {
    text = "%s",
    button1 = "Удалить",
    button2 = "Отмена",
    OnAccept = function(self, data)
        local queue = data or self.data
        if not queue or not canDelete() or sale then
            printMessage("Удаление отложено. Подтверждение появится, когда условия позволят.")
            return
        end
        cleanupRetryAt = nil
        cleanupReminderAt = nil
        deletion = {
            queue = queue,
            next = 1,
            count = 0,
            skipped = 0,
        }
    end,
    OnCancel = function(self, data, reason)
        if reason == "clicked" then
            cleanupReminderAt = GetTime() + CLEANUP_REMINDER_DELAY
        end
    end,
    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    showAlert = true,
}

local function hookArkInventory()
    if not ArkInventory or frame.arkHooked then return end
    local ark = ArkInventory
    if not ark.Frame_Item_OnLoad or not ark.Frame_Main_OnShow then return end
    frame.arkHooked = true
    hooksecurefunc(ark, "Frame_Item_OnLoad", attachItemButton)
    hooksecurefunc(ark, "Frame_Main_OnShow", function(window)
        if window.ARK_Data.loc_id == ark.Const.Location.Bag then
            refreshMarks()
        end
    end)
end

local function initializeDatabase()
    if type(ElriJunkDB) ~= "table" then ElriJunkDB = {} end
    db = ElriJunkDB
    db.version = 1
    db.items = normalizeRules(db.items)
end

local function hookBagFrames()
    hooksecurefunc("ContainerFrameItemButton_OnLoad", attachItemButton)
    hookArkInventory()
    -- Includes buttons created by ArkInventory before our OptionalDeps finished loading.
    local object = EnumerateFrames()
    while object do
        local name = object:GetName()
        if object:GetObjectType() == "Button"
            and ((name and string.match(name, "^ContainerFrame%d+Item%d+$"))
                or (object.ARK_Data and object.ARK_Data.slot_id)) then
            attachItemButton(object)
        end
        object = EnumerateFrames(object)
    end
end

local function initialize()
    initializeDatabase()
    hookBagFrames()
    updateCleanupBatch()
    cleanupAt = GetTime() + CLEANUP_INTERVAL
    printMessage("Загружен, версия " .. ADDON_VERSION .. ". Ctrl+ПКМ: монетка → крестик → снять метку. Справка: /ej.")
end

local function printVersion()
    printMessage("Загруженная версия: " .. ADDON_VERSION .. ".")
end

local function printCleanupStatus()
    printVersion()
    if not db then
        printMessage("Аддон ещё не инициализирован. Выполните /reload.")
        return
    end

    local items, count, lockedStacks = collectDeletionItems()
    local sellRules, deleteRules = 0, 0
    for _, rule in pairs(db.items) do
        if rule == SELL then sellRules = sellRules + 1
        elseif rule == DELETE then deleteRules = deleteRules + 1 end
    end
    printMessage(string.format("Сохранённые метки: продажа — %d, удаление — %d.", sellRules, deleteRules))
    printMessage(string.format("К удалению: %d шт. (%d стаков); заблокировано стаков: %d.",
        count, #items, lockedStacks))

    local ready = getUnlockedItems(items)
    local reason = getCleanupBlockReason(false)
    if not reason then
        if #items == 0 then reason = "в сумках нет вещей с крестиком"
        elseif #ready == 0 then reason = "ожидание разблокировки предметов"
        else reason = "готово; подтверждение появится в течение секунды" end
    end
    printMessage("Статус удаления: " .. reason .. ".")
end

local function listRules()
    local ids = {}
    for id in pairs(db.items) do
        table.insert(ids, id)
    end
    table.sort(ids)

    if #ids == 0 then
        printMessage("Сохранённых меток нет.")
        return
    end

    for _, id in ipairs(ids) do
        local name, link = GetItemInfo(id)
        local label = link or name or ("item:" .. id)
        local action = db.items[id] == SELL and "автопродажа" or "удаление"
        printMessage(label .. " — " .. action)
    end
end

local function showHelp()
    printMessage("Ctrl+ПКМ: монетка → крестик → снять метку. Непродаваемые вещи пропускают монетку.")
    printMessage("Серые вещи продаются при открытии торговца; крестик имеет приоритет над продажей.")
    printMessage("Подтверждение удаления — через 20 с после первой вещи в партии. Сразу: /ej clean.")
    printMessage("/ej clean — предложить удаление; /ej list — метки; /ej unmark ID — снять метку.")
    printMessage("/ej version — загруженная версия; /ej status — состояние удаления.")
end

local function handleCommand(message)
    local command = string.lower(string.match(message or "", "^%s*(.-)%s*$"))
    if command == "version" or command == "ver" then
        printVersion()
        return
    end
    synchronizeDatabase()
    if command == "status" then
        printCleanupStatus()
        return
    end
    if command == "clean" then
        showDeleteConfirmation(true)
        return
    end
    if command == "list" then
        listRules()
        return
    end

    local idText = string.match(command, "^unmark%s+(%d+)$")
    if idText then
        setItemRule(tonumber(idText), nil)
        updateCleanupBatch()
        refreshMarks()
        return
    end

    showHelp()
end

local function onEvent(self, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON_NAME then
            initialize()
        elseif db and name == "ArkInventory" then
            hookArkInventory()
        end
        return
    end
    if not db then return end
    synchronizeDatabase()

    if event == "MERCHANT_SHOW" then
        StaticPopup_Hide(DELETE_POPUP)
        if deletion then finishDeletion("Удаление остановлено: открыт торговец.") end
        startSale()
    elseif event == "MERCHANT_CLOSED" then
        if sale then
            sale.restart = nil
            confirmSale()
            if not sale.pending then finishSale() end
        end
    elseif event == "BAG_UPDATE" then
        updateCleanupBatch()
        refreshMarks()
    elseif event == "LOOT_OPENED" then
        looting = true
        StaticPopup_Hide(DELETE_POPUP)
    elseif event == "LOOT_CLOSED" then
        looting = false
        updateCleanupBatch()
    elseif event == "PLAYER_REGEN_DISABLED" then
        StaticPopup_Hide(DELETE_POPUP)
        if deletion then finishDeletion("Удаление остановлено на время боя.") end
    elseif event == "PLAYER_REGEN_ENABLED" then
        for button in pairs(buttons) do
            updateButtonMark(button)
            wrapItemClick(button)
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        looting = false
        updateCleanupBatch()
        cleanupAt = GetTime() + CLEANUP_INTERVAL
    elseif event == "PLAYER_LEAVING_WORLD" then
        looting = false
        cleanupAt = nil
        StaticPopup_Hide(DELETE_POPUP)
        if sale then
            confirmSale()
            finishSale()
        end
        if deletion then finishDeletion() end
    end
end

local function onUpdate(self, elapsed)
    if not db then return end
    synchronizeDatabase()

    updateElapsed = updateElapsed + elapsed
    if updateElapsed < UPDATE_INTERVAL then return end
    updateElapsed = 0

    updateSale()
    updateDeletion()
    if cleanupAt and GetTime() >= cleanupAt then
        cleanupAt = GetTime() + CLEANUP_INTERVAL
        updateCleanupBatch()
        showDeleteConfirmation(false)
        if cleanupAt and cleanupBatchReadyAt and cleanupBatchReadyAt > GetTime() then
            cleanupAt = math.min(cleanupAt, cleanupBatchReadyAt)
        end
    end
    refreshMarks()
end

SLASH_ELRIJUNK1, SLASH_ELRIJUNK2 = "/elrijunk", "/ej"
SlashCmdList.ELRIJUNK = handleCommand
frame:SetScript("OnEvent", onEvent)
frame:SetScript("OnUpdate", onUpdate)

local events = {
    "ADDON_LOADED",
    "MERCHANT_SHOW",
    "MERCHANT_CLOSED",
    "BAG_UPDATE",
    "LOOT_OPENED",
    "LOOT_CLOSED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LEAVING_WORLD",
    "PLAYER_LOGIN",
    "PLAYER_LOGOUT",
    "VARIABLES_LOADED",
}

for _, event in ipairs(events) do
    frame:RegisterEvent(event)
end
