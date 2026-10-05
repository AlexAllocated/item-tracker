--[[
    ItemTracker - RCLootCouncil Integration
    Single Responsibility: Detect RCLootCouncil sessions and awards,
    translate them into the ROLL_STARTED / ROLL_ENDED event protocol
    so Toast and LootHistory work without modification.

    Hook points (all fire on every client, not just ML):
      - RC:OnLootTableReceived() → items enter voting → ROLL_STARTED
      - RC:GetLootTable()[session].awarded → item awarded → ROLL_ENDED
      - Also listens for RCMLAwardSuccess (ML client only, bonus)

    Safe: does nothing if RCLootCouncil is not installed.
]]

local _, IT = ...
local RCLC = {}
IT.RCLCIntegration = RCLC

-- ============================================================================
-- Constants
-- ============================================================================

local ROLL_ID_BASE = 100000  -- offset to avoid collisions with native rollIDs
local RC_ADDON_NAMES = { "RCLootCouncil_Classic", "RCLootCouncil" }

-- ============================================================================
-- State
-- ============================================================================

local hooked = false
local activeSessions = {}  -- session → rollData

local function TrackingEnabled()
    if IT.db.settings.enabled then return true end
    wipe(activeSessions)
    return false
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function IsRCLoaded()
    for _, name in ipairs(RC_ADDON_NAMES) do
        if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name) then
            return true
        elseif IsAddOnLoaded and IsAddOnLoaded(name) then
            return true
        end
    end
    return false
end

local RC_ACEADDON_NAMES = { "RCLootCouncil_Classic", "RCLootCouncil" }

local function GetRC()
    if not LibStub then return nil end
    local ok, rc = pcall(LibStub, "AceAddon-3.0")
    if not ok or not rc then return nil end
    for _, name in ipairs(RC_ACEADDON_NAMES) do
        local ok2, addon = pcall(rc.GetAddon, rc, name)
        if ok2 and addon then return addon end
    end
    return nil
end

-- ============================================================================
-- Session Tracking
-- ============================================================================

local function OnLootTableReceived(rc)
    if not TrackingEnabled() then return end
    -- rc.enabled is false when RCLC is disabled → ignore early-return calls
    if not rc.enabled then return end
    local lt = rc:GetLootTable()
    if not lt or #lt == 0 then return end

    for session, entry in ipairs(lt) do
        -- entry.link is set by PrepareLootTable; nil means RCLC hasn't finished caching
        if entry.link and not activeSessions[session] then
            local itemID = IT:GetItemIDFromLink(entry.link)
            local rollID = ROLL_ID_BASE + session

            local rollData = {
                rollID    = rollID,
                itemLink  = entry.link,
                itemID    = itemID,
                quality   = entry.quality or select(3, GetItemInfo(entry.link)) or 4,
                icon      = entry.texture or select(10, GetItemInfo(entry.link)),
                count     = 1,
                timeLeft  = 0,
                startTime = GetTime(),
                rolls     = {},
                winner    = nil,
                finished  = false,
                source    = "RCLootCouncil",
            }

            activeSessions[session] = rollData
            IT:Debug("RCLC session item: " .. entry.link)
            IT.Events:Fire("ROLL_STARTED", rollData)
        end
    end
end

-- ============================================================================
-- Response Tracking (translates RCLC responses into ROLL_UPDATE events)
-- ============================================================================

-- Map RCLC response IDs to our rollType display format
local RCLC_RESPONSE_MAP = {
    [1]           = "council",   -- Mainspec/Need (response button 1)
    [2]           = "council",   -- Offspec/Greed (response button 2)
    [3]           = "council",   -- Minor Upgrade (response button 3)
    PASS          = "pass",
    AUTOPASS      = "pass",
    TIMEOUT       = "pass",
    DISABLED      = "pass",
}

local function OnResponseReceived(rc, name, session, data)
    if not TrackingEnabled() then return end
    local rollData = activeSessions[session]
    if not rollData or rollData.finished then return end

    local responseID = data and data.response
    if not responseID then return end
    -- Skip status responses that aren't player choices
    if responseID == "WAIT" or responseID == "ANNOUNCED" or responseID == "NOTANNOUNCED"
       or responseID == "NOTHING" or responseID == "REMOVED" or responseID == "NOTELIGIBLE"
       or responseID == "NOTINRAID" then
        return
    end

    local rollType = RCLC_RESPONSE_MAP[responseID] or "council"
    local rollNumber = data.roll or 0

    -- Get colored response text from RCLC if available
    local responseText
    local ok, text = pcall(function() return rc:GetColoredResponseText(rollData.typeCode or "default", responseID) end)
    if ok and text and text ~= "" then
        responseText = text
    end

    local entry = {
        player       = name,
        rollType     = rollType,
        number       = rollNumber,
        responseText = responseText,  -- RCLC-specific colored text
    }
    table.insert(rollData.rolls, entry)
    IT:Debug("RCLC response: " .. name .. " = " .. tostring(responseID) .. " (roll " .. rollNumber .. ")")
    IT.Events:Fire("ROLL_UPDATE", rollData.rollID, entry)
end

