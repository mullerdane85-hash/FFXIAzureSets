--[[
    FFXIAzureSets -- GSUI-styled UI on top of the BLU spell-set logic
    originally written by Ricky Gall (Nitrous of Shiva) as azureSets.

    Credit:
        * Original spell-equip strategy (PreserveTraits / ClearFirst,
          slot rotation, scheduled set+remove) -- Ricky Gall (Nitrous).
          See: https://github.com/Windower/Lua/tree/dev/addons/azureSets
        * BSD-2 license terms preserved in libs/spell_core.lua.

    What this addon adds on top of azureSets:
        * Visual panel mirroring GSUI's look
        * Tabs: Slots (current/saved loadout) | Sets (saved sets list) | Traits
        * Click to load, click X to delete (with confirmation)
        * Save Current button -> chat prompt for set name
        * Remove All button (also confirmed)
        * Toggle hotkey: Z (configurable via /faset changekey <DIK>)

    Commands preserved from azureSets so muscle memory survives:
        //faset removeall
        //faset spellset <name> [ClearFirst|PreserveTraits]
        //faset set <name>      (alias for spellset)
        //faset add <slot> <spell>
        //faset save <name>
        //faset delete <name>
        //faset currentlist
        //faset setlist
        //faset spelllist <name>
    New:
        //faset                  -- toggles the UI
        //faset changekey <DIK>  -- e.g. 'Z' or 'F12'
        //faset help
]]

_addon.name     = 'FFXIAzureSets'
_addon.version  = '1.0'
_addon.author   = 'Jason (UI) / Ricky Gall a.k.a. Nitrous (original azureSets logic)'
_addon.commands = { 'faset', 'azuresets_ui', 'asetui' }

require('tables')
require('strings')
require('logger')
local config = require('config')
local chat   = require('chat')

local spell_core = require('libs/spell_core')
local traits_lib = require('libs/traits')
local ui         = require('libs/ui')

-- =============================================================================
-- Defaults
-- =============================================================================
-- The spellsets table mirrors azureSets's layout so users migrating their
-- existing settings.xml only need to copy the <spellsets> block over (or run
-- the original azureSets long enough to populate it, then copy). The 'default'
-- sentinel and the two VW presets are kept for parity with the upstream addon.
local defaults = {}
defaults.setmode   = 'PreserveTraits'
defaults.setspeed  = 0.65
defaults.toggle_key = 'Z'
defaults.pos       = { x = 200, y = 200 }
-- Manual override for the BLU set-points cap bonus (above the level base).
-- Set via //faset setbonus N. 0 means "use auto-detection" (which tries
-- to read Assimilation merits + JP gifts from windower.ffxi.get_player()).
defaults.bonus_set_points = 0
defaults.spellsets = {}
defaults.spellsets.default = T{}
-- VW1 / VW2 presets from the original azureSets ship as-is. The user can
-- delete them via the UI's X button if they don't want them.
defaults.spellsets.vw1 = T{
    slot01='Firespit', slot02='Heat Breath', slot03='Thermal Pulse', slot04='Blastbomb',
    slot05='Infrasonics', slot06='Frost Breath', slot07='Ice Break', slot08='Cold Wave',
    slot09='Sandspin', slot10='Magnetite Cloud', slot11='Cimicine Discharge', slot12='Bad Breath',
    slot13='Acrid Stream', slot14='Maelstrom', slot15='Corrosive Ooze', slot16='Cursed Sphere',
    slot17='Awful Eye',
}
defaults.spellsets.vw2 = T{
    slot01='Hecatomb Wave', slot02='Mysterious Light', slot03='Leafstorm', slot04='Reaving Wind',
    slot05='Temporal Shift', slot06='Mind Blast', slot07='Blitzstrahl', slot08='Charged Whisker',
    slot09='Blank Gaze', slot10='Radiant Breath', slot11='Light of Penance', slot12='Actinic Burst',
    slot13='Death Ray', slot14='Eyes On Me', slot15='Sandspray',
}

local settings = config.load(defaults)

