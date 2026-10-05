--[[
    ItemTracker - LootReserve Integration
    Single Responsibility: Detect LootReserve roll requests and winners,
    translate them into the ROLL_STARTED / ROLL_ENDED event protocol
    so Toast and LootHistory work without modification.

    Hook points:
      - LootReserve.Comm.Handlers[12] (RequestRoll) → ROLL_STARTED
      - LootReserve.Comm.Handlers[19] (SendWinner)  → ROLL_ENDED
      - LootReserve:RegisterListener("RESERVES")     → reserve context

    Safe: does nothing if LootReserve is not installed.
]]

local _, IT = ...
local LRI = {}
IT.LRIntegration = LRI

-- ============================================================================
-- Constants
-- ============================================================================

local ROLL_ID_BASE = 200000  -- offset to avoid collisions
local OPCODE_REQUEST_ROLL = 12
local OPCODE_SEND_WINNER  = 19

-- ============================================================================
-- State
-- ============================================================================

local hooked = false
local activeRolls = {}    -- itemID → rollData
local reserves = {}       -- itemID → { "Player1", "Player2", ... }
local rollCounter = 0

local function TrackingEnabled()
    if IT.db.settings.enabled then return true end
    wipe(activeRolls)
    return false
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function IsLRLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("LootReserve")
    elseif IsAddOnLoaded then
        return IsAddOnLoaded("LootReserve")
    end
    return false
end

-- ============================================================================
-- Reserve Tracking
-- ============================================================================

local function OnReservesUpdated(pkg)
    if not pkg then return end
    wipe(reserves)

    -- pkg = { [playerName] = { itemID1, itemID2, ... }, ... }
    for player, items in pairs(pkg) do
        for _, itemID in ipairs(items) do
            if not reserves[itemID] then
                reserves[itemID] = {}
            end
            table.insert(reserves[itemID], player)
        end
    end
end

-- ============================================================================
-- Roll Request → ROLL_STARTED
-- ============================================================================

local MAX_ITEM_RETRIES = 5

local function OnRequestRoll(item, players, retries)
    if not TrackingEnabled() then return end
    if not item then return end
    retries = retries or 0

    local itemID
    if type(item) == "table" and item.id then
        itemID = item.id
    elseif type(item) == "number" then
        itemID = item
    else
        return
    end

    -- Build item link from ID if we don't have one
    local _, itemLink, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    if not itemLink then
        if retries < MAX_ITEM_RETRIES then
            C_Timer.After(0.5, function()
                OnRequestRoll(item, players, retries + 1)
            end)
        else
            IT:Debug("LR: gave up caching item " .. tostring(itemID) .. " after " .. MAX_ITEM_RETRIES .. " retries")
        end
        return
    end

    rollCounter = rollCounter + 1
    local rollID = ROLL_ID_BASE + rollCounter

    -- Build rolls list from reserve data
    local rollEntries = {}
    local reservers = reserves[itemID]
    if reservers then
        for _, player in ipairs(reservers) do
            table.insert(rollEntries, { player = player, rollType = "reserve", number = 0 })
        end
    end

    local rollData = {
        rollID    = rollID,
        itemLink  = itemLink,
        itemID    = itemID,
        quality   = quality or 0,
        icon      = icon,
        count     = 1,
        timeLeft  = 0,
        startTime = GetTime(),
        rolls     = rollEntries,
        winner    = nil,
        finished  = false,
        source    = "LootReserve",
    }

    activeRolls[itemID] = rollData
    IT:Debug("LR roll request: " .. itemLink)
    IT.Events:Fire("ROLL_STARTED", rollData)
end

-- ============================================================================
-- Winner → ROLL_ENDED
-- ============================================================================