-- ============================================================================
-- Fallback: detect awards via ITEM_LOOTED (works for non-council players
-- who don't receive VotingFrame comm messages)
-- ============================================================================

local function FinishSession(session, winner, source)
    if not TrackingEnabled() then return end
    local rollData = activeSessions[session]
    if not rollData or rollData.finished then return end

    rollData.finished = true
    rollData.winner = winner

    IT:Debug("RCLC award (" .. source .. "): session " .. session .. " to " .. (winner or "none"))
    IT.Events:Fire("ROLL_ENDED", rollData)

    C_Timer.After(2, function()
        if activeSessions[session] == rollData then activeSessions[session] = nil end
    end)
end

local function OnItemLooted(lootEntry)
    if not lootEntry or not lootEntry.itemID then return end
    for session, rollData in pairs(activeSessions) do
        if rollData.itemID == lootEntry.itemID and not rollData.finished then
            FinishSession(session, lootEntry.player, "loot")
            return
        end
    end
end

-- ============================================================================
-- Polling: periodically check RCLC's loot table for awarded items and
-- auto-expire sessions that have been active too long.
-- VotingFrame comms only fire for council/observer players, so non-council
-- raiders need this fallback to detect awards.
-- ============================================================================

local POLL_INTERVAL    = 2    -- seconds between checks
local MAX_SESSION_AGE  = 180  -- seconds; auto-finish after this regardless

local function PollActiveSessions()
    if not TrackingEnabled() then return end
    if not next(activeSessions) then return end

    local RC = GetRC()
    local lt = RC and RC.GetLootTable and RC:GetLootTable()
    local now = GetTime()

    for session, rollData in pairs(activeSessions) do
        if not rollData.finished then
            -- Check 1: RCLC loot table has the awarded field set (council/observer)
            if lt and lt[session] and lt[session].awarded then
                local winner = lt[session].awarded
                if winner == true then winner = nil end  -- bagged items use awarded=true
                FinishSession(session, winner, "poll")
            -- Check 2: safety timeout to prevent stuck toasts
            elseif rollData.startTime and (now - rollData.startTime) > MAX_SESSION_AGE then
                FinishSession(session, nil, "timeout")
            end
        end
    end
end

-- ============================================================================
-- Award Tracking (direct hooks — works for council/observer players)
-- ============================================================================

local function OnItemAwarded(session, winner)
    FinishSession(session, winner, "hook")
end

-- ============================================================================
-- Hook Installation
-- ============================================================================

local function InstallHooks()
    if hooked then return end

    local RC = GetRC()
    if not RC then return end

    -- Hook OnLootTableReceived (fires on all clients when ML sends loot table)
    if RC.OnLootTableReceived then
        hooksecurefunc(RC, "OnLootTableReceived", function(self)
            local ok, err = pcall(OnLootTableReceived, self)
            if not ok then IT:Debug("RCLC lootTable hook error: " .. tostring(err)) end
        end)
        IT:Debug("RCLC: hooked OnLootTableReceived")
    end

    -- Hook voting frame's OnResponseReceived and OnAwardedReceived (fire on all clients)
    local ok, VF = pcall(function() return RC:GetModule("RCVotingFrame") end)
    if ok and VF then
        if VF.OnResponseReceived then
            hooksecurefunc(VF, "OnResponseReceived", function(self, name, session, data)
                local ok2, err = pcall(OnResponseReceived, RC, name, session, data)
                if not ok2 then IT:Debug("RCLC response hook error: " .. tostring(err)) end
            end)
            IT:Debug("RCLC: hooked OnResponseReceived")
        end

        if VF.OnAwardedReceived then
            hooksecurefunc(VF, "OnAwardedReceived", function(self, session, winner)
                local ok2, err = pcall(OnItemAwarded, session, winner)
                if not ok2 then IT:Debug("RCLC award hook error: " .. tostring(err)) end
            end)
            IT:Debug("RCLC: hooked OnAwardedReceived")
        end
    end

    -- Also listen for RCMLAwardSuccess (ML client only, as bonus)
    if RC.RegisterMessage then
        RC:RegisterMessage("RCMLAwardSuccess", function(_, session, winner, status, link)
            if not activeSessions[session] then
                -- ML might see this before OnLootTableReceived fired the ROLL
                -- Just record it for history via ITEM_LOOTED (LootDetector handles it)
                return
            end
            pcall(OnItemAwarded, session, winner)
        end)
        IT:Debug("RCLC: registered RCMLAwardSuccess")
    end

    -- Clean up when session ends
    if RC.RegisterMessage then
        RC:RegisterMessage("RCSessionEnd", function()
            if not TrackingEnabled() then return end
            -- Finish any unfinished sessions
            for session, rollData in pairs(activeSessions) do
                if not rollData.finished then
                    rollData.finished = true
                    IT.Events:Fire("ROLL_ENDED", rollData)
                end
            end
            wipe(activeSessions)
        end)
    end

    -- Start polling timer for non-council award detection and safety timeout
    C_Timer.NewTicker(POLL_INTERVAL, function()
        local ok2, err = pcall(PollActiveSessions)
        if not ok2 then IT:Debug("RCLC poll error: " .. tostring(err)) end
    end)

    hooked = true
    IT:Print("RCLootCouncil integration active", IT.Colors.success)
end

-- ============================================================================
-- Public API
-- ============================================================================

function RCLC:IsActive()
    return hooked
end

function RCLC:GetActiveSession(session)
    return activeSessions[session]
end

function RCLC:GetActiveSessions()
    return activeSessions
end

-- ============================================================================
-- Module Interface
-- ============================================================================

function RCLC:Initialize()
    -- Fallback award detection for non-council players
    IT.Events:Subscribe("ITEM_LOOTED", OnItemLooted)

    if IsRCLoaded() then
        -- RC already loaded, hook now (with slight delay for RC to finish init)
        C_Timer.After(1, InstallHooks)
    else
        -- Wait for RC to load
        IT:RegisterEvent("ADDON_LOADED", function(addon)
            for _, name in ipairs(RC_ADDON_NAMES) do
                if addon == name then
                    C_Timer.After(1, InstallHooks)
                    return
                end
            end
        end)
    end
end