-- =============================================================================
-- Import from azureSets/data/settings.xml
-- =============================================================================
-- The user's original azureSets settings.xml uses the same per-spellset
-- layout we do (one slotNN element per spell), so a small hand-written
-- parser is enough to migrate every saved set. We avoid pulling in a real
-- XML lib to keep the addon self-contained.
--
-- Triggers:
--   * On load, IF settings.imported_from_azuresets is not set yet AND the
--     sibling azureSets/data/settings.xml exists, run the import once and
--     persist the flag so subsequent loads skip it.
--   * //faset import always runs it (overwriting only sets with the same
--     name -- doesn't touch any FFXIAzureSets-native sets the user has
--     created with different names).

-- One small bit of state: did we already auto-import this install? Persisted
-- via settings:save() so this is a one-shot on first load.

-- Strip XML escapes that might appear in <slotXX> values. The azureSets file
-- mostly has plain spell names, but a defensive decode covers the corner
-- cases.
local function xml_unescape(s)
    return (s:gsub('&lt;', '<')
             :gsub('&gt;', '>')
             :gsub('&quot;', '"')
             :gsub('&apos;', "'")
             :gsub('&amp;', '&'))
end

-- Parse <spellsets>…</spellsets> blob from azureSets's settings.xml. Returns
-- a flat table { setname = { slot01 = "spell", ... }, ... } or nil on parse
-- failure (e.g. file doesn't exist).
local function parse_azuresets_xml(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'azureSets settings.xml not found at '..path end
    local src = f:read('*a')
    f:close()

    -- Carve out the <spellsets>…</spellsets> region so we don't accidentally
    -- match other elements (e.g. <setmode>) as fake set names.
    local body = src:match('<spellsets%s*>(.-)</spellsets>')
    if not body then return nil, 'no <spellsets> block in azureSets settings.xml' end

    local out = {}
    -- Each set is <name>…</name> where name is alphanum/underscore. The inner
    -- captures slotNN children.
    for set_name, set_body in body:gmatch('<([%w_]+)%s*>(.-)</%1%s*>') do
        -- Skip the 'default' empty sentinel -- we have our own.
        if set_name ~= 'default' then
            local set = {}
            local any = false
            for slot_name, spell in set_body:gmatch('<(slot%d+)%s*>%s*(.-)%s*</%1%s*>') do
                spell = xml_unescape(spell)
                if spell and spell ~= '' then
                    set[slot_name] = spell
                    any = true
                end
            end
            if any then out[set_name] = set end
        end
    end
    return out
end

-- Run the import. Returns ok, message, count.
local function do_import(overwrite_existing)
    local addon_root = windower and windower.addon_path or ''
    -- Strip our own folder name and append azureSets.
    local parent = addon_root:gsub('[^/\\]+[/\\]?$', '')
    local src = parent .. 'azureSets/data/settings.xml'

    local parsed, err = parse_azuresets_xml(src)
    if not parsed then return false, err, 0 end

    local imported = 0
    local skipped  = 0
    for name, slots in pairs(parsed) do
        local exists = settings.spellsets[name] ~= nil
        if exists and not overwrite_existing then
            skipped = skipped + 1
        else
            settings.spellsets[name] = T(slots)
            imported = imported + 1
        end
    end
    settings:save('all')
    local msg = ('imported %d set%s from azureSets'):format(imported, imported == 1 and '' or 's')
    if skipped > 0 then
        msg = msg .. (' (%d already-named set%s skipped -- run //faset import to overwrite)')
            :format(skipped, skipped == 1 and '' or 's')
    end
    return true, msg, imported
end

-- =============================================================================
-- Initialization & event registration
-- =============================================================================
local initialized = false

local function refresh_ui_data()
    -- Pull a fresh view of the world for the UI to render. Cheap; called
    -- every show() and after every mutating command.
    local live = spell_core.get_current_spellset() or T{}
    local sel = ui.get_selected_set()
    local selected = sel and spell_core.get_set(sel) or live
    local selected_name = sel or 'Live'

    ui.update_data({
        live_spellset     = live,
        selected_spellset = selected,
        selected_name     = selected_name,
        sets              = spell_core.list_sets(),
        trait_groups      = traits_lib.summarize(selected),
        traits_available  = traits_lib.has_data(),
        -- Function reference so the info box can resolve per-spell metadata
        -- without us having to round-trip every spell through ui.update_data()
        -- on every render.
        spell_info_fn     = traits_lib.spell_info,
        all_spells        = spell_core.list_all_blu_spells(),
        -- Picker filter predicate. Accepts either a category name (broad
        -- "Magical", "Physical", etc) OR a specific trait name ("Fast Cast",
        -- "Auto Refresh", "Magic Attack Bonus") and answers "does this
        -- spell contribute to that filter target?". trait_db owns the
        -- actual membership mapping; we just plumb the call through.
        filter_predicate  = traits_lib.filter_match,
        -- Flat alphabetical list of every trait per category; the picker
        -- dropdown appends these after the broad categories so users can
        -- filter to a specific trait's contributors.
        all_traits_flat   = traits_lib.all_traits_flat(),
        -- BLU set-points readout. current_points = sum of point_cost across
        -- the currently selected set. max_points = base cap (computed from
        -- whichever slot BLU is on -- main or sub) plus merits + JP gifts
        -- when BLU is main. Sub-job BLU gets only the level-based base.
        current_points    = traits_lib.total_set_points(selected),
        max_points        = traits_lib.max_cap_for_player(settings.bonus_set_points),
        -- Per-spell point cost lookup so the picker preview can show the
        -- delta a hovered spell would add.
        spell_point_cost_fn = traits_lib.spell_point_cost,
        -- Preview function: "what would the Cumulative Traits panel show
        -- if I dropped this spell into slot N?". The picker uses it on
        -- hover so the user sees live trait impact while choosing.
        preview_trait_groups_fn = function(slot_num, hovered_spell_name)
            local base = selected or T{}
            local copy = {}
            for k, v in pairs(base) do copy[k] = v end
            local key = ('slot%02u'):format(tonumber(slot_num) or 0)
            if hovered_spell_name and hovered_spell_name ~= '' then
                copy[key] = hovered_spell_name
            else
                copy[key] = nil
            end
            return traits_lib.summarize(copy)
        end,
    })
end

local function initialize()
    spell_core.initialize(settings)
    -- Position from settings so the panel remembers where you put it.
    ui.set_position(settings.pos.x or 200, settings.pos.y or 200)
    ui.set_position_persistor(function(x, y)
        settings.pos.x = x
        settings.pos.y = y
        settings:save()
    end)

    ui.set_callbacks({
        on_save_current = function()
            if not spell_core.is_blue_mage() then
                ui.set_status('BLU not active -- switch to BLU on main or sub first.')
                return
            end
            -- Prefill the FFXI chat input with the command so the user just
            -- types a name and hits enter. `@input` types into the chat box
            -- without sending; perfect for a "what should we call this?" prompt.
            windower.send_command('@input //faset save ')
            ui.set_status('Type a name for the set in chat, then Enter.')
        end,

        on_remove_all = function()
            if not spell_core.is_blue_mage() then
                ui.set_status('BLU not active.')
                return
            end
            spell_core.remove_all_spells()
            ui.set_status('All spells removed.')
            refresh_ui_data()
        end,

        on_new_empty_set = function()
            -- Prefill the chat input so the user just types a name and
            -- hits enter. //faset new <name> creates an empty set; they
            -- can then click slots to fill it in via the picker. No BLU
            -- check needed since we're not reading live spells.
            windower.send_command('@input //faset new ')
            ui.set_status('Type a name for the new empty set, then Enter.')
        end,

        on_assign_slot = function(setname, slot_num, spell_name)
            -- Picker -> "put spell into slot N of saved set". spell_name
            -- nil clears the slot. spell_core persists immediately.
            if not setname then
                ui.set_status('No set selected.')
                return
            end
            local ok, err = spell_core.update_set_slot(setname, slot_num, spell_name)
            if not ok then
                ui.set_status(err or 'Edit failed.')
                return
            end
            -- Reload the saved set's view so the grid shows the edit
            -- immediately, then refresh trait totals from the new state.
            ui.view_set(setname, spell_core.get_set(setname) or {})
            refresh_ui_data()
            if spell_name then
                ui.set_status(("Set slot %02d -> %s"):format(slot_num, spell_name))
            else
                ui.set_status(("Cleared slot %02d"):format(slot_num))
            end
        end,

        on_equip_set = function(name)
            if not name then return end
            if not spell_core.is_blue_mage() then
                ui.set_status('BLU not active -- switch to BLU on main or sub first.')
                return
            end
            -- Pre-equip cap check. FFXI itself will refuse spells past
            -- the cap, but warning upfront is friendlier than watching
            -- silently-dropped slots in the scheduled set+remove phase.
            local set       = spell_core.get_set(name) or {}
            local set_pts   = traits_lib.total_set_points(set)
            local cap_pts   = traits_lib.max_cap_for_player(settings.bonus_set_points)
            if cap_pts > 0 and set_pts > cap_pts then
                local over = set_pts - cap_pts
                local warn = ('Set "%s" needs %d pts but your cap is %d (over by %d). FFXI will drop the excess spells.')
                    :format(name, set_pts, cap_pts, over)
                ui.set_status('Over cap by ' .. over .. ' pts -- equip will drop spells.')
                windower.add_to_chat(167, 'FFXIAzureSets: ' .. warn)
                -- Fall through and still attempt; user might be intentional
                -- (e.g. they swap to higher-level BLU later or have unsaved
                -- merits). FFXI's own error per-slot is the hard gate.
            end
            local ok, msg = spell_core.set_spells(name, settings.setmode)
            ui.set_status(msg or (ok and ('Equipping '..name) or 'Equip failed'))
            windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
            refresh_ui_data()
        end,

        on_view_set = function(name)
            local set = spell_core.get_set(name)
            ui.view_set(name, set or {})
            refresh_ui_data()
        end,

        on_view_live = function()
            ui.view_live(spell_core.get_current_spellset() or {})
            refresh_ui_data()
        end,

        on_delete_set = function(name)
            local ok, msg = spell_core.delete_set(name)
            ui.set_status(msg or '')
            windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
            -- If we were viewing the now-deleted set, snap back to Live.
            if ui.get_selected_set() == name then
                ui.view_live(spell_core.get_current_spellset() or {})
            end
            refresh_ui_data()
        end,
    })

    -- One-shot azureSets migration. Idempotent: the flag we persist after
    -- the first run prevents the import from re-running on subsequent loads
    -- (which would clobber any user-rename / user-edit they made post-migrate).
    if not settings.imported_from_azuresets then
        local ok, msg, count = do_import(false)
        if ok and count > 0 then
            windower.add_to_chat(207, 'FFXIAzureSets: '..msg..'.')
        elseif not ok then
            windower.add_to_chat(207, 'FFXIAzureSets: no azureSets data to import ('..tostring(msg)..').')
        end
        settings.imported_from_azuresets = true
        settings:save('all')
    end

    refresh_ui_data()
    initialized = true
end

windower.register_event('load', function()
    if windower.ffxi.get_info() and windower.ffxi.get_info().logged_in then
        initialize()
    end
end)

windower.register_event('login', function()
    initialize()
end)

windower.register_event('job change', function(job)
    if job == 16 then
        -- Re-init on BLU so spell_core picks up the freshly-loaded mjob_data.
        initialize()
        refresh_ui_data()
    else
        -- Off-job: still keep the UI usable for viewing saved sets, but the
        -- Save / Remove / Load actions will short-circuit if BLU isn't active.
        refresh_ui_data()
    end
end)

-- =============================================================================
-- Hotkey -- DIK scancode toggle. /faset changekey <letter|DIK_name> rebinds.
-- =============================================================================
local dik_map = {
    ['A']=30, ['B']=48, ['C']=46, ['D']=32, ['E']=18, ['F']=33, ['G']=34,
    ['H']=35, ['I']=23, ['J']=36, ['K']=37, ['L']=38, ['M']=50, ['N']=49,
    ['O']=24, ['P']=25, ['Q']=16, ['R']=19, ['S']=31, ['T']=20, ['U']=22,
    ['V']=47, ['W']=17, ['X']=45, ['Y']=21, ['Z']=44,
    ['F1']=59, ['F2']=60, ['F3']=61, ['F4']=62, ['F5']=63, ['F6']=64,
    ['F7']=65, ['F8']=66, ['F9']=67, ['F10']=68, ['F11']=87, ['F12']=88,
}

local function resolve_hotkey()
    local k = (settings.toggle_key or 'Z'):upper()
    return dik_map[k] or dik_map['Z']
end

-- Chat / macro / menu aware: don't fire the toggle while the user is
-- typing anywhere. Earlier this registered for the 'chat mode' event,
-- which doesn't exist in this Windower build -- Windower rejected the
-- handler with "Unknown event: chat mode" and unloaded the addon every
-- time it tried to load. The user saw this as "FFXIAzureSets is like
-- loading for everything" -- because it WAS, in a loop.
--
-- Check live state per-keypress instead. windower.ffxi.get_info() is
-- cheap and reliable; chat_open covers the chat bar AND the macro-edit
-- text field (both share the same input gate in retail FFXI). The
-- mog_house / target_lock fields can stay nil safely.
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if not pressed or blocked then return end
    local info = windower.ffxi.get_info()
    if info and info.chat_open then return end
    if dik == resolve_hotkey() then ui.toggle() end
end)

-- =============================================================================
-- Mouse routing
-- =============================================================================
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked then return end
    if ui.handle_mouse(mtype, x, y) then return true end
end)

