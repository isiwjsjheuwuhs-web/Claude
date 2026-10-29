-- nova_menu.lua v0.9.7 : standalone animated menu.
-- Floating draggable button + FPS/HUD -> animated panel -> Info / Visual / Tweaks.
-- v0.9.7: Crystals tab removed. Added landing glow & on-screen aim assist toggle.
-- Compatible with Blockman GO Lua engine; no network usage.

if _G.NovaMenu then return _G.NovaMenu end
local NovaMenu = { tabs = {} }
_G.NovaMenu = NovaMenu

---------------------------------------------------------------------
-- config
---------------------------------------------------------------------
local W, H = 840, 480
local SIDE = 180
local HEAD = 52
local ROW_W = W - SIDE - 30
local FRAME_MS = 16
local HUD_W = 220

local C = {
    clear = {0, 0, 0, 0},
    bg = {0.043, 0.051, 0.082, 0.98},
    panel = {0.067, 0.078, 0.125, 1},
    card = {0.094, 0.109, 0.165, 1},
    line = {0.17, 0.19, 0.28, 1},
    off = {0.20, 0.22, 0.31, 1},
    tabOn = {0.115, 0.13, 0.20, 1},
    accent = {0.49, 0.36, 1.00, 1},
    accent2 = {0.25, 0.85, 0.95, 1},
    text = {0.93, 0.94, 0.98, 1},
    muted = {0.55, 0.58, 0.70, 1},
    danger = {0.95, 0.32, 0.38, 1},
    good = {0.30, 0.90, 0.50, 1},
    warn = {1.00, 0.80, 0.25, 1},
}

---------------------------------------------------------------------
-- utils
---------------------------------------------------------------------
local uid = 0
local function nid(p)
    uid = uid + 1
    return "NV_" .. p .. "_" .. uid
end

local function lerp(a, b, t) return a + (b - a) * t end
local function lerpC(a, b, t)
    return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t) }
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local ease = {
    outCubic = function(t) t = 1 - t; return 1 - t * t * t end,
    inCubic = function(t) return t * t * t end,
}

local function safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function now()
    if type(os) == "table" and os.clock then return os.clock() end
    return 0
end

local function setAlpha(w, a) safeCall(function() w:SetAlpha(a) end) end
local function on(w, ev, fn) safeCall(function() w:registerEvent(ev, fn) end) end
local function sound(id) safeCall(function() SoundUtil.playSound(id) end) end
local function toast(t) safeCall(function() UIHelper.showToast(t) end) end

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

---------------------------------------------------------------------
-- widget factory
---------------------------------------------------------------------
local function win(gtype, prefix, parent)
    local w = GUIManager:createGUIWindow(gtype, nid(prefix))
    if parent then parent:AddChildWindow(w) end
    return w
end

local function box(parent, x, y, w, h, col, touch)
    local l = win(GUIType.Layout, "L", parent)
    l:SetArea({0, x}, {0, y}, {0, w}, {0, h})
    l:SetBackgroundColor(col)
    l:SetTouchable(touch == true)
    return l
end

local function text(parent, str, x, y, w, h, col, scale, align)
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
    on(b, GUIEvent.TouchUp, function() b:SetBackgroundColor(normal) end)
end

---------------------------------------------------------------------
-- state
---------------------------------------------------------------------
local S = {
    pdx = 0, pdy = 0,
    fdx = -150, fy = 6,
    fabSize = 64,
    prog = 0,
    cur = nil,
    closeOutside = true,
    pulse = true,
    hud = true,
    learned = "",
    visualLanding = true,
    landingSize = 88,
    landingDur = 1.0,
    aimEnabled = false,
    aimFov = 70,
    aimRange = 28,
    aimNearest = true,
    aimSnap = true,
}

local frame, dim, sidebar, content, indicator, root
local fab, fabInner, fabLabel
local hud = {}
local VIS = {}
local TOAST = { slots = {}, n = 3, i = 0 }

