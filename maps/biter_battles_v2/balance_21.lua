-- Factorio 2.1 balance layer.
--
-- Factorio 2.1 rebalanced vanilla prototypes that Biter Battles fights with, the
-- shotgun first of all. A scenario cannot change prototypes, so this module puts
-- the 2.0.77 behaviour back through runtime levers:
--   * the shotgun-shell damage and gun-speed modifiers of the team forces,
--     recomputed from BB's own value after every research and at every map reset;
--   * the 2.0 unlock order: the combat shotgun with military 3, piercing shells
--     with military 4 (2.1 swapped them);
--   * the 2.0 movement slow-down while a character shoots a shotgun (2.1 dropped
--     it), through the character's running speed modifier;
--   * the new 2.1 shotgun slow sticker on hit enemies, removed while a shotgun is
--     in use;
--   * the flamethrower turret, which 2.1 made lead its target: its damage x0.85
--     (owner decision, 23/10/2026), through the turret-only attack modifier.
-- The measurements behind every number are in BALANCE-2.1.md.
--
-- On Factorio 2.0 ACTIVE is false: every entry point returns at once and
-- main.lua registers no handler, so no modifier, recipe or storage key is written.
local Tables = require('maps.biter_battles_v2.tables')

local Public = {}

local ACTIVE = helpers.compare_versions(script.active_mods.base, '2.1.0') >= 0
Public.ACTIVE = ACTIVE

-- 2.1 pellet pattern: a 2.5-tile disc at full range instead of a +/-0.15 rad cone,
-- and 0.2-tile pellets instead of 0.1. Measured hits per pellet, 2.1 over 2.0:
-- x1.03 on a dense pack, x1.14 on a column, x1.2-1.25 on a lone biter. Taken out
-- of the fire rate, so the damage of one pellet, which meets flat resistances,
-- stays the 2.0 one.
Public.PELLET_GEOMETRY = 1.1

-- Per phase: the factors on (1 + modifier) that give the best gun and ammo of
-- that tech stage its 2.0 damage per pellet (`damage`) and its 2.0 pellet hits
-- per second (`rate`, on the shotgun-shell gun speed modifier).
Public.SHOTGUN_PHASES = {
    -- Before military 3: the pump shotgun with plain shells. Cooldown 60 -> 40.
    shotgun = { damage = 1, rate = (40 / 60) / Public.PELLET_GEOMETRY },
    -- Military 3: the combat shotgun with plain shells. Gun bonus x1.2 -> x1.5.
    combat = { damage = 1.2 / 1.5, rate = 1 / Public.PELLET_GEOMETRY },
    -- Military 4: the combat shotgun with piercing shells. Pellet 8 -> 12 damage,
    -- 16 -> 18 pellets a shell.
    piercing = { damage = (8 * 1.2) / (12 * 1.5), rate = (16 / 18) / Public.PELLET_GEOMETRY },
}

-- Flamethrower turret damage on 2.1, as a factor on what 2.1 gives with BB's own
-- bonuses. The flamethrower ammo modifier and the flamethrower-turret attack
-- modifier multiply (bench: -0.5 and -0.5 give x0.25, +1 and +1 give x4), so the
-- factor goes on (1 + turret modifier). Turret only: the handheld and tank
-- flamethrowers use the ammo modifier alone and stay as they are.
Public.FLAMER_TURRET_FACTOR = 0.85

-- The 2.0.77 gun prototypes: movement_slow_down_factor, and the slow-down
-- window after a shot (movement_slow_down_cooldown defaults to the cooldown).
Public.SHOTGUN_SLOWDOWN = {
    ['shotgun'] = { factor = 0.6, window = 60 },
    ['combat-shotgun'] = { factor = 0.5, window = 30 },
}

local STICKER = 'shotgun-impact-sticker'
-- The poll runs every 2 ticks.
local POLL_MARGIN = 2
-- Pellets fly at most 15 + 2.5 tiles; the hit biter may have walked a little.
local STICKER_RADIUS = 20

---A force BB arms: a team (it has a `<team>_biters` force) or the spectators.
---@param force LuaForce
---@return boolean
local function is_team_force(force)
    local name = force.name
    return name == 'spectator' or game.forces[name .. '_biters'] ~= nil
end

