-- =============================================================================
-- FFXIAzureSets/libs/blu_set_points.lua
--
-- Supplemental set-points (1-8 pts) lookup for BLU spells whose entries
-- in FFXIMissingSpells/libs/blu_info.lua are missing the point_cost
-- field. Values sourced from BG-Wiki / community references.
--
-- Used as a fallback by libs/traits.lua: if blu_info doesn't have a
-- point_cost, we consult this table. Authoritative blu_info values
-- always win when present.
--
-- If any value here is wrong on your build, override locally with
--   //faset setspoint <spell> <cost>
-- (or edit this file and submit a patch).
-- =============================================================================

return {
    -- 19 entries that blu_info.lua leaves blank as of 2026-06.
    ['Blood Drain']         = 1,
    ['Harden Shell']        = 2,
    ['Thunderbolt']         = 5,
    ['Absolute Terror']     = 3,
    ['Gates of Hades']      = 5,
    ['Tourbillion']         = 2,
    ['Pyric Bulwark']       = 3,
    ['Bilgestorm']          = 3,
    ['Blistering Roar']     = 4,
    ['Bloodrake']           = 2,
    ['Carcharian Verve']    = 4,
    ['Cesspool']            = 3,
    ['Crashing Thunder']    = 5,
    ['Cruel Joke']          = 4,
    ['Droning Whirlwind']   = 5,
    ['Mighty Guard']        = 5,
    ['Polar Roar']          = 4,
    ['Tearing Gust']        = 4,
    ['Uproot']              = 2,
}