---------------------------------------------------------------------
-- saved settings
---------------------------------------------------------------------
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
local NUM_KEYS = { "pdx", "pdy", "fdx", "fy", "fabSize", "landingSize", "landingDur", "aimFov", "aimRange" }
local BOOL_KEYS = { "hud", "pulse", "closeOutside", "visualLanding", "aimEnabled", "aimNearest", "aimSnap" }
local KNOWN = {}
for _, k in ipairs(NUM_KEYS) do KNOWN[k] = "num" end
for _, k in ipairs(BOOL_KEYS) do KNOWN[k] = "bool" end
KNOWN.learned = "str"

local function markDirty() S._dirty = true end

local function saveSettings()
    local lines = {}
    for _, k in ipairs(NUM_KEYS) do lines[#lines + 1] = k .. "=" .. tostring(S[k]) end
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
            S.landingSize = clamp(S.landingSize, 40, 160)
            S.landingDur = clamp(S.landingDur, 0.3, 3)
            S.aimFov = clamp(S.aimFov, 10, 140)
            S.aimRange = clamp(S.aimRange, 4, 80)
            return true
        end
    end
    return false
end

---------------------------------------------------------------------
-- notifications
---------------------------------------------------------------------
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

local function notify(msg, kind)
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

local function homeFab()
    S.fdx, S.fy = -150, 6
end

---------------------------------------------------------------------
-- page builder
---------------------------------------------------------------------
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
        local card = box(holder, 0, self.y, RW, h, C.line)
        local inner = box(card, 1, 1, RW - 2, h - 2, C.card)
        self.y = self.y + h + 8
        return inner
    end

    function ui:info(str)
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

    function ui:kv(key, value, col)
        local r = self:row(38)
        text(r, key, 16, 0, RW * 0.4, 36, C.muted, 0.9)
        local v = text(r, value, RW * 0.4, 0, RW * 0.6 - 18, 36, col or C.text, 0.95, HorizontalAlignment.Right)
        return { set = function(str, c)
            v:SetText(str)
            if c then v:SetTextColor(c) end
        end }
    end

    function ui:toggle(title, desc, default, cb)
        local r = self:row(58)
        local key = nid("tg")
        local state = default and true or false
        text(r, title, 16, 8, RW - 100, 20, C.text, 1)
        text(r, desc, 16, 31, RW - 100, 18, C.muted, 0.78)
        local track = box(r, RW - 66, 18, 44, 20, state and C.accent or C.off)
        local knob = box(track, state and 26 or 2, 2, 16, 16, C.text)

        local function render(v, animate)
            local x0, x1 = v and 2 or 26, v and 26 or 2
            local c0, c1 = v and C.off or C.accent, v and C.accent or C.off
            if not animate then
                knob:SetArea({0, x1}, {0, 2}, {0, 16}, {0, 16})
                track:SetBackgroundColor(c1)
                return
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
        text(r, desc, 16, 31, RW - 180, 18, C.muted, 0.78)
        local lbl = text(r, tostring(val), RW - 96, 13, 44, 30, C.text, 1, HorizontalAlignment.Center)
        local function bump(d)
            val = clamp(val + d, min, max)
            lbl:SetText(tostring(val))
            sound(0)
            if cb then pcall(cb, val) end
        end
        local m = button(r, "-", RW - 136, 12, 34, 32, C.off, C.text, 1.1, function() bump(-step) end)
        local p = button(r, "+", RW - 50, 12, 34, 32, C.accent, C.text, 1.1, function() bump(step) end)
        pressFx(m, C.off, C.line); pressFx(p, C.accent, C.accent2)
        return { get = function() return val end }
    end

    function ui:slider(title, desc, min, max, step, default, cb)
        local r = self:row(76)
        local val = clamp(default, min, max)
        local TW = RW - 56
        text(r, title, 16, 8, RW - 190, 20, C.text, 1)
        text(r, desc, 16, 29, RW - 190, 18, C.muted, 0.78)
        local lbl = text(r, tostring(val), RW - 190, 8, 60, 20, C.accent2, 1, HorizontalAlignment.Right)
        local track = box(r, 28, 58, TW, 6, C.off)
        local fill = box(track, 0, 0, 0, 6, C.accent)
        local knob = box(track, 0, -5, 16, 16, C.text)

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

        local hit = box(r, 14, 44, TW + 28, 30, C.clear, true)
        local sess = { t = -1, lx = 0 }
        on(hit, GUIEvent.TouchDown, function() sess.t = -1 end)
        on(hit, GUIEvent.TouchMove, function(args)
            local pos = args and args.position
            if not pos then return end
            local t = now()
            if t - sess.t > 0.3 then sess.lx = pos.x end
            sess.t = t
            local delta = pos.x - sess.lx
            sess.lx = pos.x
            setVal(val + delta * (max - min) / TW)
        end)

        local m = button(r, "-", RW - 126, 22, 34, 28, C.off, C.text, 1.1, function() sound(0); setVal(val - step) end)
        local p = button(r, "+", RW - 50, 22, 34, 28, C.accent, C.text, 1.1, function() sound(0); setVal(val + step) end)
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

---------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- floating button + hud
---------------------------------------------------------------------
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

local function fpsColor(v) return v >= 50 and C.good or (v >= 30 and C.warn or C.danger) end
local function pingColor(v) return v <= 80 and C.good or (v <= 180 and C.warn or C.danger) end

local function updateStats()
    local fps, ping, held = readStats()
    if S.hud then
        hud.fps:SetText(string.format("FPS %d", fps)); hud.fps:SetTextColor(fpsColor(fps))
        hud.ping:SetText(string.format("Ping %d", ping)); hud.ping:SetTextColor(pingColor(ping))
        hud.item:SetText(held >= 0 and ("Held item: " .. held) or "Held item: -")
    end
end

local function placePanel(off)
    frame:SetArea({0.5, -W / 2 + S.pdx}, {0.5, -H / 2 + S.pdy + (off or 0)}, {0, W}, {0, H})
end

local function applyProg(p)
    S.prog = p
    setAlpha(frame, p)
    placePanel((1 - p) * 24)
    dim:SetBackgroundColor({0, 0, 0, 0.55 * p})
    if fab then fab:SetBackgroundColor(lerpC(C.accent, C.accent2, p)) end
end

local function animateTo(target)
    local from = S.prog
    if target == 1 then
        root:SetVisible(true); sound(4)
    else
        sound(0)
    end
    local ms = math.max(60, 260 * math.abs(target - from))
    tween("panel", ms, target == 1 and ease.outCubic or ease.inCubic,
        function(p) applyProg(lerp(from, target, p)) end,
        function() if target == 0 then root:SetVisible(false) end end)
end

function NovaMenu.open() animateTo(1) end
function NovaMenu.close() animateTo(0) end
function NovaMenu.toggle() animateTo(S.prog < 0.5 and 1 or 0) end
function NovaMenu.isOpen() return S.prog > 0.5 end

local function buildFab(guiRoot)
    fab = box(guiRoot, 0, 0, S.fabSize, S.fabSize, C.accent, true)
    fabInner = box(fab, 3, 3, S.fabSize - 6, S.fabSize - 6, C.panel)
    fabLabel = text(fabInner, "N", 0, 0, S.fabSize - 6, S.fabSize - 6, C.text, 1.6, HorizontalAlignment.Center)
    pcall(function() fab:SetLevel(10) end)

    local function hudText(str)
        local t = text(guiRoot, str, 0, 0, HUD_W, 24, C.text, 0.95, HorizontalAlignment.Center)
        pcall(function() t:SetTextBoader(Color.BLACK) end)
        pcall(function() t:SetLevel(10) end)
        return t
    end
    hud.fps, hud.ping, hud.item = hudText("FPS -"), hudText("Ping -"), hudText("Held item: -")

    local sess = { t = -1, lx = 0, ly = 0, sx = 0, sy = 0, moved = false, lastMove = -10 }
    on(fab, GUIEvent.TouchDown, function() sess.t = -1; sess.moved = false end)
    on(fab, GUIEvent.TouchMove, function(args)
        local pos = args and args.position
        if not pos then return end
        local t = now()
        if t - sess.t > 0.3 then
            sess.lx, sess.ly = pos.x, pos.y
            sess.sx, sess.sy = pos.x, pos.y
            sess.moved = false
        end
        sess.t = t
        if not sess.moved and math.abs(pos.x - sess.sx) + math.abs(pos.y - sess.sy) > 8 then sess.moved = true end
        if sess.moved then
            sess.lastMove = t
            S.fdx = S.fdx + (pos.x - sess.lx)
            S.fy = S.fy + (pos.y - sess.ly)
            placeFab(); markDirty()
        end
        sess.lx, sess.ly = pos.x, pos.y
    end)
    on(fab, GUIEvent.Click, function()
        if now() - sess.lastMove < 0.4 then return end
        NovaMenu.toggle()
    end)

    homeFab(); placeFab()

    local t = 0
    LuaTimer:scheduleTimer(function()
        if not S.pulse or S.prog > 0.01 then return end
        t = t + 0.12
        fab:SetBackgroundColor({C.accent[1], C.accent[2], C.accent[3], 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t))})
    end, 50, -1)
