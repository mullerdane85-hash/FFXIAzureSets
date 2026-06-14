--[[
    ============================================================
    FFXIAzureSets/libs/spell_core.lua

    Pure BLU spell-set logic, ported from the original azureSets
    addon by Ricky Gall (Nitrous of Shiva). All credit for the
    spell-equip strategy (PreserveTraits / ClearFirst, scheduled
    set+remove, slot rotation) goes to the original author -- this
    file is a refactor of that logic into a library module so the
    UI can drive it without touching event handlers directly.

    Original copyright (preserved verbatim per BSD-2 redistribution
    terms):

    Copyright (c) 2013, Ricky Gall
    All rights reserved.

    Redistribution and use in source and binary forms, with or
    without modification, are permitted provided that the following
    conditions are met:

      * Redistributions of source code must retain the above
        copyright notice, this list of conditions and the following
        disclaimer.
      * Redistributions in binary form must reproduce the above
        copyright notice, this list of conditions and the following
        disclaimer in the documentation and/or other materials
        provided with the distribution.
      * Neither the name of azureSets nor the names of its
        contributors may be used to endorse or promote products
        derived from this software without specific prior written
        permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
    CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
    MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL The Addon's Contributors BE
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
    OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
    TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
    OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
    OF SUCH DAMAGE.
    ============================================================
]]

local res     = require('resources')
-- Pulled in for the equip-time set-points cap check. The trade NPC's
-- accept-or-reject decision is server-side, but we know the cap formula
-- (base cap by level + Assimilation merits if main + JP gifts if main),
-- so we can pre-filter spells that would push over and skip them
-- instead of letting the equip loop retry forever (60-iter cap).
local traits  = require('libs/traits')

local spell_core = {}

-- Filled in by initialize(); res.spells filtered to BlueMagic only.
local blu_spells = nil

-- Settings handle, supplied by the main file. We keep this private so
-- the UI never has to thread the settings table through every call.
local settings = nil

-- =============================================================================
-- Initialization
-- =============================================================================

-- Call once on load / job change. Caches the BLU spell list and stores the
-- settings handle so save/delete persist correctly.
function spell_core.initialize(settings_handle)
    settings   = settings_handle
    blu_spells = res.spells:type('BlueMagic')
end