local function OnSendWinner(item, winners, losers, roll)
    if not TrackingEnabled() then return end
    if not item then return end

    local itemID
    if type(item) == "table" and item.id then
        itemID = item.id
    elseif type(item) == "number" then
        itemID = item
    else
        return
    end

    local rollData = activeRolls[itemID]
    if not rollData then
        -- Winner without a prior RequestRoll (e.g. direct award)
        -- Create a minimal entry
        local _, itemLink, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
        rollCounter = rollCounter + 1
        rollData = {
            rollID    = ROLL_ID_BASE + rollCounter,
            itemLink  = itemLink or ("item:" .. itemID),
            itemID    = itemID,
            quality   = quality or 0,
            icon      = icon,
            count     = 1,
            timeLeft  = 0,
            startTime = GetTime(),
            rolls     = {},
            winner    = nil,
            finished  = false,
            source    = "LootReserve",
        }
    end

    -- Parse winners
    local winnerName
    if type(winners) == "table" then
        winnerName = winners[1]
        for _, w in ipairs(winners) do
            table.insert(rollData.rolls, {
                player = w,
                rollType = "reserve",
                number = tonumber(roll) or 0,
            })
        end
    elseif type(winners) == "string" and winners ~= "" then
        winnerName = winners
        table.insert(rollData.rolls, {
            player = winners,
            rollType = "reserve",
            number = tonumber(roll) or 0,
        })
    end

    rollData.finished = true
    rollData.winner = winnerName

    IT:Debug("LR winner: " .. (winnerName or "none") .. " for item " .. itemID)
    IT.Events:Fire("ROLL_ENDED", rollData)

    C_Timer.After(2, function()
        if activeRolls[itemID] == rollData then activeRolls[itemID] = nil end
    end)
end

-- ============================================================================
-- Hook Installation
-- ============================================================================

local function InstallHooks()
    if hooked then return end
    if not LootReserve then return end

    -- Register for reserve updates
    if LootReserve.RegisterListener then
        local ok = LootReserve:RegisterListener("RESERVES", "ItemTracker", OnReservesUpdated)
        if ok then
            IT:Debug("LR: registered reserve listener")
        end
    end

    -- Hook RequestRoll handler (opcode 12)
    if LootReserve.Comm and LootReserve.Comm.Handlers then
        local origRequestRoll = LootReserve.Comm.Handlers[OPCODE_REQUEST_ROLL]
        if origRequestRoll then
            LootReserve.Comm.Handlers[OPCODE_REQUEST_ROLL] = function(sender, item, players, ...)
                origRequestRoll(sender, item, players, ...)
                -- After LR processes, read the parsed RollRequest from client
                pcall(function()
                    local rr = LootReserve.Client and LootReserve.Client.RollRequest
                    if rr and rr.Item then
                        OnRequestRoll(rr.Item, nil)
                    end
                end)
            end
            IT:Debug("LR: hooked RequestRoll handler")
        end

        -- Hook SendWinner handler (opcode 19)
        local origSendWinner = LootReserve.Comm.Handlers[OPCODE_SEND_WINNER]
        if origSendWinner then
            LootReserve.Comm.Handlers[OPCODE_SEND_WINNER] = function(sender, item, winners, losers, roll, custom, phase, raidRoll)
                origSendWinner(sender, item, winners, losers, roll, custom, phase, raidRoll)
                pcall(function()
                    -- Parse item like LR does
                    local itemID = item
                    if type(item) == "string" then
                        itemID = tonumber(item:match("^(%d+)"))
                    end
                    -- Parse winners string
                    local winnerList = {}
                    if type(winners) == "string" and #winners > 0 then
                        for w in winners:gmatch("[^,]+") do
                            table.insert(winnerList, w:trim())
                        end
                    end
                    OnSendWinner({ id = itemID }, winnerList, losers, roll)
                end)
            end
            IT:Debug("LR: hooked SendWinner handler")
        end
    end

    hooked = true
    IT:Print("LootReserve integration active", IT.Colors.success)
end

-- ============================================================================
-- Public API
-- ============================================================================

function LRI:IsActive()
    return hooked
end

function LRI:GetReserves(itemID)
    return reserves[itemID]
end

function LRI:GetAllReserves()
    return reserves
end

-- ============================================================================
-- Module Interface
-- ============================================================================

function LRI:Initialize()
    if IsLRLoaded() then
        C_Timer.After(1, InstallHooks)
    else
        IT:RegisterEvent("ADDON_LOADED", function(addon)
            if addon == "LootReserve" then
                C_Timer.After(1, InstallHooks)
            end
        end)
    end
end