end

local function buildPanel(guiRoot)
    root = win(GUIType.Layout, "Root", guiRoot)
    root:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    root:SetBackgroundColor(C.clear)
    root:SetTouchable(false)
    root:SetVisible(false)
    pcall(function() root:SetLevel(5) end)

    dim = win(GUIType.Layout, "Dim", root)
    dim:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    dim:SetBackgroundColor({0, 0, 0, 0})
    dim:SetTouchable(true)
    on(dim, GUIEvent.Click, function() if S.closeOutside then NovaMenu.close() end end)

    frame = box(root, 0, 0, W, H, C.line, true)
    placePanel(0)
    local body = box(frame, 1, 1, W - 2, H - 2, C.bg)

    local header = box(body, 0, 0, W - 2, HEAD, C.panel)
    box(body, 0, HEAD, W - 2, 1, C.line)
    box(body, 0, HEAD, 70, 2, C.accent)
    text(header, "NOVA", 18, 3, 140, 28, C.text, 1.2)
    text(header, "menu", 18, 31, 140, 16, C.accent2, 0.7)

    local closeBtn = button(header, "X", W - 2 - 46, 9, 34, 34, C.off, C.text, 0.95, function() NovaMenu.close() end)
    pressFx(closeBtn, C.off, C.danger)

    local drag = box(header, 0, 0, W - 2 - 56, HEAD, C.clear, true)
    local lx, ly, lastT = 0, 0, -1
    on(drag, GUIEvent.TouchDown, function() lastT = -1 end)
    on(drag, GUIEvent.TouchMove, function(args)
        local pos = args and args.position
        if not pos then return end
        local t = now()
        if t - lastT > 0.3 then lx, ly = pos.x, pos.y end
        lastT = t
        S.pdx = S.pdx + (pos.x - lx)
        S.pdy = S.pdy + (pos.y - ly)
        lx, ly = pos.x, pos.y
        placePanel(0); markDirty()
    end)

    sidebar = box(body, 0, HEAD + 1, SIDE, H - 2 - HEAD - 1, C.panel)
    box(sidebar, SIDE - 1, 0, 1, H, C.line)
    indicator = box(sidebar, 0, indY, 3, 46, C.accent)
    local foot = text(sidebar, "nova  v0.9.7", 14, 0, SIDE - 20, 20, C.muted, 0.7)
    foot:SetArea({0, 14}, {1, -26}, {0, SIDE - 20}, {0, 20})

    content = box(body, SIDE, HEAD + 1, W - 2 - SIDE, H - 2 - HEAD - 1, C.bg)
    applyProg(0)
