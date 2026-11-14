local Public = {}

local AiTargets = require('maps.biter_battles_v2.ai_targets')
local Event = require('utils.event')
local bb_config = require('maps.biter_battles_v2.config')
local Force = require('utils.force')
local MultiSilo = require('comfy_panel.special_games.multi_silo')
local Table = require('utils.table')

local math_random = math.random
local math_sqrt = math.sqrt
local math_fmod = math.fmod
local math_floor = math.floor
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_2pi = 2 * math_pi
local math_sin = math.sin
local math_cos = math.cos
local math_atan2 = math.atan2

-- these parameters roughly approximate the radius of the average player base
-- TODO: use some metric to drive adjustments on these values as the game progresses
local MAX_STRIKE_DISTANCE = 512
local MIN_STRIKE_DISTANCE = 256
local STRIKE_TARGET_CLEARANCE = 255
local _DEBUG = false

local vector_radius = 512
local attack_vectors = {}
attack_vectors.north = {}
attack_vectors.south = {}
--awesomepatrol's pathing  updates
for p = 0.3, 0.71, 0.1 do
    local a = math.pi * p
    local x = vector_radius * math.cos(a)
    local y = vector_radius * math.sin(a)
    attack_vectors.north[#attack_vectors.north + 1] = { x, y * -1 }
    attack_vectors.south[#attack_vectors.south + 1] = { x, y }
end
local size_of_vectors = #attack_vectors.north

local function calculate_secant_intersections(r, a, b, c)
    local t = a * a + b * b
    local x = -a * c / t
    local y = -b * c / t
    local d = r * r - c * c / t
    local m = math_sqrt(d / t)
    local bm = b * m
    local am = a * m
    return {
        a = {
            x = x + bm,
            y = y - am,
        },
        b = {
            x = x - bm,
            y = y + am,
        },
    }
end

local function calculate_tangent_line(r, d)
    local r2 = r * r
    local t = r * math_sqrt(d * d - r2)
    return {
        a = t / d,
        b = d - r2 / d,
        c = -t,
    }
end

local function normalize_angle(angle)
    angle = math_fmod(angle + math_2pi, math_2pi)
    if angle > math_pi then
        angle = angle - math_2pi
    end
    return angle
end

local function calculate_strike_range(
    source_target_dx,
    source_target_dy,
    source_target_distance,
    inner_radius,
    outer_radius
)
    local theta = math_atan2(source_target_dy, source_target_dx)
    local t = calculate_tangent_line(inner_radius, source_target_distance)
    local intersections = calculate_secant_intersections(outer_radius, t.a, t.b, t.c)
    local phi = math_atan2(intersections.b.y, intersections.b.x)
    local start = normalize_angle(theta - phi)
    local finish = normalize_angle(theta + phi)
    if finish < start then
        finish = finish + math_2pi
    end
    return {
        start = start,
        finish = finish,
    }
end

local function calculate_boundary_range(boundary_offset, target_position, strike_radius)
    local c = target_position.y - boundary_offset
    local boundary_intersection = calculate_secant_intersections(strike_radius, 0, 1, c)
    local boundary_angle_start = math_atan2(boundary_intersection.a.y, boundary_intersection.a.x)
    local boundary_angle_finish = math_atan2(boundary_intersection.b.y, boundary_intersection.b.x)
    if boundary_angle_finish < boundary_angle_start then
        boundary_angle_finish = boundary_angle_finish + math_2pi
    end
    return {
        start = boundary_angle_start,
        finish = boundary_angle_finish,
    }
end

local function select_strike_position(source_position, target_position, boundary_offset)
    local source_target_dx = source_position.x - target_position.x
    local source_target_dy = source_position.y - target_position.y
    local source_target_distance = math_sqrt(source_target_dx * source_target_dx + source_target_dy * source_target_dy)
    if source_target_distance < MIN_STRIKE_DISTANCE then
        return {
            x = source_position.x,
            y = source_position.y,
        }
    end
    local strike_distance = math_random(MIN_STRIKE_DISTANCE, math_min(source_target_distance, MAX_STRIKE_DISTANCE))
    local strike_angle_range = calculate_strike_range(
        source_target_dx,
        source_target_dy,
        source_target_distance,
        STRIKE_TARGET_CLEARANCE,
        strike_distance
    )
    if boundary_offset > target_position.y - strike_distance then
        local boundary_angle_range = calculate_boundary_range(boundary_offset, target_position, strike_distance)
        strike_angle_range.start = math_max(strike_angle_range.start, boundary_angle_range.start)
        strike_angle_range.finish = math_min(strike_angle_range.finish, boundary_angle_range.finish)
    end
    local strike_angle_magnitude = strike_angle_range.finish - strike_angle_range.start
    local strike_zone_arc_length = math_floor(strike_distance * strike_angle_magnitude)
    local random_angle_offset = (math_random(0, strike_zone_arc_length) / strike_zone_arc_length)
        * strike_angle_magnitude
    local strike_angle = strike_angle_range.start + random_angle_offset
    local dx = strike_distance * math_cos(strike_angle)
    local dy = strike_distance * math_sin(strike_angle)
    return {
        x = target_position.x + dx,
        y = target_position.y + dy,
    }
end

function Public.calculate_strike_position(unit_group, target_position)
    local source_position = unit_group.position
    local normalized_source_position = { x = source_position.x, y = math_abs(source_position.y) }
    local normalized_target_position = { x = target_position.x, y = math_abs(target_position.y) }
    local boundary_offset = bb_config.border_river_width / 2
    local nominal_strike_position =
        select_strike_position(normalized_source_position, normalized_target_position, boundary_offset)
    if source_position.y < 0 then
        nominal_strike_position.y = -nominal_strike_position.y
    end
    return unit_group.surface.find_non_colliding_position('stone-furnace', nominal_strike_position, 96, 1)
end

--- Append shuffled silo attack commands to an existing command chain.
--- In multi-silo mode, uses position-based attack_area so the chain
--- survives silo destruction; otherwise targets the silo entity directly.
---@param chain defines.command[] Compound command list to append to.
---@param target_force_name string Force name ('north' or 'south').
---@param distraction defines.distraction Distraction behaviour for the appended commands.
function Public.append_silo_commands(chain, target_force_name, distraction)
    local silos = storage.rocket_silo[target_force_name]
    if not silos then
        return
    end
    local indices = Table.shuffle_indices(silos)
    local multi_silo = not MultiSilo.is_disabled()
    for _, i in ipairs(indices) do
        local silo = silos[i]
        if silo and silo.valid then
            if multi_silo then
                chain[#chain + 1] = {
                    type = defines.command.attack_area,
                    destination = silo.position,
                    radius = 32,
                    distraction = distraction,
                }
            else
                chain[#chain + 1] = {
                    type = defines.command.attack,
                    target = silo,
                    distraction = distraction,
                }
            end
        end
    end
end

---Provides the command chain for a new biter group using classic pathfinding logic, see notes in ai_strikes.lua for an explanation
---of the differences between advanced and classic pathfinding
---This biter group will take a direct path to the target_position using classic attack_vectors in ai_strikes.lua
---@param unit_group LuaCommandable
---@param target_force_name string
---@param target_position MapPosition
function Public.initiate_classic_attack(unit_group, target_force_name, target_position)
    if storage.bb_game_won_by_team then
        return
    end

    local chain = {}
    local vector = attack_vectors[target_force_name][math_random(1, size_of_vectors)]
    local distance_modifier = math_random(25, 100) * 0.01

    local position = {
        target_position.x + (vector[1] * distance_modifier),
        target_position.y + (vector[2] * distance_modifier),
    }
    position = unit_group.surface.find_non_colliding_position('stone-furnace', position, 96, 1)
    if position then
        if math_abs(position.y) < math_abs(unit_group.position.y) then
            chain[#chain + 1] = {
                type = defines.command.go_to_location,
                destination = position,
                radius = 32,
                distraction = defines.distraction.by_enemy,
            }
        end
    end

    chain[#chain + 1] = {
        type = defines.command.attack_area,
        destination = target_position,
        radius = 32,
        distraction = defines.distraction.by_enemy,
    }

    local list = storage.rocket_silo[target_force_name]
    local indices = Table.shuffle_indices(list)
    for _, i in ipairs(indices) do
        local silo = list[i]
        if silo and silo.valid then
            chain[#chain + 1] = {
                type = defines.command.attack,
                target = silo,
                distraction = defines.distraction.by_damage,
            }
        end
    end

    unit_group.set_command({
        type = defines.command.compound,
        structure_type = defines.compound_command.logical_and,
        commands = chain,
    })
end

---Provides the command chain for a new biter group using advanced pathfinding logic, see notes in ai_strikes.lua for an explanation
---of the differences between advanced and classic pathfinding.
---This biter group will travel to the strike_position before attacking the target_position
---@param unit_group LuaCommandable
---@param target_force_name string
---@param strike_position MapPosition
---@param target_position MapPosition
function Public.initiate_advanced_attack(unit_group, target_force_name, strike_position, target_position)
    if storage.bb_game_won_by_team then
        return
    end

    local chain = {}

    if strike_position then
        chain[#chain + 1] = {
            type = defines.command.go_to_location,
            destination = strike_position,
            radius = 32,
            distraction = defines.distraction.by_enemy,
        }
    end

    chain[#chain + 1] = {
        type = defines.command.attack_area,
        destination = target_position,
        radius = 32,
        distraction = defines.distraction.by_enemy,
    }

    Public.append_silo_commands(chain, target_force_name, defines.distraction.by_damage)

    unit_group.set_command({
        type = defines.command.compound,
        structure_type = defines.compound_command.return_last,
        commands = chain,
    })
end

local BEHAVIOR_RESULT = {
    [defines.behavior_result.success] = 'success',
    [defines.behavior_result.fail] = 'fail',
    [defines.behavior_result.deleted] = 'deleted',
    [defines.behavior_result.in_progress] = 'in_progress',
}

function Public.step(id, result)
    if storage.bb_game_won_by_team then
        return
    end

    if _DEBUG then
        log('ai: ' .. id .. ' ' .. BEHAVIOR_RESULT[result])
    end
end

--- Re-commands a biter unit that was removed from its group (e.g. the group is
--- disbanded or the unit is separated) with the group's current command when
--- available, falling back to a freshly built chain targeting a random player
--- structure and the rocket silo.
---@param unit LuaEntity
---@param group LuaCommandable
local function command_orphaned_unit(unit, group)
    -- BUG: During threat farming with poison capsules, biters form
    -- attack waves that target closest player structures.  This
    -- happens even with negative threat.  If in that period some
    -- biters get orphaned, they will trigger this event and acquire
    -- new command chain, unless we exit early.
    if storage.bb_threat[unit.force.name] < 0 then
        return
    end

    local commandable = unit.commandable
    if not commandable then
        return
    end

    -- The group's command can name a target that has died since: set_command
    -- then fails with "value for required field 'target' is missing", and the
    -- fallback chain below is used instead.
    if group.valid and group.has_command and pcall(commandable.set_command, group.command) then
        return
    end

    local chain = {}
    local target_force_name = Force.get_player_force_name(unit.force.name)
    local target_position = AiTargets.get_random_target(target_force_name)
    if target_position then
        chain[#chain + 1] = {
            type = defines.command.attack_area,
            destination = target_position,
            radius = 32,
            distraction = defines.distraction.by_enemy,
        }
    end
    Public.append_silo_commands(chain, target_force_name, defines.distraction.by_damage)

    if #chain > 0 then
        commandable.set_command({
            type = defines.command.compound,
            structure_type = defines.compound_command.return_last,
            commands = chain,
        })
    else
        log('unit_removed_from_group: no valid silos to chain for force=' .. target_force_name)
    end
end

---@param event LuaOnUnitRemovedFromGroup
local function on_unit_removed_from_group(event)
    if storage.bb_game_won_by_team then
        return
    end

    local unit = event.unit
    if not unit.valid then
        return
    end

    command_orphaned_unit(unit, event.group)
end

-- Factorio 2.1 crashes (SIGSEGV in GameEvents.cpp) when a unit joins or leaves a
-- group to answer a call for help, e.g. under a poison capsule cloud, as soon as
-- any script listens to on_unit_removed_from_group or on_unit_added_to_group,
-- even with an empty handler. On 2.1 the groups are watched instead: the attack
-- groups through watch_group, the groups the game makes for a call for help
-- through on_unit_group_created. A watched unit found in no group is
-- re-commanded the same way, a few ticks later, for the last watched group it
-- was seen in.
local WATCH_GROUPS = helpers.compare_versions(script.active_mods.base, '2.1.0') >= 0

---@return table
local function get_watch()
    local watch = storage.ai_watch
    if not watch then
        -- groups: the watched groups, checked in turn from index.
        -- owner: unit number -> unique id of the last watched group the unit was seen in.
        watch = { groups = {}, owner = {}, index = 1 }
        storage.ai_watch = watch
    end
    return watch
end

--- Watches the members of a new attack group for orphans (Factorio 2.1 only).
---@param unit_group LuaCommandable
function Public.watch_group(unit_group)
    if not WATCH_GROUPS or storage.bb_game_won_by_team then
        return
    end

    local units = unit_group.members
    if #units == 0 then
        return
    end

    local watch = get_watch()
    local id = unit_group.unique_id
    local numbers = {}
    for i, unit in ipairs(units) do
        local unit_number = unit.unit_number
        numbers[i] = unit_number
        watch.owner[unit_number] = id
    end
    watch.groups[#watch.groups + 1] = { group = unit_group, id = id, units = units, numbers = numbers }
end

--- Watches a group the game makes for a call for help. Its members join it
--- after it is created, so they are read again at each check.
---@param event EventData.on_unit_group_created
local function on_unit_group_created(event)
    local group = event.group
    if storage.bb_game_won_by_team or not group.valid or group.is_script_driven then
        return
    end

    local groups = get_watch().groups
    groups[#groups + 1] = { group = group, id = group.unique_id, units = {}, numbers = {}, made_by_game = true }
end

--- Checks one watched group per tick, in turn. A unit found in no group is
--- re-commanded as an orphan of this group if this group is the last watched
--- group it was seen in; otherwise it is left to that group. Dead units are
--- dropped, and the group is dropped once it has no unit left (a group made by
--- the game only once it is gone, since units join it later).
local function check_watched_group()
    local watch = storage.ai_watch
    if not watch or #watch.groups == 0 then
        return
    end

    if storage.bb_game_won_by_team then
        storage.ai_watch = nil
        return
    end

    local groups = watch.groups
    local owner = watch.owner
    local index = watch.index
    if index > #groups then
        index = 1
    end

    local entry = groups[index]
    local group = entry.group
    local id = entry.id
    local units = entry.units
    local numbers = entry.numbers
    local members = group.valid and group.members
    if members and entry.made_by_game then
        local known = {}
        for _, unit_number in ipairs(numbers) do
            known[unit_number] = true
        end
        for _, unit in ipairs(members) do
            local unit_number = unit.unit_number
            if not known[unit_number] then
                units[#units + 1] = unit
                numbers[#numbers + 1] = unit_number
            end
            owner[unit_number] = id
        end
    end

    if members and #members == #units then
        watch.index = index + 1
        return
    end

    local kept_units = {}
    local kept_numbers = {}
    for i, unit in ipairs(units) do
        local unit_number = numbers[i]
        if unit.valid then
            local commandable = unit.commandable
            local parent = commandable and commandable.parent_group
            if parent and parent.unique_id == id then
                owner[unit_number] = id
                kept_units[#kept_units + 1] = unit
                kept_numbers[#kept_numbers + 1] = unit_number
            elseif owner[unit_number] == id then
                if parent then
                    kept_units[#kept_units + 1] = unit
                    kept_numbers[#kept_numbers + 1] = unit_number
                else
                    owner[unit_number] = nil
                    command_orphaned_unit(unit, group)
                end
            end
        elseif owner[unit_number] == id then
            owner[unit_number] = nil
        end
    end

    if #kept_units == 0 and not (members and entry.made_by_game) then
        table.remove(groups, index)
        watch.index = index
    else
        entry.units = kept_units
        entry.numbers = kept_numbers
        watch.index = index + 1
    end
end

if WATCH_GROUPS then
    Event.add(defines.events.on_unit_group_created, on_unit_group_created)
    Event.add(defines.events.on_tick, check_watched_group)
else
    Event.add(defines.events.on_unit_removed_from_group, on_unit_removed_from_group)
end

return Public
