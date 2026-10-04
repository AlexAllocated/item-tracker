--[[
    ItemTracker - LootDetector Module
    Single Responsibility: Detect loot events from CHAT_MSG_LOOT,
    filter by quality threshold, and fire ITEM_LOOTED on the event bus.

    Does NOT store data or create UI — downstream modules handle that.
]]

local _, IT = ...
local Detector = {}
IT.LootDetector = Detector

-- ============================================================================
-- Locale-safe Loot Message Patterns
-- Built from Blizzard global strings so they work on any client language.
-- ============================================================================

local patterns -- built lazily after globals are available

local function BuildPatterns()
    local fmt = IT.FormatToPattern
    patterns = {
        selfMulti  = fmt(IT, LOOT_ITEM_SELF_MULTIPLE),  -- "You receive loot: %sx%d."
        self       = fmt(IT, LOOT_ITEM_SELF),            -- "You receive loot: %s."
        otherMulti = fmt(IT, LOOT_ITEM_MULTIPLE),        -- "%s receives loot: %sx%d."
        other      = fmt(IT, LOOT_ITEM),                 -- "%s receives loot: %s."
    }
end

-- ============================================================================
-- Message Parsing
-- ============================================================================

--- Parse a CHAT_MSG_LOOT message into player, itemLink, count.
--- Returns nil if the message does not match any known loot pattern.
function Detector:ParseLootMessage(msg)
    if not patterns then BuildPatterns() end

    -- Self with quantity (must be tested before self-single to avoid greedy match)
    local link, count = msg:match(patterns.selfMulti)
    if link then
        return UnitName("player"), link, tonumber(count)
    end

    -- Self single
    link = msg:match(patterns.self)
    if link then
        return UnitName("player"), link, 1
    end

    -- Other player with quantity
    local player
    player, link, count = msg:match(patterns.otherMulti)
    if player and link then
        return player, link, tonumber(count)
    end

    -- Other player single
    player, link = msg:match(patterns.other)
    if player and link then
        return player, link, 1
    end

    return nil, nil, nil
end

-- ============================================================================
-- Quality Gate
-- ============================================================================

local function PassesQualityThreshold(quality, isGroupLoot)
    local threshold = isGroupLoot
        and IT.db.settings.groupQualityThreshold
        or  IT.db.settings.soloQualityThreshold
    return quality and quality >= threshold
end

local pendingItems = {}
local retryScheduled = false
local ITEM_INFO_TIMEOUT = 60

local function PublishLoot(entry, quality, icon)
    entry.quality, entry.icon = quality, icon or entry.icon
    if IT.db.settings.enabled and PassesQualityThreshold(quality, entry.isGroupLoot) then
        IT.Events:Fire("ITEM_LOOTED", entry)
    end
end

local function ResolvePendingItem(itemID)
    local pending = pendingItems[itemID]
    if not pending then return end
    local _, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    -- Detach before publishing: subscribers can fire other loot events.
    pendingItems[itemID] = nil
    for _, request in ipairs(pending) do
        if quality ~= nil then
            PublishLoot(request.entry, quality, icon)
        elseif GetTime() < request.expires then
            pendingItems[itemID] = pendingItems[itemID] or {}
            table.insert(pendingItems[itemID], request)
        else
            IT:Debug("Item information timed out: " .. itemID)
        end
    end
end

