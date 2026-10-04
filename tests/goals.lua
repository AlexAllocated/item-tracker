local H = ...
local function setup()
    local f = H.fixture()
    f.goals = f:module("GearGoals")
    f.loadout = f.goals:GetMainLoadoutID()
    return f
end
local function bankSetup()
    local f = setup()
    f.bank, f.reads, f.updates, f.bankOpen = {}, 0, 0, false
    BANK_CONTAINER, NUM_BAG_SLOTS, NUM_BANKBAGSLOTS = -1, 4, 7
    GetContainerNumSlots = function(bag)
        assert(f.bankOpen, "bank slots were read after closing")
        f.reads = f.reads + 1
        return f.bank[bag] and 1 or 0
    end
    GetContainerItemLink = function(bag, slot)
        assert(f.bankOpen, "bank links were read after closing")
        return f.bank[bag] and ("item:" .. f.bank[bag])
    end
    f.IT.Events:Subscribe("GEAR_GOAL_LIST_CHANGED", function()
        f.updates = f.updates + 1
    end)
    function f:open()
        self.bankOpen = true
        self:event("BANKFRAME_OPENED")
    end
    function f:close()
        self.bankOpen = false
        self:event("BANKFRAME_CLOSED")
    end
    return f
end
for _, bag in ipairs({ -1, 5 }) do
    H.test("bank changes survive immediate close in bag " .. bag, function()
        local f = bankSetup()
        f.bank[bag] = 123
        f:open()
        f.clock:advance(0.3)
        assert(f.IT.charDB.bankItems[123])
        f.bank[bag] = 456
        if bag == -1 then
            f:event("PLAYERBANKSLOTS_CHANGED", 1)
        else
            f:event("BAG_UPDATE", bag)
        end
        f:close()
        f.clock:advance(1)
        assert(not f.IT.charDB.bankItems[123], "withdrawn item must leave the saved bank cache")
        assert(f.IT.charDB.bankItems[456], "deposited item must enter the saved bank cache")
    end)
end
H.test("bank slot bursts coalesce refreshes and ignore carried bags", function()
    local f = bankSetup()
    f:open()
    f.clock:advance(0.3)
    local reads = f.reads
    f:event("BAG_UPDATE", 0)
    assert(f.reads == reads)
    for i = 1, 10 do
        f.bank[-1] = i
        f:event("PLAYERBANKSLOTS_CHANGED", 1)
    end
    assert(f.updates == 1 and f.clock:active() == 1)
    assert(f.IT.charDB.bankItems[10] and not f.IT.charDB.bankItems[9])
    f.clock:advance(0.6)
    assert(f.updates == 2)
    f:close()
    f.clock:advance(1)
    assert(f.IT.charDB.bankItems[10])
end)
H.test("damaged import cannot erase existing goals", function()
    local f = setup()
    f.goals:AddGoal(f.loadout, "1", 1, 999, { obtained = true, note = "keep this" })
    local original = f.IT.charDB.goals[f.loadout]["1"]
    local invalid = {
        "!GG1!Main!1!1=broken",
        "!GG1!Main!1!1=123:1,broken",
        "!GG1!Main!1",
        "!GG1!Main!1!1=123:1|",
        "!GG1!Main!1!|1=123:1",
        "!GG1!Main!1!1=123:1||2=456:1",
        "!GG1!Main!1!1=123:1,",
        "!GG1!Main!1!1=123:1,,456:2",
        "!GG1!Main!1!1=",
        "!GG1!Main!1!1=123:1|1=456:1",
        "!GG1!Main!1!1=123:1,123:2",
        "!GG1!Main!1!1=123:1,456:1",
        "!GG1!Main!1!0=123:1",
        "!GG1!Main!1!99=123:1",
        "!GG1!Main!unknown!1=123:1",
        "!GG1!Main!1!1=0:1",
        "!GG1!Main!1!1=123:0",
        "!GG1!Main!1!1=-1:1",
        "!GG1!Main!1!1=1.5:1",
        "!GG1!Main!1!1=" .. string.rep("9", 400) .. ":1",
        "!GG1!Main!1!1=123:1!junk",
        "!GG1!Main!1!garbage|1=123:1",
    }
    for _, text in ipairs(invalid) do
        local decoded, reason = f.goals:DecodePhase(text)
        if decoded then
            f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "overwrite")
        end
        assert(f.IT.charDB.goals[f.loadout]["1"] == original, "invalid import changed saved goals: " .. text)
        assert(not decoded and type(reason) == "string", "invalid import accepted: " .. text)
    end
    assert(original[1][1].note == "keep this" and original[1][1].obtained)
