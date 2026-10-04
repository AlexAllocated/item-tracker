--[[
    ItemTracker - GearGoals Module
    Single Responsibility: Storage, loadout management, equipped scan,
    goal CRUD, rank-suppression logic, and dedup state for the gear-goal
    tracker feature. No UI, no event detection — those live in sibling
    modules (Detector, Alert, Tooltip, UI).

    Per-character data shape (in ItemTrackerCharDB):
        currentPhase = "pre-raid"             -- per-character so alts can chase
                                              -- different phases independently
        loadouts = {                          -- max 2 entries, user-named
            { id = "L1", name = "Resto",        isMain = true  },
            { id = "L2", name = "Enhancement",  isMain = false },
        }
        loadoutCounter = 2                    -- monotonic ID generator
        goals = {
            [loadoutID] = {                   -- "L1", "L2", or migrated key
                [phase] = {                   -- "pre-raid", "1", "2", "3", "3.5", "4"
                    [slotID] = {              -- INVSLOT_HEAD .. INVSLOT_RANGED
                        { itemID, rank, obtained, note },
                        ...
                    },
                },
            },
        }

    Account-wide settings (in ItemTrackerDB.settings.gearGoals):
        notifySound  = true
        popupAnchor  = nil

    Notes:
    - "Main" loadout is whichever has isMain=true; rolls map MS=main, OS=other.
    - There is no automatic detection from talent points; the user names and
      maintains the loadouts manually.
]]

local _, IT = ...
local GG = {}
IT.GearGoals = GG

-- ============================================================================
-- Constants
-- ============================================================================

GG.PHASES = { "pre-raid", "1", "2", "3", "3.5", "4" }

GG.PHASE_LABEL = {
    ["pre-raid"] = "Pre-raid",
    ["1"]        = "P1",
    ["2"]        = "P2",
    ["3"]        = "P3",
    ["3.5"]      = "P3.5",
    ["4"]        = "P4",
}

GG.PHASE_SUBTITLE = {
    ["pre-raid"] = "Heroics · Quests",
    ["1"]        = "Kara · Gruul · Mag",
    ["2"]        = "SSC · Tempest Keep",
    ["3"]        = "Hyjal · Black Temple",
    ["3.5"]      = "Zul'Aman",
    ["4"]        = "Sunwell Plateau",
}

-- 17 tracked slots (no shirt/tabard)
GG.SLOT_ORDER = {
    INVSLOT_HEAD,
    INVSLOT_NECK,
    INVSLOT_SHOULDER,
    INVSLOT_BACK,
    INVSLOT_CHEST,
    INVSLOT_WRIST,
    INVSLOT_HAND,
    INVSLOT_WAIST,
    INVSLOT_LEGS,
    INVSLOT_FEET,
    INVSLOT_FINGER1,
    INVSLOT_FINGER2,
    INVSLOT_TRINKET1,
    INVSLOT_TRINKET2,
    INVSLOT_MAINHAND,
    INVSLOT_OFFHAND,
    INVSLOT_RANGED,
}

GG.SLOT_LABEL = {
    [INVSLOT_HEAD]     = HEADSLOT,
    [INVSLOT_NECK]     = NECKSLOT,
    [INVSLOT_SHOULDER] = SHOULDERSLOT,
    [INVSLOT_BACK]     = BACKSLOT,
    [INVSLOT_CHEST]    = CHESTSLOT,
    [INVSLOT_WRIST]    = WRISTSLOT,
    [INVSLOT_HAND]     = HANDSSLOT,
    [INVSLOT_WAIST]    = WAISTSLOT,
    [INVSLOT_LEGS]     = LEGSSLOT,
    [INVSLOT_FEET]     = FEETSLOT,
    [INVSLOT_FINGER1]  = FINGER0SLOT,
    [INVSLOT_FINGER2]  = FINGER1SLOT,
    [INVSLOT_TRINKET1] = TRINKET0SLOT,
    [INVSLOT_TRINKET2] = TRINKET1SLOT,
    [INVSLOT_MAINHAND] = MAINHANDSLOT,
    [INVSLOT_OFFHAND]  = SECONDARYHANDSLOT,
    [INVSLOT_RANGED]   = RANGEDSLOT,
}

-- Class-specific labels for the ranged/relic slot. In TBC the slot 18 holds
-- different item categories per class — relic-style for Druid/Paladin/Shaman,
-- Wand for caster cloth users, Ranged weapon for Hunter/Warrior/Rogue.
local CLASS_RANGED_LABEL = {
    DRUID    = "Idol",
    PALADIN  = "Libram",
    SHAMAN   = "Totem",
    PRIEST   = "Wand",
    MAGE     = "Wand",
    WARLOCK  = "Wand",
    HUNTER   = "Ranged",
    WARRIOR  = "Ranged",
    ROGUE    = "Ranged",
}

--- Resolve the display label for a slot, using class-specific overrides for
--- the ranged/relic slot. All other slots use the localized Blizzard global.
function GG:GetSlotLabel(slotID)
    if slotID == INVSLOT_RANGED then
        local _, class = UnitClass("player")
        local override = class and CLASS_RANGED_LABEL[class]
        if override then return override end
    end
    return GG.SLOT_LABEL[slotID] or "?"
end

