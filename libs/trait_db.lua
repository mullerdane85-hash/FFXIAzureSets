-- =============================================================================
-- FFXIAzureSets/libs/trait_db.lua
--
-- BLU job-trait point database.
--
-- Source: https://www.bg-wiki.com/ffxi/Blue_Mage_Job_Traits  (scraped once
-- via WebFetch on 2026-06-05). Each saved BLU spell contributes a fixed
-- number of "trait points" toward exactly one trait. Once your total set's
-- point total in a trait crosses a threshold, that tier of the trait
-- activates. The user picks which spells to set to balance damage output
-- against trait activations.
--
-- Schema:
--   trait_db.categories : ordered list of category labels for the picker
--                         filter row.
--   trait_db.traits     : nested map -- traits[category][trait_name] =
--                         { thresholds = {6, 13, 19, 27},   -- pts for I,II,III,IV
--                           spells = { ['Battle Dance'] = 3, ... } }
--
-- We deliberately skip the bonus-modifier tiers V/VI on the wiki page.
-- They're unlocked by gear / job points / merits, not by spell-set
-- composition, so they don't matter for the picker math.
-- =============================================================================

local trait_db = {}

trait_db.categories = {
    'Physical', 'Magical', 'Defensive', 'Killer', 'Utility', 'Resist',
}

-- Friendly category display names (the table-driven render code uses these
-- on the filter buttons; internal IDs above stay short for code use).
trait_db.category_labels = {
    Physical  = 'Physical',
    Magical   = 'Magical',
    Defensive = 'Defensive',
    Killer    = 'Killer',
    Utility   = 'Utility',
    Resist    = 'Resist',
}

