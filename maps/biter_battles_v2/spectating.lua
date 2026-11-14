-- BB's own "is spectating" flag, one per player.
--
-- Factorio 2.1 removed LuaPlayer.spectator (an engine flag that, per Wube, did
-- nothing). BB used it as its own state: `init_player` and `spectate` set it,
-- `join_team` clears it and refuses a player who does not have it, and the
-- difficulty vote, the suspend vote and the comfy-panel SpectatorMode switch
-- read or write it. This module keeps exactly that flag in `storage`, so the
-- same code runs on 2.0 and 2.1.
--
-- A player with no stored value yet (a save made before this module) is seeded
-- from the force: on the spectator force means spectating. The seed is stored on
-- the first read, so later force changes do not move it; only `set` does, as
-- with the engine flag.
--
-- No requires and no event handlers: loading it changes nothing else.

local Public = {}

---@return table<uint, boolean>
local function flags()
    local t = storage.bb_spectating
    if not t then
        t = {}
        storage.bb_spectating = t
    end
    return t
end

---@param player LuaPlayer
---@return boolean
function Public.get(player)
    local t = flags()
    local value = t[player.index]
    if value == nil then
        value = player.force.name == 'spectator'
        t[player.index] = value
    end
    return value
end

---@param player LuaPlayer
---@param value boolean
function Public.set(player, value)
    flags()[player.index] = value and true or false
end

return Public