-- Item slot type -> the inventory slot(s) it can be equipped in.
-- Used to resolve a goal item to "which slot does this belong in".
local INVTYPE_TO_SLOT = {
    INVTYPE_HEAD            = { INVSLOT_HEAD },
    INVTYPE_NECK            = { INVSLOT_NECK },
    INVTYPE_SHOULDER        = { INVSLOT_SHOULDER },
    INVTYPE_CLOAK           = { INVSLOT_BACK },
    INVTYPE_CHEST           = { INVSLOT_CHEST },
    INVTYPE_ROBE            = { INVSLOT_CHEST },
    INVTYPE_WRIST           = { INVSLOT_WRIST },
    INVTYPE_HAND            = { INVSLOT_HAND },
    INVTYPE_WAIST           = { INVSLOT_WAIST },
    INVTYPE_LEGS            = { INVSLOT_LEGS },
    INVTYPE_FEET            = { INVSLOT_FEET },
    INVTYPE_FINGER          = { INVSLOT_FINGER1, INVSLOT_FINGER2 },
    INVTYPE_TRINKET         = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 },
    INVTYPE_WEAPON          = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_2HWEAPON        = { INVSLOT_MAINHAND },
    INVTYPE_WEAPONMAINHAND  = { INVSLOT_MAINHAND },
    INVTYPE_WEAPONOFFHAND   = { INVSLOT_OFFHAND },
    INVTYPE_HOLDABLE        = { INVSLOT_OFFHAND },
    INVTYPE_SHIELD          = { INVSLOT_OFFHAND },
    INVTYPE_RANGED          = { INVSLOT_RANGED },
    INVTYPE_RANGEDRIGHT     = { INVSLOT_RANGED },
    INVTYPE_THROWN          = { INVSLOT_RANGED },
    INVTYPE_RELIC           = { INVSLOT_RANGED },
}
GG.INVTYPE_TO_SLOT = INVTYPE_TO_SLOT

-- ============================================================================
-- Defaults applied to ItemTrackerDB / ItemTrackerCharDB
-- Core's DeepCopyDefaults runs at ADDON_LOADED so by the time Initialize()
-- runs these keys exist.
-- ============================================================================

local DB_DEFAULTS = {
    settings = {
        gearGoals = {
            notifySound      = true,
            popupAnimations  = true,    -- fade-in + corner pulse on the BiS drop popup
            popupAnchor      = nil,
            -- Seen-items cache for the add-dialog autocomplete (account-wide,
            -- so swapping characters carries common knowledge forward).
            -- [itemID] = { name, quality, lastSeen }
            seenItems        = {},
        },
    },
}

local CHAR_DEFAULTS = {
    currentPhase   = "pre-raid",  -- per-character, so alts can chase different phases
    -- Loadouts and goals are populated by EnsureLoadouts() at Initialize.
    loadouts       = nil,
    loadoutCounter = 0,
    goals          = {},        -- [loadoutID][phase][slotID] = { goal, ... }

    -- Persistent snapshot of the player's bank contents as a set of item IDs:
    --   bankItems = { [itemID] = true, ... }
    -- Bank slots only return data while the bank UI is open in the current
    -- session, so without this cache any goal stored in the bank reads as
    -- TARGET on every login until the player physically visits a banker.
    -- Rebuilt every time the bank becomes visible (open + bag/slot changes
    -- while open + bank close), which is fine for BiS-style tracking where
    -- items are unique pieces.
    bankItems      = {},
}

local function DeepDefaults(defaults, target)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                DeepDefaults(v, target[k])
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            DeepDefaults(v, target[k])
        end
    end
end

-- ============================================================================
-- Loadouts (max 2, user-named)
-- ============================================================================

GG.MAX_LOADOUTS = 2