trait_db.traits = {
    -- =====================================================================
    -- Physical Spell Traits
    -- =====================================================================
    Physical = {
        ['Attack Bonus'] = {
            thresholds = { 6, 13, 19, 27 },
            spells = {
                ['Battle Dance']    = 3,
                ['Uppercut']        = 3,
                ['Death Scissors']  = 4,
                ['Spinal Cleave']   = 4,
                ['Temporal Shift']  = 4,
                ['Thermal Pulse']   = 4,
                ['Embalming Earth'] = 8,
                ['Searing Tempest'] = 8,
            },
        },
        ['Accuracy Bonus'] = {
            thresholds = { 5, 11, 19, 29 },
            spells = {
                ['Dimensional Death']    = 4,
                ['Frenetic Rip']         = 4,
                ['Disseverment']         = 4,
                ['Vanity Dive']          = 4,
                ["Nature's Meditation"]  = 8,
                ['Anvil Lightning']      = 8,
            },
        },
        ['Double Attack'] = {
            thresholds = { 5 },
            spells = {
                ['Acrid Stream']      = 4,
                ['Demoralizing Roar'] = 4,
                ['Empty Thrash']      = 4,
                ['Heavy Strike']      = 4,
                ['Thrashing Assault'] = 8,
            },
        },
        ['Triple Attack'] = {
            thresholds = { 12 },
            spells = {
                ['Acrid Stream']      = 4,
                ['Demoralizing Roar'] = 4,
                ['Empty Thrash']      = 4,
                ['Heavy Strike']      = 4,
                ['Thrashing Assault'] = 8,
            },
        },
        ['Dual Wield'] = {
            thresholds = { 4, 10, 17, 26 },
            spells = {
                ['Animating Wail']    = 4,
                ['Blazing Bound']     = 4,
                ['Quad. Continuum']   = 4,
                ['Delta Thrust']      = 4,
                ['Mortal Ray']        = 4,
                ['Barbed Crescent']   = 4,
                ['Molting Plumage']   = 8,
            },
        },
        ['Evasion Bonus'] = {
            thresholds = { 6, 12, 20 },
            spells = {
                ['Screwdriver']         = 4,
                ['Hysteric Barrage']    = 4,
                ['Occultation']         = 4,
                ['Tempestuous Upheaval']= 8,
                ['Silent Storm']        = 8,
            },
        },
        ['Rapid Shot'] = {
            thresholds = { 6 },
            spells = {
                ['Feather Storm'] = 4,
                ['Jet Stream']    = 4,
                ['Hydro Shot']    = 4,
            },
        },
        ['Zanshin'] = {
            thresholds = { 3 },
            spells = {
                ['Final Sting']    = 4,
                ['Whirl of Rage']  = 4,
            },
        },
        ['Counter'] = {
            thresholds = { 5 },
            spells = {
                ['Enervation']         = 4,
                ['Asuran Claws']       = 4,
                ['Dark Orb']           = 4,
                ['Orcish Counterstance'] = 4,
            },
        },
        ['Skillchain Bonus'] = {
            thresholds = { 6, 13, 18 },
            spells = {
                ['Goblin Rush']       = 6,
                ['Benthic Typhoon']   = 6,
                ['Quadrastrike']      = 6,
                ['Paralyzing Triad']  = 8,
            },
        },
        ['Store TP'] = {
            thresholds = { 5, 11, 19 },
            spells = {
                ['Sickle Slash']  = 4,
                ['Tail Slap']     = 4,
                ['Fantod']        = 4,
                ['Sudden Lunge']  = 4,
                ['Diffusion Ray'] = 8,
            },
        },
    },

    -- =====================================================================
    -- Magical Spell Traits
    -- =====================================================================
    Magical = {
        ['Magic Attack Bonus'] = {
            thresholds = { 3, 9, 16, 24 },
            spells = {
                ['Cursed Sphere']   = 4,
                ['Sound Blast']     = 4,
                ['Eyes On Me']      = 4,
                ['Memento Mori']    = 4,
                ['Heat Breath']     = 4,
                ['Reactor Cool']    = 4,
                ['Magic Hammer']    = 4,
                ['Dream Flower']    = 4,
                ['Subduction']      = 8,
                ['Spectral Floe']   = 8,
            },
        },
        ['Magic Accuracy Bonus'] = {
            thresholds = { 8 },
            spells = {
                ['Tenebral Crush'] = 8,
            },
        },
        ['Magic Burst Bonus'] = {
            thresholds = { 6, 13, 17 },
            spells = {
                ['Leafstorm']           = 6,
                ['Cimicine Discharge']  = 6,
                ['Reaving Wind']        = 6,
                ['Rail Cannon']         = 8,
            },
        },
        ['Magic Defense Bonus'] = {
            thresholds = { 6, 12, 20 },
            spells = {
                ['Magnetite Cloud']  = 4,
                ['Ice Break']        = 4,
                ['Osmosis']          = 4,
                ['Rending Deluge']   = 8,
                ['Scouring Spate']   = 8,
            },
        },
        ['Magic Evasion Bonus'] = {
            thresholds = { 8 },
            spells = {
                ['Blinding Fulgor'] = 8,
            },
        },
        ['Fast Cast'] = {
            -- Wiki tabulates an extra "Tier 0" at 6 pts; we treat that as
            -- the first activation, then 12/21 are tier I/II.
            thresholds = { 6, 12, 21 },
            spells = {
                ['Bad Breath']       = 4,
                ['Sub-zero Smash']   = 4,
                ['Auroral Drape']    = 4,
                ['Wind Breath']      = 4,
                ['Erratic Flutter']  = 8,
            },
        },
        ['Clear Mind'] = {
            thresholds = { 3, 7, 13, 20 },
            spells = {
                ['Poison Breath']    = 4,
                ['Soporific']        = 4,
                ['Venom Shell']      = 4,
                ['Awful Eye']        = 4,
                ['Filamented Hold']  = 4,
                ['Maelstrom']        = 4,
                ['Feather Tickle']   = 4,
                ['Corrosive Ooze']   = 4,
                ['Sandspray']        = 4,
                ['Warm-Up']          = 4,
                ['Lowing']           = 4,
                ['Mind Blast']       = 4,
            },
        },
        ['Conserve MP'] = {
            thresholds = { 4, 9, 14 },
            spells = {
                ['Chaotic Eye']    = 4,
                ['Zephyr Mantle']  = 4,
                ['Frost Breath']   = 4,
                ['Firespit']       = 4,
                ['Water Bomb']     = 4,
                ['Retinal Glare']  = 8,
            },
        },
    },

    -- =====================================================================
    -- Defensive Spell Traits
    -- =====================================================================
    Defensive = {
        ['Defense Bonus'] = {
            thresholds = { 5, 11, 17, 25 },
            spells = {
                ['Grand Slam']      = 4,
                ['Terror Touch']    = 4,
                ['Saline Coat']     = 4,
                ['Vertical Cleave'] = 4,
                ['Atra. Libations'] = 8,
                ['Entomb']          = 8,
            },
        },
        ['Inquartata'] = {
            thresholds = { 7 },
            spells = {
                ['Saurian Slide'] = 8,
            },
        },
        ['Max HP Boost'] = {
            thresholds = { 5, 11, 18, 26 },
            spells = {
                ['Flying Hip Press'] = 4,
                ['Body Slam']        = 4,
                ['Frypan']           = 4,
                ['Barrier Tusk']     = 4,
                ['Thunder Breath']   = 4,
                ['Glutinous Dart']   = 4,
                ['Restoral']         = 8,
            },
        },
        ['Max MP Boost'] = {
            thresholds = { 4, 10 },
            spells = {
                ['Metallic Body']    = 4,
                ['Mysterious Light'] = 4,
                ['Hecatomb Wave']    = 4,
                ['Magic Barrier']    = 4,
                ['Vapor Spray']      = 4,
            },
        },
        ['Auto Refresh'] = {
            thresholds = { 9 },
            spells = {
                ['Stinking Gas']     = 1,
                ['Frightful Roar']   = 2,
                ['Self-Destruct']    = 2,
                ['Cold Wave']        = 1,
                ['Light of Penance'] = 2,
                ['Voracious Trunk']  = 3,
                ['Actinic Burst']    = 4,
                ['Plasma Charge']    = 4,
                ['Winds of Promy.']  = 4,
            },
        },
        ['Auto Regen'] = {
            thresholds = { 6 },
            spells = {
                ['Healing Breeze'] = 4,
                ['Sheep Song']     = 4,
                ['White Wind']     = 4,
            },
        },
        ['Tenacity'] = {
            thresholds = { 7 },
            spells = {
                ['Palling Salvo'] = 8,
            },
        },
        ['Critical Attack Bonus'] = {
            thresholds = { 6 },
            spells = {
                ['Sinker Drill'] = 8,
            },
        },
    },

    -- =====================================================================
    -- Killer Traits
    -- =====================================================================
    Killer = {
        ['Beast Killer'] = {
            thresholds = { 5 },
            spells = {
                ['Wild Oats']         = 4,
                ['Sprout Smack']      = 4,
                ['Seedspray']         = 4,
                ['1000 Needles']      = 4,
                ['Nectarous Deluge']  = 8,
            },
        },
        ['Lizard Killer'] = {
            thresholds = { 4 },
            spells = {
                ['Foot Kick']      = 4,
                ['Claw Cyclone']   = 4,
                ['Ram Charge']     = 4,
                ['Sweeping Gouge'] = 8,
            },
        },
        ['Plantoid Killer'] = {
            thresholds = { 3 },
            spells = {
                ['Power Attack']     = 4,
                ['Mandibular Bite']  = 4,
                ['Spiral Spin']      = 4,
            },
        },
        ['Undead Killer'] = {
            thresholds = { 5 },
            spells = {
                ['Bludgeon']      = 4,
                ['Smite of Rage'] = 4,
            },
        },
    },

    -- =====================================================================
    -- Utility Traits (Gilfinder / Treasure Hunter share contributors;
    -- Treasure Hunter overrides Gilfinder when active)
    -- =====================================================================
    Utility = {
        ['Gilfinder'] = {
            thresholds = { 8 },
            spells = {
                ['Charged Whisker']    = 6,
                ["Everyone's Grudge"]  = 6,
                ['Amorphic Spikes']    = 6,
            },
        },
        ['Treasure Hunter'] = {
            thresholds = { 12 },
            spells = {
                ['Charged Whisker']    = 6,
                ["Everyone's Grudge"]  = 6,
                ['Amorphic Spikes']    = 6,
            },
        },
    },

    -- =====================================================================
    -- Resist Traits
    -- =====================================================================
    Resist = {
        ['Resist Gravity'] = {
            thresholds = { 3 },
            spells = {
                ['Feather Barrier'] = 4,
                ['Regurgitation']   = 4,
            },
        },
        ['Resist Silence'] = {
            thresholds = { 4 },
            spells = {
                ['Foul Waters'] = 8,
            },
        },
        ['Resist Sleep'] = {
            thresholds = { 4 },
            spells = {
                ['Pollen']      = 4,
                ['Wild Carrot'] = 4,
                ['Magic Fruit'] = 4,
                ['Yawn']        = 4,
                ['Exuviation']  = 4,
            },
        },
    },
}

