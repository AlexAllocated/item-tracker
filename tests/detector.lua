local H = ...
local function setup()
    local f = H.fixture()
    f:module("LootDetector")
    f:module("LootHistory")
    f.values, f.receipts = {}, {}
    f.IT.Events:Subscribe("ITEM_VALUE", function(entry)
        f.values[#f.values + 1] = entry
    end)
    f.IT.Events:Subscribe("ITEM_LOOTED", function(entry)
        f.receipts[#f.receipts + 1] = entry
    end)
    return f
end
H.test("uncached loot is published once after item information arrives", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    assert(#f.values == 2 and #f.receipts == 0)
    f.clock:advance(5)
    f.items[123] = 4
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    assert(#f.receipts == 2, "both uncached copies must eventually reach history")
    assert(f.IT.LootHistory:GetCount() == 2)
    assert(f.receipts[1].timestamp == 1800000000 and f.receipts[1].icon == 123)
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    f.clock:advance(10)
    assert(#f.receipts == 2 and #f.values == 2 and f.clock:active() == 0)
end)
H.test("quality gate uses original group context", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "Other receives loot: item:123.")
    f.grouped = false
    f.items[123] = 2 -- passes solo threshold but not the group threshold
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    assert(#f.receipts == 0 and #f.values == 0)
    f:event("CHAT_MSG_LOOT", "You receive loot: item:456.")
    f.grouped = true
    f.items[456] = 2
    f:event("GET_ITEM_INFO_RECEIVED", 456, true)
    assert(#f.receipts == 1 and not f.receipts[1].isGroupLoot)
    f.items[789] = 0
    f:event("CHAT_MSG_LOOT", "You receive loot: item:789.")
    assert(#f.values == 2 and #f.receipts == 1)
end)
H.test("retry timer handles failed or missing item callbacks", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123x2.")
    f:event("GET_ITEM_INFO_RECEIVED", 123, false)
    f.clock:advance(3)
    assert(#f.receipts == 0)
    f.items[123] = 4
    f.clock:advance(4)
    assert(#f.receipts == 1 and f.receipts[1].count == 2)
    assert(#f.values == 1 and f.clock:active() == 0)
end)
H.test("quest and pushed items use the same deferred quality filter", function()
    local f = setup()
    f:event("QUEST_LOOT_RECEIVED", 10, "item:123", 2)
    f:event("CHAT_MSG_LOOT", "You receive item: item:123.")
    f:event("CHAT_MSG_SYSTEM", "You create: item:456x3.")
    assert(#f.values == 3 and #f.receipts == 0)
    f.items[123], f.items[456] = 4, 1
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    f:event("GET_ITEM_INFO_RECEIVED", 456, true)
    assert(#f.receipts == 2 and f.receipts[1].count == 2)
    f.clock:advance(4)
    assert(#f.values == 3 and #f.receipts == 2)
end)
H.test("disabled tracking does not publish queued loot", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    f.IT.db.settings.enabled = false
    f.items[123] = 4
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    f.clock:advance(4)
    assert(#f.receipts == 0 and #f.values == 1 and f.clock:active() == 0)
end)
H.test("unresolvable item retries stop", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    f.clock:advance(62)
    assert(#f.receipts == 0 and f.clock:active() == 0)
    f.items[123] = 4
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    assert(#f.receipts == 0 and #f.values == 1)
end)
H.test("late cache results reconcile with the original award time", function()
    local f = setup()
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    f:award()
    f.clock:advance(40)
    f.items[123] = 4
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    assert(f.IT.LootHistory:GetCount() == 1)
    assert(f.IT.LootHistory:GetEntry(1).wasRolled)
end)
H.test("late cache results reconcile with a nested council award", function()
    local f = setup()
    f:module("RCLCIntegration")
    f.IT.RCLCIntegration:GetActiveSessions()[1] = {
        itemID = 123,
        itemLink = "item:123",
        quality = 4,
        count = 1,
        startTime = GetTime(),
        rolls = {},
    }
    f:event("CHAT_MSG_LOOT", "You receive loot: item:123.")
    f.clock:advance(40)
    f.items[123] = 4
    f:event("GET_ITEM_INFO_RECEIVED", 123, true)
    assert(f.IT.LootHistory:GetCount() == 1 and f.IT.LootHistory:GetEntry(1).wasRolled)
    assert(f.IT.LootHistory:GetEntry(1).timestamp == 1800000000)
end)