end

---------------------------------------------------------------------
-- info tab
---------------------------------------------------------------------
local function infoTab(host)
    local ui = newPage(host, ROW_W - 4, { 0, 0, W - SIDE - 14, H - 40 })
    ui:section("profile")
    ui:kv("Menu", "Nova v0.9.7")
    ui:kv("Focus", "Visual + Aim")
    ui:section("live")
    local fps = ui:kv("FPS", "-")
    local ping = ui:kv("Ping", "-")
    local held = ui:kv("Held", "-")
    ui:section("menu")
    ui:toggle("FPS / Ping HUD", "Text under the button", S.hud, function(v) S.hud = v; setHudVisible(v); markDirty() end)
    ui:toggle("Close on outside tap", "Tap dim area to close", S.closeOutside, function(v) S.closeOutside = v; markDirty() end)
    ui:toggle("Idle pulse", "Button border animation", S.pulse, function(v) S.pulse = v; markDirty() end)
    ui:action("Reset positions", function() homeFab(); placeFab(); S.pdx, S.pdy = 0, 0; placePanel(0); markDirty() end)
    ui:finish()

    return { onShow = function()
        local fpsV, pingV, heldV = readStats()
        fps.set(string.format("%d", fpsV), fpsColor(fpsV))
        ping.set(string.format("%d ms", pingV), pingColor(pingV))
        held.set(heldV >= 0 and tostring(heldV) or "-")
    end }