-- =============================================================================
-- Derived indices, built lazily on first call. Stored as locals so they
-- persist for the addon's lifetime.
-- =============================================================================

-- spell -> { { category, trait, pts }, ... }
local spell_index = nil

-- category -> Set of spell names that contribute to anything in that category
local category_spell_index = nil

-- name lookup is case-insensitive: lowered_name -> canonical key in our tables
local lower_index = nil

local function build_indexes()
    if spell_index then return end
    spell_index          = {}
    category_spell_index = {}
    lower_index          = {}
    for cat, traits in pairs(trait_db.traits) do
        category_spell_index[cat] = category_spell_index[cat] or {}
        for trait_name, data in pairs(traits) do
            for spell_name, pts in pairs(data.spells) do
                local key = spell_name
                spell_index[key] = spell_index[key] or {}
                spell_index[key][#spell_index[key] + 1] = {
                    category = cat, trait = trait_name, pts = pts,
                }
                category_spell_index[cat][spell_name] = true
                lower_index[spell_name:lower()] = spell_name
            end
        end
    end
end

-- Resolve a spell name (any case) to its canonical key. Returns nil if the
-- spell doesn't contribute to any tracked trait.
function trait_db.canonical(name)
    if not name then return nil end
    build_indexes()
    return lower_index[name:lower()]