--- Ensure charDB has a sensible loadout list. Migration:
---   - First load on a fresh char: create one default loadout "Main".
---   - Existing data with old `[<CLASS>-<spec>]` keys: convert each to a
---     loadout, capped at MAX_LOADOUTS. The first becomes main.
local function EnsureLoadouts()
    local cdb = IT.charDB
    if not cdb then return end

    if cdb.loadouts and #cdb.loadouts > 0 then return end

    cdb.loadouts       = {}
    cdb.loadoutCounter = cdb.loadoutCounter or 0

    -- Migrate existing goal keys, if any, into loadouts (sorted alphabetically
    -- so the migration is deterministic).
    if cdb.goals then
        local existingKeys = {}
        for k in pairs(cdb.goals) do table.insert(existingKeys, k) end
        table.sort(existingKeys)
        for _, key in ipairs(existingKeys) do
            if #cdb.loadouts >= GG.MAX_LOADOUTS then break end
            local _, name = key:match("^(%w+)%-(.+)$")
            table.insert(cdb.loadouts, {
                id     = key,
                name   = name or key,
                isMain = (#cdb.loadouts == 0),
            })
        end
    end

    if #cdb.loadouts == 0 then
        cdb.loadoutCounter = cdb.loadoutCounter + 1
        table.insert(cdb.loadouts, {
            id     = "L" .. cdb.loadoutCounter,
            name   = "Main",
            isMain = true,
        })
    end
end

function GG:GetLoadouts()
    return (IT.charDB and IT.charDB.loadouts) or {}
end

function GG:GetLoadoutByID(id)
    for _, l in ipairs(self:GetLoadouts()) do
        if l.id == id then return l end
    end
    return nil
end

function GG:GetMainLoadout()
    for _, l in ipairs(self:GetLoadouts()) do
        if l.isMain then return l end
    end
    return self:GetLoadouts()[1]
end

function GG:GetMainLoadoutID()
    local m = self:GetMainLoadout()
    return m and m.id
end

function GG:GetLoadoutName(id)
    local l = self:GetLoadoutByID(id)
    return l and l.name or id
end

function GG:CanAddLoadout()
    return #self:GetLoadouts() < GG.MAX_LOADOUTS
end

--- Add a new loadout with the given display name. Returns the new loadout
--- entry, or nil + reason on failure.
function GG:AddLoadout(name)
    if not name or name:gsub("%s+", "") == "" then
        return nil, "name is empty"
    end
    if not self:CanAddLoadout() then
        return nil, "max " .. GG.MAX_LOADOUTS .. " loadouts"
    end
    local cdb = IT.charDB
    cdb.loadoutCounter = (cdb.loadoutCounter or 0) + 1
    local entry = {
        id     = "L" .. cdb.loadoutCounter,
        name   = name,
        isMain = (#cdb.loadouts == 0),
    }
    table.insert(cdb.loadouts, entry)
    IT.Events:Fire("GEAR_GOALS_LOADOUT_CHANGED", { id = entry.id, reason = "added" })
    return entry
end

function GG:RenameLoadout(id, newName)
    if not newName or newName:gsub("%s+", "") == "" then
        return false, "name is empty"
    end
    local l = self:GetLoadoutByID(id)
    if not l then return false, "loadout not found" end
    l.name = newName
    IT.Events:Fire("GEAR_GOALS_LOADOUT_CHANGED", { id = id, reason = "renamed" })
    return true
end

--- Validate and assign a hex colour (`#RRGGBB`) to a loadout. The UI uses
--- this for the small swatch on the cycle button. Pass nil to clear.
function GG:SetLoadoutColor(id, hex)
    local l = self:GetLoadoutByID(id)
    if not l then return false, "loadout not found" end
    if hex == nil or hex == "" then
        l.color = nil
    else
        local clean = (hex:sub(1, 1) == "#") and hex:sub(2) or hex
        if not clean:match("^%x%x%x%x%x%x$") then
            return false, "expected #RRGGBB"
        end
        l.color = "#" .. clean:upper()
    end
    IT.Events:Fire("GEAR_GOALS_LOADOUT_CHANGED", { id = id, reason = "color-changed" })
    return true
end

function GG:SetMainLoadout(id)
    local target = self:GetLoadoutByID(id)
    if not target then return false, "loadout not found" end
    for _, l in ipairs(self:GetLoadouts()) do
        l.isMain = (l.id == id)
    end
    IT.Events:Fire("GEAR_GOALS_LOADOUT_CHANGED", { id = id, reason = "main-changed" })
    return true
end

--- Remove a loadout and all its goals. Refuses to remove the only loadout.
function GG:RemoveLoadout(id)
    local cdb = IT.charDB
    local list = self:GetLoadouts()
    if #list <= 1 then return false, "can't remove last loadout" end

    local idx
    for i, l in ipairs(list) do if l.id == id then idx = i; break end end
    if not idx then return false, "loadout not found" end

    local wasMain = list[idx].isMain
    table.remove(list, idx)
    if cdb.goals then cdb.goals[id] = nil end
    if wasMain and list[1] then list[1].isMain = true end
    IT.Events:Fire("GEAR_GOALS_LOADOUT_CHANGED", { id = id, reason = "removed" })
    return true
end

-- ============================================================================
-- Module state (transient, not persisted)
-- ============================================================================

local state = {
    activePhase   = nil,    -- viewing phase (defaults from charDB.currentPhase)

    -- equipped[slotID] = { itemID, itemLink, quality, ilvl }
    equipped      = {},

    -- dedup: itemIDs that have already fired a notification in the current scope.
    -- Cleared on group-leave or zone change.
    dedupSeen     = {},

    -- track group/instance state for dedup-clear triggers
    wasInGroup    = nil,
    lastInstance  = nil,

    -- bank cache state (RescanBankToCache populates IT.charDB.bankItems)
    bankOpen          = false,
    bankRescanPending = false,
}
GG._state = state

-- ============================================================================
-- Goal CRUD helpers
-- ============================================================================

local function ensureSpecBucket(specKey)
    if not IT.charDB.goals then IT.charDB.goals = {} end
    if not IT.charDB.goals[specKey] then IT.charDB.goals[specKey] = {} end
    return IT.charDB.goals[specKey]
end

local function ensurePhaseBucket(specKey, phase)
    local sb = ensureSpecBucket(specKey)
    if not sb[phase] then sb[phase] = {} end
    return sb[phase]
end

local function ensureSlotBucket(specKey, phase, slotID)
    local pb = ensurePhaseBucket(specKey, phase)
    if not pb[slotID] then pb[slotID] = {} end
    return pb[slotID]
end

--- Return the ordered list of goals for a slot, or empty table.
function GG:GetGoals(specKey, phase, slotID)
    if not IT.charDB.goals then return {} end
    local sb = IT.charDB.goals[specKey];     if not sb then return {} end
    local pb = sb[phase];                     if not pb then return {} end
    return pb[slotID] or {}
end

--- Add a goal. `rank` defaults to next available rank in the slot.
--- Returns the new goal, or nil + reason on failure.
function GG:AddGoal(specKey, phase, slotID, itemID, opts)
    if not specKey or not phase or not slotID or not itemID then
        return nil, "missing argument"
    end
    opts = opts or {}
    local list = ensureSlotBucket(specKey, phase, slotID)

    -- Reject duplicates of the same itemID in the same slot
    for _, g in ipairs(list) do
        if g.itemID == itemID then return nil, "already on list" end
    end

    local goal = {
        itemID   = itemID,
        rank     = opts.rank or (#list + 1),
        obtained = opts.obtained or false,
        note     = opts.note,
    }
    table.insert(list, goal)
    self:NormalizeRanks(list)
    IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", { specKey = specKey, phase = phase, slotID = slotID })
    return goal
end

--- Remove a goal by itemID. Re-numbers remaining ranks.
function GG:RemoveGoal(specKey, phase, slotID, itemID)
    local list = self:GetGoals(specKey, phase, slotID)
    for i, g in ipairs(list) do
        if g.itemID == itemID then
            table.remove(list, i)
            self:NormalizeRanks(list)
            IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", { specKey = specKey, phase = phase, slotID = slotID })
            return true
        end
    end
    return false
end

--- Move a goal up or down the rank order. delta = -1 (up) or +1 (down).
function GG:MoveGoal(specKey, phase, slotID, itemID, delta)
    local list = self:GetGoals(specKey, phase, slotID)
    for i, g in ipairs(list) do
        if g.itemID == itemID then
            local j = i + delta
            if j < 1 or j > #list then return false end
            list[i], list[j] = list[j], list[i]
            self:NormalizeRanks(list)
            IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", { specKey = specKey, phase = phase, slotID = slotID })
            return true
        end
    end
    return false
end

function GG:NormalizeRanks(list)
    for i, g in ipairs(list) do g.rank = i end
end

function GG:SetObtained(specKey, phase, slotID, itemID, value)
    local list = self:GetGoals(specKey, phase, slotID)
    for _, g in ipairs(list) do
        if g.itemID == itemID then
            g.obtained = value and true or false
            return true
        end
    end
    return false
end

-- ============================================================================
-- Iterators / lookups
-- ============================================================================

--- Walk all matches across all specs/phases of this character for a given
--- itemID. Returns an array of `{ specKey, phase, slotID, rank, goal }`.
function GG:FindAllMatches(itemID)
    local out = {}
    if not IT.charDB.goals then return out end
    for specKey, sb in pairs(IT.charDB.goals) do
        for phase, pb in pairs(sb) do
            for slotID, list in pairs(pb) do
                for _, g in ipairs(list) do
                    if g.itemID == itemID then
                        table.insert(out, {
                            specKey = specKey,
                            phase   = phase,
                            slotID  = slotID,
                            rank    = g.rank,
                            goal    = g,
                        })
                    end
                end
            end
        end
    end
    return out
end

--- For a dropped token, walk every goal on this character and return the
--- goals whose item auto-derives back to that token. Used by the detector
--- to convert a token drop into the user's actual wishlist matches without
--- a per-item REDEMPTIONS table.
--- Each entry: `{ specKey, phase, slotID, rank, goal }`.
function GG:FindAllMatchesForToken(tokenID)
    local out = {}
    if not IT.charDB.goals or not tokenID then return out end
    local Tokens = IT.GearGoalsTokens
    if not Tokens or not Tokens.GetTokenFor then return out end

    for specKey, sb in pairs(IT.charDB.goals) do
        for phase, pb in pairs(sb) do
            for slotID, list in pairs(pb) do
                for _, g in ipairs(list) do
                    if g.itemID and Tokens:GetTokenFor(g.itemID) == tokenID then
                        table.insert(out, {
                            specKey = specKey,
                            phase   = phase,
                            slotID  = slotID,
                            rank    = g.rank,
                            goal    = g,
                        })
                    end
                end
            end
        end
    end
    return out
end

--- Determine which inventory slot an item should go into given its INVTYPE.
function GG:ResolveSlotForItem(itemID)
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
    if not equipLoc or equipLoc == "" then return nil end
    local slots = INVTYPE_TO_SLOT[equipLoc]
    if not slots or #slots == 0 then return nil end
    return slots[1], slots
end

-- ============================================================================
-- Equipped scan + rank-suppression
-- ============================================================================

local function ItemIDFromLink(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

function GG:ScanEquipped()
    for _, slotID in ipairs(GG.SLOT_ORDER) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local _, _, quality, ilvl = GetItemInfo(link)
            state.equipped[slotID] = {
                itemID    = ItemIDFromLink(link),
                itemLink  = link,
                quality   = quality,
                ilvl      = ilvl,
            }
        else
            state.equipped[slotID] = nil
        end
    end
    IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", { reason = "equipped-scan" })
end

function GG:GetEquipped(slotID) return state.equipped[slotID] end

--- The lowest goal-rank currently equipped in `slotID` for the given spec/phase.
--- Returns nil if no goal item is equipped.
local function EquippedGoalRank(specKey, phase, slotID)
    local equipped = state.equipped[slotID]
    if not equipped or not equipped.itemID then return nil end
    local list = GG:GetGoals(specKey, phase, slotID)
    for _, g in ipairs(list) do
        if g.itemID == equipped.itemID then return g.rank end
    end
    return nil
end
GG.EquippedGoalRank = EquippedGoalRank

--- Per the spec's rank-suppression rule:
--- If a rank-N goal item is currently equipped in this slot, suppress all
--- notifications for ranks >= N. (Equip rank 1 → silent. Equip rank 2 →
--- only rank 1 still notifies.) Returns true if the candidate goal is
--- still allowed to notify.
function GG:CanNotify(specKey, phase, slotID, candidateRank)
    local equippedRank = EquippedGoalRank(specKey, phase, slotID)
    if not equippedRank then return true end
    return candidateRank < equippedRank
end

-- ============================================================================
-- Per-item status (for UI rendering)
-- ============================================================================

GG.STATUS = {
    EQUIPPED = "EQUIPPED",
    OWNED    = "OWNED",
    TARGET   = "TARGET",
    LOCKED   = "LOCKED",
    COVERED  = "COVERED",   -- a higher-rank pick in this slot is owned/equipped
}

-- Bag scan: live for what's currently readable (backpack + carried bags),
-- plus a persistent snapshot of the bank read from charDB. The bank snapshot
-- is rebuilt by RescanBankToCache whenever the bank is visible (see the bank
-- event handlers in Initialize). This means goals stored in the bank are
-- counted as OWNED even when the player is nowhere near a banker.
local function ScanBagsForItemID(itemID)
    if not GetContainerNumSlots then return false end

    local function scanBag(bag)
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link and ItemIDFromLink(link) == itemID then return true end
        end
        return false
    end

    -- Live carried bags (always readable)
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        if scanBag(bag) then return true end
    end

    -- While the bank is currently open, prefer a live read — it covers the
    -- brief window between BANKFRAME_OPENED and the first throttled rescan,
    -- and it acts as a safety net if the cache is somehow stale.
    if state.bankOpen then
        if scanBag(BANK_CONTAINER or -1) then return true end
        local first = (NUM_BAG_SLOTS or 4) + 1
        local last  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7)
        for bag = first, last do
            if scanBag(bag) then return true end
        end
    end

    -- Persistent bank snapshot — populated on each bank visit, survives logout.
    local bank = IT.charDB and IT.charDB.bankItems
    if bank and bank[itemID] then return true end

    return false
end

--- Walk every bank slot we can reach and rebuild charDB.bankItems from
--- scratch. Cheap (~140 GetContainerItemLink calls worst case) and only
--- runs while the bank is visible, so the cost is bounded to actual bank
--- visits rather than every login or refresh.
---
--- The state.bankOpen guard is critical: a throttled rescan scheduled while
--- the bank was open can fire 0.2s later when the bank has already closed,
--- at which point GetContainerItemLink returns nil for bank slots and we
--- would otherwise wipe the cache to an empty table.
local function RescanBankToCache(notify)
    if not IT.charDB or not GetContainerNumSlots then return end
    if not state.bankOpen then return end

    local cache = {}
    local function scanBag(bag)
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            local id   = link and ItemIDFromLink(link)
            if id then cache[id] = true end
        end
    end

    scanBag(BANK_CONTAINER or -1)
    local firstBankBag = (NUM_BAG_SLOTS or 4) + 1
    local lastBankBag  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7)
    for bag = firstBankBag, lastBankBag do
        scanBag(bag)
    end

    IT.charDB.bankItems = cache
    if notify ~= false then IT.Events:Fire("GEAR_GOAL_LIST_CHANGED") end
end

--- PLAYERBANKSLOTS_CHANGED can fire dozens of times in rapid succession when
--- the bank first opens. Capture changes immediately while slots are readable,
--- then coalesce the UI refresh and a follow-up scan as the bank settles.
local function ScheduleBankRescan(captureNow)
    if captureNow then RescanBankToCache(false) end
    if state.bankRescanPending then return end
    state.bankRescanPending = true
    C_Timer.After(0.2, function()
        state.bankRescanPending = false
        RescanBankToCache()
    end)
end

--- Internal: ownership status for a single itemID — EQUIPPED, OWNED, or nil.
--- No phase logic, no rank logic. Reused for both "is this goal owned?" and
--- "is *some* goal in this slot owned?" (the latter drives COVERED).
local function OwnershipStatus(slotID, itemID, obtainedFlag)
    local eq = state.equipped[slotID]
    if eq and eq.itemID == itemID then return GG.STATUS.EQUIPPED end

    if obtainedFlag then return GG.STATUS.OWNED end
    for _, otherSlot in ipairs(GG.SLOT_ORDER) do
        local e = state.equipped[otherSlot]
        if e and e.itemID == itemID then return GG.STATUS.OWNED end
    end
    if ScanBagsForItemID(itemID) then return GG.STATUS.OWNED end
    return nil
end

--- Public ownership probe used by the notifier (and any future caller) to
--- ask "does the player already have this goal item, equipped or in the
--- bag/bank cache?" without going through StatusFor's phase / COVERED
--- logic. Returns true when EQUIPPED or OWNED, false otherwise.
function GG:IsItemOwned(slotID, itemID, obtainedFlag)
    return OwnershipStatus(slotID, itemID, obtainedFlag) ~= nil
end

--- Returns the display status for a goal entry given the current phase.
--- Priority:
---   1. EQUIPPED / OWNED  — this exact goal item is held
---   2. LOCKED            — goal's phase is later than current
---   3. COVERED           — a higher-rank pick in this slot is already
---                          owned/equipped (so this fallback is moot)
---   4. TARGET            — still chasing
function GG:StatusFor(specKey, phase, slotID, goal)
    local own = OwnershipStatus(slotID, goal.itemID, goal.obtained)
    if own then return own end

    local current = self:GetCurrentPhase()
    if GG:PhaseIndex(phase) > GG:PhaseIndex(current) then
        return GG.STATUS.LOCKED
    end

    -- COVERED: any higher-priority rank in this slot is already owned/equipped
    local list = self:GetGoals(specKey, phase, slotID)
    for _, other in ipairs(list) do
        if other.rank < goal.rank then
            if OwnershipStatus(slotID, other.itemID, other.obtained) then
                return GG.STATUS.COVERED
            end
        end
    end

    return GG.STATUS.TARGET
end

function GG:PhaseIndex(phase)
    for i, p in ipairs(GG.PHASES) do
        if p == phase then return i end
    end
    return 99
end

-- ============================================================================
-- Dedup state (in-memory, reset on group-leave or zone change)
-- ============================================================================

function GG:HasSeen(itemID) return state.dedupSeen[itemID] == true end

function GG:MarkSeen(itemID)
    if itemID then state.dedupSeen[itemID] = true end
end

function GG:ClearDedup(reason)
    state.dedupSeen = {}
    IT:Debug("GearGoals: dedup cleared (" .. tostring(reason) .. ")")
end

--- Drop a single itemID from the dedup set so a repeat drop can fire a
--- popup again without leaving the group / changing zone. Used by the
--- /kit drop diagnostic so the same simulated drop can be replayed.
function GG:ClearSeen(itemID)
    if itemID then state.dedupSeen[itemID] = nil end
end

-- ============================================================================
-- Seen-items cache (persistent, used by autocomplete in the add dialog)
-- ============================================================================

local SEEN_CAP   = 2000
local PRUNE_DROP = 200    -- when over cap, drop the 200 oldest entries

local function pruneSeen()
    local seen = IT.db and IT.db.settings and IT.db.settings.gearGoals
                 and IT.db.settings.gearGoals.seenItems
    if not seen then return end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    if count <= SEEN_CAP then return end

    local list = {}
    for id, entry in pairs(seen) do
        table.insert(list, { id = id, lastSeen = (entry and entry.lastSeen) or 0 })
    end
    table.sort(list, function(a, b) return a.lastSeen < b.lastSeen end)
    for i = 1, math.min(PRUNE_DROP, #list) do
        seen[list[i].id] = nil
    end
end

--- Record an item the player has encountered (chat link, tooltip, loot).
--- Lazy: missing name/quality is resolved via GetItemInfo, and the call is a
--- no-op if the item isn't yet in the local cache (try again later).
function GG:RememberItem(itemID, name, quality)
    if not itemID then return end
    if not IT.db or not IT.db.settings or not IT.db.settings.gearGoals then return end

    if not name or not quality then
        local n, _, q = GetItemInfo(itemID)
        name    = name    or n
        quality = quality or q
    end
    if not name then return end   -- not in client cache yet — skip

    local seen = IT.db.settings.gearGoals.seenItems
    seen[itemID] = {
        name     = name,
        quality  = quality or 1,
        lastSeen = time(),
    }
    pruneSeen()
end

-- ============================================================================
-- Autocomplete suggestion provider
-- ============================================================================

--- Return up to `limit` suggestions for the add-dialog autocomplete.
--- Sources, in order of priority:
---   1. AtlasLoot TBCA_BIS curated list for the player's class (all class
---      specs unioned, deduplicated, ranked by rank order within their spec).
---   2. The local seen-items cache, filtered to items equippable in `slotID`.
--- The seen-items source is only consulted when `query` is non-empty
--- (avoids dumping the cache when the dialog opens with empty input).
--- Items already on the loadout's slot list are filtered out.
function GG:GetAutocompleteSuggestions(slotID, phase, loadoutID, query, limit)
    limit = limit or 8
    query = (query or ""):lower()

    local out, seenIDs, excluded = {}, {}, {}
    for _, g in ipairs(self:GetGoals(loadoutID, phase, slotID)) do
        excluded[g.itemID] = true
    end

    local function pushIfMatches(itemID, source)
        if excluded[itemID] or seenIDs[itemID] then return end
        local name, _, quality = GetItemInfo(itemID)
        if not name then return end
        if query ~= "" and not name:lower():find(query, 1, true) then return end
        seenIDs[itemID] = true
        table.insert(out, {
            itemID  = itemID,
            name    = name,
            quality = quality or 1,
            source  = source,
        })
    end

    -- Source 1: TBCA_BIS curated picks for this slot/phase, all class specs.
    if IT.GearGoalsAtlasLoot and IT.GearGoalsAtlasLoot.GetBiSItemsForSlot then
        local items = IT.GearGoalsAtlasLoot:GetBiSItemsForSlot(slotID, phase)
        if items then
            for _, id in ipairs(items) do
                pushIfMatches(id, "BiS")
                if #out >= limit then return out end
            end
        end
    end

    -- Source 2: Seen-items cache. Only when the user has typed something —
    -- otherwise we'd dump arbitrary loot history into the dropdown.
    if query ~= "" then
        local seen = (IT.db.settings.gearGoals and IT.db.settings.gearGoals.seenItems) or {}
        for itemID, entry in pairs(seen) do
            if not excluded[itemID] and not seenIDs[itemID] and entry.name then
                if entry.name:lower():find(query, 1, true) then
                    -- Only suggest items equippable in this slot
                    local _, validSlots = self:ResolveSlotForItem(itemID)
                    local valid = false
                    if validSlots then
                        for _, s in ipairs(validSlots) do
                            if s == slotID then valid = true; break end
                        end
                    end
                    if valid then
                        pushIfMatches(itemID, "Seen")
                        if #out >= limit then break end
                    end
                end
            end
        end
    end

    return out
end

-- ============================================================================
-- Phase / spec accessors used by the UI
-- ============================================================================

function GG:GetCurrentPhase()
    return (IT.charDB and IT.charDB.currentPhase) or "pre-raid"
end

function GG:SetCurrentPhase(phase)
    IT.charDB.currentPhase = phase
    IT.Events:Fire("GEAR_GOALS_PHASE_CHANGED", { phase = phase })
end

--- The phase the UI is currently *viewing* (independent of currentPhase).
function GG:GetViewedPhase() return state.activePhase or self:GetCurrentPhase() end
function GG:SetViewedPhase(phase) state.activePhase = phase end

--- The phase preceding `phase` in the canonical order. Returns nil when
--- there is no previous (i.e. for "pre-raid").
function GG:GetPreviousPhase(phase)
    for i, p in ipairs(GG.PHASES) do
        if p == phase then
            return i > 1 and GG.PHASES[i - 1] or nil
        end
    end
    return nil
end

-- ============================================================================
-- Phase encode / decode (for Export + paste-Import)
--
-- Wire format: `!GG1!<loadoutName>!<phase>!<slots>`
--   <slots> = `<slotID>=<itemID>:<rank>,<itemID>:<rank>|<slotID>=...`
-- The loadout name has its delimiter characters squashed to `_` so the
-- header parses unambiguously. Phase is the literal phase key.
-- ============================================================================

local EXPORT_VERSION_TAG = "!GG1!"
local SAFE_NAME_PATTERN  = "[!|,:=]"

local function escapeName(name)
    return (name or ""):gsub(SAFE_NAME_PATTERN, "_")
end

local function Contains(list, value)
    for _, entry in ipairs(list) do
        if entry == value then return true end
    end
    return false
end

local function PositiveInteger(value)
    return type(value) == "number" and value > 0 and value <= 9007199254740991
        and value == math.floor(value)
end

local function ValidateDecodedPhase(decoded)
    if type(decoded) ~= "table" or type(decoded.slots) ~= "table" then
        return nil, "missing slot data"
    end
    if not Contains(GG.PHASES, decoded.phase) then return nil, "unknown phase" end
    for slotID, picks in pairs(decoded.slots) do
        if not Contains(GG.SLOT_ORDER, slotID) then return nil, "unknown equipment slot" end
        if type(picks) ~= "table" then return nil, "invalid picks for slot " .. slotID end
        local count, last = 0, 0
        local items, ranks = {}, {}
        for index, pick in pairs(picks) do
            if not PositiveInteger(index) or type(pick) ~= "table"
                or not PositiveInteger(pick.itemID) or not PositiveInteger(pick.rank) then
                return nil, "invalid pick for slot " .. slotID
            end
            if items[pick.itemID] or ranks[pick.rank] then
                return nil, "duplicate item or rank in slot " .. slotID
            end
            items[pick.itemID], ranks[pick.rank] = true, true
            count, last = count + 1, math.max(last, index)
        end
        if count ~= last then return nil, "missing pick in slot " .. slotID end
    end
    return true
end

--- Build the export string for a loadout/phase. Returns a string starting
--- with `!GG1!` so it's easy to recognise when pasted.
function GG:EncodePhase(loadoutID, phase)
    if not loadoutID or not phase then return nil end
    local loadout = self:GetLoadoutByID(loadoutID)
    local name    = escapeName(loadout and loadout.name or loadoutID)

    local slotChunks = {}
    for _, slotID in ipairs(GG.SLOT_ORDER) do
        local goals = self:GetGoals(loadoutID, phase, slotID)
        if #goals > 0 then
            local picks = {}
            for _, g in ipairs(goals) do
                table.insert(picks, g.itemID .. ":" .. g.rank)
            end
            table.insert(slotChunks, slotID .. "=" .. table.concat(picks, ","))
        end
    end
    return EXPORT_VERSION_TAG .. name .. "!" .. phase .. "!" ..
           table.concat(slotChunks, "|")
end

--- Parse an export string back into `{ name, phase, slots = { [slotID] = { {itemID, rank}, ... } } }`.
--- Returns the table on success, or nil + error string on failure. Tolerates
--- trailing whitespace; rejects strings without the `!GG1!` magic header.
function GG:DecodePhase(str)
    if type(str) ~= "string" then return nil, "not a string" end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    local body = str:match("^!GG1!(.*)$")
    if not body then return nil, "missing !GG1! header" end

    local name, phase, slotData = body:match("^([^!]+)!([^!]+)!(.*)$")
    if not (name and phase) then return nil, "malformed header" end

    local result = { name = name, phase = phase, slots = {} }
    if slotData ~= "" then
        for slotChunk in (slotData .. "|"):gmatch("(.-)|") do
            local slotID, picksStr = slotChunk:match("^(%d+)=(.+)$")
            if not slotID then return nil, "malformed slot data" end
            slotID = tonumber(slotID)
            if result.slots[slotID] then return nil, "duplicate slot " .. slotID end
            local picks = {}
            for pick in (picksStr .. ","):gmatch("(.-),") do
                local itemID, rank = pick:match("^(%d+):(%d+)$")
                if not itemID then return nil, "malformed pick for slot " .. slotID end
                table.insert(picks, { itemID = tonumber(itemID), rank = tonumber(rank) })
            end
            result.slots[slotID] = picks
        end
    end
    local valid, reason = ValidateDecodedPhase(result)
    if not valid then return nil, reason end
    return result
end

--- Apply a decoded phase blob to a loadout/phase.
--- mode: "merge" (skip duplicates, keep existing) or "overwrite" (replace).
--- Returns: ok, added, skipped (or nil + reason).
function GG:ApplyDecodedPhase(loadoutID, phase, decoded, mode)
    local valid, reason = ValidateDecodedPhase(decoded)
    if not valid then return nil, reason end
    if not self:GetLoadoutByID(loadoutID) then return nil, "loadout not found" end
    if not Contains(GG.PHASES, phase) then return nil, "unknown destination phase" end
    mode = mode or "merge"
    if mode ~= "merge" and mode ~= "overwrite" then return nil, "unknown import mode" end

    -- Prepare the entire replacement before changing saved goals or notifying
    -- listeners. A failed import must leave the original phase intact.
    local replacement = {}
    local existing = IT.charDB.goals and IT.charDB.goals[loadoutID]
    if mode == "merge" then
        for slotID, goals in pairs(existing and existing[phase] or {}) do
            local list = {}
            for _, goal in ipairs(goals) do
                local copy = {}
                for key, value in pairs(goal) do copy[key] = value end
                list[#list + 1] = copy
            end
            replacement[slotID] = list
        end
    end
    local added, skipped = 0, 0
    for slotID, picks in pairs(decoded.slots) do
        local list = replacement[slotID] or {}
        replacement[slotID] = list
        local seen, ordered = {}, {}
        for _, goal in ipairs(list) do seen[goal.itemID] = true end
        for _, pick in ipairs(picks) do ordered[#ordered + 1] = pick end
        table.sort(ordered, function(a, b) return a.rank < b.rank end)
        for _, pick in ipairs(ordered) do
            if seen[pick.itemID] then
                skipped = skipped + 1
            else
                list[#list + 1] = { itemID = pick.itemID, rank = #list + 1, obtained = false }
                seen[pick.itemID] = true
                added = added + 1
            end
        end
        self:NormalizeRanks(list)
    end
    ensureSpecBucket(loadoutID)[phase] = replacement
    IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", {
        loadoutID = loadoutID, phase = phase, reason = "imported",
    })
    return true, added, skipped
end

--- Deep-copy every per-slot goal list from `fromPhase` into `toPhase` for the
--- given loadout, resetting `obtained=false` on each copy. Overwrites
--- `toPhase` wholesale. Returns true on success, or false plus an error
--- message describing why nothing was copied.
function GG:CopyPhase(loadoutID, fromPhase, toPhase)
    if not loadoutID then return false, "no loadout" end
    if fromPhase == toPhase then return false, "same phase" end

    local goals = IT.charDB.goals
    local src   = goals and goals[loadoutID] and goals[loadoutID][fromPhase]
    if not src or not next(src) then
        return false, "source phase is empty"
    end

    if not goals[loadoutID] then goals[loadoutID] = {} end
    local dest = {}
    for slotID, list in pairs(src) do
        local copy = {}
        for _, g in ipairs(list) do
            table.insert(copy, {
                itemID   = g.itemID,
                rank     = g.rank,
                obtained = false,
                note     = g.note,
            })
        end
        dest[slotID] = copy
    end
    goals[loadoutID][toPhase] = dest

    IT.Events:Fire("GEAR_GOAL_LIST_CHANGED", {
        loadoutID = loadoutID,
        phase     = toPhase,
        reason    = "phase-copied",
    })
    return true
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

local function CheckGroupAndZoneTransitions()
    local inGroup = IsInGroup() or IsInRaid()
    local _, instType, instID = nil, nil, nil
    if IsInInstance then instType = select(2, IsInInstance()) end
    if GetInstanceInfo then _, _, _, _, _, _, _, instID = GetInstanceInfo() end
    local instKey = (instType or "") .. ":" .. (instID or "")

    if state.wasInGroup == nil then
        state.wasInGroup   = inGroup
        state.lastInstance = instKey
        return
    end

    if state.wasInGroup and not inGroup then
        GG:ClearDedup("left group")
    end
    if state.lastInstance ~= instKey then
        GG:ClearDedup("instance change: " .. tostring(state.lastInstance) .. " -> " .. instKey)
    end

    state.wasInGroup   = inGroup
    state.lastInstance = instKey
end

function GG:Initialize()
    -- One-shot migration: currentPhase used to live in account-wide settings
    -- (IT.db.settings.gearGoals.currentPhase). It's now per-character so alts
    -- can chase different phases independently. Seed each character's first
    -- value from whatever the account had so existing users don't snap back
    -- to "pre-raid". Must run BEFORE DeepDefaults, otherwise the per-char
    -- default would mask the account value we want to copy.
    if IT.charDB.currentPhase == nil
       and IT.db.settings
       and IT.db.settings.gearGoals
       and IT.db.settings.gearGoals.currentPhase then
        IT.charDB.currentPhase = IT.db.settings.gearGoals.currentPhase
    end

    -- Apply our own defaults on top of the DB
    DeepDefaults(DB_DEFAULTS,   IT.db)
    DeepDefaults(CHAR_DEFAULTS, IT.charDB)
    EnsureLoadouts()

    -- WoW events
    IT:RegisterEvent("PLAYER_LOGIN",            function() GG:ScanEquipped(); CheckGroupAndZoneTransitions() end)
    IT:RegisterEvent("PLAYER_ENTERING_WORLD",   function() GG:ScanEquipped(); CheckGroupAndZoneTransitions() end)
    IT:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() GG:ScanEquipped() end)
    IT:RegisterEvent("GROUP_ROSTER_UPDATE",      function() CheckGroupAndZoneTransitions() end)

    -- Bank cache: bank slots only return data while the bank UI is open in
    -- the current session, so we snapshot the bank into charDB.bankItems
    -- whenever the bank is visible. After that, the cache stays valid across
    -- logout, /reload, and travelling away from the banker.
    IT:RegisterEvent("BANKFRAME_OPENED",        function()
        state.bankOpen = true
        ScheduleBankRescan()
    end)
    IT:RegisterEvent("BANKFRAME_CLOSED",        function()
        state.bankOpen = false
        -- No rescan on close: PLAYERBANKSLOTS_CHANGED / BAG_UPDATE while the
        -- bank was open already kept the cache in sync with every move, and
        -- a rescan after this point would read nil from every bank slot and
        -- wipe the cache.
        IT.Events:Fire("GEAR_GOAL_LIST_CHANGED")  -- repaint without the live-bank fallback
    end)
    IT:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
        if state.bankOpen then ScheduleBankRescan(true) end
    end)
    -- BAG_UPDATE fires for both carried bags (which we don't care about for
    -- the bank cache) and bank bags (which we do, but only while the bank UI
    -- is open). Filter to bank bag IDs to avoid pointless rescans on every
    -- backpack change.
    IT:RegisterEvent("BAG_UPDATE", function(bag)
        if not state.bankOpen then return end
        if bag == (BANK_CONTAINER or -1) then ScheduleBankRescan(true); return end
        local first = (NUM_BAG_SLOTS or 4) + 1
        local last  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7)
        if bag >= first and bag <= last then ScheduleBankRescan(true) end
    end)

    IT:Debug("GearGoals initialized")
end