-- =============================================================================
-- Commands -- preserve every azureSets verb. Add a few new ones.
-- =============================================================================
local function print_help()
    local lines = {
        'FFXIAzureSets commands:',
        '  //faset                          -- toggle the UI',
        '  //faset changekey <letter>       -- rebind the toggle hotkey',
        '  //faset removeall                -- clear every set spell',
        '  //faset spellset <name> [mode]   -- equip the named set (mode: ClearFirst|PreserveTraits)',
        '  //faset set <name>               -- alias for spellset',
        '  //faset add <slot> <spell>       -- set one spell in one slot',
        '  //faset save <name>              -- save current loadout under <name>',
        '  //faset new <name>               -- create an empty set you can build up via the picker',
        '  //faset delete <name>            -- delete a saved set',
        '  //faset currentlist              -- print live loadout to chat',
        '  //faset setlist                  -- print saved set names to chat',
        '  //faset spelllist <name>         -- print one set\'s spells to chat',
        '  //faset setmode <ClearFirst|PreserveTraits>  -- default equip mode',
        '  //faset setspeed <seconds>       -- delay between set packets (default 0.65)',
        '  //faset setbonus <0-25>          -- manual cap bonus above lvl base (0 = auto-detect)',
        '  //faset debugcap                 -- print cap breakdown (level base + merits + JP)',
        '  //faset import                   -- re-import from azureSets (overwrites same-named sets)',
        '  //faset help                     -- show this list',
        ' ',
        'Hotkey: '..(settings.toggle_key or 'Z')..' toggles the panel (chat-aware -- ignored while typing).',
        'Original spell-equip logic by Ricky Gall (Nitrous of Shiva); UI by Jason.',
    }
    for _, line in ipairs(lines) do
        windower.add_to_chat(207, line .. chat.controls.reset)
    end