end

-- Return { { category, trait, pts }, ... } for a given spell. nil if unknown.
function trait_db.contributions_for(spell_name)
    if not spell_name then return nil end
    build_indexes()
    local key = lower_index[spell_name:lower()]
    return key and spell_index[key] or nil
end

-- True if a spell contributes to anything in the given category. Drives the
-- picker's category filter -- when the user selects e.g. "Magical", we show
-- only spells where contributes_to_category(name, 'Magical') is true.
function trait_db.contributes_to_category(spell_name, category)
    if not spell_name or not category then return false end
    build_indexes()
    local key = lower_index[spell_name:lower()]
    if not key then return false end
    return (category_spell_index[category] or {})[key] == true
end

-- True if a spell contributes to the named specific trait (e.g. "Fast Cast").
-- Used when the picker filter is set to a particular trait rather than a
-- whole category -- lets the user say "show me the Fast Cast contributors".
function trait_db.contributes_to_trait(spell_name, trait_name)
    if not spell_name or not trait_name then return false end
    build_indexes()
    local key = lower_index[spell_name:lower()]
    if not key then return false end
    for _, contrib in ipairs(spell_index[key] or {}) do
        if contrib.trait == trait_name then return true end
    end
    return false
end

-- Set-style index of category names so the picker's filter predicate can
-- tell "is this filter value a category name or a trait name?" in O(1).
local categories_set = nil
function trait_db.is_category(name)
    if not categories_set then
        categories_set = {}
        for _, c in ipairs(trait_db.categories) do categories_set[c] = true end
    end
    return categories_set[name] == true
end

-- Ordered list of every trait name, grouped by category then alphabetized
-- within each. Drives the picker filter dropdown so users can pick a
-- specific trait (e.g. "Fast Cast") not just a category.
local cached_traits_flat = nil
function trait_db.all_traits_flat()
    if cached_traits_flat then return cached_traits_flat end
    cached_traits_flat = {}
    for _, cat in ipairs(trait_db.categories) do
        local names = {}
        for n in pairs(trait_db.traits[cat] or {}) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            cached_traits_flat[#cached_traits_flat + 1] = n
        end
    end
    return cached_traits_flat
end

-- Compute current tier (0-4) and pts/needed-for-next given a point total.
--   thresholds = { 6, 13, 19, 27 }  -- I=6, II=13, III=19, IV=27
--   pts = 14                        -> tier 2, next_need = 5 (19 - 14)
-- Returns { tier = N, current = pts, next_at = K_or_nil, max_tier = 4 }
function trait_db.tier_for(thresholds, pts)
    pts = pts or 0
    if not thresholds or #thresholds == 0 then
        return { tier = 0, current = pts, next_at = nil, max_tier = 0 }
    end
    local tier = 0
    for i, threshold in ipairs(thresholds) do
        if pts >= threshold then tier = i else break end
    end
    return {
        tier     = tier,
        current  = pts,
        next_at  = thresholds[tier + 1],
        max_tier = #thresholds,
    }
end

-- Iterate every trait, computing pts and tier from the given spellset.
-- Returns flat list ordered by category then trait name:
--   { { category, trait, pts, tier, next_at, max_tier, contributing_spells }, ... }
-- Filters out traits with 0 pts so the column doesn't drown in noise.
function trait_db.summarize_set(spellset)
    build_indexes()
    spellset = spellset or {}
    local out = {}

    -- Lowercase set for fast lookup. Keep both the original name and lowered
    -- form so we can show the user the canonical spelling later.
    local set_lower = {}
    for _, name in pairs(spellset) do
        if type(name) == 'string' then set_lower[name:lower()] = name end
    end

    for _, cat in ipairs(trait_db.categories) do
        local traits = trait_db.traits[cat] or {}
        -- Stable alphabetic ordering within category.
        local trait_names = {}
        for name in pairs(traits) do trait_names[#trait_names + 1] = name end
        table.sort(trait_names)
        for _, trait_name in ipairs(trait_names) do
            local data = traits[trait_name]
            local pts = 0
            local hits = {}
            for spell, contrib_pts in pairs(data.spells) do
                if set_lower[spell:lower()] then
                    pts = pts + contrib_pts
                    hits[#hits + 1] = { spell = spell, pts = contrib_pts }
                end
            end
            if pts > 0 then
                local tier_info = trait_db.tier_for(data.thresholds, pts)
                table.sort(hits, function(a, b) return a.spell < b.spell end)
                out[#out + 1] = {
                    category            = cat,
                    trait               = trait_name,
                    pts                 = pts,
                    tier                = tier_info.tier,
                    next_at             = tier_info.next_at,
                    max_tier            = tier_info.max_tier,
                    contributing_spells = hits,
                }
            end
        end
    end
    return out
end

return trait_db
