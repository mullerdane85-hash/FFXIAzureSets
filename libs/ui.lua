-- =============================================================================
-- FFXIAzureSets/libs/ui.lua
--
-- Single-page panel, GSUI-styled. Four columns + an action row:
--
--   [ Saved Spell Sets ]  [ Spells of Selected ]  [ Spell Info ]  [ Cumulative Traits ]
--   [ Save Current ]  [ New Empty Set ]  [ Equip ]  [ Delete ]
--
--   * Saved Spell Sets: "[ Live ]" pinned at top, then alphabetical
--     saved-set names. Click to select. No per-row delete -- the bottom
--     Delete Spell Set button is the only delete path.
--   * Spells of Selected: 20 slot rows. Click any slot WHILE A SAVED SET
--     IS SELECTED to open the spell picker; the click on slot N becomes
--     "pick a spell for slot N (or clear it)". Live can't be edited.
--   * Spell Info: hovered spell's description + creates_trait + mp/cast
--     metadata pulled from FFXIMissingSpells/blu_info.lua.
--   * Cumulative Traits: every job trait the selected set contributes to,
--     with the count of spells per trait. Column widened so common trait
--     names like "Magic Attack Bonus" no longer overflow.
--
-- Spell picker (modal):
--   Opens when a slot row is clicked while a saved set is selected.
--   Scrollable list of every BLU spell (alphabetical, ~120 entries).
--   Click a spell -> assigned to that slot in the selected set, settings
--   saved, picker closes. A "Clear slot" button appears when the slot is
--   already filled. Cancel button closes without changes.
-- =============================================================================

local images   = require('images')
local texts    = require('texts')
-- Required directly (instead of going through state.data) as a fallback
-- in case the main file's data hook hasn't populated all_traits_flat yet
-- when the user opens the picker dropdown. The category list and trait
-- list are pure data; this require has no cost.
local trait_db_ok, trait_db_local = pcall(require, 'libs/trait_db')
if not trait_db_ok then trait_db_local = nil end

local ui = {}

-- -----------------------------------------------------------------------------
-- Layout constants
-- -----------------------------------------------------------------------------
local TITLE_BAR_H = 26
local BORDER      = 2
local PADDING     = 8
local ROW_H       = 20
local SLOT_H      = 18

local COL_SETS_W   = 150
local COL_SLOTS_W  = 200
local COL_INFO_W   = 270
local COL_TRAITS_W = 260
local COL_GAP      = 6

local PANEL_W = PADDING * 2 + COL_SETS_W + COL_SLOTS_W + COL_INFO_W + COL_TRAITS_W + COL_GAP * 3
local SLOT_COUNT = 20
local CONTENT_H = SLOT_COUNT * (SLOT_H + 2) + 4
local BTN_H = 26
local BTN_W = 145
local PANEL_H = TITLE_BAR_H + 6 + 20 + CONTENT_H + PADDING + 18 + BTN_H + PADDING

-- Picker constants. The picker is now a mini-panel of its own with three
-- sub-panels side-by-side: spell list (left), spell info (middle),
-- cumulative traits preview (right). Width sized to hold all three.
local PICKER_LIST_W    = 220
local PICKER_INFO_W    = 290
local PICKER_TRAITS_W  = 260
local PICKER_PANEL_GAP = 8
local PICKER_PADDING   = 12
local PICKER_SCROLL_W  = 24   -- gap reserved on the right of the spell list for ^/v buttons
local PICKER_W = PICKER_PADDING * 2
             + PICKER_LIST_W + PICKER_INFO_W + PICKER_TRAITS_W
             + PICKER_PANEL_GAP * 2
             + PICKER_SCROLL_W
local PICKER_VISIBLE = 18  -- spell list rows per page (taller now that we have a fixed mini-panel layout)
local PICKER_ROW_H = 18

-- Category list used by the picker AND the Cumulative Traits column
-- dropdown. Same order so muscle memory is consistent.
local CATEGORY_CYCLE = { 'All', 'Physical', 'Magical', 'Defensive', 'Killer', 'Utility', 'Resist' }
local PICKER_FILTER_H = 18

-- GSUI palette (matched as closely as I can without per-pixel sampling)
local C_TITLE_BG    = {200,  18,  22,  30}
local C_PANEL_BG    = {230,  10,  14,  20}
local C_BORDER      = {255,  90, 110, 160}
local C_COL_HEADER  = {220,  35,  55,  90}
local C_ROW_BG      = {180,  22,  28,  42}
local C_ROW_BG_SEL  = {230,  60, 120,  80}
local C_ROW_BG_HOV  = {200,  40,  60,  90}
local C_ROW_EMPTY   = {120,  18,  20,  28}
local C_BTN         = {220,  55, 125,  85}
local C_BTN_INFO    = {220,  60, 100, 180}
local C_BTN_DANGER  = {220, 200,  70,  50}
local C_BTN_NEUTRAL = {220,  60,  70,  90}
local C_BTN_DISABLED= {180,  40,  40,  50}
local C_MODAL_BG    = {255,   8,  10,  16}    -- full opacity; was 245 (semi-transparent let column rows show through)

-- -----------------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------------
local state = {
    visible = false,
    pos = { x = 80, y = 80 },
    dragging = false,
    drag_dx = 0, drag_dy = 0,

    selected_set_name = nil,
    hovered_spell = nil,

    -- Per-column scroll offsets (number of rows hidden above the first
    -- visible row). Header ^/v buttons mutate these via half-page steps.
    sets_scroll   = 0,
    info_scroll   = 0,
    traits_scroll = 0,

    -- Cumulative Traits column category filter. 'All' means no filter.
    -- Selected via a dropdown menu opened from the column header.
    traits_filter = 'All',

    -- Dropdown overlay state. When non-nil a category picker is open,
    -- floating below its owning column header. The string identifies
    -- which dropdown ("traits" for Cumulative Traits) so click handlers
    -- know which state field to update on selection.
    dropdown = nil,

    -- Picker overlay state. hovered_spell drives the in-picker info +
    -- trait-preview panels so the user sees the impact of each candidate
    -- before clicking.
    -- { slot_num = 4, current_spell = 'X' or nil, scroll = 0, filter = 'All', hovered_spell = nil }
    picker = nil,

    -- Confirm modal: { message, on_yes, on_no }
    confirm = nil,

    rects = {},
    callbacks = {
        on_save_current   = function() end,
        on_new_empty_set  = function() end,
        on_equip_set      = function(_name) end,
        on_delete_set     = function(_name) end,
        -- Clear all spells from a saved set WITHOUT deleting the set
        -- entry. Distinct from on_delete_set (which removes the set
        -- record). User asked for this so they can keep the name +
        -- start over on its contents.
        on_clear_set      = function(_name) end,
        on_view_set       = function(_name) end,
        on_view_live      = function() end,
        on_assign_slot    = function(_name, _slot, _spell) end,
    },
    data = {
        live_spellset     = {},
        sets              = {},
        selected_spellset = {},
        selected_name     = 'Live',
        trait_groups      = {},
        traits_available  = false,
        spell_info_fn     = function(_) return nil end,
        all_spells        = {},  -- alphabetical BLU spell list for picker
        all_traits_flat   = {},  -- flat list of every trait name (for filter)
        filter_predicate  = function(_spell, _filter) return true end,
        preview_trait_groups_fn = function(_slot, _spell) return nil end,
        -- BLU set-points readout. Updated by FFXIAzureSets.lua via
        -- update_data on every refresh; ui.lua displays X/Y in col 2 header
        -- so the user can see "am I over the cap?" at a glance.
        current_points       = 0,
        max_points           = 0,
        spell_point_cost_fn  = function(_) return 0 end,
    },
}

local elements = {
    title_bg = nil, title_text = nil,
    title_points_text = nil,   -- "X/Y pts" pinned to the title-bar right edge
    panel_bg = nil,
    border_t = nil, border_b = nil, border_l = nil, border_r = nil,

    col_headers = {},
    sets_rows   = {},
    slots_rows  = {},
    traits_rows = {},

    info_bg = nil, info_text = nil,

    btn_save_bg    = nil, btn_save_text    = nil,
    btn_new_bg     = nil, btn_new_text     = nil,
    btn_equip_bg   = nil, btn_equip_text   = nil,
    btn_delete_bg  = nil, btn_delete_text  = nil,
    btn_clear_bg   = nil, btn_clear_text   = nil,

    status_text = nil,

    -- Picker (inline over col 2). All create-once primitives:
    pick_bg          = nil,
    pick_filter_bg   = nil, pick_filter_text  = nil,
    pick_rows        = {},     -- spell rows, recreated each render
    pick_up_bg       = nil, pick_up_text      = nil,
    pick_down_bg     = nil, pick_down_text    = nil,
    pick_clear_bg    = nil, pick_clear_text   = nil,
    pick_cancel_bg   = nil, pick_cancel_text  = nil,

    -- Confirm modal
    modal_bg = nil, modal_text = nil,
    modal_yes_bg = nil, modal_yes_text = nil,
    modal_no_bg = nil,  modal_no_text = nil,

    -- Dropdown menu (only one open at a time)
    dropdown_bg = nil,
    dropdown_items = {},   -- list of { bg, text } per option
    dropdown_up_bg = nil, dropdown_up_text = nil,
    dropdown_down_bg = nil, dropdown_down_text = nil,
}