end)
H.test("direct import validation leaves the destination untouched", function()
    local f = setup()
    f.goals:AddGoal(f.loadout, "1", 1, 999)
    local original = f.IT.charDB.goals[f.loadout]["1"]
    local invalid = {
        {},
        { phase = "1", slots = { [1] = { { itemID = 123, rank = 1 }, { itemID = 0, rank = 2 } } } },
        { phase = "1", slots = { [1] = { [2] = { itemID = 123, rank = 1 } } } },
        { phase = "1", slots = { [1] = { { itemID = 123, rank = 1 }, extra = { itemID = 456, rank = 2 } } } },
        { phase = "1", slots = { [1] = { { itemID = 123, rank = math.huge } } } },
        { phase = "1", slots = { [1] = { { itemID = 123, rank = 0 / 0 } } } },
        { phase = "1", slots = { [1] = { { itemID = "123", rank = 1 } } } },
        { phase = "1", slots = { [1] = "invalid" } },
    }
    local updates = 0
    f.IT.Events:Subscribe("GEAR_GOAL_LIST_CHANGED", function()
        updates = updates + 1
    end)
    for _, decoded in ipairs(invalid) do
        assert(not f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "overwrite"))
        assert(f.IT.charDB.goals[f.loadout]["1"] == original)
    end
    local decoded = assert(f.goals:DecodePhase("!GG1!Main!1!1=123:1"))
    assert(not f.goals:ApplyDecodedPhase("missing", "1", decoded, "overwrite"))
    assert(not f.goals:ApplyDecodedPhase(f.loadout, "unknown", decoded, "overwrite"))
    assert(not f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "invalid"))
    assert(updates == 0 and f.IT.charDB.goals[f.loadout]["1"] == original)
end)
H.test("valid overwrite replaces the whole phase with one notification", function()
    local f = setup()
    f.goals:AddGoal(f.loadout, "1", 1, 999)
    f.goals:AddGoal(f.loadout, "2", 1, 888)
    local other = f.IT.charDB.goals[f.loadout]["2"]
    local decoded = assert(f.goals:DecodePhase("  !GG1!Main!1!1=123:2,456:1|11=789:1|12=789:1\n"))
    local updates = 0
    f.IT.Events:Subscribe("GEAR_GOAL_LIST_CHANGED", function()
        updates = updates + 1
        local goals = f.IT.charDB.goals[f.loadout]["1"]
        assert(goals[1][1].itemID == 456 and goals[1][2].itemID == 123)
        assert(goals[11][1].itemID == 789 and goals[12][1].itemID == 789)
    end)
    local ok, added, skipped = f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "overwrite")
    assert(ok and added == 4 and skipped == 0 and updates == 1)
    assert(f.IT.charDB.goals[f.loadout]["2"] == other)
    assert(decoded.slots[1][1].itemID == 123, "import must not reorder the source")
    assert(f.goals:GetGoals(f.loadout, "1", 1)[1].rank == 1)
end)
H.test("merge preserves notes ownership order and other slots", function()
    local f = setup()
    f.goals:AddGoal(f.loadout, "1", 1, 123, { obtained = true, note = "owned" })
    f.goals:AddGoal(f.loadout, "1", 2, 999)
    local decoded = assert(f.goals:DecodePhase("!GG1!Main!1!1=456:2,123:1,789:3"))
    local ok, added, skipped = f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "merge")
    assert(ok and added == 2 and skipped == 1)
    local goals = f.goals:GetGoals(f.loadout, "1", 1)
    assert(#goals == 3 and goals[1].itemID == 123 and goals[1].obtained and goals[1].note == "owned")
    assert(goals[2].itemID == 456 and goals[3].itemID == 789 and not goals[2].obtained)
    assert(f.goals:GetGoals(f.loadout, "1", 2)[1].itemID == 999)
end)
H.test("empty and populated exports round trip", function()
    local f = setup()
    f.goals:AddGoal(f.loadout, "1", 1, 123)
    local exported = f.goals:EncodePhase(f.loadout, "1")
    local decoded = assert(f.goals:DecodePhase(exported))
    assert(f.goals:ApplyDecodedPhase(f.loadout, "1", decoded, "overwrite"))
    assert(f.goals:EncodePhase(f.loadout, "1") == exported)
    local empty = assert(f.goals:DecodePhase(f.goals:EncodePhase(f.loadout, "2")))
    assert(f.goals:ApplyDecodedPhase(f.loadout, "1", empty, "overwrite"))
    assert(next(f.IT.charDB.goals[f.loadout]["1"]) == nil)
end)