end

windower.register_event('addon command', function(...)
    local args = T{...}

    -- Bare `//faset` toggles the UI.
    if #args == 0 then
        ui.toggle()
        return
    end

    local cmd = table.remove(args, 1):lower()

    if cmd == 'help' or cmd == '?' then
        print_help()
        return
    end

    if cmd == 'setbonus' then
        -- Manual override for the cap bonus above the level base. Range
        -- 0-25 (5 max merits + 20 max JP gifts per BG-Wiki). Setting it
        -- to 0 reverts to auto-detection.
        local n = tonumber(args[1])
        if not n or n < 0 or n > 25 then
            windower.add_to_chat(167, 'FFXIAzureSets: bonus must be 0-25 (5 merits max + 20 JP gifts max).')
            return
        end
        settings.bonus_set_points = n
        settings:save('all')
        if n == 0 then
            windower.add_to_chat(207, 'FFXIAzureSets: cap bonus -> auto-detect.')
        else
            windower.add_to_chat(207, 'FFXIAzureSets: cap bonus manually set to +'..n..'.')
        end
        refresh_ui_data()
        return
    end

    if cmd == 'debugcap' then
        local p = windower.ffxi.get_player() or {}
        local blu_level = traits_lib.blu_level_for_cap(p)
        local blu_slot = (p.main_job_id == 16) and 'main'
                      or (p.sub_job_id == 16) and 'sub'
                      or 'not active'
        local b = traits_lib.cap_breakdown(blu_level, settings.bonus_set_points)
        windower.add_to_chat(207, ('FFXIAzureSets cap breakdown:'))
        windower.add_to_chat(207, ('  BLU is %s (level %d) -> base %d')
            :format(blu_slot, blu_level, b.base))
        windower.add_to_chat(207, ('  auto-detected bonus = +%d (merits + JP)'):format(b.auto))
        windower.add_to_chat(207, ('  manual override     = +%d (//faset setbonus)'):format(b.manual))
        windower.add_to_chat(207, ('  using %s; total cap = %d'):format(b.using, b.total))
        if p.merits then
            windower.add_to_chat(160, ('  player.merits.assimilation = %s')
                :format(tostring(p.merits.assimilation)))
        end
        if p.job_points then
            local found_keys = {}
            for k, _ in pairs(p.job_points) do found_keys[#found_keys+1] = tostring(k) end
            windower.add_to_chat(160, ('  player.job_points keys: %s')
                :format(table.concat(found_keys, ', ')))
            -- Dump every field inside the BLU JP entry so we can see what
            -- the real field name is for set-point gifts on this build.
            local blu_jp = p.job_points.blu or p.job_points.BLU
                        or p.job_points.blue_mage or p.job_points[16]
            if type(blu_jp) == 'table' then
                windower.add_to_chat(160, '  player.job_points.blu entries:')
                local keys = {}
                for k, _ in pairs(blu_jp) do keys[#keys+1] = tostring(k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local v = blu_jp[k]
                    local v_str
                    if type(v) == 'table' then
                        v_str = '(table)'
                    elseif type(v) == 'boolean' then
                        v_str = v and 'true' or 'false'
                    else
                        v_str = tostring(v)
                    end
                    windower.add_to_chat(160, ('    .%s = %s'):format(k, v_str))
                end
            end
        end
        return
    end

    if cmd == 'new' then
        -- //faset new <name> -- create an empty set the user can populate
        -- via the picker. No BLU gate (we're not reading live spells).
        if not args[1] then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset new <name>')
            return
        end
        local ok, msg = spell_core.create_empty_set(args[1])
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
        if ok then
            -- Immediately select the new set so the user lands on it ready
            -- to click slots and fill it in.
            ui.view_set(args[1], spell_core.get_set(args[1]) or {})
        end
        refresh_ui_data()
        return
    end

    if cmd == 'import' then
        -- Manual re-import, OVERWRITES same-named sets. The auto-import on
        -- first load is idempotent; this is the escape hatch when the user
        -- wants to pull updates from a newer azureSets settings.xml.
        local ok, msg, count = do_import(true)
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..msg)
        refresh_ui_data()
        return
    end

    if cmd == 'changekey' then
        local key = args[1] and args[1]:upper()
        if not key or not dik_map[key] then
            windower.add_to_chat(167, 'FFXIAzureSets: unknown key. Try a letter A-Z or F1-F12.')
            return
        end
        settings.toggle_key = key
        settings:save()
        windower.add_to_chat(207, 'FFXIAzureSets: toggle hotkey is now '..key..'.')
        return
    end

    -- Everything else routes through spell_core. The "is BLU active" gate
    -- (main OR sub) applies to most verbs; UI viewing is allowed off-job.
    if cmd == 'setlist' then
        local sets = spell_core.list_sets()
        windower.add_to_chat(207, 'FFXIAzureSets: '..#sets..' saved set(s):')
        for _, name in ipairs(sets) do
            windower.add_to_chat(207, '  '..name)
        end
        return
    end

    if cmd == 'spelllist' then
        local name = args[1]
        if not name then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset spelllist <name>')
            return
        end
        local set = spell_core.get_set(name)
        if not set then
            windower.add_to_chat(167, 'FFXIAzureSets: no set named '..name)
            return
        end
        windower.add_to_chat(207, 'FFXIAzureSets: spells in '..name..':')
        -- Print in slot order rather than hash order.
        for i = 1, 20 do
            local k = ('slot%02u'):format(i)
            if set[k] then
                windower.add_to_chat(207, ('  %02u  %s'):format(i, set[k]))
            end
        end
        return
    end

    -- Verbs below require BLU to be active (main OR sub). Gate once.
    if not spell_core.is_blue_mage() then
        windower.add_to_chat(167, 'FFXIAzureSets: BLU not active -- switch to BLU on main or sub first.')
        return
    end

    if cmd == 'removeall' then
        spell_core.remove_all_spells()
        windower.add_to_chat(207, 'FFXIAzureSets: removed all set spells.')
        refresh_ui_data()
        return
    end

    if cmd == 'add' then
        local slot, spell = args[1], args:slice(2, #args):sconcat()
        if not slot or not spell or spell == '' then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset add <slot 1-20> <spell name>')
            return
        end
        local ok, msg = spell_core.set_single_spell(spell:lower(), slot)
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or (ok and 'OK' or 'failed')))
        refresh_ui_data()
        return
    end

    if cmd == 'save' then
        if not args[1] then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset save <name>')
            return
        end
        local ok, msg = spell_core.save_set(args[1])
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
        refresh_ui_data()
        return
    end

    if cmd == 'delete' then
        if not args[1] then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset delete <name>')
            return
        end
        local ok, msg = spell_core.delete_set(args[1])
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
        refresh_ui_data()
        return
    end

    if cmd == 'spellset' or cmd == 'set' then
        if not args[1] then
            windower.add_to_chat(167, 'FFXIAzureSets: usage -- //faset spellset <name> [ClearFirst|PreserveTraits]')
            return
        end
        local ok, msg = spell_core.set_spells(args[1], args[2])
        windower.add_to_chat(ok and 207 or 167, 'FFXIAzureSets: '..(msg or ''))
        return
    end

    if cmd == 'currentlist' then
        local cur = spell_core.get_current_spellset() or T{}
        windower.add_to_chat(207, 'FFXIAzureSets: live spellset:')
        for i = 1, 20 do
            local k = ('slot%02u'):format(i)
            if cur[k] then
                windower.add_to_chat(207, ('  %02u  %s'):format(i, cur[k]))
            end
        end
        return
    end

    if cmd == 'setmode' then
        local mode = args[1] and args[1]:lower()
        if mode ~= 'clearfirst' and mode ~= 'preservetraits' then
            windower.add_to_chat(167, 'FFXIAzureSets: setmode must be ClearFirst or PreserveTraits.')
            return
        end
        settings.setmode = (mode == 'clearfirst') and 'ClearFirst' or 'PreserveTraits'
        settings:save()
        windower.add_to_chat(207, 'FFXIAzureSets: setmode = '..settings.setmode)
        return
    end

    if cmd == 'setspeed' then
        local n = tonumber(args[1])
        if not n or n < 0.05 or n > 5 then
            windower.add_to_chat(167, 'FFXIAzureSets: setspeed needs a number 0.05-5.0 (seconds).')
            return
        end
        settings.setspeed = n
        settings:save()
        windower.add_to_chat(207, 'FFXIAzureSets: setspeed = '..n..'s')
        return
    end

    windower.add_to_chat(167, 'FFXIAzureSets: unknown command. //faset help for the list.')
end)