-- -----------------------------------------------------------------------------
-- Primitives
-- -----------------------------------------------------------------------------
local function make_bg(x, y, w, h, color)
    return images.new({
        pos = { x = x, y = y },
        size = { width = w, height = h },
        color = { alpha = color[1], red = color[2], green = color[3], blue = color[4] },
        visible = false, draggable = false,
    })
end

local function make_text(content, x, y, size, r, g, b, bold)
    local t = texts.new('', {
        pos = { x = x, y = y },
        text = {
            font = 'Arial', size = size or 10, alpha = 255,
            red = r or 255, green = g or 255, blue = b or 255,
            stroke = { width = 1, alpha = 200, red = 0, green = 0, blue = 0 },
        },
        bg = { visible = false },
        flags = { bold = bold or false, draggable = false },
        padding = 0,
    })
    t:text(content)
    return t
end

local function show(el) if el and el.show then el:show() end end
local function hide(el) if el and el.hide then el:hide() end end
local function destroy(el)
    if not el then return end
    if el.hide then el:hide() end
    if el.destroy then el:destroy() end
end

local function inside(rect, x, y)
    return rect and x >= rect.x and x < rect.x + rect.w
                and y >= rect.y and y < rect.y + rect.h
end

-- Truncate a string to fit within `max_chars` (Arial-roughly correlates with
-- pixel width). We have no proper text-measure API in Windower so we go with
-- a character cap that's calibrated against the column width in pixels.
local function fit(s, max_chars)
    if not s then return '' end
    if #s <= max_chars then return s end
    return s:sub(1, max_chars - 1) .. '...'
end

