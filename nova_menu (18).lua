-- nova_menu.lua v0.9.6 : standalone animated menu.
-- Floating draggable button + FPS/Ping/Held-item HUD -> animated panel -> Info / GUI / Tweaks / Crystals.
-- v0.9: Crystals tab = chest auto-take (item 3459, chest block 54) + floor collector with radius slider.
-- Same engine APIs as 1.lua (GUIManager / GUISystem / LuaTimer / registerEvent).
-- Nothing is sent over the network. Not tested in-game.
-- v0.9.6: Recorder (continuous probe -> nova_rec.txt).
-- Two engine calls are still unconfirmed (chest take, item click): see 'Crystals' tab -> Probe.

if _G.NovaMenu then return _G.NovaMenu end
local NovaMenu = { tabs = {} }
_G.NovaMenu = NovaMenu

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------
local W, H     = 840, 480          -- panel size
local SIDE     = 180               -- sidebar width
local HEAD     = 52                -- header height
local ROW_W    = W - SIDE - 30     -- default row width
local FRAME_MS = 16                -- tween tick
local HUD_W    = 220               -- width of the fps/ping text block

local C = {
    clear   = {0, 0, 0, 0},
    bg      = {0.043, 0.051, 0.082, 0.98},
    panel   = {0.067, 0.078, 0.125, 1},
    card    = {0.094, 0.109, 0.165, 1},
    line    = {0.17, 0.19, 0.28, 1},
    off     = {0.20, 0.22, 0.31, 1},
    tabOn   = {0.115, 0.13, 0.20, 1},
    accent  = {0.49, 0.36, 1.00, 1},
    accent2 = {0.25, 0.85, 0.95, 1},
    text    = {0.93, 0.94, 0.98, 1},
    muted   = {0.55, 0.58, 0.70, 1},
    danger  = {0.95, 0.32, 0.38, 1},
    good    = {0.30, 0.90, 0.50, 1},
    warn    = {1.00, 0.80, 0.25, 1},
}

----------------------------------------------------------------------
-- utils
----------------------------------------------------------------------
local uid = 0
local function nid(p) uid = uid + 1; return "NV_" .. p .. "_" .. uid end

local function lerp(a, b, t) return a + (b - a) * t end
local function lerpC(a, b, t)
    return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t) }
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local ease = {
    outCubic = function(t) t = 1 - t; return 1 - t * t * t end,
    inCubic  = function(t) return t * t * t end,
}

-- own clock (seconds), so we do not depend on os.clock existing
local clock = 0
local function now() return clock end

local function setAlpha(w, a) pcall(function() w:SetAlpha(a) end) end
local function on(w, ev, fn) pcall(function() w:registerEvent(ev, fn) end) end
local function sound(id) pcall(function() SoundUtil.playSound(id) end) end
local function toast(t) pcall(function() UIHelper.showToast(t) end) end

-- keyed tweens: starting a tween on a key cancels the previous one
local running = {}
local function stop(key)
    if running[key] then LuaTimer:cancel(running[key]); running[key] = nil end
end
local function tween(key, ms, fn, step, done)
    stop(key)
    local frames, f = math.max(1, math.floor(ms / FRAME_MS)), 0
    running[key] = LuaTimer:scheduleTimer(function()
        f = f + 1
        local ok = pcall(step, fn(f / frames))
        if f >= frames or not ok then
            stop(key)
            if done then pcall(done) end
        end
    end, FRAME_MS, -1)
end

----------------------------------------------------------------------
-- widget factory
----------------------------------------------------------------------
local function win(gtype, prefix, parent)
    local w = GUIManager:createGUIWindow(gtype, nid(prefix))
    if parent then parent:AddChildWindow(w) end
    return w
end

local function box(parent, x, y, w, h, col, touch)          -- absolute pixels
    local l = win(GUIType.Layout, "L", parent)
    l:SetArea({0, x}, {0, y}, {0, w}, {0, h})
    l:SetBackgroundColor(col)
    l:SetTouchable(touch == true)
    return l
end

local function text(parent, str, x, y, w, h, col, scale, align)  -- absolute pixels
    local t = win(GUIType.StaticText, "T", parent)
    t:SetArea({0, x}, {0, y}, {0, w}, {0, h})
    t:SetText(str)
    t:SetTextColor(col)
    t:SetTextScale(scale or 1)
    t:SetBackgroundColor(C.clear)
    t:SetTouchable(false)
    t:SetTextHorzAlign(align or HorizontalAlignment.Left)
    t:SetTextVertAlign(VerticalAlignment.Center)
    return t
end

local function button(parent, str, x, y, w, h, bg, fg, scale, onClick)
    local b = win(GUIType.Button, "B", parent)
    b:SetArea({0, x}, {0, y}, {0, w}, {0, h})
    b:SetText(str)
    b:SetTextColor(fg)
    b:SetTextScale(scale or 1)
    b:SetBackgroundColor(bg)
    b:SetTouchable(true)
    if onClick then on(b, GUIEvent.ButtonClick, onClick) end
    return b
end

local function pressFx(b, normal, pressed)
    on(b, GUIEvent.TouchDown, function() b:SetBackgroundColor(pressed) end)
    on(b, GUIEvent.TouchUp,   function() b:SetBackgroundColor(normal) end)
end

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------
local S = {
    pdx = 0, pdy = 0,        -- panel offset from screen center
    fdx = -150, fy = 6,      -- button: x offset from screen center, y from top
    fabSize = 64,
    prog = 0,                -- 0 closed .. 1 open
    cur = nil,               -- current tab index
    closeOutside = true,
    pulse = true,
    hud = true,
    hideBagFull = true,
    learned = "",          -- extra tip texts to hide, separated by |
    radius = 30,             -- crystals: floor search radius (blocks)
    chestDelay = 3,          -- crystals: ticks between chest stacks (100 ms each)
}
local frame, dim, sidebar, content, indicator, root
local fab, fabInner, fabLabel
local hud = {}               -- hud.fps, hud.ping, hud.item
local INFO = {}              -- live labels of the Info tab

