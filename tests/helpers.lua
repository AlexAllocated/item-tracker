local H = { passed = 0 }
function H.noop() end
function H.load(path, IT)
    return assert(loadfile((os.getenv("ITEMTRACKER_SOURCE") or ".") .. "/" .. path))("ItemTracker", IT)
end
function H.clock()
    local clock = { now = 0, timers = {} }
    GetTime = function()
        return clock.now
    end
    time = function()
        return 1800000000 + math.floor(clock.now)
    end
    local function schedule(delay, callback, interval)
        local timer = { at = clock.now + delay, callback = callback, interval = interval }
        function timer:Cancel()
            self.cancelled = true
        end
        clock.timers[#clock.timers + 1] = timer
        return timer
    end
    C_Timer = {
        After = function(delay, callback)
            return schedule(delay, callback)
        end,
        NewTicker = function(delay, callback)
            return schedule(delay, callback, delay)
        end,
    }
    function clock:advance(to)
        assert(to >= self.now)
        while true do
            local nextTimer
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.at <= to and (not nextTimer or timer.at < nextTimer.at) then
                    nextTimer = timer
                end
            end
            if not nextTimer then
                break
            end
            self.now = nextTimer.at
            if nextTimer.interval then
                nextTimer.at = self.now + nextTimer.interval
            else
                nextTimer.cancelled = true
            end
            nextTimer.callback()
        end
        self.now = to
    end
    function clock:active()
        local count = 0
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled then
                count = count + 1
            end
        end
        return count
    end
    return clock
end
function H.fixture()
    local f = { clock = H.clock(), items = {}, grouped = true, frames = {} }
    UnitName = function()
        return "Me"
    end
    GetRealmName = function()
        return "Test Realm"
    end
    IsInGroup = function()
        return f.grouped
    end
    IsInRaid = function()
        return false
    end
    IsAddOnLoaded = function()
        return false
    end
    C_AddOns, LibStub, LootReserve = nil, nil, nil
    SlashCmdList = {}
    wipe = function(t)
        for k in pairs(t) do
            t[k] = nil
        end
    end
    string.trim = function(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    CreateFrame = function()
        local frame = { scripts = {}, RegisterEvent = H.noop, UnregisterEvent = H.noop }
        function frame:SetScript(name, callback)
            self.scripts[name] = callback
        end
        f.frames[#f.frames + 1] = frame
        return frame
    end
    GetItemInfo = function(item)
        local id = type(item) == "number" and item or tonumber(item:match("item:(%d+)"))
        local quality = f.items[id]
        if quality ~= nil then
            return "Item " .. id, "item:" .. id, quality, nil, nil, nil, nil, nil, nil, id
        end
    end
    LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    LOOT_ITEM_SELF = "You receive loot: %s."
    LOOT_ITEM_MULTIPLE = "%s receives loot: %sx%d."
    LOOT_ITEM = "%s receives loot: %s."
    LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
    LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
    LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
    LOOT_ITEM_CREATED_SELF = "You create: %s."
    local slots = {
        HEAD = 1,
        NECK = 2,
        SHOULDER = 3,
        CHEST = 5,
        WAIST = 6,
        LEGS = 7,
        FEET = 8,
        WRIST = 9,
        HAND = 10,
        FINGER1 = 11,
        FINGER2 = 12,
        TRINKET1 = 13,
        TRINKET2 = 14,
        BACK = 15,
        MAINHAND = 16,
        OFFHAND = 17,
        RANGED = 18,
    }
    for name, id in pairs(slots) do
        _G["INVSLOT_" .. name] = id
    end
    local IT = {}
    H.load("Core.lua", IT)
    IT.db = {
        settings = { enabled = true, soloQualityThreshold = 2, groupQualityThreshold = 3, historySize = 100 },
        history = {},
    }
    IT.charDB = {}
    IT.Print = H.noop
    IT.Debug = function(_, message)
        -- Core deliberately catches subscriber errors; let regressions fail the test.
        if message:find("error") then
            error(message, 0)
        end
    end
    f.IT = IT
    function f:event(name, ...)
        self.frames[1].scripts.OnEvent(self.frames[1], name, ...)
    end
    function f:module(name)
        H.load("modules/" .. name .. ".lua", IT)
        IT[name]:Initialize()
        return IT[name]
    end
    function f:loot(player, count, id)
        local entry = {
            itemID = id or 123,
            itemLink = "item:" .. (id or 123),
            quality = 4,
            count = count or 1,
            player = player or "Me",
            isSelf = not player or player == "Me",
            isGroupLoot = true,
            timestamp = time(),
            icon = 123,
        }
        IT.Events:Fire("ITEM_LOOTED", entry)
        return entry
    end
    function f:award(player, count, id)
        local roll = {
            itemID = id or 123,
            itemLink = "item:" .. (id or 123),
            quality = 4,
            count = count or 1,
            winner = player or "Me",
            startTime = GetTime(),
            rollID = 100001,
            rolls = { { player = player or "Me", rollType = "council", number = 99 } },
        }
        IT.Events:Fire("ROLL_ENDED", roll)
        return roll
    end
    return f
end
function H.test(name, callback)
    if arg[2] and arg[2] ~= name then
        return
    end
    callback()
    H.passed = H.passed + 1
    print("PASS " .. name)
end
return H