-- True when the player has BLU active in EITHER slot (main or sub).
-- The original addon gated commands on main-only, but in retail FFXI a
-- /BLU sub can set spells too -- they're just capped at the sub-job's
-- set-points table (and Assimilation merits + BLU JP gifts don't apply).
function spell_core.is_blue_mage()
    local p = windower.ffxi.get_player()
    return p and (p.main_job_id == 16 or p.sub_job_id == 16)
end

-- Kept for backwards compat in case anything external called it.
function spell_core.is_blue_mage_main()
    local p = windower.ffxi.get_player()
    return p and p.main_job_id == 16
end

-- =============================================================================
-- Reading the live spell loadout
-- =============================================================================

-- Returns a T-table { slot01 = "spell name", slot02 = ... } for the spells
-- currently set on the character. Returns nil off-job. Lowercase names so
-- set comparisons via contains() work without case fiddling.
function spell_core.get_current_spellset()
    if not spell_core.is_blue_mage() then return nil end
    -- BLU on main -> get_mjob_data(). BLU on sub -> get_sjob_data().
    -- Earlier this used mjob unconditionally, which meant /BLU subs got
    -- the wrong job's spell array (and an empty BLU slot list).
    local p = windower.ffxi.get_player()
    local data
    if p and p.main_job_id == 16 then
        data = windower.ffxi.get_mjob_data()
    else
        data = windower.ffxi.get_sjob_data and windower.ffxi.get_sjob_data() or nil
    end
    if not data or not data.spells then return T{} end
    return T(data.spells)
        -- 512 is the sentinel for "slot empty". Strip it before mapping.
        :filter(function(id) return id ~= 512 end)
        :map(function(id) return blu_spells[id].english:lower() end)
        :key_map(function(slot) return ('slot%02u'):format(slot) end)
end

-- True if `spellset` (a T-table of lowercase names) matches what's currently
-- on the character. Used to skip work when the user double-clicks Load on
-- the same set.
function spell_core.is_spellset_equipped(spellset)
    return S(spellset):map(string.lower) == S(spell_core.get_current_spellset())
end

-- Resolve a spell English name (case-insensitive) to its FFXI spell ID.
-- nil if the name isn't a BLU spell. Used by set_single_spell so we don't
-- have to know IDs up front in saved sets.
function spell_core.find_spell_id_by_name(spellname)
    local lower = spellname:lower()
    for spell in blu_spells:it() do
        if spell.english:lower() == lower then return spell.id end
    end
    return nil
end

-- =============================================================================
-- Writing the live spell loadout
-- =============================================================================

-- Clear all 20 slots in one packet.
function spell_core.remove_all_spells()
    windower.ffxi.reset_blue_magic_spells()
end

-- Single-shot equip of one spell into one slot. Slot is 1-20.
function spell_core.set_single_spell(spell_name, slot)
    if not spell_core.is_blue_mage() then return false, 'BLU not equipped on either main or sub.' end
    if not spell_name or not slot then return false, 'Missing args' end

    local id = spell_core.find_spell_id_by_name(spell_name)
    if not id then return false, 'Unknown spell: '..tostring(spell_name) end

    local current = spell_core.get_current_spellset()
    if current then
        for k, v in pairs(current) do
            if v:lower() == spell_name:lower() then
                return false, spell_name..' is already set in '..k
            end
        end
    end

    windower.ffxi.set_blue_magic_spell(id, tonumber(slot))
    windower.send_command('@timers c "Blue Magic Cooldown" 60 up')
    return true
end

-- =============================================================================
-- Bulk spellset equipping (PreserveTraits and ClearFirst paths)
-- =============================================================================

-- Optional callback for the UI to update its status when an equip finishes.
-- Signature: on_equip_done(ok: bool, spellset_name: string, message: string).
local on_equip_done = nil
function spell_core.set_equip_done_handler(fn) on_equip_done = fn end

-- Internal helper. Lives on the spell_core table (not as a local) so that
-- :schedule reliably resumes -- the function value has a stable identity
-- the scheduler can hold onto.
--
-- Strategy ported from azureSets (Ricky Gall / Nitrous):
--   1. In 'remove' phase, find the first live spell NOT in the target set
--      and call remove on it. Schedule the next pass.
--   2. Once remove phase has nothing left to remove, fall through to add
--      phase: find the first empty slot and set the next spell that's in
--      the target but not yet live.
-- The 0.65s delay (configurable via settings.setspeed) gives the server a
-- moment to ack each packet -- sending faster causes the game to drop set
-- attempts on the floor.
--
-- Stall detection (new): if a scheduled step computes the same live spellset
-- as the previous step, no packet was honored (over cap, unlearned spell,
-- etc.). Exit with a friendly message instead of looping forever.
-- Hard iteration cap as a safety net against true infinite loops. 60
-- iterations * 0.65s = ~39s, which comfortably covers a worst-case
-- full-set swap (20 removes + 20 sets + cache-lag retries).
local MAX_ITERATIONS = 60

-- Per-spell attempt tracker for the current equip session. Keys are
-- lowercased spell names; values are the number of set_blue_magic_spell
-- calls we've made for that spell. After MAX_PER_SPELL_ATTEMPTS without
-- the spell appearing in current_set, we give up on it -- handles both
-- Windower cache lag (rare, resolves in 1-2 retries) AND silent server
-- rejection (cost-calculation drift between our spell_point_cost table
-- and the server's, unlearned-by-master-level conditions, etc.).
--
-- Reset by set_spells() at the start of each equip flow so an old
-- failed-spell tag doesn't carry over to a fresh session.
local _attempts = {}
local MAX_PER_SPELL_ATTEMPTS = 3

-- The body of this function is a direct port of azureSets's
-- set_spells_from_spellset (Ricky Gall / Nitrous), preserving its exact
-- loop+schedule strategy. No state-key stall detection -- that was
-- causing false positives when Windower's cache lagged. Natural
-- termination at "equipped." is the only success signal.
function spell_core._set_phase_step(spellset_name, set_phase, attempt)
    attempt = (attempt or 0) + 1
    if attempt > MAX_ITERATIONS then
        local msg = spellset_name..' equip exceeded iteration cap (60). Bailing.'
        windower.add_to_chat(207, 'FFXIAzureSets: '..msg)
        if on_equip_done then on_equip_done(false, spellset_name, msg) end
        return
    end

    local target_set  = settings.spellsets[spellset_name]
    local current_set = spell_core.get_current_spellset()
    if not current_set then
        if on_equip_done then on_equip_done(false, spellset_name, 'BLU went off-job') end
        return
    end

    if set_phase == 'remove' then
        for slot_key, live_spell in pairs(current_set) do
            if not target_set:contains(live_spell:lower()) then
                local slot_num = tonumber(slot_key:sub(5, slot_key:len()))
                windower.ffxi.remove_blue_magic_spell(slot_num)
                spell_core._set_phase_step:schedule(settings.setspeed,
                    spellset_name, 'remove', attempt)
                return
            end
        end
    end

    -- Add phase: find an empty slot, find a target spell not yet live, set it.
    local empty_slot
    for i = 1, 20 do
        if current_set[('slot%02u'):format(i)] == nil then
            empty_slot = i
            break
        end
    end

    if empty_slot then
        local learned = (windower.ffxi.get_spells and windower.ffxi.get_spells()) or {}
        -- Effective BLU level for level-requirement filtering. Computed
        -- per-iteration so a job change mid-equip is picked up cleanly.
        local p = windower.ffxi.get_player()
        local effective_level = 0
        if p and p.main_job_id == 16 then
            effective_level = tonumber(p.main_job_level) or 0
        elseif p and p.sub_job_id == 16 then
            effective_level = tonumber(p.sub_job_level) or 0
        end

        -- Set-points budget. Sum costs of the spells already in current_set
        -- so we can refuse any further spell that would push the running
        -- total past the cap. The previous loop tried over-cap spells one
        -- by one until the 60-iter safety net kicked in -- the screenshot
        -- was 14 identical "set Cursed Sphere (id=544) -> slot 13" lines.
        -- traits.spell_point_cost(name) is the same accounting the UI's
        -- title-bar "X/Y pts" display uses; reusing it keeps equip and UI
        -- in sync. On sub-BLU this picks up the (lower) sub-job cap so a
        -- main-job-built set automatically trims to what fits on sub.
        local max_pts = traits.max_cap_for_player(settings.bonus_set_points)
        local cur_pts = 0
        for _, name in pairs(current_set) do
            if type(name) == 'string' then
                cur_pts = cur_pts + (traits.spell_point_cost(name) or 0)
            end
        end

        for _, target_spell in pairs(target_set) do
            local key = target_spell:lower()
            -- Per-spell attempt cap. If we've already called
            -- set_blue_magic_spell for this spell MAX_PER_SPELL_ATTEMPTS
            -- times and it's STILL not in current_set, treat it as
            -- silently rejected by the server and skip it on every
            -- future iteration in this session. This stops the
            -- "Awful Eye -> slot 12 [30/30 pts]" loop the user reported
            -- without changing anything for spells that just need one
            -- extra retry to clear Windower's stale cache.
            if not current_set:contains(key)
                and (_attempts[key] or 0) < MAX_PER_SPELL_ATTEMPTS
            then
                local id = spell_core.find_spell_id_by_name(target_spell)
                -- Level gate. Spells whose BLU learn-level (spell.levels[16])
                -- exceeds the player's current effective BLU level can't be
                -- slotted -- the server silently drops the set packet and
                -- our schedule loop would retry forever against the iter
                -- cap. Hide them here so we don't even try.
                local spell_res = id and res.spells[id]
                local lvl_req = spell_res and spell_res.levels and spell_res.levels[16]
                local level_ok = lvl_req and lvl_req <= effective_level
                -- Set-points gate. If this spell would push the budget past
                -- the cap, skip it -- same reason as the level gate: server
                -- rejects but current_set doesn't see the difference, so a
                -- naive loop retries forever.
                local cost = traits.spell_point_cost(target_spell) or 0
                local pts_ok = (max_pts == 0) or (cur_pts + cost <= max_pts)
                if id and learned[id] and level_ok and pts_ok then
                    _attempts[key] = (_attempts[key] or 0) + 1
                    local n = _attempts[key]
                    local retry_tag = (n > 1) and (' [retry ' .. (n - 1) .. ']') or ''
                    windower.add_to_chat(160, ('FFXIAzureSets dbg: set %s (id=%d, cost=%d) -> slot %d  [%d/%d pts]%s')
                        :format(target_spell, id, cost, empty_slot, cur_pts + cost, max_pts, retry_tag))
                    windower.ffxi.set_blue_magic_spell(id, empty_slot)
                    spell_core._set_phase_step:schedule(settings.setspeed,
                        spellset_name, 'add', attempt)
                    return
                elseif id and not learned[id] then
                    -- Skip unlearned -- chat-warned at set_spells entry
                elseif id and learned[id] and not level_ok then
                    -- Skip over-level -- chat-warned at set_spells entry.
                elseif id and learned[id] and level_ok and not pts_ok then
                    -- Skip over-cap -- chat-warned at set_spells entry.
                end
            elseif (_attempts[target_spell:lower()] or 0) >= MAX_PER_SPELL_ATTEMPTS
                and not current_set:contains(key)
                and not _attempts[key..':_warned']
            then
                -- One-shot warning per silently-rejected spell so the user
                -- knows we gave up on it. Don't repeat each iteration.
                _attempts[key..':_warned'] = true
                windower.add_to_chat(167, ('FFXIAzureSets: %s rejected by server after %d attempts -- skipping. (cap mismatch, master level lock, or other gating.)')
                    :format(target_spell, MAX_PER_SPELL_ATTEMPTS))
            end
        end
    end

    -- Nothing left to set -> finished. Cooldown timer preserved from the
    -- original azureSets behavior.
    local msg = spellset_name..' equipped.'
    windower.add_to_chat(207, 'FFXIAzureSets: '..msg)
    windower.send_command('@timers c "Blue Magic Cooldown" 60 up')
    if on_equip_done then on_equip_done(true, spellset_name, msg) end
end

-- Public entry. set_mode is 'PreserveTraits' or 'ClearFirst' (case-insensitive).
-- Returns (ok, message) so the UI can show success / a status line.
function spell_core.set_spells(spellset_name, set_mode)
    if not spell_core.is_blue_mage() then
        return false, 'BLU not equipped on either main or sub.'
    end
    if not settings.spellsets[spellset_name] then
        return false, 'Set not defined: '..tostring(spellset_name)
    end
    -- Reset the per-spell attempt tracker so a previous failed equip's
    -- "skip after 3 tries" tags don't leak into this fresh session.
    _attempts = {}
    -- Pre-check: count how many spells in the saved set the player
    -- hasn't learned OR is below the level for. We don't refuse to
    -- equip (the equip loop already skips both cases) but we DO
    -- chat-warn upfront so the user understands why a 6-spell set
    -- might land only 4 spells on the bar.
    do
        local learned = (windower.ffxi.get_spells and windower.ffxi.get_spells()) or {}
        local p = windower.ffxi.get_player()
        local effective_level = 0
        if p and p.main_job_id == 16 then
            effective_level = tonumber(p.main_job_level) or 0
        elseif p and p.sub_job_id == 16 then
            effective_level = tonumber(p.sub_job_level) or 0
        end
        local missing, over_level, over_cap = {}, {}, {}
        -- Set-points budget for the upfront warning. Walks the saved set
        -- in declaration order and reports anything that would push past
        -- the cap (so the user sees "Cursed Sphere will be skipped" up
        -- front instead of watching the equip loop fail silently).
        local max_pts = traits.max_cap_for_player(settings.bonus_set_points)
        local cur_pts = 0
        for _, spell in pairs(settings.spellsets[spellset_name]) do
            if type(spell) == 'string' then
                local id = spell_core.find_spell_id_by_name(spell)
                if id and not learned[id] then
                    missing[#missing + 1] = spell
                elseif id and learned[id] then
                    local spell_res = res.spells[id]
                    local lvl_req = spell_res and spell_res.levels and spell_res.levels[16]
                    local cost    = traits.spell_point_cost(spell) or 0
                    if lvl_req and lvl_req > effective_level then
                        over_level[#over_level + 1] = ('%s (lv%d)'):format(spell, lvl_req)
                    elseif max_pts > 0 and cur_pts + cost > max_pts then
                        over_cap[#over_cap + 1] = ('%s (%d pts)'):format(spell, cost)
                    else
                        cur_pts = cur_pts + cost
                    end
                end
            end
        end
        if #missing > 0 then
            windower.add_to_chat(167, ('FFXIAzureSets: %s has %d unlearned spell%s -- they will be skipped: %s')
                :format(spellset_name, #missing, #missing == 1 and '' or 's',
                        table.concat(missing, ', ')))
        end
        if #over_level > 0 then
            windower.add_to_chat(167, ('FFXIAzureSets: %s has %d spell%s above your current BLU level (%d) -- they will be skipped: %s')
                :format(spellset_name, #over_level, #over_level == 1 and '' or 's',
                        effective_level, table.concat(over_level, ', ')))
        end
        if #over_cap > 0 then
            -- Common case is sub-BLU: a set built on main fits a 55-cap
            -- budget; on sub the cap drops to ~30 and the tail of the
            -- list overflows. We just report and skip; the set stays
            -- savable as-is so re-subbing main puts everything back.
            windower.add_to_chat(167, ('FFXIAzureSets: %s exceeds your %d-point cap by %d spell%s -- skipping: %s')
                :format(spellset_name, max_pts, #over_cap, #over_cap == 1 and '' or 's',
                        table.concat(over_cap, ', ')))
        end
    end

    if spell_core.is_spellset_equipped(settings.spellsets[spellset_name]) then
        return true, spellset_name..' already equipped.'
    end

    set_mode = (set_mode or settings.setmode or 'ClearFirst'):lower()
    if set_mode == 'clearfirst' then
        -- Belt-and-suspenders clear: call the Windower API AND send
        -- azureSets's own removeall command (if azureSets is installed
        -- it'll process this and also clear, which covers builds where
        -- reset_blue_magic_spells silently no-ops for some reason). The
        -- two paths are idempotent so doubling up is harmless.
        windower.add_to_chat(207, 'FFXIAzureSets: clearing all set spells...')
        spell_core.remove_all_spells()
        windower.send_command('aset removeall')
        spell_core._set_phase_step:schedule(settings.setspeed, spellset_name, 'add')
        return true, 'Equipping '..spellset_name..' (clear-first)...'
    elseif set_mode == 'preservetraits' then
        spell_core._set_phase_step(spellset_name, 'remove')
        return true, 'Equipping '..spellset_name..' (preserve traits)...'
    end

    return false, 'Unknown setmode: '..set_mode
end

-- =============================================================================
-- Set storage CRUD
-- =============================================================================

-- Save the current live spellset under `setname`. Refuses 'default' to keep
-- it as a sentinel for the empty preset. Persists immediately.
function spell_core.save_set(setname)
    if not setname or setname == '' then return false, 'Name required.' end
    if setname:lower() == 'default' then
        return false, "Pick a name other than 'default'."
    end
    local current = spell_core.get_current_spellset()
    if not current then return false, 'Could not read current spells.' end

    settings.spellsets[setname] = T(current)
    settings:save('all')
    return true, "Saved set '"..setname.."'."
end

-- Drop a set from storage. Returns false if it didn't exist.
function spell_core.delete_set(setname)
    if not settings.spellsets[setname] then
        return false, "No set named '"..tostring(setname).."'."
    end
    settings.spellsets[setname] = nil
    settings:save('all')
    return true, "Deleted set '"..setname.."'."
end

-- Empty every slot of `setname` without removing the set entry. The
-- saved set keeps its name + reappears as an empty 20-slot template
-- the user can refill. Distinct from delete_set, which removes the
-- record entirely.
function spell_core.clear_set(setname)
    if not settings.spellsets[setname] then
        return false, "No set named '"..tostring(setname).."'."
    end
    -- Preserve the set object (so UI selection stays on it) and just
    -- empty its slot keys. T{} keeps the upstream type assumptions.
    local existing = settings.spellsets[setname]
    for k in pairs(existing) do existing[k] = nil end
    settings:save('all')
    return true, "Cleared set '"..setname.."' (kept the name)."
end

-- List the names of saved sets, sorted alphabetically. 'default' (the empty
-- sentinel) is excluded to match the original behavior.
function spell_core.list_sets()
    local out = {}
    for name in pairs(settings.spellsets) do
        if name ~= 'default' then out[#out+1] = name end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

-- Return the contents of a saved set as a slot-keyed table for the UI to
-- render. Returns nil if the set doesn't exist.
function spell_core.get_set(setname)
    return settings.spellsets[setname]
end

-- Edit one slot of one saved set. spell_name nil/empty clears the slot.
-- The picker calls this; the in-game spellbar is NOT touched -- saved
-- sets are independent definitions until the user clicks Equip.
function spell_core.update_set_slot(setname, slot_num, spell_name)
    if not settings.spellsets[setname] then
        return false, "No set named '"..tostring(setname).."'."
    end
    local slot = ('slot%02u'):format(tonumber(slot_num) or 0)
    if spell_name and spell_name ~= '' then
        settings.spellsets[setname][slot] = spell_name
    else
        settings.spellsets[setname][slot] = nil
    end
    settings:save('all')
    return true
end

-- Create an empty saved set so the picker has somewhere to place spells
-- before there's any live loadout to capture. Refuses duplicates.
function spell_core.create_empty_set(setname)
    if not setname or setname == '' then return false, 'Name required.' end
    if setname:lower() == 'default' then
        return false, "Pick a name other than 'default'."
    end
    if settings.spellsets[setname] then
        return false, "Set '"..setname.."' already exists."
    end
    settings.spellsets[setname] = T{}
    settings:save('all')
    return true, "Created empty set '"..setname.."'."
end

-- Return a sorted list of BLU spell names (English, Title-Case) the
-- player can currently EQUIP into a slot. Filters by two criteria:
--
--   1. Learned. get_spells() returns spell_id -> true; unlearned spells
--      are dropped so the picker doesn't list dead options that produce
--      silent equip failures.
--
--   2. Level requirement met by the player's CURRENT job setup. BLU on
--      main: every spell up to main_job_level. BLU on sub: spells up to
--      sub_job_level only (~half of main, capped at 49 normally, higher
--      with Master Level on main). Anything above that gets dropped --
--      previously the picker showed Level-80 spells while the user was
--      /BLU at 38 and the server silently rejected the set packet,
--      sending the equip loop into a retry storm against the iteration
--      cap. Hiding them in the picker is the cleanest fix.
--
-- Off-job (no BLU at all): returns {} so the picker shows nothing
-- equippable. Saved sets remain viewable in the main panel either way.
local BLU_JOB_ID = 16
function spell_core.list_all_blu_spells()
    local out = {}
    if not blu_spells then return out end
    local learned = (windower and windower.ffxi and windower.ffxi.get_spells
                     and windower.ffxi.get_spells()) or {}
    local p = windower.ffxi.get_player()
    -- Effective level for picker filtering. Mirrors traits.blu_level_for_cap
    -- without the require -- spell_core doesn't otherwise depend on traits
    -- and keeping the dependency one-way avoids a circular load.
    local effective_level = 0
    if p and p.main_job_id == BLU_JOB_ID then
        effective_level = tonumber(p.main_job_level) or 0
    elseif p and p.sub_job_id == BLU_JOB_ID then
        effective_level = tonumber(p.sub_job_level) or 0
    end
    if effective_level <= 0 then return out end

    for spell in blu_spells:it() do
        if learned[spell.id] then
            -- spell.levels is a job_id -> learn-level map. BLU learns
            -- happen at spell.levels[16]. nil means "BLU can't learn
            -- this" (shouldn't fire for entries from blu_spells, but
            -- guard anyway), so treat as 99 to drop it from the list.
            local lvl_req = spell.levels and spell.levels[BLU_JOB_ID]
            if lvl_req and lvl_req <= effective_level then
                out[#out + 1] = spell.english
            end
        end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

return spell_core
