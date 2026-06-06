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
    if not spell_core.is_blue_mage() then return false, 'BLU not active (main or sub).' end
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
        for _, target_spell in pairs(target_set) do
            if not current_set:contains(target_spell:lower()) then
                local id = spell_core.find_spell_id_by_name(target_spell)
                if id then
                    windower.ffxi.set_blue_magic_spell(id, empty_slot)
                    spell_core._set_phase_step:schedule(settings.setspeed,
                        spellset_name, 'add', attempt)
                    return
                end
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
        return false, 'BLU not active (main or sub).'
    end
    if not settings.spellsets[spellset_name] then
        return false, 'Set not defined: '..tostring(spellset_name)
    end
    if spell_core.is_spellset_equipped(settings.spellsets[spellset_name]) then
        return true, spellset_name..' already equipped.'
    end

    set_mode = (set_mode or settings.setmode or 'PreserveTraits'):lower()
    if set_mode == 'clearfirst' then
        spell_core.remove_all_spells()
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

-- Return a sorted list of every LEARNED BLU spell name (English, Title-Case)
-- for the picker to render. No point showing spells the user hasn't learned --
-- they'd just be dead options that produce silent equip failures.
--
-- Windower's get_spells() returns a spell_id -> true map. Cross-referenced
-- with res.spells:type('BlueMagic') to drop non-BLU IDs and pick up the
-- canonical English name in one pass.
function spell_core.list_all_blu_spells()
    local out = {}
    if not blu_spells then return out end
    local learned = (windower and windower.ffxi and windower.ffxi.get_spells
                     and windower.ffxi.get_spells()) or {}
    for spell in blu_spells:it() do
        if learned[spell.id] then
            out[#out + 1] = spell.english
        end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

return spell_core
