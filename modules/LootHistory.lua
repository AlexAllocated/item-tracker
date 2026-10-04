--[[
    ItemTracker - LootHistory Module
    Single Responsibility: Persist loot entries in SavedVariables,
    enforce history size limits, and provide query access.

    Listens to:
        ITEM_LOOTED  — add entry to history
        ROLL_ENDED   — annotate existing entry with roll result, or add if new

    Fires:
        HISTORY_UPDATED — whenever the history list changes
]]

local _, IT = ...
local History = {}
IT.LootHistory = History

-- ============================================================================
-- Internal Data
-- ============================================================================

local history  -- reference to IT.db.history (set during Initialize)
-- Only pair notifications from this session. Weak keys release state when
-- history entries are trimmed and when a provider discards a finished roll.
local pendingLoot = setmetatable({}, { __mode = "k" })
local pendingAwards = setmetatable({}, { __mode = "k" })
local handledRolls = setmetatable({}, { __mode = "k" })

-- ============================================================================
-- History Entry Structure
-- ============================================================================

--[[
    entry = {
        itemLink    = string,
        itemID      = number,
        quality     = number,
        count       = number,
        icon        = texture,
        player      = string,       -- who received the item
        isSelf      = boolean,
        isGroupLoot = boolean,
        timestamp   = number,       -- time() (persists across reloads)
        wasRolled   = boolean,
        rolls       = { { player, rollType, number }, ... } | nil,
        winner      = string | nil,
    }
]]

-- ============================================================================
-- Core Operations
-- ============================================================================

function History:Add(entry)
    table.insert(history, 1, entry)  -- newest first
    self:EnforceLimit()
    IT.Events:Fire("HISTORY_UPDATED")
end

function History:EnforceLimit()
    local maxSize = IT.db.settings.historySize or 100
    while #history > maxSize do
        table.remove(history)
    end
end

function History:Clear()
    wipe(history)
    wipe(pendingLoot)
    wipe(pendingAwards)
    IT.Events:Fire("HISTORY_UPDATED")
end

function History:GetAll()
    return history
end

function History:GetCount()
    return #history
end

function History:GetEntry(index)
    return history[index]
end

-- ============================================================================
-- Find an existing entry by itemID within a time window.
-- ============================================================================

local MATCH_WINDOW = 30  -- seconds

function History:FindRecentByItem(itemID, maxAge)
    maxAge = maxAge or MATCH_WINDOW
    local now = time()
    for i, entry in ipairs(history) do
        if entry.itemID == itemID and type(entry.timestamp) == "number"
            and now >= entry.timestamp and now - entry.timestamp < maxAge then
            return i, entry
        end
    end
    return nil, nil
end

local function PlayerKey(name)
    if not name or name == "" then return nil end
    local player, realm = name:match("^([^%-]+)%-(.+)$")
    if not player then player, realm = name, GetRealmName and GetRealmName() or "" end
    return player:lower() .. "-" .. realm:gsub("%s", ""):lower()
end

local function Matches(entry, other, pending)
    if not pending or entry.itemID ~= other.itemID
        or not PlayerKey(entry.player) or PlayerKey(entry.player) ~= PlayerKey(other.player) then
        return false
    end
    -- Cache loading may delay ITEM_LOOTED. Match either the original receipt
    -- time or the event delivery time (RCLC's fallback awards during delivery).
    return GetTime() - pending.at < MATCH_WINDOW
        or (type(entry.timestamp) == "number" and type(other.timestamp) == "number"
            and math.abs(entry.timestamp - other.timestamp) < MATCH_WINDOW)
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

local function OnItemLooted(lootEntry)
    local remaining = lootEntry.count or 1
    -- Match oldest first and consume quantities, so two copies awarded to
    -- the same player remain two awards instead of swallowing the second.
    for i = #history, 1, -1 do
        local entry = history[i]
        local pending = pendingAwards[entry]
        if Matches(entry, lootEntry, pending) then
            local used = math.min(remaining, pending.remaining)
            remaining, pending.remaining = remaining - used, pending.remaining - used
            entry.itemLink = lootEntry.itemLink or entry.itemLink
            entry.quality = lootEntry.quality or entry.quality
            entry.icon = lootEntry.icon or entry.icon
            if pending.remaining == 0 then pendingAwards[entry] = nil end
            if remaining == 0 then
                IT.Events:Fire("HISTORY_UPDATED")
                return
            end
        end
    end

    local entry = {
        itemLink    = lootEntry.itemLink,
        itemID      = lootEntry.itemID,
        quality     = lootEntry.quality,
        count       = remaining,
        icon        = lootEntry.icon,
        player      = lootEntry.player,
        isSelf      = lootEntry.isSelf,
        isGroupLoot = lootEntry.isGroupLoot,
        timestamp   = lootEntry.timestamp or time(),
        wasRolled   = false,
        rolls       = nil,
        winner      = nil,
    }
    pendingLoot[entry] = { at = GetTime() }
    History:Add(entry)
end

local function OnRollEnded(rollData)
    if handledRolls[rollData] then return end
    handledRolls[rollData] = true
    local entry = {
        itemLink    = rollData.itemLink,
        itemID      = rollData.itemID,
        quality     = rollData.quality,
        count       = rollData.count or 1,
        icon        = rollData.icon,
        player      = rollData.winner or "Nobody",
        isSelf      = (PlayerKey(rollData.winner) == PlayerKey(UnitName("player"))),
        isGroupLoot = true,
        timestamp   = time(),
        wasRolled   = true,
        rolls       = rollData.rolls,
        winner      = rollData.winner,
    }
    local remaining = entry.count
    for i = #history, 1, -1 do
        local receipt = history[i]
        if Matches(receipt, entry, pendingLoot[receipt]) then
            local used = math.min(remaining, receipt.count)
            if remaining == entry.count then
                entry.timestamp = receipt.timestamp
                entry.itemLink = receipt.itemLink or entry.itemLink
                entry.quality = receipt.quality or entry.quality
                entry.icon = receipt.icon or entry.icon
            end
            remaining, receipt.count = remaining - used, receipt.count - used
            if receipt.count == 0 then
                pendingLoot[receipt] = nil
                table.remove(history, i)
            end
            if remaining == 0 then break end
        end
    end
    if remaining > 0 then pendingAwards[entry] = { at = GetTime(), remaining = remaining } end
    History:Add(entry)
end

-- ============================================================================
-- Module Interface
-- ============================================================================

--- One-shot migration of legacy session-time stamps (GetTime() values
--- saved before the addon switched to epoch time()). Anything still using
--- the old clock has a value far below 10^9; nil it so FormatTimeAgo
--- shows "earlier" instead of a wildly negative diff. Idempotent and
--- gated by a flag so we don't re-walk the list every load.
local function migrateLegacyTimestamps()
    if not IT.db then return end
    if IT.db.lootHistoryTimestampsMigrated then return end
    IT.db.lootHistoryTimestampsMigrated = true

    if not IT.db.history then return end
    local migrated = 0
    for _, entry in ipairs(IT.db.history) do
        if type(entry.timestamp) == "number" and entry.timestamp < 1e9 then
            entry.timestamp = nil
            migrated = migrated + 1
        end
    end
    if migrated > 0 then
        IT:Debug("LootHistory: nulled " .. migrated ..
            " session-time stamps (epoch migration).")
    end
end

function History:Initialize()
    migrateLegacyTimestamps()
    history = IT.db.history
    IT.Events:Subscribe("ITEM_LOOTED", OnItemLooted)
    IT.Events:Subscribe("ROLL_ENDED", OnRollEnded)
end