-- Word-wrap a string at word boundaries. Windower's texts primitive has no
-- auto-wrap, so long descriptions and meta lines (e.g. "Magical | Target:
-- AoE (Conal) | MP: 89 MP | Set Pts: 3 | Cast: 4 seconds | Recast: 23 seconds")
-- happily walked right off the Spell Info column into the Cumulative Traits
-- column. Preserve existing newlines in the input (they mark paragraph
-- breaks); only wrap WITHIN each paragraph.
local function wrap(s, max_chars)
    if not s then return '' end
    local lines = {}
    -- Append '\n' so the final paragraph also enters the loop.
    for paragraph in (s..'\n'):gmatch('(.-)\n') do
        if paragraph == '' then
            lines[#lines + 1] = ''
        else
            local line = ''
            for word in paragraph:gmatch('%S+') do
                if #line == 0 then
                    line = word
                elseif #line + 1 + #word > max_chars then
                    lines[#lines + 1] = line
                    line = word
                else
                    line = line .. ' ' .. word
                end
            end
            if line ~= '' then lines[#lines + 1] = line end
        end
    end
    return table.concat(lines, '\n')
end

-- -----------------------------------------------------------------------------
-- Row teardown
-- -----------------------------------------------------------------------------
local function tear_down_rows()
    local function sweep(list, fields)
        for _, r in ipairs(list) do
            for _, f in ipairs(fields) do destroy(r[f]) end
        end
    end
    sweep(elements.sets_rows,   { 'bg', 'text' })
    sweep(elements.slots_rows,  { 'bg', 'text' })
    sweep(elements.traits_rows, { 'bg', 'text' })
    sweep(elements.col_headers, { 'bg', 'text' })
    sweep(elements.pick_rows,      { 'bg', 'text' })
    sweep(elements.dropdown_items, { 'bg', 'text' })
    elements.sets_rows      = {}
    elements.slots_rows     = {}
    elements.traits_rows    = {}
    elements.col_headers    = {}
    elements.pick_rows      = {}
    elements.dropdown_items = {}

    -- Dropdown bg gets torn down each render (it moves around and changes
    -- size; cheap to recreate). Picker scaffolding and confirm modal
    -- elements are REUSED -- previously they were destroyed and rebuilt
    -- every render to keep Z-order above the column rows, but now we
    -- explicitly hide column content when the picker is open, so the
    -- Z-order trick is no longer necessary. Reusing them eliminates the
    -- cursor-flicker the user saw during picker hover (every mouse move
    -- triggered a render that destroyed ~30 picker primitives, briefly
    -- leaving the cursor with nothing to land on).
    destroy(elements.dropdown_bg)
    elements.dropdown_bg = nil
end

-- -----------------------------------------------------------------------------
-- Public mutators
-- -----------------------------------------------------------------------------
function ui.set_callbacks(cb)
    for k, v in pairs(cb) do state.callbacks[k] = v end
end

function ui.update_data(data)
    for k, v in pairs(data) do state.data[k] = v end
    if state.visible then ui.render() end
end

function ui.set_status(msg)
    if elements.status_text then
        elements.status_text:text(tostring(msg or ''))
        if state.visible then show(elements.status_text) end
    end
end

function ui.confirm(message, on_yes, on_no)
    state.confirm = {
        message = message,
        on_yes  = on_yes or function() end,
        on_no   = on_no  or function() end,
    }
    if state.visible then ui.render() end
end

function ui.get_selected_set() return state.selected_set_name end
function ui.is_visible() return state.visible end

function ui.set_position(px, py)
    state.pos.x = px; state.pos.y = py
    if state.visible then ui.render() end
end
function ui.get_position() return state.pos.x, state.pos.y end

local pos_save = function() end
function ui.set_position_persistor(fn) pos_save = fn end

function ui.view_set(name, spellset)
    state.selected_set_name      = name
    state.data.selected_spellset = spellset or {}
    state.data.selected_name     = name or 'Live'
    state.hovered_spell          = nil
    state.picker                 = nil
    if state.visible then ui.render() end
end

function ui.view_live(spellset)
    state.selected_set_name      = nil
    state.data.selected_spellset = spellset or {}
    state.data.selected_name     = 'Live'
    state.hovered_spell          = nil
    state.picker                 = nil
    if state.visible then ui.render() end
end

-- -----------------------------------------------------------------------------
-- Visibility sweep
-- -----------------------------------------------------------------------------
function ui.hide()
    state.visible = false
    for _, v in pairs(elements) do
        if type(v) == 'table' and v.hide then
            hide(v)
        elseif type(v) == 'table' then
            for _, r in ipairs(v) do
                for _, fn in ipairs({ 'bg', 'text' }) do hide(r[fn]) end
            end
        end
    end
end

function ui.show()
    state.visible = true
    ui.render()
end

function ui.toggle()
    if state.visible then ui.hide() else ui.show() end
end

-- =============================================================================
-- Render
-- =============================================================================
-- =============================================================================
-- Helper: build the wrapped Spell Info body text for a given spell.
-- Used by BOTH the main panel's column 3 AND the in-picker info panel so
-- they stay in sync. wrap_chars chosen based on the target column width.
-- Returns the assembled string ready to drop into a texts:text(...).
-- =============================================================================
local function build_spell_info_body(spell_name, wrap_chars, fallback_text)
    wrap_chars = wrap_chars or 46
    if not spell_name or spell_name == '' then
        return fallback_text or ''
    end
    local fn = state.data.spell_info_fn
    local info = fn and fn(spell_name)
    if not info then
        return spell_name .. '\n\n' .. wrap(
            '(no info -- install FFXIMissingSpells for descriptions)',
            wrap_chars)
    end
    local parts = { spell_name }
    if info.description and info.description ~= '' then
        parts[#parts+1] = ''
        parts[#parts+1] = wrap(info.description, wrap_chars)
    end
    if info.stat_bonus and info.stat_bonus ~= '' then
        parts[#parts+1] = ''
        parts[#parts+1] = wrap('Stats: ' .. info.stat_bonus, wrap_chars)
    end
    local meta_lines = {}
    local function add_meta(label, val)
        if val and val ~= '' then
            meta_lines[#meta_lines + 1] = wrap(label .. val, wrap_chars)
        end
    end
    add_meta('Type: ',    info.type)
    add_meta('Target: ',  info.target)
    add_meta('MP: ',      info.mp_cost)
    add_meta('Set Pts: ', info.point_cost)
    add_meta('Cast: ',    info.cast_time)
    add_meta('Recast: ',  info.recast_time)
    if #meta_lines > 0 then
        parts[#parts+1] = ''
        for _, l in ipairs(meta_lines) do parts[#parts+1] = l end
    end
    if info.contributions and #info.contributions > 0 then
        parts[#parts+1] = ''
        parts[#parts+1] = 'Contributes:'
        for _, c in ipairs(info.contributions) do
            parts[#parts+1] = wrap(('  %s +%dpt  (%s)')
                :format(c.trait, c.pts, c.category), wrap_chars)
        end
    elseif info.creates_trait and info.creates_trait ~= '' then
        parts[#parts+1] = ''
        parts[#parts+1] = wrap('Trait: ' .. info.creates_trait, wrap_chars)
    end
    return table.concat(parts, '\n')
end

function ui.render()
    if not state.visible then return end
    tear_down_rows()
    state.rects = {}

    local x, y = state.pos.x, state.pos.y

    -- Panel background + borders
    if not elements.panel_bg then
        elements.panel_bg = make_bg(x, y, PANEL_W, PANEL_H, C_PANEL_BG)
        elements.border_t = make_bg(x, y, PANEL_W, BORDER, C_BORDER)
        elements.border_b = make_bg(x, y + PANEL_H - BORDER, PANEL_W, BORDER, C_BORDER)
        elements.border_l = make_bg(x, y, BORDER, PANEL_H, C_BORDER)
        elements.border_r = make_bg(x + PANEL_W - BORDER, y, BORDER, PANEL_H, C_BORDER)
    else
        elements.panel_bg:pos(x, y); elements.panel_bg:size(PANEL_W, PANEL_H)
        elements.border_t:pos(x, y); elements.border_t:size(PANEL_W, BORDER)
        elements.border_b:pos(x, y + PANEL_H - BORDER); elements.border_b:size(PANEL_W, BORDER)
        elements.border_l:pos(x, y); elements.border_l:size(BORDER, PANEL_H)
        elements.border_r:pos(x + PANEL_W - BORDER, y); elements.border_r:size(BORDER, PANEL_H)
    end
    show(elements.panel_bg)
    show(elements.border_t); show(elements.border_b); show(elements.border_l); show(elements.border_r)

    -- Title bar
    if not elements.title_bg then
        elements.title_bg   = make_bg(x, y, PANEL_W, TITLE_BAR_H, C_TITLE_BG)
        elements.title_text = make_text('FFXIAzureSets   [Z] toggle', x + PADDING, y + 6, 11, 230, 240, 255, true)
        elements.title_points_text = make_text('', x, y + 6, 11, 255, 230, 130, true)
    else
        elements.title_bg:pos(x, y); elements.title_bg:size(PANEL_W, TITLE_BAR_H)
        elements.title_text:pos(x + PADDING, y + 6)
    end
    show(elements.title_bg); show(elements.title_text)
    state.rects.title = { x = x, y = y, w = PANEL_W, h = TITLE_BAR_H }

    -- Pinned points readout in the upper-right corner of the title bar
    -- (the spot a close X would normally occupy). Same logic as the col 2
    -- header counter -- live preview when the picker is hovering a candidate.
    do
        local cur_pts = state.data.current_points or 0
        local max_pts = state.data.max_points or 0
        if state.picker and state.picker.slot_num and state.data.spell_point_cost_fn then
            local slot_key = ('slot%02u'):format(state.picker.slot_num)
            local prev = (state.data.selected_spellset or {})[slot_key]
            local prev_cost = prev and state.data.spell_point_cost_fn(prev) or 0
            local cand = state.picker.hovered_spell or state.picker.current_spell
            local cand_cost = cand and state.data.spell_point_cost_fn(cand) or 0
            cur_pts = cur_pts - prev_cost + cand_cost
        end
        local pts_label = (max_pts > 0)
            and ('%d/%d pts'):format(cur_pts, max_pts)
            or  ('%d pts'):format(cur_pts)
        -- Highlight in red if user has overcommitted the cap, gold otherwise.
        if max_pts > 0 and cur_pts > max_pts then
            elements.title_points_text:color(255, 110, 110)
        else
            elements.title_points_text:color(255, 230, 130)
        end
        -- Position from the right edge. Approximate char width 7 px @ size 11
        -- -- close enough for the ~8 char label; the title bar right-aligns
        -- visually.
        local approx_w = #pts_label * 7 + 8
        elements.title_points_text:pos(x + PANEL_W - approx_w - PADDING, y + 6)
        elements.title_points_text:text(pts_label)
        show(elements.title_points_text)
    end

    -- Column headers. Header bars optionally embed two tiny scroll buttons
    -- on the right edge (^/v); the column body uses the corresponding
    -- scroll state to clamp first/last visible rows. Headers may also be
    -- clickable to cycle a category filter (currently only used by the
    -- Cumulative Traits column).
    local hdr_y = y + TITLE_BAR_H + 6
    state.rects.col_scroll = {}
    state.rects.col_header_click = {}
    local function header(text, cx, cw, scroll_key, cycle_key)
        local bg = make_bg(cx, hdr_y, cw, 18, C_COL_HEADER)
        local tx = make_text(text, cx + 6, hdr_y + 3, 10, 255, 255, 255, true)
        show(bg); show(tx)
        elements.col_headers[#elements.col_headers + 1] = { bg = bg, text = tx }
        if cycle_key then
            -- Header label is clickable (excluding the right edge where the
            -- scroll arrows live). Click cycles the category filter for
            -- that column.
            state.rects.col_header_click[cycle_key] = {
                x = cx, y = hdr_y, w = cw - 36, h = 18,
            }
        end
        if scroll_key then
            local up_x   = cx + cw - 32
            local down_x = cx + cw - 16
            local sb_y   = hdr_y + 2
            local up_bg = make_bg(up_x, sb_y, 14, 14, C_BTN_NEUTRAL)
            local up_tx = make_text('^', up_x + 4, sb_y, 10, 255, 255, 255, true)
            local dn_bg = make_bg(down_x, sb_y, 14, 14, C_BTN_NEUTRAL)
            local dn_tx = make_text('v', down_x + 3, sb_y, 10, 255, 255, 255, true)
            show(up_bg); show(up_tx); show(dn_bg); show(dn_tx)
            elements.col_headers[#elements.col_headers + 1] = { bg = up_bg, text = up_tx }
            elements.col_headers[#elements.col_headers + 1] = { bg = dn_bg, text = dn_tx }
            state.rects.col_scroll[scroll_key] = {
                up   = { x = up_x,   y = sb_y, w = 14, h = 14 },
                down = { x = down_x, y = sb_y, w = 14, h = 14 },
            }
        end
    end
    local col1_x = x + PADDING
    local col2_x = col1_x + COL_SETS_W + COL_GAP
    local col3_x = col2_x + COL_SLOTS_W + COL_GAP
    local col4_x = col3_x + COL_INFO_W + COL_GAP
    header('Saved Spell Sets',       col1_x, COL_SETS_W,   'sets')
    -- Col 2 header. Points counter lives in the upper-right corner of the
    -- title bar instead of here (this header was redundant once the corner
    -- display was added).
    header('Spells of Selected Set', col2_x, COL_SLOTS_W)   -- fixed 20 rows; no scroll needed
    header('Spell Info',             col3_x, COL_INFO_W,   'info')
    -- Cumulative Traits header label includes the active filter and a
    -- small "v" indicator so the user can see it's a dropdown.
    local traits_hdr = (state.traits_filter == 'All')
        and 'Cumulative Traits  v'
        or ('Cumulative Traits: ' .. state.traits_filter .. '  v')
    header(traits_hdr, col4_x, COL_TRAITS_W, 'traits', 'traits')

    local body_y = hdr_y + 20
    local body_h = CONTENT_H

    -- Column 1: Saved sets list (scroll-aware)
    do
        state.rects.sets_rows = {}
        local entries = { { name = '[ Live ]', is_live = true } }
        for _, name in ipairs(state.data.sets or {}) do
            entries[#entries + 1] = { name = name, is_live = false }
        end

        local row_h = SLOT_H + 2
        local max_rows = math.floor(body_h / row_h)
        -- Clamp scroll: never go beyond what's actually scrollable.
        local max_scroll = math.max(0, #entries - max_rows)
        if state.sets_scroll > max_scroll then state.sets_scroll = max_scroll end
        if state.sets_scroll < 0 then state.sets_scroll = 0 end

        local first = state.sets_scroll + 1
        local last  = math.min(#entries, first + max_rows - 1)
        for visual = 1, last - first + 1 do
            local entry = entries[first + visual - 1]
            local ry = body_y + (visual - 1) * row_h
            local is_selected =
                (entry.is_live and state.selected_set_name == nil) or
                (not entry.is_live and entry.name == state.selected_set_name)
            local bg_color = is_selected and C_ROW_BG_SEL or C_ROW_BG
            local bg = make_bg(col1_x, ry, COL_SETS_W, SLOT_H, bg_color)
            local label = fit(entry.name, 22)
            local text = make_text(label, col1_x + 8, ry + 3, 10, 255, 255, 255, is_selected)
            show(bg); show(text)
            elements.sets_rows[#elements.sets_rows + 1] = { bg = bg, text = text }
            state.rects.sets_rows[#state.rects.sets_rows + 1] = {
                row = { x = col1_x, y = ry, w = COL_SETS_W, h = SLOT_H,
                        name = entry.name, is_live = entry.is_live },
            }
        end
    end

    -- Column 2: Spell slots of selected set
    do
        local spellset = state.data.selected_spellset or {}
        state.rects.slot_rows = {}
        local editable = (state.selected_set_name ~= nil)
        for i = 1, SLOT_COUNT do
            local key = ('slot%02u'):format(i)
            local spell = spellset[key]
            local ry = body_y + (i - 1) * (SLOT_H + 2)
            local hovered = spell and state.hovered_spell == spell
            local bg_color =
                hovered and C_ROW_BG_HOV or
                (spell and C_ROW_BG or C_ROW_EMPTY)
            local bg = make_bg(col2_x, ry, COL_SLOTS_W, SLOT_H, bg_color)
            local label = ('%02d  %s'):format(i, fit(spell or '--', 23))
            local txt = make_text(label, col2_x + 6, ry + 3, 10,
                                  spell and 255 or 140, spell and 255 or 140, spell and 220 or 140)
            show(bg); show(txt)
            elements.slots_rows[#elements.slots_rows + 1] = { bg = bg, text = txt }
            -- Track click-rect on EVERY slot when a saved set is selected
            -- (so users can click empty slots to add a spell).
            state.rects.slot_rows[#state.rects.slot_rows + 1] = {
                x = col2_x, y = ry, w = COL_SLOTS_W, h = SLOT_H,
                slot_num = i, spell = spell, editable = editable,
            }
        end
    end

    -- Column 3: Spell info
    if not elements.info_bg then
        elements.info_bg   = make_bg(0, 0, 0, 0, C_ROW_BG)
        elements.info_text = make_text('', 0, 0, 9, 220, 220, 255)
    end
    elements.info_bg:pos(col3_x, body_y); elements.info_bg:size(COL_INFO_W, body_h)
    elements.info_text:pos(col3_x + 8, body_y + 6)
    do
        -- Spell Info column is 270 px wide at size 9 Arial. ~46 chars/line
        -- is the safe wrap target -- anything wider walks into the Traits
        -- column at the right.
        local WRAP_CHARS = 46
        local body
        -- Picker priority: when the spell picker is open over col 2, the
        -- info panel shows the picker's hovered/current spell so cols 3+4
        -- act as the picker's preview area. Falls back to the main panel's
        -- hover state when no picker is open.
        local active_spell = (state.picker and state.picker.hovered_spell)
                          or (state.picker and state.picker.current_spell)
                          or state.hovered_spell
        if active_spell then
            body = build_spell_info_body(active_spell, WRAP_CHARS)
        else
            local sel = state.data.selected_name or 'Live'
            local count = 0
            for _ in pairs(state.data.selected_spellset or {}) do count = count + 1 end
            local cur = state.data.current_points or 0
            local maxp = state.data.max_points or 0
            local pts_line = (maxp > 0)
                and ('%d/%d set points used.'):format(cur, maxp)
                or  ('%d set points used.'):format(cur)
            local hint = (state.selected_set_name ~= nil)
                and 'Hover a slot for spell info.\nClick a slot to add or change its spell.'
                or 'Hover a slot for spell info.\n(Live can\'t be edited -- select a saved set to build.)'
            body = ('Viewing: %s\n%d spell%s in this set.\n%s\n\n%s')
                :format(sel, count, count == 1 and '' or 's',
                        pts_line, wrap(hint, WRAP_CHARS))
        end
        -- Slice by line for info_scroll. Column body fits ~22 lines at
        -- size 9 Arial; only scroll when the wrapped body actually
        -- exceeds that. Otherwise leave the offset at 0 so the user
        -- doesn't accidentally scroll past the end of a 3-line entry.
        local info_lines = {}
        for line in (body..'\n'):gmatch('(.-)\n') do
            info_lines[#info_lines + 1] = line
        end
        local INFO_VISIBLE = math.floor(body_h / 14)
        local max_info_scroll = math.max(0, #info_lines - INFO_VISIBLE)
        if state.info_scroll > max_info_scroll then state.info_scroll = max_info_scroll end
        if state.info_scroll < 0 then state.info_scroll = 0 end
        if state.info_scroll > 0 or #info_lines > INFO_VISIBLE then
            local slice = {}
            local first = state.info_scroll + 1
            local last  = math.min(#info_lines, first + INFO_VISIBLE - 1)
            for i = first, last do slice[#slice + 1] = info_lines[i] end
            elements.info_text:text(table.concat(slice, '\n'))
        else
            elements.info_text:text(body)
        end
    end
    show(elements.info_bg); show(elements.info_text)

    -- Column 4: Cumulative traits.
    -- When the spell picker is open, swap the live trait_groups for a
    -- LIVE PREVIEW computed against the set with state.picker's hovered
    -- spell substituted into the slot being edited. That way the user
    -- sees exactly which traits would tier up if they pick the highlighted
    -- spell, without having to commit first.
    do
        local raw_groups
        if state.picker and state.data.preview_trait_groups_fn then
            local preview_spell = state.picker.hovered_spell
                               or state.picker.current_spell
            raw_groups = state.data.preview_trait_groups_fn(
                state.picker.slot_num, preview_spell) or {}
        else
            raw_groups = state.data.trait_groups or {}
        end
        -- Apply category filter so the user can focus on one trait family
        -- when tuning a set ("show me only Magical so I can see how close
        -- I am to the next MAB tier"). When filter == 'All', no work.
        local groups
        if state.traits_filter == 'All' then
            groups = raw_groups
        else
            groups = {}
            for _, g in ipairs(raw_groups) do
                if g.category == state.traits_filter then
                    groups[#groups + 1] = g
                end
            end
        end
        if not state.data.traits_available then
            local bg = make_bg(col4_x, body_y, COL_TRAITS_W, SLOT_H * 3, C_ROW_EMPTY)
            local text = make_text('Install FFXIMissingSpells\nfor trait totals.',
                col4_x + 8, body_y + 6, 9, 180, 180, 180)
            show(bg); show(text)
            elements.traits_rows[#elements.traits_rows + 1] = { bg = bg, text = text }
        elseif #groups == 0 then
            local msg = (state.traits_filter == 'All')
                and 'No traits from this set.'
                or ('No ' .. state.traits_filter .. ' traits in this set.')
            local bg = make_bg(col4_x, body_y, COL_TRAITS_W, SLOT_H, C_ROW_EMPTY)
            local text = make_text(msg, col4_x + 8, body_y + 4, 9, 180, 180, 180)
            show(bg); show(text)
            elements.traits_rows[#elements.traits_rows + 1] = { bg = bg, text = text }
        else
            local max_rows = math.floor(body_h / (SLOT_H + 2))
            local max_scroll = math.max(0, #groups - max_rows)
            if state.traits_scroll > max_scroll then state.traits_scroll = max_scroll end
            if state.traits_scroll < 0 then state.traits_scroll = 0 end
            local first = state.traits_scroll + 1
            local last  = math.min(#groups, first + max_rows - 1)
            -- Roman numeral lookup for tier display (capped at IV; the
            -- bonus tiers V/VI from the wiki page aren't gated by spell
            -- points so we don't try to render them).
            local roman = { 'I', 'II', 'III', 'IV', 'V', 'VI' }
            for visual = 1, last - first + 1 do
                local g = groups[first + visual - 1]
                local ry = body_y + (visual - 1) * (SLOT_H + 2)
                local bg = make_bg(col4_x, ry, COL_TRAITS_W, SLOT_H, C_ROW_BG)
                -- Build a compact label:
                --   "Magic Attack Bonus  II  12/16"  (have II, need 16 for III)
                --   "Lizard Killer       I   4"     (already maxed at I, no next)
                local tier_label = g.tier > 0 and (roman[g.tier] or ('T'..g.tier)) or '-'
                local progress
                if g.next_at then
                    progress = ('%d/%d'):format(g.pts, g.next_at)
                else
                    progress = ('%d'):format(g.pts)
                end
                local label = ('%s  %s  %s'):format(fit(g.trait, 22), tier_label, progress)
                -- Color cue: gold when at next-tier-1 (cheapest unlock left),
                -- normal otherwise.
                local r1, g1, b1 = 220, 220, 255
                if g.next_at and (g.next_at - g.pts) <= 2 then
                    r1, g1, b1 = 255, 230, 130  -- "close to next tier" highlight
                end
                local txt = make_text(label, col4_x + 6, ry + 3, 10, r1, g1, b1)
                show(bg); show(txt)
                elements.traits_rows[#elements.traits_rows + 1] = { bg = bg, text = txt }
            end
        end
    end

    -- Status line
    if not elements.status_text then
        elements.status_text = make_text('', x + PADDING, y + PANEL_H - BTN_H - PADDING - 16, 9, 200, 220, 255)
    else
        elements.status_text:pos(x + PADDING, y + PANEL_H - BTN_H - PADDING - 16)
    end
    show(elements.status_text)

    -- Action row: Save Current | New Empty Set | Equip | Delete
    local action_y = y + PANEL_H - BTN_H - PADDING
    local has_sel = (state.selected_set_name ~= nil)
    local function ensure_btn(field_bg, field_text, label)
        if not elements[field_bg] then
            elements[field_bg]   = make_bg(0, 0, BTN_W, BTN_H, C_BTN)
            elements[field_text] = make_text(label, 0, 0, 10, 255, 255, 255, true)
        end
    end
    ensure_btn('btn_save_bg',   'btn_save_text',   'Save Current Spell Set')
    ensure_btn('btn_new_bg',    'btn_new_text',    'New Empty Set')
    ensure_btn('btn_equip_bg',  'btn_equip_text',  'Equip Spell Set')
    -- Clear sits between Equip and Delete: it empties every slot of the
    -- currently-selected set WITHOUT deleting the set entry itself, so the
    -- user can keep the set name + start fresh on its contents. Distinct
    -- from Delete (which removes the saved set entirely).
    ensure_btn('btn_clear_bg',  'btn_clear_text',  'Clear Spell Set')
    ensure_btn('btn_delete_bg', 'btn_delete_text', 'Delete Spell Set')
    local function place_btn(field_bg, field_text, bx, color, label)
        local bg = elements[field_bg]
        local tx = elements[field_text]
        bg:pos(bx, action_y); bg:size(BTN_W, BTN_H)
        bg:alpha(color[1]); bg:color(color[2], color[3], color[4])
        tx:pos(bx + 10, action_y + 6)
        tx:text(label)
        show(bg); show(tx)
        return { x = bx, y = action_y, w = BTN_W, h = BTN_H }
    end
    local bx = x + PADDING
    state.rects.btn_save   = place_btn('btn_save_bg',   'btn_save_text',   bx, C_BTN,         'Save Current')
    bx = bx + BTN_W + COL_GAP
    state.rects.btn_new    = place_btn('btn_new_bg',    'btn_new_text',    bx, C_BTN_NEUTRAL, 'New Empty Set')
    bx = bx + BTN_W + COL_GAP
    state.rects.btn_equip  = place_btn('btn_equip_bg',  'btn_equip_text',  bx,
        has_sel and C_BTN_INFO or C_BTN_DISABLED, 'Equip Spell Set')
    bx = bx + BTN_W + COL_GAP
    -- Clear sits between Equip and Delete (per user request) so the
    -- destructive Delete button stays at the far right where it's harder
    -- to misclick.
    state.rects.btn_clear  = place_btn('btn_clear_bg',  'btn_clear_text',  bx,
        has_sel and C_BTN_NEUTRAL or C_BTN_DISABLED, 'Clear Spell Set')
    bx = bx + BTN_W + COL_GAP
    state.rects.btn_delete = place_btn('btn_delete_bg', 'btn_delete_text', bx,
        has_sel and C_BTN_DANGER or C_BTN_DISABLED, 'Delete Spell Set')

    -- Spell picker -> column 2 transforms into the picker view; cols 3 and
    -- 4 stay live and act as the preview area. No more centered modal,
    -- no more bleed-through, no more leftover headers on close. Only the
    -- col 2 slot rows are hidden behind the picker UI.
    if state.picker then
        for _, r in ipairs(elements.slots_rows) do hide(r.bg); hide(r.text) end
    end

    -- Spell picker (inline, over col 2) ------------------------------------
    if state.picker then
        -- Picker lives over col 2 only. Cols 3 (Spell Info) and 4
        -- (Cumulative Traits) stay visible and reflect picker state.
        -- Layout inside col 2 column:
        --   row 1: filter trigger ("Filter: All  v")
        --   row 2..N-2: scrollable spell list (with right-edge scroll arrows)
        --   row N-1: Cancel + optional Clear
        local px = col2_x
        local py = body_y
        local pw = COL_SLOTS_W
        local ph = body_h
        local SCROLL_W = 18

        if not elements.pick_bg then
            elements.pick_bg          = make_bg(0, 0, pw, ph, C_PANEL_BG)
            elements.pick_filter_bg   = make_bg(0, 0, pw - 2, PICKER_FILTER_H, C_BTN_NEUTRAL)
            elements.pick_filter_text = make_text('', 0, 0, 10, 255, 255, 255, true)
            elements.pick_up_bg       = make_bg(0, 0, SCROLL_W, 18, C_BTN_NEUTRAL)
            elements.pick_up_text     = make_text('^', 0, 0, 10, 255, 255, 255, true)
            elements.pick_down_bg     = make_bg(0, 0, SCROLL_W, 18, C_BTN_NEUTRAL)
            elements.pick_down_text   = make_text('v', 0, 0, 10, 255, 255, 255, true)
            elements.pick_clear_bg    = make_bg(0, 0, 70, BTN_H - 4, C_BTN_DANGER)
            elements.pick_clear_text  = make_text('Clear', 0, 0, 10, 255, 255, 255, true)
            elements.pick_cancel_bg   = make_bg(0, 0, 90, BTN_H - 4, C_BTN_NEUTRAL)
            elements.pick_cancel_text = make_text('Cancel', 0, 0, 10, 255, 255, 255, true)
        end

        -- Picker background fills the column 2 area so col 2's slot rows
        -- behind it are completely covered. (slots_rows are also hidden
        -- explicitly above, but the opaque bg here is the visual guarantee.)
        elements.pick_bg:pos(px, py); elements.pick_bg:size(pw, ph)
        show(elements.pick_bg)

        -- Filter trigger
        local active_filter = state.picker.filter or 'All'
        local filter_y = py + 2
        elements.pick_filter_bg:pos(px + 1, filter_y); elements.pick_filter_bg:size(pw - 2, PICKER_FILTER_H)
        elements.pick_filter_text:pos(px + 8, filter_y + 2)
        elements.pick_filter_text:text(('Filter: %s  v'):format(active_filter))
        show(elements.pick_filter_bg); show(elements.pick_filter_text)
        state.rects.pick_filter_trigger = {
            x = px + 1, y = filter_y, w = pw - 2, h = PICKER_FILTER_H,
        }

        -- Build the displayed spell list. Two filters layered:
        --   1. Already-used exclusion (so a spell can't be in two slots).
        --      The current slot's spell stays visible as the "current"
        --      selection / "leave it alone" affordance.
        --   2. Category filter (predicate from trait_db).
        local all_spells = state.data.all_spells or {}
        local used = {}
        local current_lc = state.picker.current_spell
            and state.picker.current_spell:lower() or nil
        for _, spell_name in pairs(state.data.selected_spellset or {}) do
            if type(spell_name) == 'string' then
                local lc = spell_name:lower()
                if lc ~= current_lc then used[lc] = true end
            end
        end
        local visible_spells = {}
        for _, spell in ipairs(all_spells) do
            if not used[spell:lower()] then
                if active_filter == 'All'
                   or state.data.filter_predicate(spell, active_filter) then
                    visible_spells[#visible_spells + 1] = spell
                end
            end
        end

        -- Layout: leave the bottom for the action row (Cancel + optional Clear).
        local footer_h = BTN_H - 4 + 6
        local list_top = filter_y + PICKER_FILTER_H + 4
        local list_bottom = py + ph - footer_h - 2
        local list_h = list_bottom - list_top
        local list_x = px + 1
        local list_w = pw - 2 - SCROLL_W - 2
        local sb_x  = list_x + list_w + 2
        local row_h = PICKER_ROW_H - 1
        local visible_count = math.max(1, math.floor(list_h / row_h))

        local total = #visible_spells
        local max_scroll = math.max(0, total - visible_count)
        if (state.picker.scroll or 0) > max_scroll then state.picker.scroll = max_scroll end
        local first = (state.picker.scroll or 0) + 1
        local last  = math.min(total, first + visible_count - 1)
        state.rects.pick_rows = {}
        for i = first, last do
            local spell = visible_spells[i]
            local idx = i - first
            local ry = list_top + idx * row_h
            local is_current = (state.picker.current_spell and spell:lower() == state.picker.current_spell:lower())
            local is_hovered = (state.picker.hovered_spell and spell:lower() == state.picker.hovered_spell:lower())
            local bg_color = is_current and C_ROW_BG_SEL
                          or (is_hovered and C_ROW_BG_HOV or C_ROW_BG)
            local bg = make_bg(list_x, ry, list_w, row_h - 1, bg_color)
            local tx = make_text(fit(spell, 25), list_x + 6, ry + 2, 10, 255, 255, 255, is_current or is_hovered)
            show(bg); show(tx)
            elements.pick_rows[#elements.pick_rows + 1] = { bg = bg, text = tx }
            state.rects.pick_rows[#state.rects.pick_rows + 1] = {
                x = list_x, y = ry, w = list_w, h = row_h - 1, spell = spell,
            }
        end
        if total == 0 then
            local bg = make_bg(list_x, list_top, list_w, row_h - 1, C_ROW_EMPTY)
            local tx = make_text('(no spells)', list_x + 6, list_top + 2, 10, 180, 180, 180)
            show(bg); show(tx)
            elements.pick_rows[#elements.pick_rows + 1] = { bg = bg, text = tx }
        end

        -- Scroll arrows on the right edge of the picker, aligned with the
        -- list area. Reuse the create-once elements.
        elements.pick_up_bg:pos(sb_x, list_top); elements.pick_up_bg:size(SCROLL_W, 18)
        elements.pick_up_text:pos(sb_x + 6, list_top + 2)
        elements.pick_down_bg:pos(sb_x, list_bottom - 18); elements.pick_down_bg:size(SCROLL_W, 18)
        elements.pick_down_text:pos(sb_x + 6, list_bottom - 16)
        show(elements.pick_up_bg); show(elements.pick_up_text)
        show(elements.pick_down_bg); show(elements.pick_down_text)
        state.rects.pick_up   = { x = sb_x, y = list_top, w = SCROLL_W, h = 18 }
        state.rects.pick_down = { x = sb_x, y = list_bottom - 18, w = SCROLL_W, h = 18 }

        -- Footer: Cancel always, Clear if the slot was already filled.
        local fy = list_bottom + 4
        if state.picker.current_spell then
            elements.pick_clear_bg:pos(px + 2, fy); elements.pick_clear_bg:size(70, BTN_H - 4)
            elements.pick_clear_text:pos(px + 2 + 18, fy + 4)
            show(elements.pick_clear_bg); show(elements.pick_clear_text)
            state.rects.pick_clear = { x = px + 2, y = fy, w = 70, h = BTN_H - 4 }
        else
            hide(elements.pick_clear_bg); hide(elements.pick_clear_text)
            state.rects.pick_clear = nil
        end
        elements.pick_cancel_bg:pos(px + pw - 92, fy); elements.pick_cancel_bg:size(90, BTN_H - 4)
        elements.pick_cancel_text:pos(px + pw - 92 + 26, fy + 4)
        show(elements.pick_cancel_bg); show(elements.pick_cancel_text)
        state.rects.pick_cancel = { x = px + pw - 92, y = fy, w = 90, h = BTN_H - 4 }
        -- Bounds for outside-click dismissal
        state.rects.picker_bounds = { x = px, y = py, w = pw, h = ph }
    else
        -- Picker is closed: hide everything we might have created
        hide(elements.pick_bg)
        hide(elements.pick_filter_bg);  hide(elements.pick_filter_text)
        hide(elements.pick_up_bg);      hide(elements.pick_up_text)
        hide(elements.pick_down_bg);    hide(elements.pick_down_text)
        hide(elements.pick_clear_bg);   hide(elements.pick_clear_text)
        hide(elements.pick_cancel_bg);  hide(elements.pick_cancel_text)
        state.rects.pick_filter_trigger = nil
        state.rects.pick_up = nil; state.rects.pick_down = nil
        state.rects.pick_clear = nil; state.rects.pick_cancel = nil
        state.rects.pick_rows = nil; state.rects.picker_bounds = nil
    end

    -- Dropdown overlay -----------------------------------------------------
    -- Renders BELOW its anchor header, on top of everything else (except
    -- the confirm modal which always wins). One dropdown at a time; click
    -- an option to select+close, click outside to dismiss.
    --
    -- Bleed-through pre-fix: Windower draws text on a layer above images,
    -- so an opaque dropdown bg STILL doesn't cover text rows underneath
    -- it -- the spell names show through. For each known dropdown anchor,
    -- hide the row elements it overlaps before drawing the dropdown.
    if state.dropdown then
        if state.dropdown.key == 'picker_filter' then
            -- Dropdown sits over col 2 (the picker spell list).
            for _, r in ipairs(elements.pick_rows or {}) do
                hide(r.bg); hide(r.text)
            end
        elseif state.dropdown.key == 'traits' then
            -- Dropdown sits over col 4 (the cumulative traits list).
            for _, r in ipairs(elements.traits_rows or {}) do
                hide(r.bg); hide(r.text)
            end
        end

        local d = state.dropdown
        local options = d.options or {}
        local ITEM_H = 20
        local mw = math.max(d.width or 160, 160)
        -- Cap visible item count so the dropdown can scroll instead of
        -- growing huge. Anything beyond gets ^/v buttons (24 px col on
        -- the right edge). Tunable: bumped to 18 so the user sees more
        -- options per page before scrolling.
        local SCROLL_W = 22
        local MAX_VISIBLE = 18
        local needs_scroll = #options > MAX_VISIBLE
        local visible_count = needs_scroll and MAX_VISIBLE or #options
        local mh = visible_count * ITEM_H + 4
        local mx = d.anchor_x
        local my = d.anchor_y
        -- Clamp horizontally so the dropdown stays inside the panel.
        if mx + mw > x + PANEL_W - PADDING then
            mx = x + PANEL_W - PADDING - mw
        end
        -- Clamp vertically: if the dropdown would overflow the panel,
        -- slide it up so its bottom edge stays inside.
        if my + mh > y + PANEL_H - PADDING then
            my = y + PANEL_H - PADDING - mh
        end
        if not elements.dropdown_bg then
            elements.dropdown_bg = make_bg(mx, my, mw, mh, C_MODAL_BG)
        end
        elements.dropdown_bg:pos(mx, my); elements.dropdown_bg:size(mw, mh)
        show(elements.dropdown_bg)
        state.rects.dropdown_items = {}
        local active_value = d.active_value or state[d.key .. '_filter'] or 'All'
        -- Clamp scroll
        d.scroll = d.scroll or 0
        local max_scroll = math.max(0, #options - visible_count)
        if d.scroll > max_scroll then d.scroll = max_scroll end
        if d.scroll < 0 then d.scroll = 0 end
        local first = d.scroll + 1
        local last  = math.min(#options, first + visible_count - 1)
        local row_w = mw - 4 - (needs_scroll and SCROLL_W or 0)
        for visual_i = 1, last - first + 1 do
            local opt = options[first + visual_i - 1]
            local iy = my + 2 + (visual_i - 1) * ITEM_H
            local is_active = (opt == active_value)
            local color = is_active and C_BTN_INFO or C_ROW_BG
            local bg = make_bg(mx + 2, iy, row_w, ITEM_H - 2, color)
            local tx = make_text(opt, mx + 10, iy + 3, 10, 255, 255, 255, is_active)
            show(bg); show(tx)
            elements.dropdown_items[#elements.dropdown_items + 1] = { bg = bg, text = tx }
            state.rects.dropdown_items[#state.rects.dropdown_items + 1] = {
                x = mx + 2, y = iy, w = row_w, h = ITEM_H - 2, value = opt,
            }
        end
        if needs_scroll then
            -- Tiny ^/v buttons on the right edge of the dropdown
            local sb_x = mx + mw - SCROLL_W - 1
            if not elements.dropdown_up_bg then
                elements.dropdown_up_bg   = make_bg(0, 0, SCROLL_W, 16, C_BTN_NEUTRAL)
                elements.dropdown_up_text = make_text('^', 0, 0, 10, 255, 255, 255, true)
                elements.dropdown_down_bg   = make_bg(0, 0, SCROLL_W, 16, C_BTN_NEUTRAL)
                elements.dropdown_down_text = make_text('v', 0, 0, 10, 255, 255, 255, true)
            end
            elements.dropdown_up_bg:pos(sb_x, my + 2); elements.dropdown_up_bg:size(SCROLL_W, 16)
            elements.dropdown_up_text:pos(sb_x + 7, my + 3)
            elements.dropdown_down_bg:pos(sb_x, my + mh - 18); elements.dropdown_down_bg:size(SCROLL_W, 16)
            elements.dropdown_down_text:pos(sb_x + 7, my + mh - 17)
            show(elements.dropdown_up_bg); show(elements.dropdown_up_text)
            show(elements.dropdown_down_bg); show(elements.dropdown_down_text)
            state.rects.dropdown_up   = { x = sb_x, y = my + 2,        w = SCROLL_W, h = 16 }
            state.rects.dropdown_down = { x = sb_x, y = my + mh - 18,  w = SCROLL_W, h = 16 }
        else
            hide(elements.dropdown_up_bg); hide(elements.dropdown_up_text)
            hide(elements.dropdown_down_bg); hide(elements.dropdown_down_text)
            state.rects.dropdown_up = nil
            state.rects.dropdown_down = nil
        end
        state.rects.dropdown_bounds = { x = mx, y = my, w = mw, h = mh }
    else
        hide(elements.dropdown_bg)
        hide(elements.dropdown_up_bg); hide(elements.dropdown_up_text)
        hide(elements.dropdown_down_bg); hide(elements.dropdown_down_text)
        state.rects.dropdown_items  = nil
        state.rects.dropdown_bounds = nil
        state.rects.dropdown_up = nil
        state.rects.dropdown_down = nil
    end

    -- Confirm modal (on top of everything, including picker and dropdown)
    if state.confirm then
        local mw, mh = 360, 120
        local mx = x + (PANEL_W - mw) / 2
        local my = y + (PANEL_H - mh) / 2
        if not elements.modal_bg then
            elements.modal_bg       = make_bg(0, 0, mw, mh, C_MODAL_BG)
            elements.modal_text     = make_text('', 0, 0, 11, 255, 230, 230, true)
            elements.modal_yes_bg   = make_bg(0, 0, 90, 28, C_BTN_DANGER)
            elements.modal_yes_text = make_text('Yes', 0, 0, 11, 255, 255, 255, true)
            elements.modal_no_bg    = make_bg(0, 0, 90, 28, C_BTN_INFO)
            elements.modal_no_text  = make_text('No', 0, 0, 11, 255, 255, 255, true)
        end
        elements.modal_bg:pos(mx, my); elements.modal_bg:size(mw, mh)
        elements.modal_text:pos(mx + 16, my + 16)
        elements.modal_text:text(state.confirm.message or 'Are you sure?')
        local yes_x = mx + 40
        local no_x  = mx + mw - 130
        elements.modal_yes_bg:pos(yes_x, my + mh - 40); elements.modal_yes_bg:size(90, 28)
        elements.modal_yes_text:pos(yes_x + 32, my + mh - 33)
        elements.modal_no_bg:pos(no_x, my + mh - 40); elements.modal_no_bg:size(90, 28)
        elements.modal_no_text:pos(no_x + 36, my + mh - 33)
        show(elements.modal_bg); show(elements.modal_text)
        show(elements.modal_yes_bg); show(elements.modal_yes_text)
        show(elements.modal_no_bg); show(elements.modal_no_text)
        state.rects.modal_yes = { x = yes_x, y = my + mh - 40, w = 90, h = 28 }
        state.rects.modal_no  = { x = no_x,  y = my + mh - 40, w = 90, h = 28 }
    else
        hide(elements.modal_bg); hide(elements.modal_text)
        hide(elements.modal_yes_bg); hide(elements.modal_yes_text)
        hide(elements.modal_no_bg); hide(elements.modal_no_text)
        state.rects.modal_yes = nil; state.rects.modal_no = nil
    end
end

-- =============================================================================
-- Mouse handling
-- =============================================================================
local function open_picker(slot_num, current_spell)
    state.picker = {
        slot_num = slot_num,
        current_spell = current_spell,
        scroll = 0,
        filter = 'All',
    }
    state.dropdown = nil   -- close any open dropdown so it doesn't overlap
    if state.visible then ui.render() end
end

local function close_picker()
    state.picker = nil
    -- Belt-and-suspenders: hide every picker element directly. Cheaper
    -- now that the inline picker has way fewer primitives than the old
    -- modal -- just bg + filter + scroll buttons + footer.
    hide(elements.pick_bg)
    hide(elements.pick_filter_bg);  hide(elements.pick_filter_text)
    hide(elements.pick_up_bg);      hide(elements.pick_up_text)
    hide(elements.pick_down_bg);    hide(elements.pick_down_text)
    hide(elements.pick_clear_bg);   hide(elements.pick_clear_text)
    hide(elements.pick_cancel_bg);  hide(elements.pick_cancel_text)
    for _, r in ipairs(elements.pick_rows or {}) do
        hide(r.bg); hide(r.text)
    end
    state.rects.pick_filter_trigger = nil
    state.rects.pick_up    = nil; state.rects.pick_down = nil
    state.rects.pick_clear = nil; state.rects.pick_cancel = nil
    state.rects.pick_rows  = nil; state.rects.picker_bounds = nil
    if state.visible then ui.render() end
end

function ui.handle_mouse(mtype, x, y)
    if not state.visible then return false end

    local panel_rect = { x = state.pos.x, y = state.pos.y, w = PANEL_W, h = PANEL_H }
    local over_panel = inside(panel_rect, x, y)

    -- Dropdown: eats events while open. Options dispatch on click, the
    -- dropdown body swallows other inside clicks, outside clicks close
    -- the dropdown. Anchor click is special: the click would otherwise
    -- fall through to the anchor's own handler and immediately reopen the
    -- dropdown, so we swallow it on close to make toggle behavior work.
    if state.dropdown then
        if mtype == 1 then
            -- Scroll buttons (only present when the dropdown is taller than
            -- its visible window).
            if state.rects.dropdown_up and inside(state.rects.dropdown_up, x, y) then
                state.dropdown.scroll = math.max(0, (state.dropdown.scroll or 0) - 4)
                ui.render(); return true
            end
            if state.rects.dropdown_down and inside(state.rects.dropdown_down, x, y) then
                state.dropdown.scroll = (state.dropdown.scroll or 0) + 4
                ui.render(); return true
            end
            for _, r in ipairs(state.rects.dropdown_items or {}) do
                if inside(r, x, y) then
                    if state.dropdown.on_select then
                        state.dropdown.on_select(r.value)
                    end
                    state.dropdown = nil
                    ui.render()
                    return true
                end
            end
            if not inside(state.rects.dropdown_bounds, x, y) then
                -- Outside-click: close the dropdown AND swallow the
                -- click. Previously this fell through to the handler
                -- below for a "dismiss + action in one click" UX, but
                -- in the picker that meant clicking off the filter
                -- accidentally selected the spell row beneath it. The
                -- safer rule: closing a menu doesn't double as an
                -- action. User clicks once more to do whatever they
                -- wanted next.
                state.dropdown = nil
                ui.render()
                return true
            end
        elseif mtype == 0 or mtype == 2 then
            -- Pass move/up events through so dragging isn't blocked.
        end
    end

    -- Confirm modal: eats everything while open
    if state.confirm then
        if mtype == 1 then
            if inside(state.rects.modal_yes, x, y) then
                local cb = state.confirm.on_yes
                state.confirm = nil; ui.render(); cb()
                return true
            elseif inside(state.rects.modal_no, x, y) then
                local cb = state.confirm.on_no
                state.confirm = nil; ui.render(); cb()
                return true
            end
        end
        return true
    end

    -- Spell picker (inline): hover on rows updates state.picker.hovered_spell
    -- so cols 3 (Spell Info) and 4 (Cumulative Traits) preview the result.
    -- Clicks: filter trigger / scroll arrows / Clear / Cancel / row.
    -- Click OUTSIDE the picker bounds also closes it -- the picker is
    -- inline, not modal, so this is intuitive.
    if state.picker then
        if mtype == 0 then
            local new_hover = nil
            for _, r in ipairs(state.rects.pick_rows or {}) do
                if inside(r, x, y) then new_hover = r.spell; break end
            end
            if new_hover ~= state.picker.hovered_spell then
                state.picker.hovered_spell = new_hover
                ui.render()
            end
            return true
        end
        if mtype == 1 then
            if inside(state.rects.pick_cancel, x, y) then
                close_picker(); return true
            end
            if state.rects.pick_filter_trigger and inside(state.rects.pick_filter_trigger, x, y) then
                if state.dropdown and state.dropdown.key == 'picker_filter' then
                    state.dropdown = nil
                else
                    -- Build filter options list: All + 6 categories + every
                    -- individual trait. The trait list is bundled into the
                    -- data hook so we can compute it once per init rather
                    -- than rebuild on every dropdown open. Fall back to a
                    -- direct trait_db lookup if the data hook hasn't been
                    -- pushed yet (defensive -- shouldn't happen in practice
                    -- but guarantees the dropdown shows all 43 options).
                    local opts = { 'All' }
                    for _, c in ipairs(CATEGORY_CYCLE) do
                        if c ~= 'All' then opts[#opts+1] = c end
                    end
                    local trait_list = state.data.all_traits_flat
                    if (not trait_list or #trait_list == 0) and trait_db_local then
                        trait_list = trait_db_local.all_traits_flat()
                    end
                    for _, t in ipairs(trait_list or {}) do
                        opts[#opts+1] = t
                    end
                    state.dropdown = {
                        key = 'picker_filter',
                        anchor_x = state.rects.pick_filter_trigger.x,
                        anchor_y = state.rects.pick_filter_trigger.y + state.rects.pick_filter_trigger.h,
                        anchor_rect = state.rects.pick_filter_trigger,
                        width = state.rects.pick_filter_trigger.w,
                        options = opts,
                        active_value = state.picker.filter or 'All',
                        scroll = 0,
                        on_select = function(value)
                            if state.picker then
                                state.picker.filter = value
                                state.picker.scroll = 0
                            end
                        end,
                    }
                end
                ui.render(); return true
            end
            if inside(state.rects.pick_up, x, y) then
                state.picker.scroll = math.max(0, (state.picker.scroll or 0) - 6)
                ui.render(); return true
            end
            if inside(state.rects.pick_down, x, y) then
                state.picker.scroll = (state.picker.scroll or 0) + 6
                ui.render(); return true
            end
            if state.rects.pick_clear and inside(state.rects.pick_clear, x, y) then
                state.callbacks.on_assign_slot(state.selected_set_name, state.picker.slot_num, nil)
                close_picker()
                return true
            end
            for _, r in ipairs(state.rects.pick_rows or {}) do
                if inside(r, x, y) then
                    -- Auto-advance: after assigning the spell, look for the
                    -- next empty slot starting at slot_num + 1 (wrapping
                    -- around through slot 1 if we hit slot 20). If found,
                    -- reopen the picker on that slot with the SAME filter
                    -- and scroll state so the user can rapid-fire pick
                    -- spells from one filtered list. Only closes when the
                    -- set is full.
                    local prior_filter = state.picker.filter
                    local prior_scroll = state.picker.scroll
                    local prior_slot   = state.picker.slot_num
                    state.callbacks.on_assign_slot(state.selected_set_name, prior_slot, r.spell)
                    -- on_assign_slot calls ui.view_set which nils state.picker
                    -- and refreshes data. Read the freshly-updated spellset
                    -- to find the next empty slot.
                    local set = state.data.selected_spellset or {}
                    local function slot_key(i) return ('slot%02u'):format(i) end
                    local next_slot
                    for i = prior_slot + 1, 20 do
                        if not set[slot_key(i)] then next_slot = i; break end
                    end
                    if not next_slot then
                        for i = 1, prior_slot - 1 do
                            if not set[slot_key(i)] then next_slot = i; break end
                        end
                    end
                    if next_slot then
                        state.picker = {
                            slot_num = next_slot,
                            current_spell = set[slot_key(next_slot)],
                            scroll = prior_scroll,
                            filter = prior_filter,
                            hovered_spell = nil,
                        }
                        ui.render()
                    else
                        close_picker()
                    end
                    return true
                end
            end
            -- Click outside picker bounds (but still over the panel) closes
            -- the picker. Outside the panel entirely is handled by the
            -- camera-rubber-band fallback at the bottom of this function.
            if state.rects.picker_bounds and not inside(state.rects.picker_bounds, x, y) then
                if over_panel then
                    close_picker()
                    return true
                end
            end
        end
        if over_panel then return true end
    end

    -- Title-bar drag start
    if mtype == 1 and inside(state.rects.title, x, y) then
        state.dragging = true
        state.drag_dx = x - state.pos.x
        state.drag_dy = y - state.pos.y
        return true
    end

    if mtype == 1 then
        -- Column scroll arrows. Each click pages by half the column's
        -- visible row count (calculated from CONTENT_H) so users land
        -- somewhere reasonable without micro-clicking row by row.
        local SCROLL_STEP = 6
        for key, rects in pairs(state.rects.col_scroll or {}) do
            if inside(rects.up, x, y) then
                state[key..'_scroll'] = math.max(0, (state[key..'_scroll'] or 0) - SCROLL_STEP)
                ui.render(); return true
            end
            if inside(rects.down, x, y) then
                state[key..'_scroll'] = (state[key..'_scroll'] or 0) + SCROLL_STEP
                ui.render(); return true
            end
        end

        -- Column header opens a dropdown picker. Currently only the
        -- Cumulative Traits column uses this; the others just won't have
        -- entries in col_header_click. If the same dropdown is already
        -- open, the click closes it (toggle behavior). anchor_rect is
        -- recorded so the dropdown handler can swallow outside-clicks
        -- that land on it (preventing reopen-on-toggle).
        for key, rect in pairs(state.rects.col_header_click or {}) do
            if inside(rect, x, y) then
                if state.dropdown and state.dropdown.key == key then
                    state.dropdown = nil
                else
                    state.dropdown = {
                        key = key,
                        anchor_x = rect.x,
                        anchor_y = rect.y + rect.h,
                        anchor_rect = rect,
                        width = rect.w + 36, -- header width inc. scroll arrows
                        options = CATEGORY_CYCLE,
                        on_select = function(value)
                            state[key .. '_filter'] = value
                            state[key .. '_scroll'] = 0
                        end,
                    }
                end
                ui.render(); return true
            end
        end

        -- Saved sets: click row to select
        for _, r in ipairs(state.rects.sets_rows or {}) do
            if inside(r.row, x, y) then
                if r.row.is_live then state.callbacks.on_view_live()
                else                  state.callbacks.on_view_set(r.row.name) end
                return true
            end
        end

        -- Slot rows: click to edit (open picker) when a saved set is selected
        for _, r in ipairs(state.rects.slot_rows or {}) do
            if inside(r, x, y) then
                if r.editable then
                    open_picker(r.slot_num, r.spell)
                else
                    ui.set_status('Select a saved set to edit slots ([Live] is read-only).')
                end
                return true
            end
        end

        -- Action row
        if inside(state.rects.btn_save, x, y) then
            state.callbacks.on_save_current(); return true
        end
        if inside(state.rects.btn_new, x, y) then
            state.callbacks.on_new_empty_set(); return true
        end
        if inside(state.rects.btn_equip, x, y) then
            if state.selected_set_name then state.callbacks.on_equip_set(state.selected_set_name)
            else ui.set_status('Select a saved set first.') end
            return true
        end
        if inside(state.rects.btn_clear, x, y) then
            if state.selected_set_name then
                local name = state.selected_set_name
                ui.confirm("Clear all spells from '"..name.."'? (Set keeps its name.)",
                    function() state.callbacks.on_clear_set(name) end)
            else
                ui.set_status('Select a saved set first.')
            end
            return true
        end
        if inside(state.rects.btn_delete, x, y) then
            if state.selected_set_name then
                local name = state.selected_set_name
                ui.confirm("Delete spell set '"..name.."'?",
                    function() state.callbacks.on_delete_set(name) end)
            else
                ui.set_status('Live cannot be deleted -- select a saved set.')
            end
            return true
        end
    elseif mtype == 2 then
        if state.dragging then
            state.dragging = false
            pos_save(state.pos.x, state.pos.y)
            return true
        end
    elseif mtype == 0 then
        if state.dragging then
            state.pos.x = x - state.drag_dx
            state.pos.y = y - state.drag_dy
            ui.render()
            return true
        end
        local new_hover = nil
        for _, r in ipairs(state.rects.slot_rows or {}) do
            if r.spell and inside(r, x, y) then new_hover = r.spell; break end
        end
        if new_hover ~= state.hovered_spell then
            state.hovered_spell = new_hover
            -- Reset info-column scroll so the new spell starts at the top.
            state.info_scroll = 0
            ui.render()
        end
        if over_panel then return true end
    end

    if over_panel then return true end
    return false
end

return ui