end

---------------------------------------------------------------------
-- visual overlay and aim assist
---------------------------------------------------------------------
local function ringText(parent, name, color, size)
    local w = win(GUIType.StaticText, name, parent)
    w:SetText("◉")
    w:SetTextColor(color)
    w:SetTextScale(1.4)
    w:SetBackgroundColor(C.clear)
    w:SetTouchable(false)
    w:SetVisible(false)
    w:SetArea({0.5, -size / 2}, {0.5, -size / 2}, {0, size}, {0, size})
    return w
end

local function makeAimButton(guiRoot)
    local b = button(guiRoot, "AIM", 0, 0, 72, 34, C.off, C.text, 0.9, function()
        S.aimEnabled = not S.aimEnabled
        b:SetBackgroundColor(S.aimEnabled and C.accent2 or C.off)
        notify(S.aimEnabled and "AIM ON" or "AIM OFF", S.aimEnabled and "ok" or nil)
    end)
    b:SetArea({1, -86}, {1, -52}, {0, 72}, {0, 34})
    b:SetBackgroundColor(C.off)
    pcall(function() b:SetLevel(12) end)
    return b
end

local function getPlayer()
    return safeCall(function() return PlayerManager:getClientPlayer() end)
end

local function getPlayerPos()
    local p = getPlayer()
    if not p or not p.Player then return nil end
    return safeCall(function() return p.Player:getPosition() end)
end

