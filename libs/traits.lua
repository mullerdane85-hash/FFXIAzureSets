-- =============================================================================
-- FFXIAzureSets/libs/traits.lua
--
-- Adapter sitting in front of two data sources:
--
--   1. trait_db.lua (bundled with this addon) -- exact per-spell point
--      values for every BLU trait, scraped from BG-Wiki. This is the
--      authoritative source for the "X points toward Y trait" math and
--      for the Cumulative Traits column / picker filter.
--
--   2. FFXIMissingSpells/libs/blu_info.lua (optional sibling addon) --
--      free-form descriptions, MP cost, cast time, etc. for spell tooltips.
--      We degrade gracefully when this isn't installed.
--
-- The UI uses traits.summarize / traits.spell_info / traits.has_data so
-- it doesn't care which source is providing each field.
-- =============================================================================

local trait_db = require('libs/trait_db')

-- Supplemental set-points lookup -- fills in the 19 BLU spells whose
-- blu_info.lua entries don't have a point_cost field. Lazy-loaded since
-- the file is small (one require call's worth of work) and doesn't
-- depend on anything else.
local supplemental_setpoints_ok, supplemental_setpoints = pcall(require, 'libs/blu_set_points')
if not supplemental_setpoints_ok then supplemental_setpoints = {} end

local traits = {}

-- -----------------------------------------------------------------------------
-- Optional blu_info loader (same as before)
-- -----------------------------------------------------------------------------
local cached_blu_info = nil
local cached_load_attempt = false

local function load_blu_info()
    if cached_load_attempt then return cached_blu_info end
    cached_load_attempt = true
    local addon_root = windower and windower.addon_path or ''
    local parent = addon_root:gsub('[^/\\]+[/\\]?$', '')
    local sibling = parent .. 'FFXIMissingSpells/libs/blu_info.lua'
    local ok, mod = pcall(dofile, sibling)
    if ok and type(mod) == 'table' then
        cached_blu_info = mod
        return mod
    end
    return nil
end

function traits.has_data()
    -- True when EITHER source is available. trait_db is always there, so
    -- this is effectively always true now -- kept for backwards compat
    -- (some UI paths still gate on it).
    return true
end

-- -----------------------------------------------------------------------------
-- Trait summary -- now powered by trait_db.
-- Returns the same { trait, spells, tier, pts, next_at } shape the UI expects.
-- -----------------------------------------------------------------------------
function traits.summarize(spellset)
    return trait_db.summarize_set(spellset)
end

-- -----------------------------------------------------------------------------
-- Per-spell info for the tooltip. Merges the optional blu_info entry with
-- the always-available trait_db contributions so the Spell Info column
-- shows "Contributes: Magic Attack Bonus +4pt | Clear Mind +4pt" even when
-- FFXIMissingSpells isn't installed.
-- -----------------------------------------------------------------------------
function traits.spell_info(spell_name)
    if not spell_name then return nil end

    -- Title-case rebuild for blu_info key lookup (blu_info uses canonical
    -- English; live spell names come through lowercased).
    local title = spell_name:gsub('(%a)(%w*)', function(first, rest)
        return first:upper() .. rest:lower()
    end)

    local info = load_blu_info()
    local entry = info and (info[spell_name] or info[title]) or nil

    local contribs = trait_db.contributions_for(spell_name)

    -- Even when blu_info isn't installed, we still want to return a usable
    -- entry shape so the Spell Info column has SOMETHING to display.
    if not entry and not contribs then
        -- Last-ditch: maybe the supplemental setpoints table has it; that
        -- still gives the tooltip a "Set Pts: N" line.
        local sp = supplemental_setpoints[spell_name] or supplemental_setpoints[title]
        if sp then return { point_cost = tostring(sp) } end
        return nil
    end

    -- Shallow copy of the blu_info entry (if any) so we don't mutate the
    -- shared module-level table.
    local merged = {}
    if entry then for k, v in pairs(entry) do merged[k] = v end end

    if contribs and #contribs > 0 then
        merged.contributions = contribs   -- UI walks this for the "Contributes" block
    end

    -- Supplemental setpoints fallback: if blu_info didn't include
    -- point_cost for this spell, fill it from the bundled table so the
    -- tooltip's "Set Pts: N" line shows up consistently across all 198
    -- BLU spells.
    if not merged.point_cost or merged.point_cost == '' then
        local sp = supplemental_setpoints[spell_name] or supplemental_setpoints[title]
        if sp then merged.point_cost = tostring(sp) end
    end

    return merged
end

-- Pass-throughs so the UI can ask the trait_db about category membership
-- (used by the picker filter row).
function traits.contributes_to_category(spell_name, category)
    return trait_db.contributes_to_category(spell_name, category)
end

-- Unified filter predicate. `filter` may be one of:
--   * 'All'              -> always true (no filter)
--   * <category name>    -> spell contributes to ANY trait in that category
--   * <trait name>       -> spell specifically contributes to THAT trait
-- The picker uses this so the same filter dropdown can hold both broad
-- category filters AND fine-grained trait filters.
function traits.filter_match(spell_name, filter)
    if not filter or filter == 'All' then return true end
    if trait_db.is_category(filter) then
        return trait_db.contributes_to_category(spell_name, filter)
    end
    return trait_db.contributes_to_trait(spell_name, filter)
end

function traits.categories() return trait_db.categories end
function traits.all_traits_flat() return trait_db.all_traits_flat() end

-- =============================================================================
-- BLU set-points math
-- =============================================================================
-- Each BLU spell carries a "point_cost" (1-8) and the player has a cap
-- determined by BLU level + Assimilation merits (up to +5) + job points
-- (up to +20). Cap by level per BG-Wiki Blue Magic Set Points table.

-- Per-spell point cost from blu_info (string in source; parsed to number).
function traits.spell_point_cost(spell_name)
    local info = traits.spell_info(spell_name)
    if not info or not info.point_cost then return 0 end
    return tonumber(info.point_cost) or 0
end

-- Sum of point_cost across every spell in a slotted set.
function traits.total_set_points(spellset)
    if not spellset then return 0 end
    local total = 0
    for _, name in pairs(spellset) do
        if type(name) == 'string' then
            total = total + traits.spell_point_cost(name)
        end
    end
    return total
end

-- Base cap from BLU level alone (no merits or job points). Matches the
-- table at https://www.bg-wiki.com/ffxi/Blue_Mage.
function traits.base_cap_for_level(level)
    level = tonumber(level) or 0
    if level < 1                  then return 0 end
    if level <= 10                then return 10 end
    if level <= 20                then return 15 end
    if level <= 30                then return 20 end
    if level <= 40                then return 25 end
    if level <= 50                then return 30 end
    if level <= 60                then return 35 end
    if level <= 70                then return 40 end
    if level <= 80                then return 45 end
    if level <= 90                then return 50 end
    return 55
end

-- BLU job id in res.jobs.
local BLU_JOB_ID = 16

-- Returns the effective BLU level for set-points cap purposes:
--   * main_job_level when BLU is the main job
--   * sub_job_level  when BLU is sub  (capped at sub's normal limit;
--                                       no extra clamp needed -- the
--                                       game already returns the right
--                                       value, e.g. 49 unmerit'd, up to
--                                       60 with Master Level)
--   * 0              when BLU isn't active at all
function traits.blu_level_for_cap(player)
    if not player then return 0 end
    if player.main_job_id == BLU_JOB_ID then
        return tonumber(player.main_job_level) or 0
    end
    if player.sub_job_id == BLU_JOB_ID then
        return tonumber(player.sub_job_level) or 0
    end
    return 0
end

-- Best-effort Assimilation merit + JP bonus auto-detection. Windower's
-- merit/JP field names vary across builds, so we try a few likely keys.
-- Returns the total bonus (0-25 expected) above the level base cap.
--
-- Sub-job NOTE: merits and JP gifts only apply when the job is main. If
-- BLU is sub, return 0 regardless of merit/JP values -- the sub-job cap
-- is just whatever the level table says.
function traits.auto_detected_bonus()
    if not windower or not windower.ffxi then return 0 end
    local p = windower.ffxi.get_player()
    if not p then return 0 end

    -- Sub-job BLU doesn't benefit from Assimilation merits or BLU JP
    -- gifts; cap is exactly the level-based base. Bail early.
    if p.main_job_id ~= BLU_JOB_ID then return 0 end

    local merits = 0
    if type(p.merits) == 'table' then
        -- Assimilation is one of the BLU group 2 merits. Try both
        -- lowercase and Title-Case keys to be safe.
        merits = tonumber(p.merits.assimilation)
              or tonumber(p.merits.Assimilation)
              or 0
        -- Clamp -- max merits is 5.
        if merits > 5 then merits = 5 end
    end

    local jp_bonus = 0
    if type(p.job_points) == 'table' then
        -- BLU job points are nested under .blu on this Windower build
        -- (confirmed via //faset debugcap dump). The set-points bonus
        -- is the value of .blue_magic_point_bonus, capped at 20.
        local jp = p.job_points.blu
                or p.job_points.BLU
                or p.job_points.blue_mage
                or p.job_points[16]   -- BLU job_id
        if type(jp) == 'table' then
            -- blue_magic_point_bonus is the canonical Windower field on
            -- this build. Earlier names kept as defensive fallbacks for
            -- older / forked builds.
            local raw = tonumber(jp.blue_magic_point_bonus)
                     or tonumber(jp.set_points_gifts)
                     or tonumber(jp.set_points)
                     or tonumber(jp.gifts)
                     or 0
            jp_bonus = math.min(20, raw)
        end
    end

    return merits + jp_bonus
end

-- Final max cap. Manual override (set via //faset setbonus) wins over
-- auto-detection. Returns base + chosen bonus.
--
-- For sub-job BLU, auto_detected_bonus() already returns 0; the manual
-- override still applies on top of the level base for users who want to
-- force a number (rarely useful since sub-job has no merit/JP boosts,
-- but harmless).
function traits.max_cap(level, manual_bonus)
    local base = traits.base_cap_for_level(level)
    if base == 0 then return 0 end
    local bonus
    if manual_bonus and tonumber(manual_bonus) and tonumber(manual_bonus) > 0 then
        bonus = tonumber(manual_bonus)
    else
        bonus = traits.auto_detected_bonus()
    end
    return base + bonus
end

-- Convenience: compute the cap straight from the live player struct so
-- callers don't have to thread main-vs-sub level lookup through their
-- own code.
function traits.max_cap_for_player(manual_bonus)
    if not windower or not windower.ffxi then return 0 end
    local p = windower.ffxi.get_player()
    if not p then return 0 end
    local level = traits.blu_level_for_cap(p)
    return traits.max_cap(level, manual_bonus)
end

-- Diagnostic helper: returns a table describing what was detected so the
-- user / //faset debugcap command can print it to chat. Lets the user see
-- whether auto-detection found anything when their displayed cap doesn't
-- match the game.
function traits.cap_breakdown(level, manual_bonus)
    local base = traits.base_cap_for_level(level)
    local auto = traits.auto_detected_bonus()
    local manual = (manual_bonus and tonumber(manual_bonus)) or 0
    return {
        base   = base,
        auto   = auto,
        manual = manual,
        total  = base + (manual > 0 and manual or auto),
        using  = manual > 0 and 'manual' or 'auto',
    }
end

return traits