---@param force LuaForce
---@return string
function Public.shotgun_phase(force)
    local t = force.technologies
    if t['military-4'].researched then
        return 'piercing'
    elseif t['military-3'].researched then
        return 'combat'
    end
    return 'shotgun'
end

---The shotgun-shell damage modifier BB gives this force on 2.0: its combat
---balance record, else the base value of tables.lua.
---@param force LuaForce
---@return number
function Public.bb_shotgun_damage(force)
    local record = storage.combat_balance and storage.combat_balance[force.name]
    if record and record.shotgun then
        return record.shotgun
    end
    local base = Tables.ammo_modifiers and Tables.ammo_modifiers() or Tables.base_ammo_modifiers
    return base['shotgun-shell'] or 0
end

local speed_techs
---The shotgun-shell gun speed modifier the researched technologies give, as the
---engine adds it on 2.0 (BB itself never sets this one).
---@param force LuaForce
---@return number
function Public.vanilla_shotgun_speed(force)
    if not speed_techs then
        speed_techs = {}
        for name, tech in pairs(prototypes.technology) do
            for _, effect in pairs(tech.effects) do
                if effect.type == 'gun-speed' and effect.ammo_category == 'shotgun-shell' then
                    speed_techs[#speed_techs + 1] = { name = name, modifier = effect.modifier }
                end
            end
        end
        table.sort(speed_techs, function(a, b)
            return a.name < b.name
        end)
    end
    local sum = 0
    local techs = force.technologies
    for _, t in ipairs(speed_techs) do
        if techs[t.name].researched then
            sum = sum + t.modifier
        end
    end
    return sum
end

---The 2.1 shotgun-shell damage and gun speed modifiers for BB's 2.0 ones.
---
---The fire rate is pulled back through the gun speed modifier, but Factorio
---clamps a negative gun speed modifier to 0 (bench: -0.39 fires exactly like 0),
---so the rate can only come down as far as research has raised it. What it
---cannot absorb is split evenly, in ratio terms, between a lower pellet damage
---and a residual fire rate: neither unarmoured nor armoured biters (flat physical
---resistance 4 to 12 a pellet) then swing far from 2.0. From weapon shooting
---speed 1 (combat shotgun), 2 (piercing shells) or 4 (pump shotgun) the rate
---covers it all and the damage of one pellet is the 2.0 one.
---@param damage number BB's shotgun-shell damage modifier
---@param speed number the shotgun-shell gun speed modifier from research
---@param phase_name string 'shotgun' | 'combat' | 'piercing'
---@return number damage_modifier, number speed_modifier
function Public.shotgun_modifiers(damage, speed, phase_name)
    local phase = Public.SHOTGUN_PHASES[phase_name]
    local rate = (1 + speed) * phase.rate
    local extra = 1
    if rate < 1 then
        extra = math.sqrt(rate)
        rate = 1
    end
    return (1 + damage) * phase.damage * extra - 1, rate - 1
end

---The flamethrower-turret attack modifier BB gives this force on 2.0: its combat
---balance record (refined flammables), else the base value of tables.lua.
---@param force LuaForce
---@return number
function Public.bb_flamer_turret(force)
    local record = storage.combat_balance and storage.combat_balance[force.name]
    if record and record.flamethrower_damage then
        return record.flamethrower_damage
    end
    local base = Tables.turret_attack_modifiers and Tables.turret_attack_modifiers()
        or Tables.base_turret_attack_modifiers
    return base['flamethrower-turret'] or 0
end

---The 2.1 flamethrower-turret attack modifier for BB's 2.0 one: x0.85 damage.
---@param bb_modifier number
---@return number
function Public.flamer_turret_modifier(bb_modifier)
    return (1 + bb_modifier) * Public.FLAMER_TURRET_FACTOR - 1
end

---The flamethrower turret of one force at x0.85 of BB's value.
---@param force LuaForce
function Public.apply_flamer_turret(force)
    if not ACTIVE or not (force.valid and is_team_force(force)) then
        return
    end
    local modifier = Public.flamer_turret_modifier(Public.bb_flamer_turret(force))
    force.set_turret_attack_modifier('flamethrower-turret', modifier)
end

---Put the 2.0 shotgun on one force: modifiers for its tech stage, unlock order.
---@param force LuaForce
function Public.apply_shotgun(force)
    if not ACTIVE or not (force.valid and is_team_force(force)) then
        return
    end
    local damage, speed = Public.shotgun_modifiers(
        Public.bb_shotgun_damage(force),
        Public.vanilla_shotgun_speed(force),
        Public.shotgun_phase(force)
    )
    force.set_ammo_damage_modifier('shotgun-shell', damage)
    force.set_gun_speed_modifier('shotgun-shell', speed)
    local techs, recipes = force.technologies, force.recipes
    recipes['combat-shotgun'].enabled = techs['military-3'].researched
    recipes['piercing-shotgun-shell'].enabled = techs['military-4'].researched
end

---on_research_finished / on_research_reversed, registered by main.lua after BB's
---own handlers (2.1 only).
---@param event EventData.on_research_finished|EventData.on_research_reversed
function Public.on_research(event)
    if not ACTIVE then
        return
    end
    Public.apply_shotgun(event.research.force)
    Public.apply_flamer_turret(event.research.force)
end

---init.lua, at the end of Init.forces(): after the reset and BB's base modifiers.
function Public.on_forces_reset()
    if not ACTIVE then
        return
    end
    for _, force in pairs(game.forces) do
        Public.apply_shotgun(force)
        Public.apply_flamer_turret(force)
    end
end

-- functions.lua laser_buff: BB sets the laser turret attack modifier to the step
-- of the last laser-weapons-damage level researched (level 7 and above: 0.5).
local BB_LASER_TURRET = { 0.2, 0.2, 0.4, 0.4, 0.4, 0.5, 0.5 }

---BB's own modifiers of a team force, as functions.lua and init.lua last wrote
---them: its combat balance record, else the tables.lua base.
---@param force LuaForce
function Public.reapply_bb_modifiers(force)
    if not ACTIVE or not (force.valid and is_team_force(force)) then
        return
    end
    local record = storage.combat_balance and storage.combat_balance[force.name] or {}
    local ammo = Tables.ammo_modifiers and Tables.ammo_modifiers() or Tables.base_ammo_modifiers
    local turret = Tables.turret_attack_modifiers and Tables.turret_attack_modifiers()
        or Tables.base_turret_attack_modifiers
    force.set_ammo_damage_modifier('bullet', record.bullet or ammo['bullet'] or 0)
    force.set_ammo_damage_modifier('flamethrower', record.flame_damage or ammo['flamethrower'] or 0)
    force.set_ammo_damage_modifier('landmine', record.land_mine or ammo['landmine'] or 0)
    if record.grenade_damage then
        force.set_ammo_damage_modifier('grenade', record.grenade_damage)
    end
    local flamer = record.flamethrower_damage or turret['flamethrower-turret'] or 0
    force.set_turret_attack_modifier('flamethrower-turret', flamer)
    -- A key of the record exists once BB has handled that research family.
    if record.shotgun then
        -- physical-projectile-damage: BB zeroes the vanilla gun turret bonus.
        force.set_turret_attack_modifier('gun-turret', 0)
    end
    local laser = turret['laser-turret'] or 0
    if record.laser_damage then
        local techs = force.technologies
        for level = #BB_LASER_TURRET, 1, -1 do
            if techs['laser-weapons-damage-' .. level].researched then
                laser = BB_LASER_TURRET[level]
                break
            end
        end
    end
    force.set_turret_attack_modifier('laser-turret', laser)
end

---on_configuration_changed (2.1 only): a save from another version or mod set.
---The engine re-applies every technology effect then, which wipes the modifiers
---BB sets by script (measured: a 2.0 save loaded on 2.1 had bullet 0.76 -> 0.20,
---flamethrower -0.60 -> 0, flamethrower turret -0.80 -> 0). Put BB's back, then
---the 2.1 layer (shotgun, flamethrower turret). Biter force modifiers come back
---at the next feed.
function Public.on_configuration_changed()
    if not ACTIVE then
        return
    end
    for _, force in pairs(game.forces) do
        Public.reapply_bb_modifiers(force)
        Public.apply_shotgun(force)
        Public.apply_flamer_turret(force)
    end
end

---Give back the running speed modifier the character had before the slow-down,
---unless something else changed it meanwhile.
---@param state table
---@param character LuaEntity
function Public.restore(state, character)
    if math.abs(character.character_running_speed_modifier - state.set) < 1e-6 then
        character.character_running_speed_modifier = state.m0
    end
    state.applied_keep = nil
end

---The shotgun this character holds, and the rounds left in its ammo slot.
---@param character LuaEntity
---@return string? gun, integer rounds, string? ammo, integer? index
local function shotgun_rounds(character)
    local index = character.selected_gun_index
    if not index then
        return nil, 0
    end
    local gun = character.get_inventory(defines.inventory.character_guns)[index]
    if not (gun.valid_for_read and Public.SHOTGUN_SLOWDOWN[gun.name]) then
        return nil, 0
    end
    local ammo = character.get_inventory(defines.inventory.character_ammo)[index]
    if not ammo.valid_for_read then
        return gun.name, 0, nil, index
    end
    return gun.name, (ammo.count - 1) * ammo.prototype.magazine_size + ammo.ammo, ammo.name, index
end

---One character: open or extend the 2.0 slow-down window when its shotgun has
---fired since the last call (fewer rounds in the ammo slot; on 2.0 the slow-down
---also follows a shot, not the fire key), apply or lift the slow-down, and clear
---the shotgun stickers around it while the window is open. `state` belongs to
---this character.
---@param state table
---@param character LuaEntity
---@param tick integer
---@return boolean window `state` still has a window open or a modifier to give back
---@return boolean holding the character holds a shotgun (keep counting its rounds)
function Public.update_character(state, character, tick)
    if not ACTIVE then
        return false, false
    end
    local gun, rounds, ammo, index = shotgun_rounds(character)
    if
        gun
        and gun == state.gun
        and index == state.index
        and state.rounds
        and rounds < state.rounds
        and (ammo == nil or ammo == state.ammo)
        and not character.vehicle
    then
        local slow = Public.SHOTGUN_SLOWDOWN[gun]
        -- + POLL_MARGIN: a shot is seen up to 2 ticks late, the window must not
        -- lapse between two shots of a gun that fires once per window.
        state.until_tick = tick + slow.window + POLL_MARGIN
        state.keep = 1 - slow.factor
    end
    state.gun, state.index, state.rounds, state.ammo = gun, index, rounds, ammo
    if state.until_tick ~= nil and tick <= state.until_tick then
        local stickers = character.surface.find_entities_filtered({
            name = STICKER,
            position = character.position,
            radius = STICKER_RADIUS,
        })
        for _, sticker in pairs(stickers) do
            sticker.destroy()
        end
        if state.applied_keep ~= state.keep then
            if state.applied_keep == nil then
                state.m0 = character.character_running_speed_modifier
            end
            -- 2.0 multiplies the whole speed by `keep`. Exoskeletons multiply on their
            -- own, so scaling (1 + force + character modifier) by `keep` is the same.
            local total = 1 + character.force.character_running_speed_modifier + state.m0
            local value = math.max(-1, state.m0 - total * (1 - state.keep))
            character.character_running_speed_modifier = value
            state.applied_keep = state.keep
            state.set = value
        end
        return true, gun ~= nil
    end
    state.until_tick = nil
    if state.applied_keep ~= nil then
        Public.restore(state, character)
    end
    return false, gun ~= nil
end

---on_nth_tick(2), registered by main.lua on 2.1 only. The state is kept per
---character entity, not per player: a character whose player left or got a new
---body still runs out its window and gets its modifier back.
---@param event NthTickEventData
function Public.poll_players(event)
    if not ACTIVE then
        return
    end
    local states = storage.bb21_shotgun_users
    if not states then
        states = {}
        storage.bb21_shotgun_users = states
    end
    local tick = event.tick
    local guns = defines.inventory.character_guns
    for _, player in pairs(game.connected_players) do
        local character = player.character
        if character and character.valid and not states[character.unit_number] then
            local index = character.selected_gun_index
            local gun = index and character.get_inventory(guns)[index]
            if gun and gun.valid_for_read and Public.SHOTGUN_SLOWDOWN[gun.name] then
                states[character.unit_number] = { character = character }
            end
        end
    end
    for unit_number, state in pairs(states) do
        local character = state.character
        if not character.valid then
            states[unit_number] = nil
        else
            local window, holding = Public.update_character(state, character, tick)
            if not window then
                local player = holding and character.player
                if not (player and player.connected) then
                    states[unit_number] = nil
                end
            end
        end
    end
end

return Public