local function getEntityList()
    local out = {}
    for id = 1, 1500 do
        local e = safeCall(function() return EngineWorld:getEntity(id) end)
        if e ~= nil then out[#out + 1] = e end
    end
    return out
end

local function angleDiff(a, b)
    local x = (a - b + 180) % 360
    if x < 0 then x = x + 360 end
    if x > 180 then x = x - 360 end
    return math.abs(x)
end

local function findAimTarget()
    local p = getPlayer()
    if not p or not p.Player then return nil end
    local pos = getPlayerPos()
    if not pos then return nil end
    local yaw = safeCall(function() return p.Player.rotationYaw or 0 end)
    local best, bestScore = nil, 999999
    for _, e in ipairs(getEntityList()) do
        local ePos = safeCall(function() return e:getPosition() end)
        if ePos then
            local dx, dz = ePos.x - pos.x, ePos.z - pos.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist > 0.2 and dist <= S.aimRange then
                local ang = math.deg(math.atan2(dz, dx))
                local diff = angleDiff(ang, yaw)
                if diff <= S.aimFov / 2 then
                    local score = S.aimNearest and dist or diff
                    if score < bestScore then
                        bestScore = score
                        best = { entity = e, dist = dist, pos = ePos, diff = diff }
                    end
                end
            end
        end
    end
    return best
end

local function snapAim()
    if not S.aimEnabled or not S.aimSnap then return end
    local target = findAimTarget()
    if not target or not target.pos then return end
    local p = getPlayer()
    if not p or not p.Player then return end
    local pos = getPlayerPos()
    if not pos then return end
    local dx, dz = target.pos.x - pos.x, target.pos.z - pos.z
    local yaw = math.deg(math.atan2(dz, dx))
    safeCall(function() p.Player:setPositionAndRotation(pos.x, pos.y, pos.z, yaw, 0) end)
    safeCall(function() p.Player.rotationYaw = yaw end)
    safeCall(function() p.Player:setRotationYawHead(yaw) end)
end

local function updateAimVisual()
    if not VIS.aimRing then return end
    if S.aimEnabled then
        local target = findAimTarget()
        if target then
            VIS.aimRing:SetVisible(true)
            VIS.aimRing:SetTextColor(C.accent2)
            VIS.aimRing:SetTextScale(1.5)
            local alpha = clamp(1 - (target.dist / math.max(1, S.aimRange)), 0.2, 0.98)
            setAlpha(VIS.aimRing, alpha)
        else
            VIS.aimRing:SetVisible(false)
        end
        VIS.crossH:SetVisible(true)
        VIS.crossV:SetVisible(true)
    else
        VIS.aimRing:SetVisible(false)
        VIS.crossH:SetVisible(false)
        VIS.crossV:SetVisible(false)
    end
end

local LANDING = { active = false, lastY = nil }
local function triggerLandingGlow()
    if not S.visualLanding then return end
    LANDING.active = true
    VIS.land:SetVisible(true)
    setAlpha(VIS.land, 1)
    tween("landingGlow", math.max(80, S.landingDur * 1000), ease.outCubic,
        function(p)
            local s = S.landingSize * (1.05 - p * 0.45)
            VIS.land:SetArea({0.5, -(s / 2)}, {0.5, 60 + (1 - p) * 18}, {0, s}, {0, s})
            VIS.land:SetTextScale(1.4 + (1 - p) * 0.9)
            setAlpha(VIS.land, (1 - p) * 0.9)
        end,
        function()
            VIS.land:SetVisible(false)
            LANDING.active = false
        end)
end

local function jumpTracker()
    local p = getPlayer()
    if not p or not p.Player then return end
    local pos = getPlayerPos()
    if not pos then return end
    if LANDING.lastY == nil then LANDING.lastY = pos.y; return end
    local delta = pos.y - LANDING.lastY
    if delta > 0.7 then triggerLandingGlow() end
    LANDING.lastY = pos.y
end

local function createVisualOverlay(guiRoot)
    VIS.root = win(GUIType.Layout, "VIS", guiRoot)
    VIS.root:SetArea({0, 0}, {0, 0}, {1, 0}, {1, 0})
    VIS.root:SetBackgroundColor(C.clear)
    VIS.root:SetTouchable(false)
    pcall(function() VIS.root:SetLevel(14) end)

    VIS.aimRing = ringText(VIS.root, "AimRing", C.accent2, 56)
    VIS.aimRing:SetArea({0.5, -28}, {0.5, -28}, {0, 56}, {0, 56})

    VIS.land = ringText(VIS.root, "LandRing", C.good, S.landingSize)
    VIS.land:SetArea({0.5, -S.landingSize / 2}, {0.5, 60}, {0, S.landingSize}, {0, S.landingSize})

    VIS.crossH = box(VIS.root, 0, 0, 2, 18, C.accent2)
    VIS.crossV = box(VIS.root, 0, 0, 18, 2, C.accent2)
    VIS.crossH:SetArea({0.5, -1}, {0.5, -9}, {0, 2}, {0, 18})
    VIS.crossV:SetArea({0.5, -9}, {0.5, -1}, {0, 18}, {0, 2})
    VIS.crossH:SetVisible(false)
    VIS.crossV:SetVisible(false)

    VIS.aimButton = makeAimButton(guiRoot)
end

local function updateVisualOverlay()
    if not VIS.root then return end
    if S.aimEnabled then
        VIS.crossH:SetVisible(true)
        VIS.crossV:SetVisible(true)
        updateAimVisual()
    else
        VIS.crossH:SetVisible(false)
        VIS.crossV:SetVisible(false)
        VIS.aimRing:SetVisible(false)
    end
    if not S.visualLanding then VIS.land:SetVisible(false) end
end

local function visualTab(ui)
    ui:section("landing")
    ui:toggle("Landing glow", "Smooth ring after jump", S.visualLanding, function(v) S.visualLanding = v; if not v then VIS.land:SetVisible(false) end; markDirty() end)
    ui:slider("Glow size", "Ring size", 40, 160, 4, S.landingSize, function(v) S.landingSize = v; markDirty() end)
    ui:slider("Glow time", "Seconds", 0.3, 3.0, 0.1, S.landingDur, function(v) S.landingDur = v; markDirty() end)

    ui:section("aim")
    ui:toggle("Aim assist", "Center ring + target selection", S.aimEnabled, function(v) S.aimEnabled = v; if not v then VIS.aimRing:SetVisible(false) end; markDirty() end)
    ui:slider("FOV", "Degrees", 10, 140, 5, S.aimFov, function(v) S.aimFov = v; markDirty() end)
    ui:slider("Range", "Blocks", 4, 80, 1, S.aimRange, function(v) S.aimRange = v; markDirty() end)
    ui:toggle("Nearest target", "Prefer closest target", S.aimNearest, function(v) S.aimNearest = v; markDirty() end)
    ui:toggle("Auto aim snap", "Rotate to target when active", S.aimSnap, function(v) S.aimSnap = v; markDirty() end)

    ui:action("Center test ring", function()
        VIS.aimRing:SetVisible(true)
        VIS.aimRing:SetTextColor(C.warn)
        setAlpha(VIS.aimRing, 1)
        LuaTimer:schedule(function() VIS.aimRing:SetVisible(false) end, 500)
    end)

    return { onShow = function() updateVisualOverlay() end }
end

---------------------------------------------------------------------
-- startup
---------------------------------------------------------------------
local function boot()
    local guiRoot = safeCall(function() return GUISystem.Instance():GetRootWindow() end)
    if not guiRoot then
        LuaTimer:schedule(boot, 300)
        return
    end

    buildPanel(guiRoot)
    buildFab(guiRoot)
    buildToasts(guiRoot)
    createVisualOverlay(guiRoot)

    NovaMenu.addTab("Info", infoTab, true)
    NovaMenu.addTab("Visual", visualTab)
    NovaMenu.addTab("Tweaks", function(ui)
        ui:section("visual")
        ui:info("Landing glow appears under the player after jump. The on-screen AIM button toggles aim assist without reopening the menu.")
        ui:toggle("Visual helper visible", "Enable overlay layers", true, function() end)
        ui:finish()
    end)

    LuaTimer:scheduleTimer(function()
        pcall(updateStats)
        pcall(updateVisualOverlay)
        if S.aimEnabled then pcall(snapAim) end
    end, 150, -1)

    LuaTimer:scheduleTimer(function()
        pcall(jumpTracker)
        pcall(updateVisualOverlay)
        if S.aimEnabled then pcall(snapAim) end
    end, 60, -1)

    LuaTimer:scheduleTimer(function()
        if S._dirty then S._dirty = false; pcall(saveSettings) end
    end, 1500, -1)

    notify("Nova ready", "ok")
end

boot()
return NovaMenu