----------------------------------------------------------------------
-- saved settings (positions, toggles) -> small text file
----------------------------------------------------------------------
-- folders tried in order; the first one that opens for writing wins
local DATA_DIRS = {
    "/storage/emulated/0/Android/data/com.sandboxol.blockymods.channel.official/files/",
    "/storage/emulated/0/Android/data/com.sandboxol.blockymods.channel.official/",
    "/storage/emulated/0/Android/data/com.sandboxol.blockymods/files/",
    "",
}
local function pathsFor(name)
    local t = {}
    for _, d in ipairs(DATA_DIRS) do t[#t + 1] = d .. name end
    return t
end
local SAVE_PATHS = pathsFor("nova_settings.txt")
local NUM_KEYS  = { "pdx", "pdy", "fdx", "fy", "fabSize", "radius", "chestDelay" }
local BOOL_KEYS = { "hud", "pulse", "closeOutside", "hideBagFull" }
local KNOWN = {}
for _, k in ipairs(NUM_KEYS) do KNOWN[k] = "num" end
for _, k in ipairs(BOOL_KEYS) do KNOWN[k] = "bool" end
KNOWN.learned = "str"

local function markDirty() S._dirty = true end

local function saveSettings()
    local lines = {}
    for _, k in ipairs(NUM_KEYS)  do lines[#lines + 1] = k .. "=" .. tostring(S[k]) end
    for _, k in ipairs(BOOL_KEYS) do lines[#lines + 1] = k .. "=" .. tostring(S[k]) end
    if S.learned ~= "" then lines[#lines + 1] = "learned=" .. S.learned:gsub("[\r\n]", " ") end
    local data = table.concat(lines, "\n")
    for _, path in ipairs(SAVE_PATHS) do
        local ok = pcall(function()
            local f = io.open(path, "w")
            if not f then error("open failed") end
            f:write(data); f:close()
        end)
        if ok then return true end
    end
    return false
end

local function loadSettings()
    for _, path in ipairs(SAVE_PATHS) do
        local data
        pcall(function()
            local f = io.open(path, "r")
            if f then data = f:read("*a"); f:close() end
        end)
        if data and #data > 0 then
            for k, v in data:gmatch("([%w_]+)=([^\n\r]+)") do
                if KNOWN[k] == "num" and tonumber(v) then
                    S[k] = clamp(tonumber(v), -4000, 4000)
                elseif KNOWN[k] == "bool" then
                    S[k] = (v == "true")
                elseif KNOWN[k] == "str" then
                    S[k] = v:sub(1, 600)
                end
            end
            S.fabSize = clamp(S.fabSize, 48, 88)
            S.radius = clamp(S.radius, 5, 150)
            S.chestDelay = clamp(S.chestDelay, 1, 20)
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
-- menu-style notifications (3 slots, round robin)
----------------------------------------------------------------------
local TOAST = { slots = {}, n = 3, i = 0 }

local function buildToasts(guiRoot)
    for k = 1, TOAST.n do
        local card = box(guiRoot, 0, 0, 340, 42, C.accent)
        card:SetArea({0.5, -170}, {0, 150 + (k - 1) * 48}, {0, 340}, {0, 42})
        local inner = box(card, 1, 1, 338, 40, C.panel)
        local bar = box(inner, 0, 0, 4, 40, C.accent)
        local lbl = text(inner, "", 14, 0, 318, 40, C.text, 0.9)
        pcall(function() card:SetLevel(15) end)
        card:SetVisible(false)
        TOAST.slots[k] = { card = card, bar = bar, lbl = lbl, gen = 0 }
    end
end

local function notify(msg, kind)               -- kind: "ok" | "bad" | nil
    if #TOAST.slots == 0 then toast(msg); return end
    TOAST.i = TOAST.i % TOAST.n + 1
    local k = TOAST.i
    local sl = TOAST.slots[k]
    sl.gen = sl.gen + 1
    local gen = sl.gen
    local col = (kind == "bad") and C.danger or ((kind == "ok") and C.good or C.accent)
    sl.card:SetBackgroundColor(col)
    sl.bar:SetBackgroundColor(col)
    sl.lbl:SetText(msg)
    sl.card:SetVisible(true)
    local y = 150 + (k - 1) * 48
    tween("toast" .. k, 220, ease.outCubic, function(p)
        sl.card:SetArea({0.5, -170}, {0, y - 14 * (1 - p)}, {0, 340}, {0, 42})
        setAlpha(sl.card, p)
    end)
    LuaTimer:schedule(function()
        if sl.gen ~= gen then return end
        tween("toast" .. k, 220, ease.inCubic, function(p)
            sl.card:SetArea({0.5, -170}, {0, y - 14 * p}, {0, 340}, {0, 42})
            setAlpha(sl.card, 1 - p)
        end, function() if sl.gen == gen then sl.card:SetVisible(false) end end)
    end, 2400)
end
NovaMenu.notify = notify

local function homeFab()     -- top of the screen, a bit left of center
    S.fdx, S.fy = -150, 6
end

----------------------------------------------------------------------
-- game info helpers
----------------------------------------------------------------------
local function readStats()
    local fps, ping, held = 0, 0, -1
    pcall(function() fps = Root.Instance():getFPS() or 0 end)
    pcall(function() ping = ClientNetwork.Instance():getRaknetPing() or 0 end)
    pcall(function()
        local p = PlayerManager:getClientPlayer()
        if p and p.Player then held = p.Player:getHeldItemId() or -1 end
    end)
    return fps, ping, held
end

local function fpsColor(v)  return v >= 50 and C.good or (v >= 30 and C.warn or C.danger) end
local function pingColor(v) return v <= 80 and C.good or (v <= 180 and C.warn or C.danger) end

local function gameVersion()
    local v = "?.??.?"
    pcall(function()
        local info = HostApi.getClientInfo()
        if info then
            info = json.decode(info)
            if info and info.app_version then v = info.app_version end
        end
    end)
    return v
end

local function profile()
    local name, id, sex = "Unknown", "?", 1
    pcall(function() id = tostring(CGame.Instance():getPlatformUserId()) end)
    pcall(function()
        local p = PlayerManager:getClientPlayer()
        if p then
            name = p:getName() or name
            if p.Player and p.Player.getSex then sex = p.Player:getSex()
            elseif p.getSex then sex = p:getSex() end
        end
    end)
    return name, id, sex
end

----------------------------------------------------------------------
-- page builder (rows inside a scroll pane)
----------------------------------------------------------------------
-- parent/area optional: default is a full-size page inside `content`
local function newPage(parent, rowW, area)
    local RW = rowW or ROW_W
    local pane = win(GUIType.ScrollablePane, "P", parent or content)
    if area then
        pane:SetArea({0, area[1]}, {0, area[2]}, {0, area[3]}, {0, area[4]})
    else
        pane:SetArea({0, 6}, {0, 6}, {1, -12}, {1, -12})
    end
    pane:InitializeContainer()
    pane:SetProperty("AutoScrollBar", "true")

    local holder = win(GUIType.Layout, "PH")
    holder:SetWidth({0, RW + 6})
    holder:SetHeight({0, 600})

    local ui = { y = 4, pane = pane, holder = holder }

    function ui:section(str)
        text(holder, str:upper(), 4, self.y, RW, 20, C.accent2, 0.8)
        self.y = self.y + 24
    end

    function ui:row(h)
        local card  = box(holder, 0, self.y, RW, h, C.line)
        local inner = box(card, 1, 1, RW - 2, h - 2, C.card)
        self.y = self.y + h + 8
        return inner
    end

    function ui:info(str)                      -- StaticText does not wrap: wrap by hand
        local maxChars = math.floor((RW - 32) / 8.8)
        local lines, cur = {}, ""
        for word in str:gmatch("%S+") do
            if #cur + #word + 1 > maxChars and #cur > 0 then
                lines[#lines + 1] = cur; cur = word
            else
                cur = (#cur > 0) and (cur .. " " .. word) or word
            end
        end
        if #cur > 0 then lines[#lines + 1] = cur end
        local h = 20 + #lines * 20
        local r = self:row(h)
        for k, ln in ipairs(lines) do
            text(r, ln, 16, 10 + (k - 1) * 20, RW - 32, 20, C.muted, 0.88)
        end
    end

    function ui:kv(key, value, col)            -- "key ........ value" row, value updatable
        local r = self:row(38)
        text(r, key, 16, 0, RW * 0.4, 36, C.muted, 0.9)
        local v = text(r, value, RW * 0.4, 0, RW * 0.6 - 18, 36, col or C.text, 0.95, HorizontalAlignment.Right)
        return {
            set = function(str, c)
                v:SetText(str)
                if c then v:SetTextColor(c) end
            end,
        }
    end

    function ui:toggle(title, desc, default, cb)
        local r   = self:row(58)
        local key = nid("tg")
        local state = default and true or false
        text(r, title, 16, 8, RW - 100, 20, C.text, 1)
        text(r, desc,  16, 31, RW - 100, 18, C.muted, 0.78)
        local track = box(r, RW - 66, 18, 44, 20, state and C.accent or C.off)
        local knob  = box(track, state and 26 or 2, 2, 16, 16, C.text)

        local function render(v, animate)
            local x0, x1 = v and 2 or 26, v and 26 or 2
            local c0, c1 = v and C.off or C.accent, v and C.accent or C.off
            if not animate then
                knob:SetArea({0, x1}, {0, 2}, {0, 16}, {0, 16}); track:SetBackgroundColor(c1); return
            end
            tween(key, 180, ease.outCubic, function(p)
                knob:SetArea({0, lerp(x0, x1, p)}, {0, 2}, {0, 16}, {0, 16})
                track:SetBackgroundColor(lerpC(c0, c1, p))
            end)
        end

        button(r, "", 0, 0, RW - 2, 56, C.clear, C.text, 1, function()
            state = not state
            render(state, true)
            sound(state and 70 or 0)
            if cb then pcall(cb, state) end
        end)
        return {
            get = function() return state end,
            set = function(v) state = v and true or false; render(state, true) end,
        }
    end

    function ui:stepper(title, desc, min, max, step, default, cb)
        local r, val = self:row(58), default
        text(r, title, 16, 8, RW - 180, 20, C.text, 1)
        text(r, desc,  16, 31, RW - 180, 18, C.muted, 0.78)
        local lbl = text(r, tostring(val), RW - 96, 13, 44, 30, C.text, 1, HorizontalAlignment.Center)
        local function bump(d)
            val = clamp(val + d, min, max)
            lbl:SetText(tostring(val))
            sound(0)
            if cb then pcall(cb, val) end
        end
        local m = button(r, "-", RW - 136, 12, 34, 32, C.off, C.text, 1.1, function() bump(-step) end)
        local p = button(r, "+", RW - 50,  12, 34, 32, C.accent, C.text, 1.1, function() bump(step) end)
        pressFx(m, C.off, C.line); pressFx(p, C.accent, C.accent2)
        return { get = function() return val end }
    end

    function ui:slider(title, desc, min, max, step, default, cb)
        local r   = self:row(76)
        local val = clamp(default, min, max)
        local acc = val
        local TW  = RW - 56
        text(r, title, 16, 8, RW - 190, 20, C.text, 1)
        text(r, desc,  16, 29, RW - 190, 18, C.muted, 0.78)
        local lbl   = text(r, tostring(val), RW - 190, 8, 60, 20, C.accent2, 1, HorizontalAlignment.Right)
        local track = box(r, 28, 58, TW, 6, C.off)
        local fill  = box(track, 0, 0, 0, 6, C.accent)
        local knob  = box(track, 0, -5, 16, 16, C.text)

        local function render()
            local p = (val - min) / math.max(1, max - min)
            fill:SetArea({0, 0}, {0, 0}, {0, p * TW}, {0, 6})
            knob:SetArea({0, p * TW - 8}, {0, -5}, {0, 16}, {0, 16})
            lbl:SetText(tostring(val))
        end
        local function setVal(v)
            v = clamp(math.floor(v / step + 0.5) * step, min, max)
            if v ~= val then val = v; render(); if cb then pcall(cb, val) end end
        end
        render()

        -- drag on the track: move by finger delta (same session logic as the panel header)
        local hit = box(r, 14, 44, TW + 28, 30, C.clear, true)
        local sess = { t = -1, lx = 0 }
        on(hit, GUIEvent.TouchDown, function() sess.t = -1; acc = val end)
        on(hit, GUIEvent.TouchMove, function(args)
            local pos = args and args.position
            if not pos then return end
            local t = now()
            if t - sess.t > 0.3 then sess.lx = pos.x end
            sess.t = t
            acc = clamp(acc + (pos.x - sess.lx) * (max - min) / TW, min, max)
            sess.lx = pos.x
            setVal(acc)
        end)

        local m = button(r, "-", RW - 126, 22, 34, 28, C.off, C.text, 1.1, function() sound(0); setVal(val - step) end)
        local p = button(r, "+", RW - 50,  22, 34, 28, C.accent, C.text, 1.1, function() sound(0); setVal(val + step) end)
        pressFx(m, C.off, C.line); pressFx(p, C.accent, C.accent2)
        return { get = function() return val end }
    end

    function ui:action(title, cb)
        local r = self:row(46)
        local b = button(r, title, 6, 6, RW - 14, 32, C.accent, C.text, 0.95, function()
            sound(4)
            if cb then pcall(cb) end
        end)
        pressFx(b, C.accent, C.accent2)
    end

    function ui:finish()
        holder:SetHeight({0, self.y + 8})
        pane:AddItem(holder)
    end
    return ui
end

----------------------------------------------------------------------
-- tabs
----------------------------------------------------------------------
local function tabY(i) return 16 + (i - 1) * 54 end
local indY = 16

local function selectTab(i, instant)
    if i == S.cur or not NovaMenu.tabs[i] then return end
    local old = S.cur
    S.cur = i

    local fromY, toY = indY, tabY(i)
    tween("ind", instant and FRAME_MS or 240, ease.outCubic, function(p)
        indY = lerp(fromY, toY, p)
        indicator:SetArea({0, 0}, {0, indY}, {0, 3}, {0, 46})
    end)

    for k, t in ipairs(NovaMenu.tabs) do
        t.btn:SetTextColor(k == i and C.text or C.muted)
        t.btn:SetBackgroundColor(k == i and C.tabOn or C.clear)
    end

    if old and NovaMenu.tabs[old] then
        local op = NovaMenu.tabs[old].ui.pane
        stop("pin" .. old)
        tween("pout" .. old, 120, ease.inCubic, function(p) setAlpha(op, 1 - p) end,
            function() op:SetVisible(false) end)
    end
    local np = NovaMenu.tabs[i].ui.pane
    stop("pout" .. i)
    np:SetVisible(true)
    tween("pin" .. i, instant and FRAME_MS or 260, ease.outCubic, function(p)
        setAlpha(np, p)
        np:SetArea({0, 6 + (1 - p) * 18}, {0, 6}, {1, -12}, {1, -12})
    end)
    local t = NovaMenu.tabs[i]
    if t.onShow then pcall(t.onShow) end
end

-- builder(ui) for a normal scrolling page.
-- custom=true: builder(host) gets a plain full-size Layout and must return nothing special.
function NovaMenu.addTab(name, builder, custom)
    local i = #NovaMenu.tabs + 1
    local btn = button(sidebar, "   " .. name, 0, tabY(i), SIDE, 46, C.clear, C.muted, 0.95, function()
        sound(0)
        selectTab(i)
    end)
    pcall(function() btn:SetTextHorzAlign(HorizontalAlignment.Left) end)

    local ui, onShow
    if custom then
        local host = box(content, 6, 6, W - 2 - SIDE - 12, H - 2 - HEAD - 1 - 12, C.clear)
        host:SetArea({0, 6}, {0, 6}, {1, -12}, {1, -12})
        host:SetVisible(false)
        local okb, ret = pcall(builder, host)
        ui = { pane = host }
        if okb and type(ret) == "table" then onShow = ret.onShow end
    else
        ui = newPage()
        ui.pane:SetVisible(false)
        local okb, ret = pcall(builder, ui)
        if okb and type(ret) == "table" then onShow = ret.onShow end
        ui:finish()
    end
    NovaMenu.tabs[i] = { name = name, btn = btn, ui = ui, onShow = onShow }
    if not S.cur then selectTab(i, true) end
    return ui
end

----------------------------------------------------------------------
-- floating button + hud (positions)
----------------------------------------------------------------------
-- all positions are anchored to the screen center ({0.5, offset}) so they stay
-- centered whatever unit scale the engine uses
local function placeFab()
    local s = S.fabSize
    S.fy = math.max(0, S.fy)
    fab:SetArea({0.5, S.fdx - s / 2}, {0, S.fy}, {0, s}, {0, s})
    fabInner:SetArea({0, 3}, {0, 3}, {0, s - 6}, {0, s - 6})
    fabLabel:SetArea({0, 0}, {0, 0}, {0, s - 6}, {0, s - 6})
    pcall(function() fabLabel:SetTextScale(s / 40) end)

    local hy = S.fy + s + 4
    hud.fps:SetArea({0.5, S.fdx - HUD_W / 2}, {0, hy}, {0, HUD_W / 2}, {0, 24})
    hud.ping:SetArea({0.5, S.fdx}, {0, hy}, {0, HUD_W / 2}, {0, 24})
    hud.item:SetArea({0.5, S.fdx - HUD_W / 2}, {0, hy + 24}, {0, HUD_W}, {0, 24})
end

local function setHudVisible(v)
    for _, k in ipairs({ "fps", "ping", "item" }) do hud[k]:SetVisible(v) end
end

local function updateStats()
    local fps, ping, held = readStats()
    if S.hud then
        hud.fps:SetText(string.format("FPS %d", fps));   hud.fps:SetTextColor(fpsColor(fps))
        hud.ping:SetText(string.format("Ping %d", ping)); hud.ping:SetTextColor(pingColor(ping))
        hud.item:SetText(held >= 0 and ("Held item: " .. held) or "Held item: -")
    end
    if S.prog > 0.5 and INFO.fps then
        INFO.fps.set(tostring(fps), fpsColor(fps))
        INFO.ping.set(ping .. " ms", pingColor(ping))
        INFO.held.set(held >= 0 and tostring(held) or "-")
    end
end

----------------------------------------------------------------------
-- open / close (single progress value, safe to spam)
----------------------------------------------------------------------
local function placePanel(off)
    frame:SetArea({0.5, -W / 2 + S.pdx}, {0.5, -H / 2 + S.pdy + (off or 0)}, {0, W}, {0, H})
end

local function applyProg(p)
    S.prog = p
    setAlpha(frame, p)
    placePanel((1 - p) * 24)
    dim:SetBackgroundColor({0, 0, 0, 0.55 * p})
    if fab then fab:SetBackgroundColor(lerpC(C.accent, C.accent2, p)) end   -- border follows state
end

local function refreshProfile()
    if not INFO.name then return end
    local name, id, sex = profile()
    INFO.name:SetText(name)
    INFO.id:SetText("ID " .. id)
    INFO.sex.set(sex == 2 and "Girl" or "Boy")
    pcall(function()
        INFO.aw:SetActor1(sex == 2 and "girl.actor" or "boy.actor", "idle", 105)
        INFO.aw:SetActorByUserId(id, 0)
    end)
end

local function animateTo(target)
    local from = S.prog
    if target == 1 then
        root:SetVisible(true); sound(4); pcall(refreshProfile)
        local ct = NovaMenu.tabs[S.cur or 0]
        if ct and ct.onShow and ct ~= NovaMenu.tabs[1] then pcall(ct.onShow) end
    else
        sound(0)
    end
    local ms = math.max(60, 260 * math.abs(target - from))
    tween("panel", ms, target == 1 and ease.outCubic or ease.inCubic,
        function(p) applyProg(lerp(from, target, p)) end,
        function() if target == 0 then root:SetVisible(false) end end)
end

function NovaMenu.open()   animateTo(1) end
function NovaMenu.close()  animateTo(0) end
function NovaMenu.toggle() animateTo(S.prog < 0.5 and 1 or 0) end
function NovaMenu.isOpen() return S.prog > 0.5 end

----------------------------------------------------------------------
-- floating button build
----------------------------------------------------------------------
local function buildFab(guiRoot)
    -- the button is its own frame: accent border (fab) + dark body (fabInner)
    fab = box(guiRoot, 0, 0, S.fabSize, S.fabSize, C.accent, true)
    fabInner = box(fab, 3, 3, S.fabSize - 6, S.fabSize - 6, C.panel)
    fabLabel = text(fabInner, "N", 0, 0, S.fabSize - 6, S.fabSize - 6, C.text, 1.6, HorizontalAlignment.Center)
    pcall(function() fab:SetLevel(10) end)

    -- hud text under the button
    local function hudText(str)
        local t = text(guiRoot, str, 0, 0, HUD_W, 24, C.text, 0.95, HorizontalAlignment.Center)
        pcall(function() t:SetTextBoader(Color.BLACK) end)
        pcall(function() t:SetLevel(10) end)
        return t
    end
    hud.fps, hud.ping, hud.item = hudText("FPS -"), hudText("Ping -"), hudText("Held item: -")

    -- drag with the finger (same session logic as the panel header), tap = toggle
    local sess = { t = -1, lx = 0, ly = 0, sx = 0, sy = 0, moved = false, lastMove = -10 }
    on(fab, GUIEvent.TouchDown, function() sess.t = -1; sess.moved = false end)
    on(fab, GUIEvent.TouchMove, function(args)
        local pos = args and args.position
        if not pos then return end
        local t = now()
        if t - sess.t > 0.3 then                       -- new touch session
            sess.lx, sess.ly = pos.x, pos.y
            sess.sx, sess.sy = pos.x, pos.y
            sess.moved = false
        end
        sess.t = t
        if not sess.moved and math.abs(pos.x - sess.sx) + math.abs(pos.y - sess.sy) > 8 then
            sess.moved = true
        end
        if sess.moved then
            sess.lastMove = t
            S.fdx = S.fdx + (pos.x - sess.lx)          -- move by finger delta
            S.fy  = S.fy  + (pos.y - sess.ly)
            placeFab(); markDirty()
        end
        sess.lx, sess.ly = pos.x, pos.y
    end)
    on(fab, GUIEvent.Click, function()
        if now() - sess.lastMove < 0.4 then return end  -- a drag is not a tap
        NovaMenu.toggle()
    end)

    homeFab()
    placeFab()

    -- idle pulse on the border (only while closed)
    local t = 0
    LuaTimer:scheduleTimer(function()
        if not S.pulse or S.prog > 0.01 then return end
        t = t + 0.12
        fab:SetBackgroundColor({C.accent[1], C.accent[2], C.accent[3], 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t))})
    end, 50, -1)
end

----------------------------------------------------------------------
-- panel build
----------------------------------------------------------------------
local function buildPanel(guiRoot)
    root = win(GUIType.Layout, "Root", guiRoot)
    root:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    root:SetBackgroundColor(C.clear)
    root:SetTouchable(false)
    root:SetVisible(false)
    pcall(function() root:SetLevel(5) end)

    -- backdrop: swallows touches, optionally closes the menu
    dim = win(GUIType.Layout, "Dim", root)
    dim:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    dim:SetBackgroundColor({0, 0, 0, 0})
    dim:SetTouchable(true)
    on(dim, GUIEvent.Click, function() if S.closeOutside then NovaMenu.close() end end)

    frame = box(root, 0, 0, W, H, C.line, true)                 -- 1px border
    placePanel(0)
    local body = box(frame, 1, 1, W - 2, H - 2, C.bg)

    -- header
    local header = box(body, 0, 0, W - 2, HEAD, C.panel)
    box(body, 0, HEAD, W - 2, 1, C.line)
    box(body, 0, HEAD, 70, 2, C.accent)
    text(header, "NOVA", 18, 3, 140, 28, C.text, 1.2)
    text(header, "menu", 18, 31, 140, 16, C.accent2, 0.7)

    local closeBtn = button(header, "X", W - 2 - 46, 9, 34, 34, C.off, C.text, 0.95, function() NovaMenu.close() end)
    pressFx(closeBtn, C.off, C.danger)

    -- drag zone over the header
    local drag = box(header, 0, 0, W - 2 - 56, HEAD, C.clear, true)
    local lx, ly, lastT = 0, 0, -1
    on(drag, GUIEvent.TouchDown, function() lastT = -1 end)
    on(drag, GUIEvent.TouchMove, function(args)
        local pos = args and args.position
        if not pos then return end
        local t = now()
        if t - lastT > 0.3 then lx, ly = pos.x, pos.y end     -- new drag session
        lastT = t
        S.pdx = S.pdx + (pos.x - lx)                          -- move by finger delta
        S.pdy = S.pdy + (pos.y - ly)
        lx, ly = pos.x, pos.y
        placePanel(0); markDirty()
    end)

    -- sidebar
    sidebar = box(body, 0, HEAD + 1, SIDE, H - 2 - HEAD - 1, C.panel)
    box(sidebar, SIDE - 1, 0, 1, H, C.line)
    indicator = box(sidebar, 0, indY, 3, 46, C.accent)
    local foot = text(sidebar, "nova  v0.9.6", 14, 0, SIDE - 20, 20, C.muted, 0.7)
    foot:SetArea({0, 14}, {1, -26}, {0, SIDE - 20}, {0, 20})

    -- content
    content = box(body, SIDE, HEAD + 1, W - 2 - SIDE, H - 2 - HEAD - 1, C.bg)

    applyProg(0)
end

----------------------------------------------------------------------
-- Info tab: rotating character + profile, live stats, menu options
----------------------------------------------------------------------
local function infoTab(host)
    local PW, PH = W - 2 - SIDE - 12, H - 2 - HEAD - 1 - 12
    local LW = 210

    -- left: character card
    local card  = box(host, 0, 0, LW, PH, C.line)
    local inner = box(card, 1, 1, LW - 2, PH - 2, C.card)
    local stage = box(inner, 6, 6, LW - 14, PH - 90, C.panel)

    INFO.aw = GUIManager:createGUIWindow(GUIType.ActorWindow, nid("Actor"))
    INFO.aw:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    stage:AddChildWindow(INFO.aw)
    pcall(function() INFO.aw:SetActor1("boy.actor", "idle", 105) end)

    INFO.name = text(inner, "Unknown", 8, PH - 80, LW - 18, 26, C.accent2, 1.05, HorizontalAlignment.Center)
    INFO.id   = text(inner, "ID ?",    8, PH - 54, LW - 18, 22, C.muted, 0.8, HorizontalAlignment.Center)

    -- rotation: only while the menu is open and this tab is showing
    local rot = 0
    LuaTimer:scheduleTimer(function()
        if S.prog < 0.5 or S.cur ~= 1 then return end
        rot = (rot + 1.5) % 360
        pcall(function() INFO.aw:SetRotateY(rot) end)
    end, 20, -1)

    -- right: scrolling column
    local RX = LW + 12
    local RW = PW - RX - 28
    local ui = newPage(host, RW, { RX, 0, PW - RX, PH })

    ui:section("profile")
    INFO.sex = ui:kv("Gender", "Boy")
    ui:kv("Game version", gameVersion())
    ui:kv("Menu", "Nova v0.9.6")

    ui:section("live")
    INFO.fps  = ui:kv("FPS", "-")
    INFO.ping = ui:kv("Ping", "-")
    INFO.held = ui:kv("Held item id", "-")

    ui:section("menu")
    ui:toggle("FPS / Ping HUD", "Text under the button", S.hud, function(v) S.hud = v; setHudVisible(v); markDirty() end)
    ui:toggle("Close on outside tap", "Tap the dimmed area to close", S.closeOutside, function(v) S.closeOutside = v; markDirty() end)
    ui:toggle("Idle pulse", "Button border animation", S.pulse, function(v) S.pulse = v; markDirty() end)
    ui:stepper("Button size", "Floating button size", 48, 88, 4, S.fabSize, function(v)
        S.fabSize = v; placeFab(); markDirty()
    end)
    ui:action("Reset positions", function()
        homeFab(); placeFab()
        S.pdx, S.pdy = 0, 0; placePanel(0)
        markDirty()
    end)
    ui:action("Replay intro", function() NovaMenu.playIntro() end)
    ui:finish()
end

----------------------------------------------------------------------
-- GUI tab: scan every window, hide / show, copy, export
----------------------------------------------------------------------
local function wsafe(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end
local function wname(w)
    local n = tostring(wsafe(function() return w:GetName() end, ""))
    if n == "" then n = tostring(wsafe(function() return w:GetText() end, "")) end
    n = n:gsub("[\r\n]+", " ")
    return n ~= "" and n or "<?>"
end
local function wtext(w)
    local t = tostring(wsafe(function() return w:GetText() end, ""))
    t = t:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #t > 40 then t = t:sub(1, 37) .. "..." end
    return t
end
local function wvis(w)   return wsafe(function() return w:IsVisible() end, false) and true or false end
local function wtouch(w) return wsafe(function() return w:IsTouchable() end, false) and true or false end
local function wsize(w)
    local sz = wsafe(function() return w:GetPixelSize() end, nil)
    if sz and sz.x then return string.format("%dx%d", sz.x, sz.y) end
    return "?"
end

local MAX_NODES = 6000
local DUMP_FILES = {
    "/storage/emulated/0/Android/data/com.sandboxol.blockymods/files/nova_gui_dump.txt",
    "nova_gui_dump.txt",
}

local function guiTab(host)
    local PW, PH = W - 2 - SIDE - 12, H - 2 - HEAD - 1 - 12
    local LISTW = PW - 44
    local ROWS, ROW_H = 11, 30
    local LIST_Y = 40
    local G = { tree = nil, flat = {}, open = {}, sel = nil, query = "", visOnly = false,
                top = 1, hidden = {}, total = 0 }
    local rowsW = {}
    local applyFilter, render

    ------------------------------------------------------------ scan
    local function scan()
        local rootW = wsafe(function() return GUISystem.Instance():GetRootWindow() end, nil)
        if not rootW then notify("GUI root not found", "bad"); return end
        local count = 0
        local function build(w, path, depth)
            count = count + 1
            local node = { win = w, path = path, depth = depth, name = wname(w), kids = {} }
            if count < MAX_NODES then
                local c = wsafe(function() return w:GetChildCount() end, 0) or 0
                for i = 0, c - 1 do
                    local ch = wsafe(function() return w:GetChildByIndex(i) end, nil)
                    if ch then
                        local nm = wname(ch)
                        if nm:sub(1, 3) ~= "NV_" then      -- hide the menu's own windows
                            node.kids[#node.kids + 1] = build(ch, path .. "/" .. i .. ":" .. nm, depth + 1)
                        end
                    end
                end
            end
            return node
        end
        G.tree, G.total, G.sel = build(rootW, "root", 0), count, nil
    end

    ------------------------------------------------------------ filter
    local function matches(n, q)
        if q == "" then return true end
        return n.name:lower():find(q, 1, true) ~= nil or wtext(n.win):lower():find(q, 1, true) ~= nil
    end
    local function hasMatch(n, q, memo)
        local m = memo[n]
        if m ~= nil then return m end
        local r = matches(n, q)
        if not r then
            for _, k in ipairs(n.kids) do
                if hasMatch(k, q, memo) then r = true; break end
            end
        end
        memo[n] = r
        return r
    end

    local function flatten()
        local out, memo, q = {}, {}, G.query:lower()
        if not G.tree then return out end
        local function walk(n)
            if n.depth > 0 then
                if q ~= "" and not hasMatch(n, q, memo) then return end
                if G.visOnly and not wvis(n.win) then return end
                out[#out + 1] = n
            end
            if n.depth == 0 or q ~= "" or G.open[n.path] then
                for _, k in ipairs(n.kids) do walk(k) end
            end
        end
        walk(G.tree)
        return out
    end

    ------------------------------------------------------------ export
    local function exportLines()
        local lines = { "# Nova GUI dump  windows scanned: " .. G.total
            .. (G.visOnly and "  (visible only)" or "")
            .. (G.query ~= "" and ("  filter: " .. G.query) or "") }
        local memo, q = {}, G.query:lower()
        if not G.tree then return lines end
        local function walk(n)
            if n.depth > 0 then
                if q ~= "" and not hasMatch(n, q, memo) then return end
                if G.visOnly and not wvis(n.win) then return end
                local t = wtext(n.win)
                lines[#lines + 1] = string.format("%s%s  [vis=%s touch=%s kids=%d size=%s]%s",
                    string.rep("  ", n.depth - 1), n.name, tostring(wvis(n.win)),
                    tostring(wtouch(n.win)), #n.kids, wsize(n.win), t ~= "" and ('  "' .. t .. '"') or "")
            end
            for _, k in ipairs(n.kids) do walk(k) end
        end
        walk(G.tree)
        return lines
    end

    local function doCopy()
        local lines = exportLines()
        local txt = table.concat(lines, "\n")
        local ok = pcall(function() ClientHelper.onSetClipboard(txt) end)
        notify(ok and ("Copied " .. #lines .. " lines") or "Clipboard not available", ok and "ok" or "bad")
    end

    local function doSave()
        local lines = exportLines()
        local txt = table.concat(lines, "\n")
        for _, path in ipairs(DUMP_FILES) do
            local ok = pcall(function()
                local f = io.open(path, "w")
                if not f then error("open failed") end
                f:write(txt); f:close()
            end)
            if ok then notify("Saved " .. #lines .. " lines: " .. path:match("[^/]+$"), "ok"); return end
        end
        notify("Could not write the file", "bad")
    end

    ------------------------------------------------------------ top bar
    text(host, "find", 0, 0, 36, 34, C.muted, 0.85)
    local edit = GUIManager:createGUIWindow(GUIType.Edit, nid("Edit"))
    host:AddChildWindow(edit)
    edit:SetArea({0, 40}, {0, 0}, {0, 214}, {0, 34})
    pcall(function() edit:SetBackgroundColor(C.card) end)
    pcall(function() edit:SetTextColor(C.text) end)
    local function onEdit()
        local q = tostring(wsafe(function() return edit:GetText() end, "") or "")
        if q ~= G.query then G.query, G.top = q, 1; applyFilter() end
    end
    on(edit, GUIEvent.EditTextInput, onEdit)
    on(edit, GUIEvent.WindowLostFocus, onEdit)

    local scanBtn = button(host, "Scan", 262, 0, 64, 34, C.accent, C.text, 0.9, function()
        scan(); G.top = 1; applyFilter(); notify("Scanned " .. G.total .. " windows", "ok")
    end)
    local visBtn
    visBtn = button(host, "All windows", 334, 0, 112, 34, C.off, C.text, 0.85, function()
        G.visOnly = not G.visOnly
        visBtn:SetText(G.visOnly and "Visible only" or "All windows")
        visBtn:SetBackgroundColor(G.visOnly and C.accent or C.off)
        G.top = 1; applyFilter()
    end)
    button(host, "Copy", 454, 0, 64, 34, C.off, C.text, 0.9, doCopy)
    button(host, "Save", 526, 0, 64, 34, C.off, C.text, 0.9, doSave)
    pressFx(scanBtn, C.accent, C.accent2)

    ------------------------------------------------------------ list
    local listFrame = box(host, 0, LIST_Y, LISTW, ROWS * ROW_H, C.card, true)

    local function scrollBy(d)
        G.top = clamp(G.top + d, 1, math.max(1, #G.flat - ROWS + 1))
        render()
    end

    local acc, lastY, lastT, lastScroll = 0, 0, -1, -10
    local function dragMove(args)
        local pos = args and args.position
        if not pos then return end
        local t = now()
        if t - lastT > 0.3 then lastY, acc = pos.y, 0 end
        lastT = t
        acc = acc + (lastY - pos.y)
        lastY = pos.y
        while acc >= ROW_H do scrollBy(1);  acc = acc - ROW_H; lastScroll = t end
        while acc <= -ROW_H do scrollBy(-1); acc = acc + ROW_H; lastScroll = t end
    end
    on(listFrame, GUIEvent.TouchMove, dragMove)

    local function select(node)
        G.sel = node
        render()
    end

    for r = 1, ROWS do
        local y = (r - 1) * ROW_H
        local row = {}
        row.bg    = box(listFrame, 0, y, LISTW, ROW_H - 1, (r % 2 == 0) and C.card or C.panel)
        row.arrow = button(listFrame, "", 0, y, 26, ROW_H - 1, C.clear, C.accent2, 0.9, function()
            local n = row.node
            if n and #n.kids > 0 then G.open[n.path] = not G.open[n.path]; applyFilter() end
        end)
        row.name  = button(listFrame, "", 28, y, LISTW - 28 - 70, ROW_H - 1, C.clear, C.text, 0.85, function()
            if now() - lastScroll < 0.4 then return end
            if row.node then select(row.node) end
        end)
        pcall(function() row.name:SetTextHorzAlign(HorizontalAlignment.Left) end)
        on(row.name, GUIEvent.TouchMove, dragMove)
        row.eye = button(listFrame, "", LISTW - 66, y + 3, 60, ROW_H - 7, C.off, C.text, 0.8, function()
            local n = row.node
            if not n then return end
            local v = wvis(n.win)
            pcall(function() n.win:SetVisible(not v) end)
            if v then G.hidden[n.win] = true else G.hidden[n.win] = nil end
            render()
        end)
        rowsW[r] = row
    end

    -- scroll buttons (always work, even if finger-drag does not)
    local function sbtn(label, y, d)
        local b = button(host, label, LISTW + 4, y, 40, 44, C.off, C.text, 0.9, function() scrollBy(d) end)
        pressFx(b, C.off, C.line)
    end
    sbtn("^^", LIST_Y,        -ROWS)
    sbtn("^",  LIST_Y + 62,   -1)
    sbtn("v",  LIST_Y + 124,  1)
    sbtn("vv", LIST_Y + 186,  ROWS)

    ------------------------------------------------------------ detail bar
    local DY = LIST_Y + ROWS * ROW_H + 6
    local d1 = text(host, "tap a window name to inspect it", 0, DY, 400, 18, C.text, 0.78)
    local d2 = text(host, "", 0, DY + 18, 400, 18, C.muted, 0.75)
    button(host, "Copy name", 406, DY + 2, 92, 32, C.off, C.text, 0.82, function()
        if G.sel then
            local ok = pcall(function() ClientHelper.onSetClipboard(G.sel.name) end)
            notify(ok and ("Copied: " .. G.sel.name) or "Clipboard not available", ok and "ok" or "bad")
        else
            notify("Select a window first")
        end
    end)
    button(host, "Restore", 504, DY + 2, 92, 32, C.accent, C.text, 0.82, function()
        local c = 0
        for w in pairs(G.hidden) do
            pcall(function() w:SetVisible(true) end)
            c = c + 1
        end
        G.hidden = {}
        render()
        notify(c > 0 and ("Restored " .. c .. " windows") or "Nothing hidden", c > 0 and "ok" or nil)
    end)

    ------------------------------------------------------------ render
    render = function()
        for r = 1, ROWS do
            local row, node = rowsW[r], G.flat[G.top + r - 1]
            row.node = node
            local show = node ~= nil
            row.bg:SetVisible(show); row.arrow:SetVisible(show)
            row.name:SetVisible(show); row.eye:SetVisible(show)
            if show then
                local vis = wvis(node.win)
                local label = string.rep("  ", math.min(node.depth - 1, 8)) .. node.name
                if #label > 56 then label = label:sub(1, 53) .. "..." end
                local selected = (G.sel == node)
                row.name:SetText(label)
                row.name:SetTextColor(selected and C.accent2 or (vis and C.text or C.muted))
                row.arrow:SetText(#node.kids > 0 and ((G.open[node.path] or G.query ~= "") and "v" or ">") or "")
                row.eye:SetText(vis and "HIDE" or "SHOW")
                row.eye:SetBackgroundColor(vis and C.off or C.accent)
                row.bg:SetBackgroundColor(selected and C.tabOn or ((r % 2 == 0) and C.card or C.panel))
            end
        end
        local n = #G.flat
        local last = math.min(n, G.top + ROWS - 1)
        d2:SetText(string.format("rows %d-%d of %d   |   scanned %d windows", n > 0 and G.top or 0, last, n, G.total))
        if G.sel then
            local w = G.sel.win
            local t = wtext(w)
            d1:SetText(string.format("%s  vis=%s touch=%s kids=%d size=%s%s", G.sel.name, tostring(wvis(w)),
                tostring(wtouch(w)), #G.sel.kids, wsize(w), t ~= "" and ('  "' .. t .. '"') or ""))
        else
            d1:SetText("tap a window name to inspect it")
        end
    end

    applyFilter = function()
        G.flat = flatten()
        G.top = clamp(G.top, 1, math.max(1, #G.flat - ROWS + 1))
        render()
    end

    return { onShow = function() scan(); applyFilter() end }
end

----------------------------------------------------------------------
-- Tweaks: hide the "bag full" tip popup (display only)
----------------------------------------------------------------------
-- The server sends HostApi.sendCommonTip(player, "bag_full"). The client shows it in the
-- "CommonTip" window (full-screen dim + message). We only hide that window when its
-- message text looks like the bag-full text. Nothing is sent to the server.
local TIP = { last = "", hidden = 0 }

local function tipIsBagFull(txt)
    local t = txt:lower()
    if t == "" then return false end
    if t:find("bag_full", 1, true) then return true end
    if t:find("едостаточно места", 1, true) then return true end   -- ru: bag_full = "Недостаточно места"
    if t:find("full", 1, true) and (t:find("bag", 1, true) or t:find("backpack", 1, true)
        or t:find("inventory", 1, true)) then return true end
    if t:find("полн", 1, true) and (t:find("юкзак", 1, true) or t:find("нвентар", 1, true)
        or t:find("умк", 1, true)) then return true end
    for item in tostring(S.learned or ""):gmatch("[^|]+") do
        if t == item then return true end
    end
    return false
end

local function findNamed(w, name, depth)
    if not w then return nil end
    if wname(w) == name then return w end
    if (depth or 0) >= 4 then return nil end
    local c = wsafe(function() return w:GetChildCount() end, 0) or 0
    for i = 0, c - 1 do
        local ch = wsafe(function() return w:GetChildByIndex(i) end, nil)
        local r = findNamed(ch, name, (depth or 0) + 1)
        if r then return r end
    end
    return nil
end

-- Windows that can show the bag-full text: the small "CommonTip" popup and the
-- wooden "TipDialog" (title "Подсказка", Cancel / OK) seen in the screenshot.
local GUARDED = { "CommonTip", "TipDialog" }

-- text of every visible "...Message" label inside a dialog (variant panels that are
-- hidden are skipped, so stale text from another skin does not count)
local function collectMessage(root)
    local parts = {}
    local function walk(w, d)
        if d > 6 or not wvis(w) then return end
        if wname(w):sub(-7) == "Message" then
            local t = tostring(wsafe(function() return w:GetText() end, ""))
            if t ~= "" then parts[#parts + 1] = t end
        end
        local c = wsafe(function() return w:GetChildCount() end, 0) or 0
        for i = 0, c - 1 do
            local ch = wsafe(function() return w:GetChildByIndex(i) end, nil)
            if ch then walk(ch, d + 1) end
        end
    end
    walk(root, 0)
    return table.concat(parts, " ")
end

-- Why it flickered: the server re-sends the tip over and over, the game shows the
-- dialog again each time, and hiding it a tick later is visible. So a matching dialog is
-- "parked": moved off screen and made transparent, then hidden. When the game shows it
-- again it appears off screen, so there is nothing to see and nothing to block taps.
-- Any other tip that appears is moved back (unparked) on the next check.
local function startTipGuard()
    local cache, parked, tick = {}, {}, 0
    TIP.found = {}

    local function park(w, name)
        pcall(function() w:SetArea({8, 0}, {8, 0}, {1, 0}, {1, 0}) end)
        setAlpha(w, 0)
        pcall(function() w:SetVisible(false) end)
        parked[name] = true
    end
    local function unpark(w, name)
        pcall(function() w:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0}) end)
        setAlpha(w, 1)
        parked[name] = nil
    end

    LuaTimer:scheduleTimer(function()
        tick = tick + 1
        for _, name in ipairs(GUARDED) do
            local w = cache[name]
            if not w then
                w = wsafe(function() return GUIManager:getWindowByName(name) end, nil)
                if not w and tick % 30 == 0 then          -- slow fallback: look through the tree
                    local rootW = wsafe(function() return GUISystem.Instance():GetRootWindow() end, nil)
                    w = findNamed(rootW, name, 0)
                end
                if w then cache[name] = w; TIP.found[name] = true end
            end
            if w then
                if parked[name] and not S.hideBagFull then
                    unpark(w, name)                       -- feature switched off: give it back
                elseif wvis(w) then
                    local txt = collectMessage(w)
                    if txt ~= "" then TIP.last = txt end
                    if S.hideBagFull and tipIsBagFull(txt) then
                        park(w, name)
                        TIP.hidden = TIP.hidden + 1
                    elseif parked[name] and txt ~= "" then
                        unpark(w, name)                   -- a different tip: show it normally
                    end
                end
            end
        end
    end, 16, -1)
end

local function tweaksTab(ui)
    ui:section("tips")
    ui:toggle("Hide 'bag full' tip", "Skip the popup when your bag is full", S.hideBagFull, function(v)
        S.hideBagFull = v; markDirty()
    end)
    ui:info("Only the popup is hidden. The game still cannot pick up items while the bag is full.")
    local seen  = ui:kv("Last tip text", "-")
    local count = ui:kv("Hidden this session", "0")
    local found = ui:kv("Dialog windows found", "-")
    ui:action("Always hide the last tip text", function()
        if TIP.last == "" then notify("No tip seen yet"); return end
        local t = TIP.last:lower()
        if not (("|" .. S.learned .. "|"):find("|" .. t .. "|", 1, true)) then
            S.learned = (S.learned == "") and t or (S.learned .. "|" .. t)
            markDirty()
        end
        notify("Will hide: " .. (#TIP.last > 30 and TIP.last:sub(1, 27) .. "..." or TIP.last), "ok")
    end)
    ui:action("Forget learned texts", function()
        S.learned = ""; markDirty(); notify("Learned texts cleared", "ok")
    end)
    return { onShow = function()
        local t = TIP.last
        seen.set(t == "" and "-" or (#t > 34 and t:sub(1, 31) .. "..." or t))
        count.set(tostring(TIP.hidden))
        local f = {}
        for _, n in ipairs(GUARDED) do f[#f + 1] = n .. (TIP.found and TIP.found[n] and ": yes" or ": no") end
        found.set(table.concat(f, "  "))
    end }
end

----------------------------------------------------------------------
-- crystals: chest auto-take + floor collector (tab "Crystals")
-- Engine calls that are not confirmed live in ONE place (the ADAPT section) and are
-- resolved at runtime from candidate names. The Probe button dumps what the engine
-- really exposes, so the two "not wired" calls can be hard-coded after one test run.
----------------------------------------------------------------------
local CR = {
    ITEM = 3459, CHEST_BLOCK = 54,
    chestOpen = false, ev = {},
    scanned = 0, inRadius = 0, visits = 0, takes = 0, picked = 0, fp = "EntityActorNpc|generic|generic|1.00|0.70", clickVia = nil,
    listSrc = "-", visited = {}, busy = false, ticks = 0, warnedTake = false,
}

-- ---------- ADAPT: runtime-resolved engine access ----------
local function callAny(obj, names, ...)             -- first candidate method that answers
    if obj == nil then return nil end
    for _, n in ipairs(names) do
        local okf, fn = pcall(function() return obj[n] end)
        if okf and type(fn) == "function" then
            local okc, r = pcall(fn, obj, ...)
            if okc and r ~= nil then return r, n end
        end
    end
    return nil
end

local function getWorld()
    local w
    pcall(function() w = Blockman.Instance():getWorld() end)
    if not w then pcall(function() w = EngineWorld.getWorld() end) end
    return w
end

local LIST_CALLS  = { "getLoadedEntityMap", "getLoadedEntityList", "getEntityList", "getAllEntities", "getEntities" }
local LIST_FIELDS = { "loadedEntityList", "entityList", "m_entityList", "entities" }
local function entityList()
    local w = getWorld()
    if not w then return nil end
    for _, n in ipairs(LIST_CALLS) do
        local ok, r = pcall(function() return w[n](w) end)
        if ok and type(r) == "table" then CR.listSrc = n .. "()"; return r end
    end
    for _, n in ipairs(LIST_FIELDS) do
        local ok, r = pcall(function() return w[n] end)
        if ok and type(r) == "table" then CR.listSrc = n; return r end
    end
    return nil
end

local ID_MAX = 3000
local idCache = { t = -10, list = {} }
local function entityListByIds()                    -- getLoadedEntityMap() is opaque; walk ids instead
    if now() - idCache.t < 1 then return idCache.list end
    local out = {}
    for id = 1, ID_MAX do
        local e
        pcall(function() e = EngineWorld:getEntity(id) end)
        if e ~= nil then out[id] = e end
    end
    idCache.t, idCache.list = now(), out
    CR.listSrc = "EngineWorld:getEntity(1.." .. ID_MAX .. ")"
    return out
end

local function numField(o, names)
    for _, n in ipairs(names) do
        local ok, v = pcall(function() return o[n] end)
        if ok and type(v) == "number" then return v end
    end
end

local function itemIdOf(e)                          -- id of a dropped-item entity, or nil
    local id = callAny(e, { "getItemId", "getItemID" })
    if type(id) == "number" then return id end
    local stack = callAny(e, { "getEntityItem", "getItemStack", "getItem" })
    if stack ~= nil then
        id = callAny(stack, { "getItemId", "getItemID" })
        if type(id) == "number" then return id end
        id = numField(stack, { "itemID", "itemId", "id" })
        if id then return id end
    end
    return numField(e, { "itemId", "itemID" })
end

local function posOf(e)
    local p
    pcall(function() p = e:getPosition() end)
    if not p then pcall(function() p = e:getPosition(0) end) end
    return p
end

-- UNCONFIRMED call 1: pull one stack out of the open chest. Fill in from the probe dump.
local function takeStack(inv, slot)
    return false
end

-- dropped items are plain "Entity" objects, so the crystal is recognised by a learned fingerprint
local function fingerprint(e)
    local c = callAny(e, { "getClassName" })
    local n = callAny(e, { "getEntityName" })
    local t = callAny(e, { "getTranslatedEntityName" })
    local w = callAny(e, { "getWidth" })
    local h = callAny(e, { "getHeight" })
    return ("%s|%s|%s|%.2f|%.2f"):format(tostring(c), tostring(n), tostring(t), tonumber(w) or 0, tonumber(h) or 0)
end

local atan2 = math.atan2 or math.atan
local function faceTo(pos)                          -- turn the player toward a point (yaw/pitch, MC convention)
    local me = PlayerManager:getClientPlayer()
    if not me or not me.Player then return end
    local mp; pcall(function() mp = me.Player:getPosition() end)
    if not mp then return end
    local dx, dy, dz = pos.x - mp.x, pos.y - mp.y, pos.z - mp.z
    local yaw = math.deg(atan2(-dx, dz))
    local pitch = -math.deg(atan2(dy, math.sqrt(dx * dx + dz * dz)))
    pcall(function() me.Player:setPositionAndRotation(mp.x, mp.y, mp.z, yaw, pitch) end)
    pcall(function() me.Player.rotationYaw = yaw; me.Player.rotationPitch = pitch end)
    pcall(function() me.Player:setRotationYawHead(yaw) end)
end

-- Click call (EXPERIMENTAL): the recording shows a scene click ~2 blocks from a dropped item picks it up.
local function clickItem(entry)
    local me = PlayerManager:getClientPlayer()
    local mp; if me and me.Player then pcall(function() mp = me.Player:getPosition() end) end
    if not mp or not entry or not entry.pos then return false end
    local dx, dy, dz = entry.pos.x - mp.x, entry.pos.y + 0.35 - mp.y, entry.pos.z - mp.z
    local len = math.max(0.01, math.sqrt(dx * dx + dy * dy + dz * dz))
    local k = 12 / len
    local from = { x = mp.x, y = mp.y, z = mp.z }
    local to   = { x = mp.x + dx * k, y = mp.y + dy * k, z = mp.z + dz * k }
    local fired = false
    local ev = CEvents and CEvents.ClickSceneEvent
    if ev then
        for _, m in ipairs({ "invoke", "fire", "trigger", "dispatch", "emit" }) do
            if pcall(function() ev[m](ev, from, to) end) then fired = true; CR.clickVia = "event:" .. m; break end
        end
    end
    if pcall(function() Blockman.Instance():tryClickSceneCentre() end) and not fired then CR.clickVia = "centre click" end
    return fired
end

-- ---------- chest ----------
local function chestWindow()
    local w
    pcall(function() w = GUIManager:getWindowByName("Chest-Content-Chest") end)
    return w
end

local function isChestOpen()                        -- IsVisible() stays true even when closed
    local w = chestWindow()
    if not w then return false end
    local v
    local ok = pcall(function() v = w:IsVisibleInScreen() end)
    if not ok or type(v) ~= "boolean" then pcall(function() v = w:IsVisible() end) end
    return v == true
end

pcall(function()                                    -- same event the server listener uses
    BaseListener.registerCallBack(CEvents.ChestOpenEvent, function(a, b, c)
        CR.ev = { a, b, c }
    end)
end)

CR.evs, CR.reg = {}, {}
local function onEv(evName, a, b, c, d)
    local old = CR.evs[evName]
    CR.evs[evName] = { a, b, c, d, n = (old and old.n or 0) + 1 }
    if evName == "ChestOpenSpHandleEvent" then CR.ev = { a, b, c, d } end
end
for _, evName in ipairs({ "ChestOpenSpHandleEvent", "EntityItemSpawnEvent", "InventoryStackChange", "InventoryItemStackChangedEvent" }) do
    local okA = pcall(function()
        BaseListener.registerCallBack(CEvents[evName], function(a, b, c, d) onEv(evName, a, b, c, d) end)
    end)
    local okB = pcall(function()
        CEvents[evName]:registerCallBack(function(a, b, c, d) onEv(evName, a, b, c, d) end)
    end)
    CR.reg[#CR.reg + 1] = ("%s base=%s direct=%s"):format(evName, tostring(okA), tostring(okB))
end

local function bagCount()                           -- how many crystals are in the bag right now
    local me = PlayerManager:getClientPlayer()
    if not me then return nil end
    return (callAny(me, { "getItemNumById" }, CR.ITEM))
end

local function chestInventory()
    for _, a in ipairs(CR.ev) do
        if callAny(a, { "getSizeInventory", "getSize", "getSlotCount" }) ~= nil then return a end
    end
    return nil
end

local function chestTick()
    local inv = chestInventory()
    if not inv then return end
    local size = callAny(inv, { "getSizeInventory", "getSize", "getSlotCount" }) or 0
    for slot = 0, size - 1 do
        local st = callAny(inv, { "getStackInSlot", "getItemStack", "getItem" }, slot)
        if st ~= nil then
            local id = callAny(st, { "getItemId", "getItemID" }) or numField(st, { "itemID", "itemId", "id" })
            if id == CR.ITEM then
                if takeStack(inv, slot) then
                    CR.takes = CR.takes + 1
                elseif not CR.warnedTake then
                    CR.warnedTake = true
                    notify("Crystal found in chest, but take call is not wired yet. Run Probe.", "bad")
                end
                return                                  -- one stack per tick
            end
        end
    end
end

-- ---------- floor ----------
local function scanFloor()
    local me = PlayerManager:getClientPlayer()
    if not me or not me.Player then return {} end
    local mp = me.Player:getPosition()
    local list = entityListByIds()
    if next(list) == nil then list = entityList() or {} end
    local out, n, hit = {}, 0, 0
    if list and mp then
        for _, e in pairs(list) do
            n = n + 1
            if e ~= me.Player and ((CR.fp and fingerprint(e) == CR.fp) or itemIdOf(e) == CR.ITEM) then
                local p = posOf(e)
                if p then
                    local dx, dy, dz = p.x - mp.x, p.y - mp.y, p.z - mp.z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= S.radius then
                        hit = hit + 1
                        out[#out + 1] = { e = e, pos = p, d = d, key = tostring(e.entityId or e) }
                    end
                end
            end
        end
    end
    CR.scanned, CR.inRadius = n, hit
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function moveTo(pos, done)
    if type(_G.Teleport) == "function" then             -- use the existing helper when it is loaded
        pcall(_G.Teleport, VectorUtil.newVector3(pos.x, pos.y, pos.z))
        LuaTimer:schedule(done, 1600)
        return
    end
    local me = PlayerManager:getClientPlayer()
    if not me or not me.Player then done(); return end
    local sp = me.Player:getPosition()
    if not sp then done(); return end
    local dx, dy, dz = pos.x - sp.x, pos.y - sp.y, pos.z - sp.z
    local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz) / 4))
    local i, id = 0, nil
    id = LuaTimer:scheduleTimer(function()
        i = i + 1
        local t = math.min(1, i / steps)
        local q = PlayerManager:getClientPlayer()
        if not q or not q.Player then LuaTimer:cancel(id); return end
        pcall(function()
            q.Player:setPosition(VectorUtil.newVector3(sp.x + dx * t, sp.y + dy * t, sp.z + dz * t))
        end)
        if i >= steps then LuaTimer:cancel(id); LuaTimer:schedule(done, 150) end
    end, 40, -1)
end

local function standoff(pos)                        -- stop ~1.5 blocks short of the item, at eye height
    local me = PlayerManager:getClientPlayer()
    local mp; if me and me.Player then pcall(function() mp = me.Player:getPosition() end) end
    if not mp then return pos end
    local dx, dz = pos.x - mp.x, pos.z - mp.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 2 then return mp end
    local k = (len - 1.5) / len
    return { x = mp.x + dx * k, y = pos.y + 1.6, z = mp.z + dz * k }
end

local function learnCrystal()                       -- fingerprint of the nearest entity within 6 blocks
    local me = PlayerManager:getClientPlayer()
    if not me or not me.Player then notify("Learn: no player", "bad"); return end
    local mp; pcall(function() mp = me.Player:getPosition() end)
    if not mp then return end
    idCache.t = -10
    local best, bd
    for _, e in pairs(entityListByIds()) do
        if e ~= me.Player then
            local p = posOf(e)
            if p then
                local d = math.sqrt((p.x - mp.x) ^ 2 + (p.y - mp.y) ^ 2 + (p.z - mp.z) ^ 2)
                if d < 6 and (not bd or d < bd) then best, bd = e, d end
            end
        end
    end
    if not best then notify("Learn: nothing within 6 blocks", "bad"); return end
    CR.fp = fingerprint(best)
    notify("Learned: " .. CR.fp:sub(1, 40), "ok")
end

local function floorTick()
    if CR.busy then return end
    local list = scanFloor()
    local target
    for _, c in ipairs(list) do
        if (CR.visited[c.key] or 0) < now() then target = c; break end
    end
    if not target then return end
    CR.busy = true
    CR.visited[target.key] = now() + 10                 -- skip it for 10 s if it is still there
    local before = bagCount()
    moveTo(standoff(target.pos), function()
        LuaTimer:schedule(function()
            pcall(faceTo, target.pos)
            LuaTimer:schedule(function()
                pcall(clickItem, target)
                CR.visits = CR.visits + 1
                LuaTimer:schedule(function()            -- success = crystals in the bag went up
                    local after = bagCount()
                    if before and after and after > before then CR.picked = CR.picked + (after - before) end
                    CR.busy = false
                end, 700)
            end, 150)
        end, 200)
    end)
end

-- ---------- probe ----------
local function namesOf(o)
    local seen, out, visited = {}, {}, {}
    local function add(t)
        for k in pairs(t) do
            local n = tostring(k)
            if not seen[n] then seen[n] = true; out[#out + 1] = n end
        end
    end
    local function walk(t, depth)
        if type(t) ~= "table" or visited[t] or depth > 6 then return end
        visited[t] = true
        pcall(add, t)
        for _, pk in ipairs({ "__parent0", "__parent1", "__parent2" }) do
            local ok, par = pcall(function() return t[pk] end)
            if ok then walk(par, depth + 1) end
        end
        local mt = getmetatable(t)
        if type(mt) == "table" then
            walk(mt, depth + 1)
            if type(mt.__index) == "table" then walk(mt.__index, depth + 1) end
        end
    end
    pcall(function()
        if type(o) == "table" then walk(o, 0) end
        local mt = getmetatable(o)
        if type(mt) == "table" then walk(mt, 0) end
    end)
    table.sort(out)
    return out
end

local HINTS = { "take", "move", "click", "pick", "transfer", "slot", "swap", "drop", "quick", "shift", "container", "stack", "collect", "item", "position", "pos" }
local function dumpObj(L, label, o)
    L[#L + 1] = ("== %s (%s)"):format(label, type(o))
    if o == nil then return end
    local n = namesOf(o)
    L[#L + 1] = #n > 0 and table.concat(n, ", ") or "(no names reachable)"
    local h = {}
    for _, name in ipairs(n) do
        local low = name:lower()
        for _, k in ipairs(HINTS) do
            if low:find(k, 1, true) then h[#h + 1] = name; break end
        end
    end
    if #h > 0 then L[#L + 1] = "  >> hints: " .. table.concat(h, ", ") end
end

local function winInfo(w)
    local nm, ty, vis, cnt, txt, ud = "?", "?", "?", 0, "", ""
    pcall(function() nm = tostring(w:GetName()) end)
    pcall(function() ty = tostring(w:GetWindowType()) end)
    pcall(function() vis = tostring(w:IsVisible()) end)
    pcall(function() cnt = w:GetChildCount() end)
    pcall(function() txt = tostring(w:GetText()) end)
    pcall(function() ud = tostring(w:GetUserData()) end)
    local ev = ""
    pcall(function()
        local l = w:GetLuaEventList()
        if type(l) == "table" then
            local t = {}
            for k in pairs(l) do t[#t + 1] = tostring(k) end
            ev = table.concat(t, "/")
        end
    end)
    return ("%s [%s] vis=%s kids=%s text=%s ev=%s ud=%s"):format(nm, ty, vis, tostring(cnt), txt:sub(1, 24), ev, ud:sub(1, 24))
end

local function dumpTree(L, w, depth, budget)
    if depth > 4 or budget.n <= 0 then return end
    local cnt = 0
    pcall(function() cnt = w:GetChildCount() end)
    for i = 0, math.min(cnt, 12) - 1 do
        local c
        pcall(function() c = w:GetChildByIndex(i) end)
        if c and budget.n > 0 then
            budget.n = budget.n - 1
            L[#L + 1] = string.rep("  ", depth) .. winInfo(c)
            if not budget.first then budget.first = c end
            dumpTree(L, c, depth + 1, budget)
        end
    end
end

local function entitySamples(L)
    local map = entityListByIds()
    local total, classes, shown = 0, {}, 0
    for k, e in pairs(map) do
        total = total + 1
        local cls = "?"
        pcall(function() cls = tostring((getmetatable(e) or {}).__name or type(e)) end)
        local iid = itemIdOf(e)
        local key = cls .. (iid and ("#item" .. tostring(iid)) or "")
        if not classes[key] and shown < 8 then
            classes[key] = true; shown = shown + 1
            local pos = posOf(e)
            L[#L + 1] = ("-- sample id=%s class=%s pos=%s itemId=%s"):format(
                tostring(k), cls, pos and ("%.1f,%.1f,%.1f"):format(pos.x, pos.y, pos.z) or "-", tostring(iid))
            dumpObj(L, "entity class " .. cls, e)
        end
    end
    L[#L + 1] = "== entities found by id walk 1.." .. ID_MAX .. ": " .. total
end

local function probeExtras(L)
    L[#L + 1] = "== event registration"
    for _, r in ipairs(CR.reg) do L[#L + 1] = r end

    local w = getWorld()
    local map; if w then pcall(function() map = w:getLoadedEntityMap() end) end
    dumpObj(L, "entity map object", map)

    -- what ScrollableInventory adds on top of a plain window
    local cw = chestWindow()
    local gen; pcall(function() gen = GUIManager:createGUIWindow(GUIType.Layout, nid("PG")) end)
    if cw then
        local base = {}
        if gen then for _, n in ipairs(namesOf(gen)) do base[n] = true end end
        local extra = {}
        for _, n in ipairs(namesOf(cw)) do if not base[n] then extra[#extra + 1] = n end end
        L[#L + 1] = "== chest window extra methods (vs plain Layout): " .. (#extra > 0 and table.concat(extra, ", ") or "-")
    end

    -- globals and singletons that look relevant
    local gl = {}
    pcall(function()
        for k, v in pairs(_G) do
            local n = tostring(k):lower()
            for _, h in ipairs({ "chest", "inventory", "slot", "pickup", "loot", "container", "packet", "drop" }) do
                if n:find(h, 1, true) then gl[#gl + 1] = tostring(k) .. ":" .. type(v); break end
            end
        end
    end)
    table.sort(gl)
    L[#L + 1] = "== globals (chest/inventory/slot/pickup/loot/container/packet/drop): " .. (#gl > 0 and table.concat(gl, ", ") or "-")
    local bm; pcall(function() bm = Blockman.Instance() end)
    dumpObj(L, "Blockman.Instance()", bm)
    dumpObj(L, "ClientHelper", ClientHelper)
    dumpObj(L, "EngineWorld", EngineWorld)
    dumpObj(L, "HostApi", HostApi)

    -- read-only experiments on the bag inventory
    local pl; pcall(function() pl = PlayerManager:getClientPlayer() end)
    local inv = pl and callAny(pl, { "getInventory" })
    if inv then
        L[#L + 1] = "== bag inventory: size=" .. tostring(callAny(inv, { "getSizeInventory" }))
            .. " hasItem(" .. CR.ITEM .. ")=" .. tostring(callAny(inv, { "hasItem" }, CR.ITEM))
            .. " slotContain=" .. tostring(callAny(inv, { "getInventorySlotContainItem" }, CR.ITEM))
        for i = 0, 8 do
            local st = callAny(inv, { "getStackInSlot" }, i)
            if st ~= nil then dumpObj(L, "ItemStack object (bag slot " .. i .. ")", st); break end
        end
    end

    -- find a chest block next to the player and read its tile entity
    local me = pl and pl.Player
    local mp; if me then pcall(function() mp = me:getPosition() end) end
    if mp and w then
        local cx, cy, cz = math.floor(mp.x), math.floor(mp.y), math.floor(mp.z)
        local found
        for x = -6, 6 do
            for y = -3, 3 do
                for z = -6, 6 do
                    if not found then
                        local ok, id = pcall(function() return EngineWorld:getBlockId(VectorUtil.newVector3(cx + x, cy + y, cz + z)) end)
                        if ok and id == CR.CHEST_BLOCK then found = { cx + x, cy + y, cz + z } end
                    end
                end
            end
        end
        if not found then
            L[#L + 1] = "== chest block (54) within 6 blocks: none"
        else
            L[#L + 1] = ("== chest block (54) at %d,%d,%d"):format(found[1], found[2], found[3])
            local te
            pcall(function() te = w:getBlockTileEntity(VectorUtil.newVector3(found[1], found[2], found[3])) end)
            if te == nil then pcall(function() te = w:getBlockTileEntity(found[1], found[2], found[3]) end) end
            dumpObj(L, "tile entity", te)
            local sz = te and callAny(te, { "getSizeInventory" })
            L[#L + 1] = "tile entity size: " .. tostring(sz)
            local shown = 0
            for i = 0, (sz or 0) - 1 do
                local st = callAny(te, { "getStackInSlot" }, i)
                if st ~= nil then
                    local id = callAny(st, { "getItemId", "getItemID" }) or numField(st, { "itemID", "itemId", "id" })
                    local n  = callAny(st, { "getStackSize" }) or numField(st, { "stackSize", "count", "num" })
                    L[#L + 1] = ("  slot %d: id=%s count=%s"):format(i, tostring(id), tostring(n))
                    shown = shown + 1
                    if shown >= 12 then break end
                end
            end
        end
    end
end


local GTABLES = { "ContainerChest", "Container", "GuiScrollableInventory", "GuiItemSlot", "Slot", "BoundSlot",
    "GuiSlotTable", "ClientPacketSender", "InventoryLargeChest", "InventoryProxy", "InventoryPlayer",
    "gui_playerInventoryControl", "TileEntityChest", "GUIScrolledContainer", "PacketSender" }
local function keysOf(t)
    local out = {}
    for k, v in pairs(t) do
        local tv, str = type(v), tostring(k)
        if tv == "function" then
            local ok, info = pcall(function() return debug.getinfo(v, "u") end)
            str = str .. ((ok and info and info.nparams) and ("(" .. tostring(info.nparams) .. ")") or "()")
        elseif tv == "table" then
            local sub, c = {}, 0
            for k2 in pairs(v) do c = c + 1; if c <= 8 then sub[#sub + 1] = tostring(k2) end end
            str = str .. "{" .. table.concat(sub, ",") .. (c > 8 and ",..." or "") .. "}"
        else
            str = str .. ":" .. tv
        end
        out[#out + 1] = str
    end
    table.sort(out)
    return out
end
local function dumpGlobalTables(L)
    for _, name in ipairs(GTABLES) do
        local t = _G[name]
        if type(t) == "table" then
            L[#L + 1] = "== table " .. name .. ": " .. table.concat(keysOf(t), ", ")
            local mt = getmetatable(t)
            if type(mt) == "table" and type(mt.__index) == "table" and mt.__index ~= t then
                L[#L + 1] = "   inherited: " .. table.concat(keysOf(mt.__index), ", ")
            end
        else
            L[#L + 1] = "== table " .. name .. ": " .. type(t)
        end
    end
    local g2 = {}
    pcall(function()
        for k, v in pairs(_G) do
            local n = tostring(k):lower()
            for _, h in ipairs({ "aabb", "entityitem", "itementity", "dropitem", "itemstack", "playercontrol", "controller" }) do
                if n:find(h, 1, true) then g2[#g2 + 1] = tostring(k) .. ":" .. type(v); break end
            end
        end
    end)
    table.sort(g2)
    L[#L + 1] = "== more globals: " .. (#g2 > 0 and table.concat(g2, ", ") or "-")
end

local function runProbe()
    local L = { "nova crystals probe v4 | chest open: " .. tostring(isChestOpen()) .. " | list source: " .. CR.listSrc }
    local p; pcall(function() p = PlayerManager:getClientPlayer() end)
    L[#L + 1] = "crystals in bag (getItemNumById " .. CR.ITEM .. "): " .. tostring(bagCount())

    L[#L + 1] = "== events seen"
    for name, d in pairs(CR.evs) do
        L[#L + 1] = ("%s x%s  args: %s, %s, %s, %s"):format(name, tostring(d.n), type(d[1]), type(d[2]), type(d[3]), type(d[4]))
    end
    for name, d in pairs(CR.evs) do
        for i = 1, 4 do
            if type(d[i]) == "userdata" or type(d[i]) == "table" then dumpObj(L, name .. " arg " .. i, d[i]) end
        end
    end

    local cw = chestWindow()
    L[#L + 1] = "== chest window: " .. (cw and winInfo(cw) or "nil")
    local budget = { n = 60 }
    if cw then dumpTree(L, cw, 1, budget) end
    if budget.first then dumpObj(L, "first chest child", budget.first) end
    local iw; pcall(function() iw = GUIManager:getWindowByName("Chest-Content-Inventory") end)
    L[#L + 1] = "== bag window: " .. (iw and winInfo(iw) or "nil")
    local b2 = { n = 20 }
    if iw then dumpTree(L, iw, 1, b2) end

    if p then
        dumpObj(L, "player.getInventory()", callAny(p, { "getInventory" }))
        dumpObj(L, "client player.Player", p.Player)
    end
    entitySamples(L)
    probeExtras(L)
    dumpGlobalTables(L)

    local ev = {}
    pcall(function()
        for k in pairs(CEvents) do
            local s2 = tostring(k):lower()
            if s2:find("chest") or s2:find("inventory") or s2:find("item") or s2:find("pick") or s2:find("slot") then ev[#ev + 1] = tostring(k) end
        end
    end)
    table.sort(ev)
    L[#L + 1] = "== CEvents: " .. (#ev > 0 and table.concat(ev, ", ") or "-")

    local data, path = table.concat(L, "\n"), nil
    for _, pth in ipairs(pathsFor("nova_probe.txt")) do
        local ok = pcall(function()
            local f = io.open(pth, "w")
            if not f then error("open failed") end
            f:write(data); f:close()
        end)
        if ok then path = pth; break end
    end
    if path then
        local short = path:gsub("^/storage/emulated/0/Android/data/", "")
        notify("Probe saved: " .. short, "ok")
        print("[Nova] probe saved to " .. path)
    else
        notify("Probe: could not write file, dump is in the log", "bad")
        print("[Nova] probe dump (no writable path):\n" .. data)
    end
end

-- ---------- recorder: the "video" probe ----------
-- Records while you play by hand: game events, calls into the Lua container/packet classes,
-- chest open/close, bag slot changes, crystal count, entities appearing/disappearing.
-- Output: nova_rec.txt (flushed every 2 s). Everything is pcall-guarded and removed on stop.
local REC = {
    on = false, buf = {}, path = nil, shortPath = "-", lines = 0, rate = {}, wl = {},
    prevSlots = {}, prevBag = nil, prevOpen = false, ents = {}, itemEnts = {}, entsInit = false,
    seenClass = {}, evReg = false, timer = nil, n = 0,
}

local function ser(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return '"' .. v:sub(1, 40) .. '"' end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t == "table" then
        if getmetatable(v) then return "<obj>" end
        if depth >= 3 then return "{..}" end
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts + 1] = "..."; break end
            parts[#parts + 1] = tostring(k) .. "=" .. ser(x, depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if t == "userdata" then
        local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return ("vec(%.1f,%.1f,%.1f)"):format(x, y, z)
        end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

local function rec(msg)
    if not REC.on then return end
    REC.lines = REC.lines + 1
    REC.buf[#REC.buf + 1] = ("[%.2f] %s"):format(now(), msg)
    while #REC.buf > 3000 do table.remove(REC.buf, 1) end
end

local function allow(key, perSec)                   -- per-key rate limit, suppressed counts are logged
    local t = now()
    local b = REC.rate[key]
    if not b or t - b.t >= 1 then
        if b and b.sup > 0 then rec(("(%s suppressed %d)"):format(key, b.sup)) end
        b = { t = t, n = 0, sup = 0 }
        REC.rate[key] = b
    end
    b.n = b.n + 1
    if b.n > perSec then b.sup = b.sup + 1; return false end
    return true
end

local function classOf(e)
    local c = "?"
    pcall(function() c = tostring((getmetatable(e) or {}).__name or type(e)) end)
    return c
end

local function isNoise(name, allowCtor)
    local n = name:lower()
    if allowCtor and (n == "new" or n == "ctor" or n == "init") then return false end
    return n:find("update", 1, true) or n:find("tick", 1, true) or n:find("render", 1, true)
        or n:find("draw", 1, true) or n:sub(1, 2) == "__" or n == "new" or n == "ctor" or n == "class"
end

local function wrapTable(label, t, filter, allowCtor)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for k, f in pairs(t) do
        if type(k) == "string" and type(f) == "function" and not (filter and not filter(k)) and not (not filter and isNoise(k, allowCtor)) then
            local orig, key = f, label .. "." .. k
            local wrapper = function(...)
                if REC.on and not REC.quiet and allow(key, 12) then
                    local args, cnt = { ... }, select("#", ...)
                    pcall(function()
                        local a = {}
                        for i = 1, math.min(cnt, 6) do a[#a + 1] = ser(args[i], 1) end
                        rec("CALL " .. key .. "(" .. table.concat(a, ", ") .. ")")
                    end)
                end
                return orig(...)
            end
            t[k] = wrapper
            REC.wl[#REC.wl + 1] = { t = t, k = k, orig = orig, wrapper = wrapper }
            n = n + 1
        end
    end
    return n
end

local EV_HINT = { "chest", "inventory", "item", "pick", "drop", "slot", "container", "click", "gui", "window", "loot", "collect", "use", "touch" }
local function hookEvents()                         -- registered once, silent unless recording
    if REC.evReg then return end
    REC.evReg = true
    pcall(function()
        for name in pairs(CEvents) do
            local low = tostring(name):lower()
            local want = false
            for _, h in ipairs(EV_HINT) do if low:find(h, 1, true) then want = true; break end end
            if low:sub(1, 3) == "get" then want = false end      -- these expect a return value
            if want then
                pcall(function()
                    BaseListener.registerCallBack(CEvents[name], function(a, b, c, d)
                        if REC.on and allow("EV." .. name, 8) then
                            rec("EVENT " .. name .. "(" .. ser(a, 1) .. ", " .. ser(b, 1) .. ", " .. ser(c, 1) .. ", " .. ser(d, 1) .. ")")
                        end
                    end)
                end)
            end
        end
    end)
end

local CHESTY = { ContainerChest = true, InventoryLargeChest = true, GuiScrollableInventory = true, GuiItemSlot = true }
local WRAP_TABLES = { "ContainerChest", "Container", "Slot", "BoundSlot", "GuiItemSlot", "GuiScrollableInventory",
    "GuiSlotTable", "ClientPacketSender", "PacketSender", "InventoryLargeChest", "InventoryProxy",
    "InventoryPlayer", "gui_playerInventoryControl", "GUIScrolledContainer" }

local function stackSig(st)
    if st == nil then return "-" end
    local ok, a, b, c = pcall(function() return st:get() end)
    if ok then return ser(a) .. "/" .. ser(b) .. "/" .. ser(c) end
    return "?"
end

local function chestVis()
    local w = chestWindow()
    if not w then return "window=nil" end
    local a, b = "?", "?"
    pcall(function() a = tostring(w:IsVisible()) end)
    pcall(function() b = tostring(w:IsVisibleInScreen()) end)
    return "IsVisible=" .. a .. " IsVisibleInScreen=" .. b
end

local function entityInfo(e)
    local out = {}
    local function add(label, names)
        out[#out + 1] = label .. "=" .. ser(callAny(e, names))
    end
    add("className", { "getClassName" }); add("name", { "getEntityName" }); add("tname", { "getTranslatedEntityName" })
    add("uid", { "getUniqueID" }); add("super", { "getSuperClassID" }); add("dead", { "isDead" })
    add("w", { "getWidth" }); add("h", { "getHeight" }); add("props", { "getCustomProperties" })
    return table.concat(out, " ")
end

local function pollState()
    local open = isChestOpen()
    local cv = chestVis()
    if cv ~= REC.prevVis then rec("STATE chest window " .. cv .. " -> open=" .. tostring(open)); REC.prevVis = cv end
    local bag = bagCount()
    if bag ~= REC.prevBag then rec("STATE crystals in bag: " .. tostring(REC.prevBag) .. " -> " .. tostring(bag)); REC.prevBag = bag end
    local pl = PlayerManager:getClientPlayer()
    local inv = pl and callAny(pl, { "getInventory" })
    if inv then
        local size = callAny(inv, { "getSizeInventory" }) or 0
        for i = 0, size - 1 do
            local sig = stackSig(callAny(inv, { "getStackInSlot" }, i))
            if REC.prevSlots[i] ~= sig then
                if REC.prevSlots[i] ~= nil then rec(("SLOT %d: %s -> %s"):format(i, REC.prevSlots[i], sig)) end
                REC.prevSlots[i] = sig
            end
        end
    end
end

local function pollEntities()
    local list = entityListByIds()
    local me = PlayerManager:getClientPlayer()
    local mp; if me and me.Player then pcall(function() mp = me.Player:getPosition() end) end
    local cur = {}
    for id, e in pairs(list) do
        cur[id] = true
        local cls = classOf(e)
        if not REC.seenClass[cls] then
            REC.seenClass[cls] = true
            rec("CLASS " .. cls .. " methods: " .. table.concat(namesOf(e), ", "))
        end
        if not REC.ents[id] then
            REC.ents[id] = true
            if REC.entsInit then
                local pos, iid = posOf(e), itemIdOf(e)
                local d = (mp and pos) and math.sqrt((pos.x - mp.x) ^ 2 + (pos.y - mp.y) ^ 2 + (pos.z - mp.z) ^ 2) or nil
                if iid or (d and d < 15) then
                    REC.itemEnts[id] = iid or true
                    rec(("ENTITY + id=%d class=%s item=%s pos=%s dist=%s | %s"):format(id, cls, tostring(iid),
                        pos and ("%.1f,%.1f,%.1f"):format(pos.x, pos.y, pos.z) or "-", d and ("%.1f"):format(d) or "-", entityInfo(e)))
                end
            end
        end
    end
    for id in pairs(REC.ents) do
        if not cur[id] then
            REC.ents[id] = nil
            if REC.itemEnts[id] then rec(("ENTITY - id=%d (was near)"):format(id)); REC.itemEnts[id] = nil end
        end
    end
    REC.entsInit = true
end

local function recFlush()
    if not REC.path or #REC.buf == 0 then return end
    local data = table.concat(REC.buf, "\n") .. "\n"
    REC.buf = {}
    pcall(function()
        local f = io.open(REC.path, "a")
        if f then f:write(data); f:close() end
    end)
end

local function recStop()
    if not REC.on then return end
    rec("=== recording stopped ===")
    if REC.timer then LuaTimer:cancel(REC.timer); REC.timer = nil end
    for _, w in ipairs(REC.wl) do
        if w.t[w.k] == w.wrapper then w.t[w.k] = w.orig end
    end
    REC.wl = {}
    recFlush()
    REC.on = false
    notify("Recording saved: " .. REC.shortPath, "ok")
end

local function recStart()
    if REC.on then return end
    REC.path = nil
    for _, pth in ipairs(pathsFor("nova_rec.txt")) do
        local ok = pcall(function()
            local f = io.open(pth, "w")
            if not f then error("open failed") end
            f:write("nova recorder started\n"); f:close()
        end)
        if ok then REC.path = pth; break end
    end
    if not REC.path then notify("Recorder: cannot write a file", "bad"); return false end
    REC.shortPath = REC.path:gsub("^/storage/emulated/0/Android/data/", "")
    REC.on, REC.lines, REC.buf, REC.rate, REC.n = true, 0, {}, {}, 0
    REC.prevSlots, REC.prevBag, REC.prevOpen, REC.prevVis, REC.quiet = {}, nil, false, nil, false
    REC.ents, REC.itemEnts, REC.entsInit, REC.seenClass = {}, {}, false, {}

    local pc; pcall(function() pc = Blockman.Instance().m_playerControl end)
    rec("HEADER m_playerControl: " .. table.concat(namesOf(pc), ", "))

    local wrapped = {}
    for _, name in ipairs(WRAP_TABLES) do
        local t = _G[name]
        if type(t) == "table" then wrapped[#wrapped + 1] = name .. "=" .. wrapTable(name, t, nil, CHESTY[name]) end
    end
    local me = PlayerManager:getClientPlayer()
    if me then
        local mt = getmetatable(me)
        local cls = type(mt) == "table" and mt.__index or nil
        if type(cls) == "table" then
            local names = { sendPacket = true, doClientAction = true }
            wrapped[#wrapped + 1] = "player=" .. wrapTable("player", cls, function(k) return names[k] end)
        end
    end
    rec("HEADER wrapped: " .. table.concat(wrapped, " "))

    hookEvents()
    REC.timer = LuaTimer:scheduleTimer(function()
        if not REC.on then return end
        REC.n = REC.n + 1
        REC.quiet = true                                -- our own polling must not show up as CALL lines
        pcall(pollState)
        if REC.n % 4 == 0 then pcall(pollEntities) end
        REC.quiet = false
        if REC.n % 8 == 0 then
            local p = PlayerManager:getClientPlayer()
            local pos; if p and p.Player then pcall(function() pos = p.Player:getPosition() end) end
            if pos then rec(("POS %.1f,%.1f,%.1f"):format(pos.x, pos.y, pos.z)) end
            recFlush()
        end
    end, 250, -1)
    notify("Recording... go play by hand", "ok")
    return true
end

-- ---------- chest lab ----------
-- The chest slots are drawn by the engine (no child windows, no Lua calls when you tap them).
-- This lab reads the window geometry and tests how its native touch entry points can be driven.
local GEO = { "GetScreenRenderArea", "GetUnclippedOuterRect", "GetClippedOuterRect", "GetHitTestRect", "GetRenderArea",
    "GetArea", "GetPixelSize", "GetPosition", "GetWidth", "GetHeight", "GetXPosition", "GetYPosition" }

local function shape(v, depth)
    depth = depth or 0
    local t = type(v)
    if t ~= "userdata" and t ~= "table" then return ser(v) end
    if depth > 1 then return "<" .. t .. ">" end
    local parts = {}
    for _, k in ipairs({ "x", "y", "z", "w", "h", "width", "height", "left", "top", "right", "bottom", "min", "max", "offset", "scale" }) do
        local ok, val = pcall(function() return v[k] end)
        if ok and val ~= nil then parts[#parts + 1] = k .. "=" .. shape(val, depth + 1) end
    end
    if #parts > 0 then return "{" .. table.concat(parts, ",") .. "}" end
    local ok, ts = pcall(tostring, v)
    return ok and tostring(ts):sub(1, 40) or ("<" .. t .. ">")
end

local function rectOf(v)
    if v == nil then return nil end
    local function f(k)
        local ok, x = pcall(function() return v[k] end)
        return (ok and type(x) == "number") and x or nil
    end
    local l, t, r, b = f("left"), f("top"), f("right"), f("bottom")
    if l and t and r and b then return l, t, r, b end
    local x, y, w, h = f("x"), f("y"), f("width") or f("w"), f("height") or f("h")
    if x and y and w and h then return x, y, x + w, y + h end
    return nil
end

local function writeNamed(name, data)
    for _, pth in ipairs(pathsFor(name)) do
        local ok = pcall(function()
            local f = io.open(pth, "w")
            if not f then error("open failed") end
            f:write(data); f:close()
        end)
        if ok then return pth end
    end
    return nil
end

local function runChestLab()
    if not isChestOpen() then notify("Open a chest first, then press the lab", "bad"); return end
    local w = chestWindow()
    local L = { "nova chest lab | crystals in bag: " .. tostring(bagCount()) }
    local cx, cy
    for _, n in ipairs(GEO) do
        local ok, a, b = pcall(function() return w[n](w) end)
        L[#L + 1] = ("%s -> %s%s"):format(n, ok and shape(a) or ("ERR " .. tostring(a)), (ok and b ~= nil) and (", " .. shape(b)) or "")
        if ok and not cx then
            local l, t, r, bt = rectOf(a)
            if l then cx, cy = (l + r) / 2, (t + bt) / 2; L[#L + 1] = ("   rect from %s: %.1f,%.1f .. %.1f,%.1f"):format(n, l, t, r, bt) end
        end
    end
    cx, cy = cx or 0, cy or 0
    L[#L + 1] = ("tap point used: %.1f, %.1f"):format(cx, cy)
    local forms = {
        { "xy table",       function(x, y) return w:TouchDown({ x = x, y = y }), w:TouchUp({ x = x, y = y }) end },
        { "position table", function(x, y) return w:TouchDown({ position = { x = x, y = y } }), w:TouchUp({ position = { x = x, y = y } }) end },
        { "Vector2",        function(x, y) local v = VectorUtil.newVector2(x, y); return w:TouchDown(v), w:TouchUp(v) end },
        { "numbers",        function(x, y) return w:TouchDown(x, y), w:TouchUp(x, y) end },
    }
    local i = 0
    local function nextForm()
        i = i + 1
        if i > #forms then
            local path = writeNamed("nova_lab.txt", table.concat(L, "\n"))
            notify(path and "Lab saved: nova_lab.txt" or "Lab: could not write file", path and "ok" or "bad")
            return
        end
        local before = bagCount()
        local r1, r2
        local ok, err = pcall(function() r1, r2 = forms[i][2](cx, cy) end)
        L[#L + 1] = ("form %s: %s"):format(forms[i][1], ok and ("no error, returns " .. ser(r1) .. ", " .. ser(r2)) or ("ERR " .. tostring(err)))
        LuaTimer:schedule(function()
            L[#L + 1] = ("   bag %s -> %s | chest open: %s"):format(tostring(before), tostring(bagCount()), tostring(isChestOpen()))
            nextForm()
        end, 700)
    end
    nextForm()
end

-- ---------- tab ----------
local CRI = {}
local function crystalsTab(ui)
    ui:section("chest")
    ui:toggle("Chest: auto take crystals", "Takes item " .. CR.ITEM .. " from an open chest (block " .. CR.CHEST_BLOCK .. "), stack by stack",
        false, function(v) CR.chestOn = v; CR.warnedTake = false end)
    ui:stepper("Take delay", "Ticks between stacks (1 tick = 100 ms)", 1, 20, 1, S.chestDelay, function(v)
        S.chestDelay = v; markDirty()
    end)

    ui:section("floor")
    ui:toggle("Floor: collect crystals", "Flies to dropped crystals inside the radius, one by one",
        false, function(v) CR.floorOn = v; CR.busy = false end)
    ui:slider("Search radius", "Blocks around you", 5, 150, 5, S.radius, function(v)
        S.radius = v; markDirty()
    end)

    ui:section("status")
    CRI.bag     = ui:kv("Crystals in bag", "-", C.good)
    CRI.chest   = ui:kv("Chest open", "no")
    CRI.scan    = ui:kv("Entities scanned", "-")
    CRI.found   = ui:kv("Crystals in radius", "-")
    CRI.src     = ui:kv("Entity list source", "-")
    CRI.visits  = ui:kv("Floor visits", "0")
    CRI.picked  = ui:kv("Collected (bag +)", "0", C.good)
    CRI.fp      = ui:kv("Crystal fingerprint", "not learned", C.warn)
    CRI.takes   = ui:kv("Chest stacks taken", "0")
    CRI.takeCall  = ui:kv("Take call",  "not wired", C.warn)
    CRI.clickCall = ui:kv("Click call", "experimental", C.warn)

    ui:section("recorder")
    ui:info("Switch Record on, close the panel, take crystals by hand (chest, then floor), reopen the panel and switch Record off. Result: nova_rec.txt.")
    local recTg
    recTg = ui:toggle("Record (events, calls, state)", "Logs everything to nova_rec.txt every 2 seconds", false, function(v)
        if v then
            if recStart() == false then recTg.set(false) end
        else
            recStop()
        end
    end)
    CRI.recLines = ui:kv("Recorded lines", "0")
    CRI.recFile  = ui:kv("Recording file", "-")
    ui:action("Add mark", function() rec("=== MARK ==="); notify("Mark added", "ok") end)

    ui:section("tools")
    ui:info("Open a chest and stand near a crystal, then press Probe. The dump goes to nova_probe.txt in the game data folder.")
    ui:action("Probe", runProbe)
    ui:action("Scan floor now", function()
        local l = scanFloor()
        notify(("%d crystal(s) in %d blocks (%d entities)"):format(#l, S.radius, CR.scanned), #l > 0 and "ok" or nil)
    end)
    ui:action("Chest lab (open a chest first)", runChestLab)
    ui:action("Learn crystal (stand next to one)", learnCrystal)
    ui:action("Clear skipped list", function() CR.visited = {}; notify("Skipped list cleared", "ok") end)

    return { onShow = function()
        CRI.chest.set(isChestOpen() and "yes" or "no")
        CRI.bag.set(tostring(bagCount() or "-"))
        CRI.recLines.set(tostring(REC.lines)); CRI.recFile.set(REC.shortPath)
        CRI.scan.set(tostring(CR.scanned)); CRI.found.set(tostring(CR.inRadius))
        CRI.src.set(CR.listSrc)
        CRI.visits.set(tostring(CR.visits)); CRI.takes.set(tostring(CR.takes))
        CRI.picked.set(tostring(CR.picked)); CRI.fp.set(CR.fp and CR.fp:sub(1, 26) or "not learned")
        CRI.clickCall.set(CR.clickVia or "experimental")
    end }
end

local function startCrystals()
    local tick = 0
    LuaTimer:scheduleTimer(function()
        local open = isChestOpen()
        if S.prog > 0.5 and CRI.chest then
            CRI.chest.set(open and "yes" or "no")
            CRI.bag.set(tostring(bagCount() or "-"))
        CRI.recLines.set(tostring(REC.lines)); CRI.recFile.set(REC.shortPath)
            CRI.scan.set(tostring(CR.scanned)); CRI.found.set(tostring(CR.inRadius))
            CRI.src.set(CR.listSrc)
            CRI.visits.set(tostring(CR.visits)); CRI.takes.set(tostring(CR.takes))
        CRI.picked.set(tostring(CR.picked)); CRI.fp.set(CR.fp and CR.fp:sub(1, 26) or "not learned")
        CRI.clickCall.set(CR.clickVia or "experimental")
        end
        if open and CR.chestOn then
            tick = tick + 1
            if tick >= S.chestDelay then tick = 0; pcall(chestTick) end
        else
            tick = 0
        end
        CR.ticks = CR.ticks + 1
        if CR.floorOn and not open and CR.ticks % 3 == 0 then pcall(floorTick) end
    end, 100, -1)
end

----------------------------------------------------------------------
-- intro: loading splash with a real step-by-step percentage
----------------------------------------------------------------------
local SP = { pct = 0, target = 0, BARW = 300, busy = false, shown = false, phase = 0 }

local function spSetPct(p)
    SP.pct = p
    local fw = SP.BARW * p
    SP.fill:SetArea({0, 0}, {0, 0}, {0, fw}, {0, 10})
    SP.pctTxt:SetText(string.format("%d%%", math.floor(p * 100 + 0.5)))
    local showShine = fw > 44
    SP.shine:SetVisible(showShine)
end

local function spSetTarget(t)
    SP.target = t
    local from = SP.pct
    tween("sp_bar", 280, ease.outCubic, function(p) spSetPct(lerp(from, t, p)) end)
end

local function buildSplash(guiRoot)
    local cw, ch = 380, 190

    SP.root = win(GUIType.Layout, "Splash", guiRoot)
    SP.root:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    SP.root:SetBackgroundColor({0, 0, 0, 0})
    SP.root:SetTouchable(false)
    pcall(function() SP.root:SetLevel(20) end)

    SP.card = box(SP.root, 0, 0, cw, ch, C.accent)
    SP.card:SetArea({0.5, -cw / 2}, {0.5, -ch / 2}, {0, cw}, {0, ch})
    local inner = box(SP.card, 1, 1, cw - 2, ch - 2, C.panel)
    box(inner, 0, 0, cw - 2, 2, C.accent2)
    text(inner, "NOVA", 0, 16, cw - 2, 52, C.text, 2.0, HorizontalAlignment.Center)
    SP.sub = text(inner, "starting", 0, 70, cw - 2, 22, C.muted, 0.85, HorizontalAlignment.Center)

    SP.track = box(inner, (cw - 2 - SP.BARW) / 2, 108, SP.BARW, 10, C.off)
    SP.fill  = box(SP.track, 0, 0, 0, 10, C.accent)
    SP.shine = box(SP.fill, 0, 0, 36, 10, {1, 1, 1, 0.35})
    SP.pctTxt = text(inner, "0%", 0, 126, cw - 2, 28, C.text, 1.1, HorizontalAlignment.Center)
    SP.root:SetVisible(false)

    -- shine sweeps along the filled part while the splash is visible
    LuaTimer:scheduleTimer(function()
        if not SP.shown then return end
        SP.phase = (SP.phase + 0.035) % 1
        local fw = SP.BARW * SP.pct
        if fw > 44 then SP.shine:SetArea({0, SP.phase * (fw - 36)}, {0, 0}, {0, 36}, {0, 10}) end
    end, 30, -1)
end

local function spShow()
    SP.shown = true
    SP.pct, SP.target = 0, 0
    spSetPct(0)
    SP.sub:SetTextColor(C.muted)
    SP.root:SetVisible(true)
    tween("sp_show", 260, ease.outCubic, function(p)
        SP.root:SetBackgroundColor({0, 0, 0, 0.78 * p})
        SP.card:SetArea({0.5, -190}, {0.5, -95 + (1 - p) * 24}, {0, 380}, {0, 190})
        setAlpha(SP.card, p)
    end)
end

local function spHide(done)
    tween("sp_show", 320, ease.inCubic, function(p)
        SP.root:SetBackgroundColor({0, 0, 0, 0.78 * (1 - p)})
        SP.card:SetArea({0.5, -190}, {0.5, -95 - p * 18}, {0, 380}, {0, 190})
        setAlpha(SP.card, 1 - p)
    end, function()
        SP.root:SetVisible(false)
        SP.shown, SP.busy = false, false
        if done then pcall(done) end
    end)
end

-- steps = { { label = "...", fn = function() ... end }, ... }
local function runSplash(steps, done)
    if SP.busy then return end
    SP.busy = true
    spShow()
    local n = #steps
    local function step(i)
        if i > n then
            SP.sub:SetText("Ready")
            spSetTarget(1)
            LuaTimer:schedule(function() spHide(done) end, 500)
            return
        end
        SP.sub:SetText(steps[i].label)
        local ok, err = pcall(steps[i].fn)
        if ok then
            SP.sub:SetTextColor(C.muted)
        else
            SP.sub:SetText("failed: " .. steps[i].label)
            SP.sub:SetTextColor(C.danger)
            print("[Nova] " .. steps[i].label .. ": " .. tostring(err))
        end
        spSetTarget(i / n)
        LuaTimer:schedule(function() step(i + 1) end, 280)
    end
    LuaTimer:schedule(function() step(1) end, 320)       -- let the card fade in first
end

function NovaMenu.playIntro()
    if SP.busy then return end
    runSplash({
        { label = "Checking interface", fn = function() end },
        { label = "Syncing profile",    fn = refreshProfile },
        { label = "Reading live stats", fn = updateStats },
        { label = "Applying theme",     fn = function() applyProg(S.prog) end },
    })
end

----------------------------------------------------------------------
-- boot (waits for the GUI root)
----------------------------------------------------------------------
local booted = false
local function boot()
    if booted then return end
    local guiRoot
    pcall(function() guiRoot = GUISystem.Instance():GetRootWindow() end)
    if not guiRoot then LuaTimer:schedule(boot, 500); return end
    booted = true

    LuaTimer:scheduleTimer(function() clock = clock + 0.05 end, 50, -1)

    buildSplash(guiRoot)
    runSplash({
        { label = "Loading settings",    fn = loadSettings },
        { label = "Building panel",      fn = function() buildPanel(guiRoot) end },
        { label = "Creating button",     fn = function() buildFab(guiRoot); setHudVisible(S.hud) end },
        { label = "Loading notifications", fn = function() buildToasts(guiRoot) end },
        { label = "Loading Info tab",    fn = function() NovaMenu.addTab("Info", infoTab, true) end },
        { label = "Loading GUI tab",     fn = function() NovaMenu.addTab("GUI", guiTab, true) end },
        { label = "Loading tweaks",      fn = function() NovaMenu.addTab("Tweaks", tweaksTab); startTipGuard() end },
        { label = "Loading crystals",    fn = function() NovaMenu.addTab("Crystals", crystalsTab); startCrystals() end },
        { label = "Starting live stats", fn = function()
            LuaTimer:scheduleTimer(function() pcall(updateStats) end, 250, -1)
            LuaTimer:scheduleTimer(function()
                if S._dirty then S._dirty = false; pcall(saveSettings) end
            end, 1500, -1)
        end },
        { label = "Applying theme",      fn = function() applyProg(0) end },
    }, function() notify("Nova ready", "ok") end)
end

boot()
return NovaMenu
