local H = ...
H.test("roll timestamps survive reload", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    f.clock:advance(100)
    f:award()
    local timestamp = history:GetEntry(1).timestamp
    assert(timestamp == time(), "roll history must use epoch time")
    f.clock:advance(190)
    local saved = f.IT.db
    local reload = H.fixture()
    reload.clock:advance(190)
    reload.IT.db = saved
    reload:module("LootHistory")
    assert(saved.history[1].timestamp == timestamp)
    assert(reload.IT:FormatTimeAgo(timestamp) == "1m ago")
end)
H.test("recent lookup tolerates migrated timestamps", function()
    local f = H.fixture()
    f.IT.db.history = { { itemID = 123, timestamp = 100 }, { itemID = 123, timestamp = time() - 5 } }
    local history = f:module("LootHistory")
    assert(history:GetEntry(1).timestamp == nil)
    assert(history:FindRecentByItem(123) == 2)
    f.clock:advance(40)
    assert(history:FindRecentByItem(123) == nil)
end)
for _, order in ipairs({ "loot first", "award first" }) do
    H.test("external award reconciles " .. order, function()
        local f = H.fixture()
        local history = f:module("LootHistory")
        if order == "loot first" then
            f:loot()
            f:award("Me-TestRealm")
        else
            f:award("Me-TestRealm")
            f:loot()
        end
        assert(history:GetCount() == 1, "one award must create one history entry")
        local entry = history:GetEntry(1)
        assert(entry.wasRolled and entry.winner == "Me-TestRealm" and entry.isSelf)
        assert(entry.count == 1 and entry.rolls[1].number == 99)
    end)
    H.test("repeated copies remain distinct " .. order, function()
        local f = H.fixture()
        local history = f:module("LootHistory")
        if order == "loot first" then
            f:loot()
            f:loot()
            f:award()
            f:award()
        else
            f:award()
            f:award()
            f:loot()
            f:loot()
        end
        assert(history:GetCount() == 2)
        for _, entry in ipairs(history:GetAll()) do
            assert(entry.wasRolled and entry.count == 1)
        end
        f:loot()
        assert(history:GetCount() == 3, "a third copy must not match a consumed award")
    end)
end
H.test("stack quantities are consumed once", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    f:loot(nil, 3)
    f:award()
    f:award()
    assert(history:GetCount() == 3 and history:GetEntry(3).count == 1)
    history:Clear()
    f:award(nil, 3)
    f:loot()
    f:loot(nil, 3)
    assert(history:GetCount() == 2)
    assert(history:GetEntry(1).count == 1 and not history:GetEntry(1).wasRolled)
    assert(history:GetEntry(2).count == 3 and history:GetEntry(2).wasRolled)
end)
H.test("different recipients and old drops stay separate", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    f:loot("Me-OtherRealm")
    f:award("Me-TestRealm")
    f:loot("Another")
    assert(history:GetCount() == 3)
    f.clock:advance(31)
    f:loot("Me-TestRealm")
    assert(history:GetCount() == 4)
    f.IT.Events:Fire("ROLL_ENDED", { itemID = 123, count = 1, rolls = {}, startTime = GetTime() })
    assert(history:GetCount() == 5, "a roll without a winner cannot consume loot")
end)
H.test("a repeated callback does not hide a new roll with the same id", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    local first = f:award()
    f.IT.Events:Fire("ROLL_ENDED", first)
    assert(history:GetCount() == 1)
    f:award()
    assert(history:GetCount() == 2)
end)
H.test("native roll table does not suppress another copy", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    local roll = f:award()
    f.IT.RollTracker = {
        GetActiveRolls = function()
            return { [1] = roll }
        end,
    }
    f:loot()
    f:loot()
    assert(history:GetCount() == 2)
end)
H.test("cleared and reloaded history cannot consume new loot", function()
    local f = H.fixture()
    local history = f:module("LootHistory")
    f:award()
    history:Clear()
    f:loot()
    assert(history:GetCount() == 1 and not history:GetEntry(1).wasRolled)
    local saved = f.IT.db
    local reload = H.fixture()
    reload.IT.db = saved
    local reloaded = reload:module("LootHistory")
    reload:award()
    assert(reloaded:GetCount() == 2)
end)
for _, first in ipairs({ "LootHistory", "RCLCIntegration" }) do
    H.test("nested RCLC award with " .. first .. " subscribed first", function()
        local f = H.fixture()
        f:module(first)
        f:module(first == "LootHistory" and "RCLCIntegration" or "LootHistory")
        local sessions = f.IT.RCLCIntegration:GetActiveSessions()
        for i = 1, 2 do
            sessions[i] = {
                itemID = 123,
                itemLink = "item:123",
                quality = 4,
                count = 1,
                startTime = GetTime(),
                rollID = 100000 + i,
                rolls = {},
                finished = false,
            }
        end
        f:loot()
        f:loot()
        local history = f.IT.LootHistory
        assert(history:GetCount() == 2)
        for _, entry in ipairs(history:GetAll()) do
            assert(entry.wasRolled and entry.winner == "Me")
        end
    end)
end
H.test("LootReserve winner hook reconciles ordinary loot", function()
    local f = H.fixture()
    f.items[123] = 4
    IsAddOnLoaded = function(name)
        return name == "LootReserve"
    end
    LootReserve = { Comm = { Handlers = { [19] = H.noop } } }
    f:module("LRIntegration")
    local history = f:module("LootHistory")
    f.clock:advance(1)
    assert(f.IT.LRIntegration:IsActive())
    f:loot()
    LootReserve.Comm.Handlers[19]("Leader", "123", " Me-TestRealm ", "", 99)
    assert(history:GetCount() == 1 and history:GetEntry(1).rolls[1].number == 99)
    f.clock:advance(4)
    LootReserve.Comm.Handlers[19]("Leader", "123", "Me", "", 88)
    f:loot()
    assert(history:GetCount() == 2 and history:GetEntry(1).rolls[1].number == 88)
end)