local function ScheduleItemRetry()
    if retryScheduled or not next(pendingItems) then return end
    retryScheduled = true
    C_Timer.After(2, function()
        retryScheduled = false
        local ids = {}
        for itemID in pairs(pendingItems) do ids[#ids + 1] = itemID end
        for _, itemID in ipairs(ids) do ResolvePendingItem(itemID) end
        ScheduleItemRetry()
    end)
end

local function ProcessLoot(entry, quality)
    if quality ~= nil then
        PublishLoot(entry, quality, entry.icon)
        return
    end
    pendingItems[entry.itemID] = pendingItems[entry.itemID] or {}
    table.insert(pendingItems[entry.itemID], { entry = entry, expires = GetTime() + ITEM_INFO_TIMEOUT })
    ScheduleItemRetry()
end

-- ============================================================================
-- Shared Self-Item Processing
-- Fires ITEM_VALUE for EVERY self-received item (the "show everything" stream
-- the on-screen loot text listens to) and, if it clears the quality gate,
-- ITEM_LOOTED for the history/toast path. Used by both the looted stream and
-- the pushed/created stream so conjured food, healthstones, crafted/traded
-- items etc. surface on screen even though they're below the history threshold.
-- ============================================================================

local function ProcessSelfItem(link, count, quality, icon)
    local itemID = IT:GetItemIDFromLink(link)
    if not itemID then return end

    local isGroupLoot = IsInGroup() or IsInRaid()
    local entry = {
        itemLink    = link,
        itemID      = itemID,
        quality     = quality or 0,
        count       = count or 1,
        player      = UnitName("player"),
        isSelf      = true,
        isGroupLoot = isGroupLoot,
        timestamp   = time(),
        icon        = icon,
    }

    -- Every self-received item feeds the on-screen loot text, regardless of
    -- the history quality threshold.
    IT.Events:Fire("ITEM_VALUE", entry)

    ProcessLoot(entry, quality)
end

-- ============================================================================
-- Pushed / Created Item Patterns
-- Items that appear in bags without a loot window: mage food/water and warlock
-- healthstones you pick up ("You receive item: %s."), and self-conjured or
-- crafted items ("You create: %s."). On TBC 2.5.x these arrive via
-- CHAT_MSG_LOOT (with CHAT_MSG_SYSTEM kept as a fallback for other clients).
-- ============================================================================

local pushPatterns

local function BuildPushPatterns()
    local fmt = IT.FormatToPattern
    pushPatterns = {}
    -- Ordered most-specific (…MULTIPLE) first so the count variants win.
    if LOOT_ITEM_PUSHED_SELF_MULTIPLE then
        pushPatterns[#pushPatterns + 1] = { p = fmt(IT, LOOT_ITEM_PUSHED_SELF_MULTIPLE), multi = true }
    end
    if LOOT_ITEM_CREATED_SELF_MULTIPLE then
        pushPatterns[#pushPatterns + 1] = { p = fmt(IT, LOOT_ITEM_CREATED_SELF_MULTIPLE), multi = true }
    end
    if LOOT_ITEM_PUSHED_SELF then
        pushPatterns[#pushPatterns + 1] = { p = fmt(IT, LOOT_ITEM_PUSHED_SELF), multi = false }
    end
    if LOOT_ITEM_CREATED_SELF then
        pushPatterns[#pushPatterns + 1] = { p = fmt(IT, LOOT_ITEM_CREATED_SELF), multi = false }
    end
end

--- Parse a pushed/created "You receive item:" / "You create:" line.
--- Returns itemLink, count or nil if the message doesn't match.
local function ParsePushedMessage(msg)
    if not pushPatterns then BuildPushPatterns() end
    for _, entry in ipairs(pushPatterns) do
        if entry.multi then
            local link, count = msg:match(entry.p)
            if link then return link, tonumber(count) or 1 end
        else
            local link = msg:match(entry.p)
            if link then return link, 1 end
        end
    end
    return nil
end

--- Shared handler for a pushed/created message body (CHAT_MSG_LOOT + fallback).
local function HandlePushedMessage(msg)
    if not IT.db.settings.enabled then return end
    local link, count = ParsePushedMessage(msg)
    if not link then return end
    local _, _, quality, _, _, _, _, _, _, icon = GetItemInfo(link)
    ProcessSelfItem(link, count, quality, icon)
end

-- ============================================================================
-- Event Handler
-- ============================================================================

local function OnChatMsgLoot(msg)
    if not IT.db.settings.enabled then return end

    local player, itemLink, count = Detector:ParseLootMessage(msg)
    if not player or not itemLink then
        -- Not a "You receive loot:" line. On 2.5.x, pushed/created items
        -- (mage food, healthstones, crafted items) arrive here as
        -- "You receive item:" / "You create:" lines — handle them too.
        HandlePushedMessage(msg)
        return
    end

    local itemID = IT:GetItemIDFromLink(itemLink)
    if not itemID then return end

    local _, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemLink)
    local isGroupLoot = IsInGroup() or IsInRaid()
    local isSelf = (player == UnitName("player"))

    -- In solo mode only show own loot; in group mode show everyone's
    if not isGroupLoot and not isSelf then return end

    local entry = {
        itemLink    = itemLink,
        itemID      = itemID,
        quality     = quality or 0,
        count       = count or 1,
        player      = player,
        isSelf      = isSelf,
        isGroupLoot = isGroupLoot,
        timestamp   = time(),
        icon        = icon,
    }

    -- Gold tracking needs all self-looted items regardless of quality
    if isSelf then
        IT.Events:Fire("ITEM_VALUE", entry)
    end

    ProcessLoot(entry, quality)
end

-- ============================================================================
-- Quest Reward Detection
-- CHAT_MSG_LOOT does not fire for quest rewards from NPCs.
-- QUEST_LOOT_RECEIVED(questID, itemLink, count) fires in TBC Classic.
-- Fallback: CHAT_MSG_SYSTEM with LOOT_ITEM_PUSHED_SELF pattern.
-- ============================================================================

local function OnQuestLootReceived(questID, itemLink, count)
    if not IT.db.settings.enabled then return end
    if not itemLink then return end

    local _, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemLink)
    ProcessSelfItem(itemLink, count, quality, icon)
end

--- Fallback: some clients deliver pushed/created item lines on CHAT_MSG_SYSTEM
--- instead of CHAT_MSG_LOOT. Route them through the same shared handler.
local function OnChatMsgSystem(msg)
    HandlePushedMessage(msg)
end

-- Test helper: run a raw CHAT_MSG_LOOT message body through the real parser,
-- exercising the loot + pushed/created detection exactly as the game would.
function Detector:SimulateChatLoot(msg)
    OnChatMsgLoot(msg)
end

-- ============================================================================
-- Gold Tracking
-- Session-only (not persisted). Fires GOLD_LOOTED for UI display.
-- ============================================================================

local sessionCopper = 0

--- Parse a CHAT_MSG_MONEY message into copper value.
--- Uses GOLD_AMOUNT / SILVER_AMOUNT / COPPER_AMOUNT globals which are
--- localized format strings like "%d Gold" → convert to "(%d+) Gold" pattern.
local moneyPatterns

local function BuildMoneyPatterns()
    moneyPatterns = {}
    -- GOLD_AMOUNT = "%d Gold" → "(%d+) Gold"
    if GOLD_AMOUNT then
        moneyPatterns.gold = GOLD_AMOUNT:gsub("%%d", "(%%d+)")
    end
    if SILVER_AMOUNT then
        moneyPatterns.silver = SILVER_AMOUNT:gsub("%%d", "(%%d+)")
    end
    if COPPER_AMOUNT then
        moneyPatterns.copper = COPPER_AMOUNT:gsub("%%d", "(%%d+)")
    end
end

local function ParseMoneyMessage(msg)
    if not moneyPatterns then BuildMoneyPatterns() end

    local copper = 0
    if moneyPatterns.gold then
        local g = msg:match(moneyPatterns.gold)
        if g then copper = copper + tonumber(g) * 10000 end
    end
    if moneyPatterns.silver then
        local s = msg:match(moneyPatterns.silver)
        if s then copper = copper + tonumber(s) * 100 end
    end
    if moneyPatterns.copper then
        local c = msg:match(moneyPatterns.copper)
        if c then copper = copper + tonumber(c) end
    end

    return copper
end

local function AddSessionGold(copper)
    sessionCopper = sessionCopper + copper
    IT.Events:Fire("GOLD_LOOTED", sessionCopper)
    if IT.db.settings.toastGold then
        IT.Events:Fire("GOLD_DROP", copper)
    end
end

local function OnChatMsgMoney(msg)
    if not IT.db.settings.enabled then return end
    local copper = ParseMoneyMessage(msg)
    if copper > 0 then
        AddSessionGold(copper)
    end
end

local function OnQuestTurnedIn(questID, xpReward, moneyReward)
    if not IT.db.settings.enabled then return end
    if moneyReward and moneyReward > 0 then
        AddSessionGold(moneyReward)
    end
end

function Detector:GetSessionGold()
    return sessionCopper
end

function Detector:ResetSessionGold()
    sessionCopper = 0
    IT.Events:Fire("GOLD_LOOTED", 0)
end

-- Test helper: add copper directly (used by /it test gold)
function Detector._addTestGold(copper)
    sessionCopper = sessionCopper + copper
    IT.Events:Fire("GOLD_LOOTED", sessionCopper)
    IT.Events:Fire("GOLD_DROP", copper)
end

-- ============================================================================
-- Module Interface
-- ============================================================================

function Detector:Initialize()
    IT:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(itemID, success)
        if success ~= false then ResolvePendingItem(itemID) end
    end)
    IT:RegisterEvent("CHAT_MSG_LOOT", OnChatMsgLoot)
    IT:RegisterEvent("CHAT_MSG_MONEY", OnChatMsgMoney)
    IT:RegisterEvent("QUEST_TURNED_IN", OnQuestTurnedIn)
    -- Quest rewards (TBC Classic Anniversary)
    IT:RegisterEvent("QUEST_LOOT_RECEIVED", function(...)
        local ok, err = pcall(OnQuestLootReceived, ...)
        if not ok then IT:Debug("QUEST_LOOT_RECEIVED error: " .. tostring(err)) end
    end)
    -- Fallback: items pushed to bags (quest rewards on older clients, mail, etc.)
    IT:RegisterEvent("CHAT_MSG_SYSTEM", OnChatMsgSystem)
end
