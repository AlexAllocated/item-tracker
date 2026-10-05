local H = ...
local function council()
    local f = H.fixture()
    f.items[123], f.items[456] = 4, 4
    local vf = { OnResponseReceived = H.noop, OnAwardedReceived = H.noop }
    local rc = { enabled = true, loot = { { link = "item:123", quality = 4 } }, messages = {} }
    function rc:GetLootTable() return self.loot end
    function rc:OnLootTableReceived() end
    function rc:GetModule() return vf end
    function rc:RegisterMessage(event, fn) self.messages[event] = fn end
    IsAddOnLoaded = function(name) return name == "RCLootCouncil" end
    LibStub = function() return { GetAddon = function() return rc end } end
    hooksecurefunc = function(object, name, fn)
        local original = object[name]
        object[name] = function(...) original(...); fn(...) end
    end
    f:module("RCLCIntegration")
    f:module("LootHistory")
    f.clock:advance(1)
    return f, rc, vf
end
H.test("old council cleanup preserves a replacement session", function()
    local f, rc, vf = council()
    rc:OnLootTableReceived()
    vf:OnAwardedReceived(1, "Me")
    rc.messages.RCSessionEnd()
    rc.loot = { { link = "item:456", quality = 4 } }
    rc:OnLootTableReceived()
    local replacement = f.IT.RCLCIntegration:GetActiveSession(1)
    f.clock:advance(3)
    assert(f.IT.RCLCIntegration:GetActiveSession(1) == replacement)
    vf:OnAwardedReceived(1, "Me")
    assert(f.IT.LootHistory:GetCount() == 2 and f.IT.LootHistory:GetEntry(1).itemID == 456)
    f.clock:advance(5)
    assert(not f.IT.RCLCIntegration:GetActiveSession(1), "the replacement still cleans itself up")
end)
for _, callback in ipairs({ "start", "response", "award", "poll", "end" }) do
    H.test("disabled council integration ignores " .. callback, function()
        local f, rc, vf = council()
        if callback ~= "start" then rc:OnLootTableReceived() end
        local emitted = 0
        for _, event in ipairs({ "ROLL_STARTED", "ROLL_UPDATE", "ROLL_ENDED" }) do
            f.IT.Events:Subscribe(event, function() emitted = emitted + 1 end)
        end
        f.IT.db.settings.enabled = false
        if callback == "start" then rc:OnLootTableReceived()
        elseif callback == "response" then vf:OnResponseReceived("Me", 1, { response = 1 })
        elseif callback == "award" then vf:OnAwardedReceived(1, "Me")
        elseif callback == "poll" then rc.loot[1].awarded = "Me"; f.clock:advance(3)
        else rc.messages.RCSessionEnd() end
        assert(emitted == 0 and f.IT.LootHistory:GetCount() == 0)
        assert(not next(f.IT.RCLCIntegration:GetActiveSessions()))
        f.IT.db.settings.enabled = true
        rc.loot = { { link = "item:456", quality = 4 } }
        rc:OnLootTableReceived()
        assert(f.IT.RCLCIntegration:GetActiveSession(1).itemID == 456)
    end)
end
local function reserve()
    local f = H.fixture()
    f.items[123] = 4
    IsAddOnLoaded = function(name) return name == "LootReserve" end
    LootReserve = { Client = { RollRequest = { Item = { id = 123 } } },
        Comm = { Handlers = { [12] = H.noop, [19] = H.noop } } }
    f:module("LRIntegration")
    f:module("LootHistory")
    f.clock:advance(1)
    return f, LootReserve.Comm.Handlers
end
H.test("disabled reserve integration ignores requests and direct awards", function()
    local f, handlers = reserve()
    local starts = 0
    f.IT.Events:Subscribe("ROLL_STARTED", function() starts = starts + 1 end)
    f.IT.db.settings.enabled = false
    handlers[12]("Leader")
    handlers[19]("Leader", "123", "Me", "", 99)
    assert(starts == 0 and f.IT.LootHistory:GetCount() == 0)
    f.IT.db.settings.enabled = true
    handlers[12]("Leader")
    handlers[19]("Leader", "123", "Me", "", 99)
    assert(starts == 1 and f.IT.LootHistory:GetCount() == 1)
end)
H.test("old reserve cleanup preserves the next roll for the same item", function()
    local f, handlers = reserve()
    local rolls, ended = {}, {}
    f.IT.Events:Subscribe("ROLL_STARTED", function(roll) rolls[#rolls + 1] = roll end)
    f.IT.Events:Subscribe("ROLL_ENDED", function(roll) ended[#ended + 1] = roll end)
    handlers[12]("Leader")
    handlers[19]("Leader", "123", "Me", "", 99)
    handlers[12]("Leader")
    f.clock:advance(3)
    handlers[19]("Leader", "123", "Me", "", 88)
    assert(ended[2] == rolls[2], "the award must finish the existing roll, not invent a new one")
end)
