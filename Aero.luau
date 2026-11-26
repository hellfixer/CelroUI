-- AERO | Visual-only control panel. Feature controls change UI state only.
-- Potassium: run this script after attaching to a Roblox client.
-- Local artwork: workspace/Aero/aero-landscape.png
-- Right Shift: show / hide. Drag the title bar to move.
-- v3.3: multi-pick dropdowns, animated editors and Lucide tab icons.
-- Raw loader (returns the Aero API):
-- local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/hellfixer/CelroUI/refs/heads/main/Aero.luau"))()

local CONFIG = {
    Title = "Aero",
    Width = 900,
    Height = 616,
    AssetPath = "Aero/aero-landscape.png",
    ToggleKey = Enum.KeyCode.RightShift,
    SettingsPath = "Aero/settings.json",
    ConfigsPath = "Aero/configs.json",
}

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local env = (type(getgenv) == "function" and getgenv()) or _G
local previous = env.AeroUI
if type(previous) == "table" and type(previous.Destroy) == "function" then
    pcall(previous.Destroy)
end

-- Public methods are registered in stages so controls can call later modules.
local api: {[string]: any} = {}
local HttpService = game:GetService("HttpService")
local DEFAULTS = {
    Accent = "Ocean", Scale = 1, GlassOpacity = 0.88,
    Animations = true, SmoothDragging = true, Wallpaper = true, Shadows = true,
    LockPosition = false, RememberPosition = true, FreeMouse = true,
    ToggleKey = "RightShift", ToggleMode = "Toggle", Notifications = true, NotifyWhenHidden = true,
    NotificationDuration = 4, NotificationLimit = 3, AutoSave = true,
}
local PALETTES = {
    Ocean = { Color3.fromRGB(51,164,219), Color3.fromRGB(13,115,180), Color3.fromRGB(132,230,250) },
    Meadow = { Color3.fromRGB(116,190,55), Color3.fromRGB(64,141,22), Color3.fromRGB(198,248,131) },
    Iris = { Color3.fromRGB(167,123,216), Color3.fromRGB(116,71,171), Color3.fromRGB(228,199,255) },
    Rose = { Color3.fromRGB(224,128,163), Color3.fromRGB(180,64,111), Color3.fromRGB(255,203,225) },
}
local numberRules = {
    Scale = {0.75, 1.25, 0.05}, GlassOpacity = {0.45, 1, 0.01},
    NotificationDuration = {2, 10, 1}, NotificationLimit = {1, 5, 1},
}
local preferences = table.clone(DEFAULTS)
-- Declare state fields up front for Potassium's older Luau analyzer.
-- Deferred hooks/jobs are filled by the owning module before their first use.
type RuntimeState = {
    Hidden: boolean, CapturingKey: boolean, Dirty: boolean, Generation: number,
    Controls: {[string]: any}, Groups: {[any]: any}, Refreshers: {() -> ()},
    Toasts: {any}, ToastIds: {[string]: any}, PageNames: {string},
    Minimized: boolean?, SelectedTab: number?, NavigationSignature: string?,
    TabDisabled: {[number]: boolean}, PersistenceError: boolean?, ExternalDestroy: boolean?,
    SavedPosition: {X: number, Y: number}?, DragTarget: any, SliderDrag: any, TogglePressed: any,
    PageTask: any, VisibilityTask: any, MinimizeTask: any, SaveTask: any,
    MinimizeGeneration: number?, VisibilityGeneration: number?,
    Preview: {[string]: any}, PreviewDefaults: {[string]: any},
    PreviewControls: {[string]: any}, PreviewRules: {[string]: any},
    RefreshNavigation: any, RefreshNavigationLabel: any,
    RefreshSettings: any, RefreshToasts: any, RefreshPreview: any,
    DrawEspPreview: any, OpenConfig: any,
    SetMinimized: any, SettleVisibility: any,
    UpdateBinding: any, UnbindHotkey: any, ShortcutHeld: boolean?,
    KeyCapture: any, OnKeyBegan: any, OnKeyEnded: any, OnKeyFocusLost: any, CloseEditor: any,
    UpdateSlider: any, EndSlider: any, GroupFor: any, Relayout: any,
}
local state: RuntimeState = { Hidden = false, CapturingKey = false, Dirty = false, Controls = {},
    Groups = {}, Refreshers = {}, Toasts = {}, ToastIds = {}, Generation = 0, TabDisabled = {},
    PageNames={"Main","Player","Settings","Visuals","Automation"},
    Preview={}, PreviewDefaults={}, PreviewControls={}, PreviewRules={} }
local function validateSetting(key: string, value: any): any
    local rule = numberRules[key]
    if rule then
        if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return nil end
        return math.clamp(math.floor(value / rule[3] + 0.5) * rule[3], rule[1], rule[2])
    elseif key == "Accent" then return PALETTES[value] and value or nil
    elseif key == "ToggleMode" then
        if value == "Toggle" or value == "Hold" then return value end
    elseif key == "ToggleKey" then
        if type(value) ~= "string" or value == "Unknown" or value == "Escape" then return nil end
        local ok, keyCode = pcall(function() return Enum.KeyCode[value] end)
        return ok and keyCode and value or nil
    elseif type(DEFAULTS[key]) == "boolean" and type(value) == "boolean" then return value end
    return nil
end
if type(isfile) == "function" and type(readfile) == "function" then
    local ok, saved = pcall(function()
        if isfile(CONFIG.SettingsPath) then return HttpService:JSONDecode(readfile(CONFIG.SettingsPath)) end
        return nil
    end)
    if ok and type(saved) == "table" then
        for key, value in pairs(saved) do
            local checked = validateSetting(key, value)
            if checked ~= nil then preferences[key] = checked end
        end
        if preferences.RememberPosition and type(saved.Position) == "table" then
            local x, y = saved.Position.X, saved.Position.Y
            if type(x) == "number" and type(y) == "number" and x == x and y == y
                and math.abs(x) < 100000 and math.abs(y) < 100000 then state.SavedPosition = saved.Position end
        end
    end
end
local connections, activeTweens, ownedConnections, pendingTasks = {}, {}, {}, {}
local alive = true
local function connect(signal, callback, owner)
    local connection = signal:Connect(callback)
    connections[connection] = true
    if owner then
        ownedConnections[owner] = ownedConnections[owner] or {}
        ownedConnections[owner][connection] = true
    end
    return connection
end
local function disconnect(connection)
    if connection then connection:Disconnect(); connections[connection] = nil end
end
local function releaseTree(root)
    local objects = root:GetDescendants()
    table.insert(objects, root)
    for _, object in ipairs(objects) do
        for connection in pairs(ownedConnections[object] or {}) do disconnect(connection) end
        ownedConnections[object] = nil
        if activeTweens[object] then activeTweens[object]:Cancel(); activeTweens[object] = nil end
    end
end
local function cancelTask(ticket)
    local thread = ticket and pendingTasks[ticket]
    if thread then
        pendingTasks[ticket] = nil
        if thread ~= coroutine.running() then pcall(task.cancel, thread) end
    end
end
local function cancelControlDrag(handle)
    local active=state.SliderDrag
    if active and (handle==nil or active.Handle==handle) then
        state.SliderDrag=nil
        if active.Cancel then active.Cancel() end
    end
end
local function schedule(seconds, callback)
    local ticket = {}
    pendingTasks[ticket] = task.delay(seconds, function()
        pendingTasks[ticket] = nil
        if alive then callback() end
    end)
    return ticket
end

local function create(class, properties, parent)
    local object = Instance.new(class)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    object.Parent = parent
    return object
end

local rgb = Color3.fromRGB
local WHITE = rgb(255, 255, 255)
local INK = rgb(22, 67, 90)
local MUTED = rgb(69, 111, 130)

local function round(object, radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius) }, object)
end

local function stroke(object, color, transparency, thickness)
    return create("UIStroke", {
        Color = color or WHITE, Transparency = transparency or 0,
        Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, object)
end

local function gradient(object, stops, rotation, transparency)
    local keys = {}
    for _, stop in ipairs(stops) do
        table.insert(keys, ColorSequenceKeypoint.new(stop[1], stop[2]))
    end
    local properties = { Color = ColorSequence.new(keys), Rotation = rotation or 90 }
    if transparency then
        local alpha = {}
        for _, stop in ipairs(transparency) do
            table.insert(alpha, NumberSequenceKeypoint.new(stop[1], stop[2]))
        end
        properties.Transparency = NumberSequence.new(alpha)
    end
    return create("UIGradient", properties, object)
end

local function frame(parent, name, x, y, w, h, color, transparency, radius)
    local object = create("Frame", {
        Name = name, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
        BackgroundColor3 = color or WHITE, BackgroundTransparency = transparency or 0,
        BorderSizePixel = 0,
    }, parent)
    if radius then round(object, radius) end
    return object
end

local function label(parent, name, text, x, y, w, h, size, color, bold)
    return create("TextLabel", {
        Name = name, Text = text, Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(w, h), BackgroundTransparency = 1,
        BorderSizePixel = 0, Font = bold and Enum.Font.SourceSansSemibold or Enum.Font.SourceSans,
        TextSize = size, TextColor3 = color or INK,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
end

local function tween(object, properties, duration)
    if not alive then return end
    if activeTweens[object] then activeTweens[object]:Cancel() end
    if not preferences.Animations then
        activeTweens[object] = nil
        for key, value in pairs(properties) do object[key] = value end
        return
    end
    local animation = TweenService:Create(object,
        TweenInfo.new(duration or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties)
    activeTweens[object] = animation
    animation:Play()
    return animation
end

local function line(parent, x, y, width, angle, color, thickness)
    local object = frame(parent, "Line", x, y, width, thickness or 2, color or WHITE)
    object.AnchorPoint = Vector2.new(0.5, 0.5)
    object.Rotation = angle
    round(object, 2)
    return object
end

local function icon(parent, kind, x, y, size, color)
    local root = frame(parent, "Icon_" .. kind, x, y, size, size, WHITE, 1)
    local scale = size / 24
    local function l(px, py, length, angle, thickness)
        return line(root, px * scale, py * scale, length * scale, angle, color, (thickness or 2) * scale)
    end
    if kind == "home" then
        l(7, 9, 13, -42); l(17, 9, 13, 42)
        l(5, 16, 10, 90); l(19, 16, 10, 90); l(12, 21, 15, 0)
        l(12, 17, 7, 90)
    elseif kind == "arrow" then
        l(11, 12, 16, 0); l(16, 8, 11, 45); l(16, 16, 11, -45)
    elseif kind == "back" then
        l(13, 12, 16, 0); l(8, 8, 11, -45); l(8, 16, 11, 45)
    elseif kind == "down" then
        l(8,10,11,45); l(16,10,11,-45)
    elseif kind == "check" then
        l(8,14,8,45); l(15,12,14,-45)
    elseif kind == "grid" then
        for row = 0, 1 do
            for col = 0, 1 do
                frame(root, "Tile", (3 + col * 11) * scale, (3 + row * 11) * scale,
                    7 * scale, 7 * scale, color, 0.04, 1.5 * scale)
            end
        end
    elseif kind == "person" then
        frame(root,"Head",8*scale,2*scale,8*scale,8*scale,color,0,5*scale)
        frame(root,"Shoulders",3*scale,12*scale,18*scale,10*scale,color,0,6*scale)
    elseif kind == "eye" then
        local eye=frame(root,"Eye",2*scale,6*scale,20*scale,12*scale,WHITE,1,8*scale)
        stroke(eye,color,0,2*scale)
        frame(root,"Pupil",9*scale,9*scale,6*scale,6*scale,color,0,3*scale)
    elseif kind == "bolt" then
        l(12,7,13,-58,3);l(12,12,10,-10,3);l(12,17,13,-58,3)
    elseif kind == "close" then
        l(12, 12, 15, 45); l(12, 12, 15, -45)
    elseif kind == "minus" then
        l(12, 15, 13, 0)
    elseif kind == "restore" then
        local box = frame(root, "Box", 6 * scale, 6 * scale, 12 * scale, 12 * scale, WHITE, 1, 1)
        stroke(box, color, 0, 1.5 * scale)
    elseif kind == "gear" then
        local ring = frame(root, "GearRing", 7*scale, 7*scale, 10*scale, 10*scale, WHITE, 1, 8*scale)
        stroke(ring, color, 0, 2*scale)
        for angle = 0, 315, 45 do
            local rad = math.rad(angle)
            l(12 + math.cos(rad)*8, 12 + math.sin(rad)*8, 5, angle, 3)
        end
    end
    return root
end

local function gloss(parent, x, y, w, h, radius)
    local shine = frame(parent, "GlassReflection", x, y, w, h, WHITE, 0, radius)
    gradient(shine, { {0, WHITE}, {1, WHITE} }, 90, { {0, 0.23}, {0.8, 0.7}, {1, 0.94} })
    return shine
end

local function orb(parent, name, x, y, diameter, green, kind)
    local rim = frame(parent, name, x, y, diameter, diameter, WHITE, 0, diameter / 2)
    gradient(rim, { {0, rgb(250,255,255)}, {0.48, rgb(88,156,173)}, {1, rgb(238,255,255)} })
    stroke(rim, rgb(30,99,137), 0.17, 1)
    local ball = frame(rim, "Orb", 3, 3, diameter - 6, diameter - 6, WHITE, 0, diameter)
    gradient(ball, green and {
        {0, rgb(200,255,125)}, {0.46, rgb(74,170,18)}, {0.5, rgb(35,132,12)}, {1, rgb(155,246,57)},
    } or {
        {0, rgb(145,232,255)}, {0.46, rgb(19,143,210)}, {0.5, rgb(8,96,178)}, {1, rgb(61,221,245)},
    })
    gloss(ball, 3, 2, diameter - 12, (diameter - 6) * 0.47, diameter)
    if kind then
        icon(ball, kind, (diameter - 6) * 0.25, (diameter - 6) * 0.25,
            (diameter - 6) * 0.5, WHITE)
    else
        local leaf = frame(ball, "Leaf", diameter * 0.28, diameter * 0.31,
            diameter * 0.37, diameter * 0.23, rgb(172,245,63), 0, diameter)
        leaf.Rotation = -33
        gradient(leaf, {{0, rgb(237,255,153)}, {1, rgb(64,172,18)}})
    end
    return rim
end

local function button(parent, name, text, x, y, w, h, green, symbol)
    local object = create("TextButton", {
        Name = name, Text = "", Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
        BackgroundColor3 = WHITE, BorderSizePixel = 0, AutoButtonColor = false,
        Selectable = true,
    }, parent)
    round(object, 8)
    stroke(object, green and rgb(61,126,16) or rgb(24,100,151), 0.04, 1)
    gradient(object, green and {
        {0, rgb(195,247,126)}, {0.47, rgb(121,201,54)}, {0.5, rgb(77,162,20)}, {1, rgb(133,217,47)},
    } or {
        {0, rgb(166,231,255)}, {0.47, rgb(73,176,225)}, {0.5, rgb(20,133,197)}, {1, rgb(64,187,233)},
    })
    local shine = gloss(object, 2, 2, w - 4, h * 0.46, 7)
    local textLabel = label(object, "Caption", text, symbol and 15 or 0, 0, symbol and w - 48 or w, h, 19, WHITE, true)
    if not symbol then textLabel.TextXAlignment=Enum.TextXAlignment.Center end
    textLabel.TextStrokeColor3 = green and rgb(40,98,3) or rgb(4,78,127)
    textLabel.TextStrokeTransparency = 0.75
    if symbol then icon(object, symbol, w - 33, (h - 20) / 2, 20, WHITE) end
    local hover = frame(object, "HoverGlow", 0, 0, w, h, WHITE, 1, 8)
    connect(object.MouseEnter, function() if object.Active then tween(hover, { BackgroundTransparency = 0.84 }) end end, object)
    connect(object.MouseLeave, function() tween(hover, { BackgroundTransparency = 1 }) end, object)
    connect(object.MouseButton1Down, function() if object.Active then tween(shine, { BackgroundTransparency = 0.58 }, 0.08) end end, object)
    connect(object.MouseButton1Up, function() tween(shine, { BackgroundTransparency = 0 }, 0.12) end, object)
    object.Active = true
    return object
end

local host
if type(gethui) == "function" then
    local ok, container = pcall(gethui)
    if ok then host = container end
end
if not host then
    local player = Players.LocalPlayer
    assert(player, "Aero must run in a Roblox client, after Potassium is attached.")
    host = player:WaitForChild("PlayerGui")
end

local gui = create("ScreenGui", {
    Name = "AeroInterface", ResetOnSpawn = false, IgnoreGuiInset = true,
    DisplayOrder = 96, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, host)
-- Only replace our own GUI, never clear CoreGui or other libraries' drawings.
for _, child in ipairs(host:GetChildren()) do
    if child ~= gui and child.Name == "AeroInterface" and child:GetAttribute("AeroOwned") then child:Destroy() end
end
gui:SetAttribute("AeroOwned", true)

local W, H = CONFIG.Width, CONFIG.Height
-- A transparent anchor keeps the title bar stationary while minimizing.
local anchor = frame(gui, "WindowAnchor", 0, 0, W, H, WHITE, 1)
local uiScale = create("UIScale", { Scale = 1 }, anchor)
local visibilityHost=frame(anchor,"VisibilityHost",W/2,H/2,W+48,H+48,WHITE,1)
visibilityHost.AnchorPoint=Vector2.new(0.5,0.5)
local visibilityOffset=frame(visibilityHost,"VisibilityOffset",0,0,W+48,H+48,WHITE,1)
-- Static texture bounds include the shadow; minimizing changes the pivot, not the texture size.
local visibilityGroup=create("CanvasGroup",{Name="WindowVisibility",Size=UDim2.fromScale(1,1),
    BackgroundTransparency=1,GroupTransparency=0},visibilityOffset)
local window = frame(visibilityGroup, "Window", 24, 24, W, H, WHITE, 1)
for index = 1, 5 do
    local spread = index * 3
    frame(window, "Shadow" .. index, -spread, -spread + 8,
        W + spread * 2, H + spread * 2, rgb(3,34,54), 0.95, 18 + spread)
end
local shell = frame(window, "GlassShell", 0, 0, W, H, WHITE, 0.12, 15)
shell.ClipsDescendants=true
gradient(shell, {
    {0, rgb(198,239,251)}, {0.12, rgb(107,178,203)},
    {0.5, rgb(197,237,242)}, {1, rgb(104,179,190)},
}, 72)
stroke(shell, rgb(18,76,103), 0.05, 1)
local innerRim = frame(shell, "InnerRim", 2, 2, W - 4, H - 4, WHITE, 1, 13)
stroke(innerRim, WHITE, 0.2, 1)
local titlebar = frame(shell, "Titlebar", 1, 1, W - 2, 41, WHITE, 1, 14)
gloss(titlebar, 2, 1, W - 6, 20, 12)
orb(titlebar, "AppOrb", 11, 6, 28, false)
local titleText = label(titlebar, "WindowTitle", CONFIG.Title .. "  /  Control panel", 48, 0, 470, 40, 17, rgb(18,58,79), true)
titleText.TextStrokeColor3 = WHITE
titleText.TextStrokeTransparency = 0.72

-- The drag surface deliberately stops before the window controls.
local dragSurface = create("TextButton", {
    Name = "DragHandle", Text = "", AutoButtonColor = false, Active = true, Modal = true,
    BackgroundTransparency = 1, Size = UDim2.fromOffset(W - 110, 41),
}, titlebar)

local minimize = button(titlebar, "Minimize", "", W - 96, 5, 38, 28, false)
icon(minimize, "minus", 9, 2, 20, WHITE)
local restoreIcon=icon(minimize,"restore",9,2,20,WHITE)
restoreIcon.Visible=false
local close = button(titlebar, "Close", "", W - 53, 5, 40, 28, false)
local closeGradient = close:FindFirstChildOfClass("UIGradient")
closeGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, rgb(255,185,151)),
    ColorSequenceKeypoint.new(0.48, rgb(224,102,71)),
    ColorSequenceKeypoint.new(0.5, rgb(180,53,31)),
    ColorSequenceKeypoint.new(1, rgb(237,132,82)),
})
icon(close, "close", 10, 3, 20, WHITE)

local content = create("CanvasGroup",{Name="Content",Position=UDim2.fromOffset(0,42),
    Size=UDim2.fromOffset(W,H-42),BackgroundTransparency=1,GroupTransparency=0},shell)
local paper = frame(content, "FrostedCanvas", 10, 0, W - 20, H - 52, WHITE, 0.07, 9)
gradient(paper, {{0, rgb(235,251,255)}, {0.64, rgb(219,242,245)}, {1, rgb(198,230,229)}})
stroke(paper, WHITE, 0.06, 1)

local tabs = frame(content, "Navigation", 26, 13, W - 52, 46, WHITE, 1)
local tabButtons = {}
for slot,item in ipairs({{"Overview","home",1},{"Player","person",2},{"Visuals","eye",4},{"Automation","bolt",5},{"Settings","gear",3}}) do
    local index=item[3]
    local tab=create("TextButton",{Name="Tab"..index,Text="",BackgroundTransparency=1,
        BorderSizePixel=0,AutoButtonColor=false,Active=true,Selectable=true,
        Position=UDim2.fromOffset((slot-1)*78,-2),Size=UDim2.fromOffset(64,48)},tabs)
    local visual=frame(tab,"IconVisual",0,-10,64,68,WHITE,1)
    -- An offset pivot moves the orb through a tiny GPU-transformed arc.
    -- Its layout position stays fixed instead of stepping between rounded pixels.
    local floatLayer=frame(visual,"FloatLayer",-32,33,256,256,WHITE,1)
    floatLayer.AnchorPoint=Vector2.new(0.5,0.5)
    local tabOrb=orb(floatLayer,"TabOrb",10,12,44,false,item[2])
    tabOrb.AnchorPoint=Vector2.new(0.5,0.5);tabOrb.Position=UDim2.fromOffset(192,128)
    local iconScale=create("UIScale",{Scale=1},tabOrb)
    local alphaObjects={}
    for _,object in ipairs(visual:GetDescendants()) do
        local property=object:IsA("UIStroke") and "Transparency" or object:IsA("GuiObject") and "BackgroundTransparency"
        if property then table.insert(alphaObjects,{Object=object,Property=property,Base=object[property]}) end
    end
    local ball=tabOrb.Orb
    tabButtons[index] = { Button=tab, Visual=visual, Orb=tabOrb, IconScale=iconScale,
        FloatLayer=floatLayer,AlphaObjects=alphaObjects,DefaultIcon=ball:FindFirstChild("Icon_"..item[2]) }
end
do
    -- Lucide sprites from https://github.com/latte-soft/lucide-roblox/blob/master/tarmac-manifest.toml
    -- Equivalent names from https://github.com/iconify/icon-sets/blob/master/json/lucide.json
    --[=[
# MIT License

Copyright (c) 2023 Latte Softworks <https://latte.to>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

# Lucide License (ISC)

Lucide Icons (this package's icon sources) are licensed under ISC License. You can view it online directly at <https://lucide.dev/license>.

## ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022.

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    ]=]
    local sheets={16898612629,16898612819,16898613044,16898613353,16898613509,16898613613,16898613699,16898613777,16898613869}
    -- Icon name to spritesheet index and the top-left pixel of its 48px cell.
    local icons={
        ["a-arrow-down"]={1,771,0},
        ["a-arrow-up"]={1,0,771},
        ["a-large-small"]={1,771,257},
        ["accessibility"]={1,257,771},
        ["activity"]={1,514,771},
        ["activity-square"]={1,771,514},
        ["air-vent"]={1,820,0},
        ["airplay"]={1,771,49},
        ["alarm-check"]={1,49,771},
        ["alarm-clock"]={1,257,820},
        ["alarm-clock-check"]={1,0,820},
        ["alarm-clock-minus"]={1,820,257},
        ["alarm-clock-off"]={1,771,306},
        ["alarm-clock-plus"]={1,306,771},
        ["alarm-minus"]={1,820,514},
        ["alarm-plus"]={1,771,563},
        ["alarm-smoke"]={1,563,771},
        ["album"]={1,514,820},
        ["alert-circle"]={1,869,0},
        ["alert-octagon"]={1,820,49},
        ["alert-triangle"]={1,771,98},
        ["align-center"]={1,0,869},
        ["align-center-horizontal"]={1,98,771},
        ["align-center-vertical"]={1,49,820},
        ["align-end-horizontal"]={1,869,257},
        ["align-end-vertical"]={1,820,306},
        ["align-horizonal-distribute-center"]={1,771,355},
        ["align-horizonal-distribute-end"]={1,355,771},
        ["align-horizonal-distribute-start"]={1,306,820},
        ["align-horizontal-distribute-center"]={1,771,355},
        ["align-horizontal-distribute-end"]={1,355,771},
        ["align-horizontal-distribute-start"]={1,306,820},
        ["align-horizontal-justify-center"]={1,257,869},
        ["align-horizontal-justify-end"]={1,869,514},
        ["align-horizontal-justify-start"]={1,820,563},
        ["align-horizontal-space-around"]={1,771,612},
        ["align-horizontal-space-between"]={1,612,771},
        ["align-justify"]={1,563,820},
        ["align-left"]={1,514,869},
        ["align-right"]={1,918,0},
        ["align-start-horizontal"]={1,869,49},
        ["align-start-vertical"]={1,820,98},
        ["align-vertical-distribute-center"]={1,771,147},
        ["align-vertical-distribute-end"]={1,147,771},
        ["align-vertical-distribute-start"]={1,98,820},
        ["align-vertical-justify-center"]={1,49,869},
        ["align-vertical-justify-end"]={1,0,918},
        ["align-vertical-justify-start"]={1,918,257},
        ["align-vertical-space-around"]={1,869,306},
        ["align-vertical-space-between"]={1,820,355},
        ["ambulance"]={1,771,404},
        ["ampersand"]={1,404,771},
        ["ampersands"]={1,355,820},
        ["anchor"]={1,306,869},
        ["angry"]={1,257,918},
        ["annoyed"]={1,918,514},
        ["antenna"]={1,869,563},
        ["anvil"]={1,820,612},
        ["aperture"]={1,771,661},
        ["app-window"]={1,612,820},
        ["app-window-mac"]={1,661,771},
        ["apple"]={1,563,869},
        ["archive"]={1,918,49},
        ["archive-arrow-up"]={1,514,918},
        ["archive-restore"]={1,514,918},
        ["archive-x"]={1,967,0},
        ["area-chart"]={1,869,98},
        ["armchair"]={1,820,147},
        ["arrow-big-down"]={1,196,771},
        ["arrow-big-down-dash"]={1,771,196},
        ["arrow-big-left"]={1,98,869},
        ["arrow-big-left-dash"]={1,147,820},
        ["arrow-big-right"]={1,0,967},
        ["arrow-big-right-dash"]={1,49,918},
        ["arrow-big-up"]={1,918,306},
        ["arrow-big-up-dash"]={1,967,257},
        ["arrow-down"]={1,967,49},
        ["arrow-down-0-1"]={1,869,355},
        ["arrow-down-01"]={1,869,355},
        ["arrow-down-1-0"]={1,820,404},
        ["arrow-down-10"]={1,820,404},
        ["arrow-down-a-z"]={1,771,453},
        ["arrow-down-az"]={1,771,453},
        ["arrow-down-circle"]={1,453,771},
        ["arrow-down-from-line"]={1,404,820},
        ["arrow-down-left"]={1,257,967},
        ["arrow-down-left-from-circle"]={1,355,869},
        ["arrow-down-left-square"]={1,306,918},
        ["arrow-down-narrow-wide"]={1,967,514},
        ["arrow-down-right"]={1,820,661},
        ["arrow-down-right-from-circle"]={1,918,563},
        ["arrow-down-right-square"]={1,869,612},
        ["arrow-down-square"]={1,771,710},
        ["arrow-down-to-dot"]={1,710,771},
        ["arrow-down-to-line"]={1,661,820},
        ["arrow-down-up"]={1,612,869},
        ["arrow-down-wide-narrow"]={1,563,918},
        ["arrow-down-z-a"]={1,514,967},
        ["arrow-down-za"]={1,514,967},
        ["arrow-left"]={1,98,918},
        ["arrow-left-circle"]={1,918,98},
        ["arrow-left-from-line"]={1,869,147},
        ["arrow-left-right"]={1,820,196},
        ["arrow-left-square"]={1,196,820},
        ["arrow-left-to-line"]={1,147,869},
        ["arrow-right"]={1,453,820},
        ["arrow-right-circle"]={1,49,967},
        ["arrow-right-from-line"]={1,967,306},
        ["arrow-right-left"]={1,918,355},
        ["arrow-right-square"]={1,869,404},
        ["arrow-right-to-line"]={1,820,453},
        ["arrow-up"]={1,967,355},
        ["arrow-up-0-1"]={1,404,869},
        ["arrow-up-01"]={1,404,869},
        ["arrow-up-1-0"]={1,355,918},
        ["arrow-up-10"]={1,355,918},
        ["arrow-up-a-z"]={1,306,967},
        ["arrow-up-az"]={1,306,967},
        ["arrow-up-circle"]={1,967,563},
        ["arrow-up-down"]={1,918,612},
        ["arrow-up-from-dot"]={1,869,661},
        ["arrow-up-from-line"]={1,820,710},
        ["arrow-up-left"]={1,661,869},
        ["arrow-up-left-from-circle"]={1,771,759},
        ["arrow-up-left-square"]={1,710,820},
        ["arrow-up-narrow-wide"]={1,612,918},
        ["arrow-up-right"]={1,918,147},
        ["arrow-up-right-from-circle"]={1,563,967},
        ["arrow-up-right-square"]={1,967,98},
        ["arrow-up-square"]={1,869,196},
        ["arrow-up-to-line"]={1,196,869},
        ["arrow-up-wide-narrow"]={1,147,918},
        ["arrow-up-z-a"]={1,98,967},
        ["arrow-up-za"]={1,98,967},
        ["arrows-up-from-line"]={1,918,404},
        ["asterisk"]={1,869,453},
        ["asterisk-square"]={8,710,771},
        ["at-sign"]={1,453,869},
        ["atom"]={1,404,918},
        ["audio-lines"]={1,355,967},
        ["audio-waveform"]={1,967,612},
        ["award"]={1,918,661},
        ["axe"]={1,869,710},
        ["axis-3-d"]={1,820,759},
        ["axis-3d"]={1,820,759},
        ["baby"]={1,771,808},
        ["backpack"]={1,710,869},
        ["badge"]={1,661,967},
        ["badge-alert"]={1,661,918},
        ["badge-cent"]={1,612,967},
        ["badge-check"]={1,967,147},
        ["badge-dollar-sign"]={1,918,196},
        ["badge-euro"]={1,196,918},
        ["badge-exclamation-point"]={1,661,918},
        ["badge-help"]={1,147,967},
        ["badge-indian-rupee"]={1,967,404},
        ["badge-info"]={1,918,453},
        ["badge-japanese-yen"]={1,453,918},
        ["badge-minus"]={1,404,967},
        ["badge-percent"]={1,967,661},
        ["badge-plus"]={1,918,710},
        ["badge-pound-sterling"]={1,869,759},
        ["badge-question-mark"]={1,147,967},
        ["badge-russian-ruble"]={1,820,808},
        ["badge-swiss-franc"]={1,771,857},
        ["badge-x"]={1,710,918},
        ["baggage-claim"]={1,967,196},
        ["ban"]={1,196,967},
        ["banana"]={1,967,453},
        ["banknote"]={1,453,967},
        ["bar-chart"]={1,967,759},
        ["bar-chart-2"]={1,967,710},
        ["bar-chart-3"]={1,918,759},
        ["bar-chart-4"]={1,869,808},
        ["bar-chart-big"]={1,820,857},
        ["bar-chart-horizontal"]={1,710,967},
        ["bar-chart-horizontal-big"]={1,771,906},
        ["barcode"]={1,918,808},
        ["baseline"]={1,869,857},
        ["bath"]={1,820,906},
        ["battery"]={1,967,857},
        ["battery-charging"]={1,771,955},
        ["battery-exclamation-point"]={1,820,955},
        ["battery-full"]={1,967,808},
        ["battery-low"]={1,918,857},
        ["battery-medium"]={1,869,906},
        ["battery-warning"]={1,820,955},
        ["beaker"]={1,918,906},
        ["bean"]={1,967,906},
        ["bean-off"]={1,869,955},
        ["bed"]={2,771,0},
        ["bed-double"]={1,918,955},
        ["bed-single"]={1,967,955},
        ["beef"]={2,0,771},
        ["beer"]={2,257,771},
        ["beer-off"]={2,771,257},
        ["bell"]={2,820,257},
        ["bell-dot"]={2,771,514},
        ["bell-electric"]={2,514,771},
        ["bell-minus"]={2,820,0},
        ["bell-off"]={2,771,49},
        ["bell-plus"]={2,49,771},
        ["bell-ring"]={2,0,820},
        ["between-horizonal-end"]={2,771,306},
        ["between-horizonal-start"]={2,306,771},
        ["between-horizontal-end"]={2,771,306},
        ["between-horizontal-start"]={2,306,771},
        ["between-vertical-end"]={2,257,820},
        ["between-vertical-start"]={2,820,514},
        ["bike"]={2,771,563},
        ["binary"]={2,563,771},
        ["biohazard"]={2,514,820},
        ["bird"]={2,869,0},
        ["bitcoin"]={2,820,49},
        ["blend"]={2,771,98},
        ["blinds"]={2,98,771},
        ["blocks"]={2,49,820},
        ["bluetooth"]={2,771,355},
        ["bluetooth-connected"]={2,0,869},
        ["bluetooth-off"]={2,869,257},
        ["bluetooth-searching"]={2,820,306},
        ["bold"]={2,355,771},
        ["bolt"]={2,306,820},
        ["bomb"]={2,257,869},
        ["bone"]={2,869,514},
        ["book"]={2,820,612},
        ["book-a"]={2,820,563},
        ["book-audio"]={2,771,612},
        ["book-check"]={2,612,771},
        ["book-copy"]={2,563,820},
        ["book-dashed"]={2,514,869},
        ["book-down"]={2,918,0},
        ["book-headphones"]={2,869,49},
        ["book-heart"]={2,820,98},
        ["book-image"]={2,771,147},
        ["book-key"]={2,147,771},
        ["book-lock"]={2,98,820},
        ["book-marked"]={2,49,869},
        ["book-minus"]={2,0,918},
        ["book-open"]={2,820,355},
        ["book-open-check"]={2,918,257},
        ["book-open-text"]={2,869,306},
        ["book-plus"]={2,771,404},
        ["book-template"]={2,514,869},
        ["book-text"]={2,404,771},
        ["book-type"]={2,355,820},
        ["book-up"]={2,257,918},
        ["book-up-2"]={2,306,869},
        ["book-user"]={2,918,514},
        ["book-x"]={2,869,563},
        ["bookmark"]={2,514,918},
        ["bookmark-check"]={2,771,661},
        ["bookmark-minus"]={2,661,771},
        ["bookmark-plus"]={2,612,820},
        ["bookmark-x"]={2,563,869},
        ["boom-box"]={2,967,0},
        ["bot"]={2,869,98},
        ["bot-message-square"]={2,918,49},
        ["box"]={2,771,196},
        ["box-select"]={2,820,147},
        ["boxes"]={2,196,771},
        ["braces"]={2,147,820},
        ["brackets"]={2,98,869},
        ["brain"]={2,967,257},
        ["brain-circuit"]={2,49,918},
        ["brain-cog"]={2,0,967},
        ["brick-wall"]={2,918,306},
        ["briefcase"]={2,771,453},
        ["briefcase-business"]={2,869,355},
        ["briefcase-medical"]={2,820,404},
        ["bring-to-front"]={2,453,771},
        ["brush"]={2,404,820},
        ["bug"]={2,257,967},
        ["bug-off"]={2,355,869},
        ["bug-play"]={2,306,918},
        ["building"]={2,918,563},
        ["building-2"]={2,967,514},
        ["building-complex"]={2,967,514},
        ["bus"]={2,820,661},
        ["bus-front"]={2,869,612},
        ["cable"]={2,710,771},
        ["cable-car"]={2,771,710},
        ["cake"]={2,612,869},
        ["cake-slice"]={2,661,820},
        ["calculator"]={2,563,918},
        ["calendar"]={2,355,918},
        ["calendar-check"]={2,967,49},
        ["calendar-check-2"]={2,514,967},
        ["calendar-clock"]={2,918,98},
        ["calendar-days"]={2,869,147},
        ["calendar-fold"]={2,820,196},
        ["calendar-heart"]={2,196,820},
        ["calendar-minus"]={2,98,918},
        ["calendar-minus-2"]={2,147,869},
        ["calendar-off"]={2,49,967},
        ["calendar-plus"]={2,918,355},
        ["calendar-plus-2"]={2,967,306},
        ["calendar-range"]={2,869,404},
        ["calendar-search"]={2,820,453},
        ["calendar-x"]={2,404,869},
        ["calendar-x-2"]={2,453,820},
        ["camera"]={2,967,563},
        ["camera-off"]={2,306,967},
        ["candlestick-chart"]={2,918,612},
        ["candy"]={2,771,759},
        ["candy-cane"]={2,869,661},
        ["candy-off"]={2,820,710},
        ["cannabis"]={2,710,820},
        ["captions"]={2,612,918},
        ["captions-off"]={2,661,869},
        ["car"]={2,918,147},
        ["car-front"]={2,563,967},
        ["car-taxi-front"]={2,967,98},
        ["caravan"]={2,869,196},
        ["carrot"]={2,196,869},
        ["case-lower"]={2,147,918},
        ["case-sensitive"]={2,98,967},
        ["case-upper"]={2,967,355},
        ["cassette-tape"]={2,918,404},
        ["cast"]={2,869,453},
        ["castle"]={2,453,869},
        ["cat"]={2,404,918},
        ["cctv"]={2,355,967},
        ["chart-no-axes-column"]={1,967,710},
        ["chart-no-axes-column-increasing"]={1,967,759},
        ["chart-no-axes-gantt"]={4,869,857},
        ["check"]={2,710,869},
        ["check-check"]={2,967,612},
        ["check-circle"]={2,869,710},
        ["check-circle-2"]={2,918,661},
        ["check-square"]={2,771,808},
        ["check-square-2"]={2,820,759},
        ["chef-hat"]={2,661,918},
        ["cherry"]={2,612,967},
        ["chevron-down"]={2,196,918},
        ["chevron-down-circle"]={2,967,147},
        ["chevron-down-square"]={2,918,196},
        ["chevron-first"]={2,147,967},
        ["chevron-last"]={2,967,404},
        ["chevron-left"]={2,404,967},
        ["chevron-left-circle"]={2,918,453},
        ["chevron-left-square"]={2,453,918},
        ["chevron-right"]={2,869,759},
        ["chevron-right-circle"]={2,967,661},
        ["chevron-right-square"]={2,918,710},
        ["chevron-up"]={2,710,918},
        ["chevron-up-circle"]={2,820,808},
        ["chevron-up-square"]={2,771,857},
        ["chevrons-down"]={2,967,196},
        ["chevrons-down-up"]={2,661,967},
        ["chevrons-left"]={2,967,453},
        ["chevrons-left-right"]={2,196,967},
        ["chevrons-right"]={2,967,710},
        ["chevrons-right-left"]={2,453,967},
        ["chevrons-up"]={2,869,808},
        ["chevrons-up-down"]={2,918,759},
        ["chrome"]={2,820,857},
        ["church"]={2,771,906},
        ["cigarette"]={2,967,759},
        ["cigarette-off"]={2,710,967},
        ["circle"]={3,771,355},
        ["circle-alert"]={2,918,808},
        ["circle-arrow-down"]={2,869,857},
        ["circle-arrow-down-left-exit"]={1,355,869},
        ["circle-arrow-down-right-exit"]={1,918,563},
        ["circle-arrow-left"]={2,820,906},
        ["circle-arrow-out-down-left"]={2,771,955},
        ["circle-arrow-out-down-right"]={2,967,808},
        ["circle-arrow-out-up-left"]={2,918,857},
        ["circle-arrow-out-up-right"]={2,869,906},
        ["circle-arrow-right"]={2,820,955},
        ["circle-arrow-up"]={2,967,857},
        ["circle-arrow-up-left-exit"]={1,771,759},
        ["circle-arrow-up-right-exit"]={1,563,967},
        ["circle-check"]={2,869,955},
        ["circle-check-big"]={2,918,906},
        ["circle-chevron-down"]={2,967,906},
        ["circle-chevron-left"]={2,918,955},
        ["circle-chevron-right"]={2,967,955},
        ["circle-chevron-up"]={3,771,0},
        ["circle-dashed"]={3,0,771},
        ["circle-divide"]={3,771,257},
        ["circle-dollar-sign"]={3,257,771},
        ["circle-dot"]={3,514,771},
        ["circle-dot-dashed"]={3,771,514},
        ["circle-ellipsis"]={3,820,0},
        ["circle-equal"]={3,771,49},
        ["circle-exclamation-point"]={1,869,0},
        ["circle-fading-plus"]={3,49,771},
        ["circle-gauge"]={3,0,820},
        ["circle-help"]={3,820,257},
        ["circle-letter-p-off"]={3,257,820},
        ["circle-minus"]={3,771,306},
        ["circle-off"]={3,306,771},
        ["circle-parking"]={3,820,514},
        ["circle-parking-off"]={3,257,820},
        ["circle-pause"]={3,771,563},
        ["circle-percent"]={3,563,771},
        ["circle-play"]={3,514,820},
        ["circle-plus"]={3,869,0},
        ["circle-power"]={3,820,49},
        ["circle-question-mark"]={3,820,257},
        ["circle-slash"]={3,98,771},
        ["circle-slash-2"]={3,771,98},
        ["circle-slashed"]={3,771,98},
        ["circle-stop"]={3,49,820},
        ["circle-user"]={3,869,257},
        ["circle-user-round"]={3,0,869},
        ["circle-x"]={3,820,306},
        ["circuit-board"]={3,355,771},
        ["citrus"]={3,306,820},
        ["clapperboard"]={3,257,869},
        ["clipboard"]={3,49,869},
        ["clipboard-check"]={3,869,514},
        ["clipboard-copy"]={3,820,563},
        ["clipboard-edit"]={3,771,612},
        ["clipboard-list"]={3,612,771},
        ["clipboard-minus"]={3,563,820},
        ["clipboard-paste"]={3,514,869},
        ["clipboard-pen"]={3,869,49},
        ["clipboard-pen-line"]={3,918,0},
        ["clipboard-plus"]={3,820,98},
        ["clipboard-signature"]={3,771,147},
        ["clipboard-type"]={3,147,771},
        ["clipboard-x"]={3,98,820},
        ["clock"]={3,771,661},
        ["clock-1"]={3,0,918},
        ["clock-10"]={3,918,257},
        ["clock-11"]={3,869,306},
        ["clock-12"]={3,820,355},
        ["clock-2"]={3,771,404},
        ["clock-3"]={3,404,771},
        ["clock-4"]={3,355,820},
        ["clock-5"]={3,306,869},
        ["clock-6"]={3,257,918},
        ["clock-7"]={3,918,514},
        ["clock-8"]={3,869,563},
        ["clock-9"]={3,820,612},
        ["cloud"]={3,918,306},
        ["cloud-cog"]={3,661,771},
        ["cloud-download"]={3,612,820},
        ["cloud-drizzle"]={3,563,869},
        ["cloud-fog"]={3,514,918},
        ["cloud-hail"]={3,967,0},
        ["cloud-lightning"]={3,918,49},
        ["cloud-moon"]={3,820,147},
        ["cloud-moon-rain"]={3,869,98},
        ["cloud-off"]={3,771,196},
        ["cloud-rain"]={3,147,820},
        ["cloud-rain-wind"]={3,196,771},
        ["cloud-snow"]={3,98,869},
        ["cloud-sun"]={3,0,967},
        ["cloud-sun-rain"]={3,49,918},
        ["cloud-upload"]={3,967,257},
        ["cloudy"]={3,869,355},
        ["clover"]={3,820,404},
        ["club"]={3,771,453},
        ["code"]={3,355,869},
        ["code-2"]={3,453,771},
        ["code-square"]={8,820,196},
        ["code-xml"]={3,404,820},
        ["codepen"]={3,306,918},
        ["codesandbox"]={3,257,967},
        ["coffee"]={3,967,514},
        ["cog"]={3,918,563},
        ["coins"]={3,869,612},
        ["columns"]={3,661,820},
        ["columns-2"]={3,820,661},
        ["columns-3"]={3,771,710},
        ["columns-4"]={3,710,771},
        ["combine"]={3,612,869},
        ["command"]={3,563,918},
        ["compass"]={3,514,967},
        ["component"]={3,967,49},
        ["computer"]={3,918,98},
        ["concierge-bell"]={3,869,147},
        ["cone"]={3,820,196},
        ["construction"]={3,196,820},
        ["contact"]={3,49,967},
        ["contact-2"]={3,147,869},
        ["contact-round"]={3,98,918},
        ["container"]={3,967,306},
        ["contrast"]={3,918,355},
        ["cookie"]={3,869,404},
        ["cooking-pot"]={3,820,453},
        ["copy"]={3,918,612},
        ["copy-check"]={3,453,820},
        ["copy-minus"]={3,404,869},
        ["copy-plus"]={3,355,918},
        ["copy-slash"]={3,306,967},
        ["copy-x"]={3,967,563},
        ["copyleft"]={3,869,661},
        ["copyright"]={3,820,710},
        ["corner-down-left"]={3,771,759},
        ["corner-down-right"]={3,710,820},
        ["corner-left-down"]={3,661,869},
        ["corner-left-up"]={3,612,918},
        ["corner-right-down"]={3,563,967},
        ["corner-right-up"]={3,967,98},
        ["corner-up-left"]={3,918,147},
        ["corner-up-right"]={3,869,196},
        ["cpu"]={3,196,869},
        ["creative-commons"]={3,147,918},
        ["credit-card"]={3,98,967},
        ["croissant"]={3,967,355},
        ["crop"]={3,918,404},
        ["cross"]={3,869,453},
        ["crosshair"]={3,453,869},
        ["crown"]={3,404,918},
        ["cuboid"]={3,355,967},
        ["cup-soda"]={3,967,612},
        ["curly-braces"]={2,147,820},
        ["currency"]={3,918,661},
        ["cylinder"]={3,869,710},
        ["database"]={3,710,869},
        ["database-backup"]={3,820,759},
        ["database-zap"]={3,771,808},
        ["delete"]={3,661,918},
        ["dessert"]={3,612,967},
        ["diameter"]={3,967,147},
        ["diamond"]={3,196,918},
        ["diamond-percent"]={3,918,196},
        ["dice-1"]={3,147,967},
        ["dice-2"]={3,967,404},
        ["dice-3"]={3,918,453},
        ["dice-4"]={3,453,918},
        ["dice-5"]={3,404,967},
        ["dice-6"]={3,967,661},
        ["dices"]={3,918,710},
        ["diff"]={3,869,759},
        ["disc"]={3,661,967},
        ["disc-2"]={3,820,808},
        ["disc-3"]={3,771,857},
        ["disc-album"]={3,710,918},
        ["divide"]={3,967,453},
        ["divide-circle"]={3,967,196},
        ["divide-square"]={3,196,967},
        ["dna"]={3,967,710},
        ["dna-off"]={3,453,967},
        ["dock"]={3,918,759},
        ["dog"]={3,869,808},
        ["dollar-sign"]={3,820,857},
        ["donut"]={3,771,906},
        ["door-closed"]={3,710,967},
        ["door-open"]={3,967,759},
        ["dot"]={3,918,808},
        ["dot-square"]={8,918,355},
        ["download"]={3,820,906},
        ["download-cloud"]={3,869,857},
        ["drafting-compass"]={3,771,955},
        ["drama"]={3,967,808},
        ["dribbble"]={3,918,857},
        ["drill"]={3,869,906},
        ["droplet"]={3,820,955},
        ["droplets"]={3,967,857},
        ["drum"]={3,918,906},
        ["drumstick"]={3,869,955},
        ["dumbbell"]={3,967,906},
        ["ear"]={3,967,955},
        ["ear-off"]={3,918,955},
        ["earth"]={4,0,771},
        ["earth-lock"]={4,771,0},
        ["eclipse"]={4,771,257},
        ["edit"]={8,710,820},
        ["edit-2"]={7,771,49},
        ["edit-3"]={7,771,514},
        ["egg"]={4,514,771},
        ["egg-fried"]={4,257,771},
        ["egg-off"]={4,771,514},
        ["ellipsis"]={4,771,49},
        ["ellipsis-vertical"]={4,820,0},
        ["equal"]={4,0,820},
        ["equal-not"]={4,49,771},
        ["equal-square"]={8,869,404},
        ["eraser"]={4,820,257},
        ["euro"]={4,771,306},
        ["expand"]={4,306,771},
        ["external-link"]={4,257,820},
        ["eye"]={4,771,563},
        ["eye-off"]={4,820,514},
        ["facebook"]={4,563,771},
        ["factory"]={4,514,820},
        ["fan"]={4,869,0},
        ["fast-forward"]={4,820,49},
        ["feather"]={4,771,98},
        ["fence"]={4,98,771},
        ["ferris-wheel"]={4,49,820},
        ["figma"]={4,0,869},
        ["file"]={4,820,661},
        ["file-archive"]={4,869,257},
        ["file-audio"]={4,771,355},
        ["file-audio-2"]={4,820,306},
        ["file-axis-3-d"]={4,355,771},
        ["file-axis-3d"]={4,355,771},
        ["file-badge"]={4,257,869},
        ["file-badge-2"]={4,306,820},
        ["file-bar-chart"]={4,820,563},
        ["file-bar-chart-2"]={4,869,514},
        ["file-box"]={4,771,612},
        ["file-chart-column"]={4,869,514},
        ["file-chart-column-increasing"]={4,820,563},
        ["file-chart-line"]={4,306,869},
        ["file-check"]={4,563,820},
        ["file-check-2"]={4,612,771},
        ["file-clock"]={4,514,869},
        ["file-code"]={4,869,49},
        ["file-code-2"]={4,918,0},
        ["file-cog"]={4,820,98},
        ["file-cog-2"]={4,820,98},
        ["file-diff"]={4,771,147},
        ["file-digit"]={4,147,771},
        ["file-down"]={4,98,820},
        ["file-edit"]={4,49,869},
        ["file-heart"]={4,0,918},
        ["file-image"]={4,918,257},
        ["file-input"]={4,869,306},
        ["file-json"]={4,771,404},
        ["file-json-2"]={4,820,355},
        ["file-key"]={4,355,820},
        ["file-key-2"]={4,404,771},
        ["file-line-chart"]={4,306,869},
        ["file-lock"]={4,918,514},
        ["file-lock-2"]={4,257,918},
        ["file-minus"]={4,820,612},
        ["file-minus-2"]={4,869,563},
        ["file-music"]={4,771,661},
        ["file-output"]={4,661,771},
        ["file-pen"]={4,563,869},
        ["file-pen-line"]={4,612,820},
        ["file-pie-chart"]={4,514,918},
        ["file-play"]={4,355,869},
        ["file-plus"]={4,918,49},
        ["file-plus-2"]={4,967,0},
        ["file-question"]={4,869,98},
        ["file-question-mark"]={4,869,98},
        ["file-scan"]={4,820,147},
        ["file-search"]={4,196,771},
        ["file-search-2"]={4,771,196},
        ["file-signature"]={4,147,820},
        ["file-sliders"]={4,98,869},
        ["file-spreadsheet"]={4,49,918},
        ["file-stack"]={4,0,967},
        ["file-symlink"]={4,967,257},
        ["file-terminal"]={4,918,306},
        ["file-text"]={4,869,355},
        ["file-type"]={4,771,453},
        ["file-type-2"]={4,820,404},
        ["file-up"]={4,453,771},
        ["file-video"]={4,355,869},
        ["file-video-2"]={4,404,820},
        ["file-video-camera"]={4,404,820},
        ["file-volume"]={4,257,967},
        ["file-volume-2"]={4,306,918},
        ["file-warning"]={4,967,514},
        ["file-x"]={4,869,612},
        ["file-x-2"]={4,918,563},
        ["files"]={4,771,710},
        ["film"]={4,710,771},
        ["filter"]={4,612,869},
        ["filter-x"]={4,661,820},
        ["fingerprint"]={4,563,918},
        ["fingerprint-pattern"]={4,563,918},
        ["fire-extinguisher"]={4,514,967},
        ["fish"]={4,869,147},
        ["fish-off"]={4,967,49},
        ["fish-symbol"]={4,918,98},
        ["flag"]={4,98,918},
        ["flag-off"]={4,820,196},
        ["flag-triangle-left"]={4,196,820},
        ["flag-triangle-right"]={4,147,869},
        ["flame"]={4,967,306},
        ["flame-kindling"]={4,49,967},
        ["flashlight"]={4,869,404},
        ["flashlight-off"]={4,918,355},
        ["flask-conical"]={4,453,820},
        ["flask-conical-off"]={4,820,453},
        ["flask-round"]={4,404,869},
        ["flip-horizontal"]={4,306,967},
        ["flip-horizontal-2"]={4,355,918},
        ["flip-vertical"]={4,918,612},
        ["flip-vertical-2"]={4,967,563},
        ["flower"]={4,820,710},
        ["flower-2"]={4,869,661},
        ["focus"]={4,771,759},
        ["fold-horizontal"]={4,710,820},
        ["fold-vertical"]={4,661,869},
        ["folder"]={4,404,967},
        ["folder-archive"]={4,612,918},
        ["folder-check"]={4,563,967},
        ["folder-clock"]={4,967,98},
        ["folder-closed"]={4,918,147},
        ["folder-cog"]={4,869,196},
        ["folder-cog-2"]={4,869,196},
        ["folder-dot"]={4,196,869},
        ["folder-down"]={4,147,918},
        ["folder-edit"]={4,98,967},
        ["folder-git"]={4,918,404},
        ["folder-git-2"]={4,967,355},
        ["folder-heart"]={4,869,453},
        ["folder-input"]={4,453,869},
        ["folder-kanban"]={4,404,918},
        ["folder-key"]={4,355,967},
        ["folder-lock"]={4,967,612},
        ["folder-minus"]={4,918,661},
        ["folder-open"]={4,820,759},
        ["folder-open-dot"]={4,869,710},
        ["folder-output"]={4,771,808},
        ["folder-pen"]={4,710,869},
        ["folder-plus"]={4,661,918},
        ["folder-root"]={4,612,967},
        ["folder-search"]={4,918,196},
        ["folder-search-2"]={4,967,147},
        ["folder-symlink"]={4,196,918},
        ["folder-sync"]={4,147,967},
        ["folder-tree"]={4,967,404},
        ["folder-up"]={4,918,453},
        ["folder-x"]={4,453,918},
        ["folders"]={4,967,661},
        ["footprints"]={4,918,710},
        ["fork-knife"]={9,869,196},
        ["fork-knife-crossed"]={9,918,147},
        ["forklift"]={4,869,759},
        ["form-input"]={4,820,808},
        ["forward"]={4,771,857},
        ["frame"]={4,710,918},
        ["framer"]={4,661,967},
        ["frown"]={4,967,196},
        ["fuel"]={4,196,967},
        ["fullscreen"]={4,967,453},
        ["function-square"]={4,453,967},
        ["gallery-horizontal"]={4,918,759},
        ["gallery-horizontal-end"]={4,967,710},
        ["gallery-thumbnails"]={4,869,808},
        ["gallery-vertical"]={4,771,906},
        ["gallery-vertical-end"]={4,820,857},
        ["gamepad"]={4,967,759},
        ["gamepad-2"]={4,710,967},
        ["gantt-chart"]={4,869,857},
        ["gantt-chart-square"]={4,918,808},
        ["gauge"]={4,771,955},
        ["gauge-circle"]={4,820,906},
        ["gavel"]={4,967,808},
        ["gem"]={4,918,857},
        ["ghost"]={4,869,906},
        ["gift"]={4,820,955},
        ["git-branch"]={4,918,906},
        ["git-branch-plus"]={4,967,857},
        ["git-commit"]={4,869,955},
        ["git-commit-horizontal"]={4,869,955},
        ["git-commit-vertical"]={4,967,906},
        ["git-compare"]={4,967,955},
        ["git-compare-arrows"]={4,918,955},
        ["git-fork"]={5,771,0},
        ["git-graph"]={5,0,771},
        ["git-merge"]={5,771,257},
        ["git-pull-request"]={5,49,771},
        ["git-pull-request-arrow"]={5,257,771},
        ["git-pull-request-closed"]={5,771,514},
        ["git-pull-request-create"]={5,820,0},
        ["git-pull-request-create-arrow"]={5,514,771},
        ["git-pull-request-draft"]={5,771,49},
        ["github"]={5,0,820},
        ["gitlab"]={5,820,257},
        ["glass-water"]={5,771,306},
        ["glasses"]={5,306,771},
        ["globe"]={5,771,563},
        ["globe-2"]={5,257,820},
        ["globe-lock"]={5,820,514},
        ["goal"]={5,563,771},
        ["grab"]={5,514,820},
        ["graduation-cap"]={5,869,0},
        ["grape"]={5,820,49},
        ["grid"]={5,98,771},
        ["grid-2-x-2"]={5,771,98},
        ["grid-2x2"]={5,771,98},
        ["grid-3-x-3"]={5,98,771},
        ["grid-3x3"]={5,98,771},
        ["grip"]={5,869,257},
        ["grip-horizontal"]={5,49,820},
        ["grip-vertical"]={5,0,869},
        ["group"]={5,820,306},
        ["guitar"]={5,771,355},
        ["half-note"]={6,355,918},
        ["ham"]={5,355,771},
        ["hammer"]={5,306,820},
        ["hand"]={5,563,820},
        ["hand-coins"]={5,257,869},
        ["hand-grab"]={5,514,820},
        ["hand-heart"]={5,869,514},
        ["hand-helping"]={5,820,563},
        ["hand-metal"]={5,771,612},
        ["hand-platter"]={5,612,771},
        ["handshake"]={5,514,869},
        ["hard-drive"]={5,820,98},
        ["hard-drive-download"]={5,918,0},
        ["hard-drive-upload"]={5,869,49},
        ["hard-hat"]={5,771,147},
        ["hash"]={5,147,771},
        ["haze"]={5,98,820},
        ["hdmi-port"]={5,49,869},
        ["heading"]={5,355,820},
        ["heading-1"]={5,0,918},
        ["heading-2"]={5,918,257},
        ["heading-3"]={5,869,306},
        ["heading-4"]={5,820,355},
        ["heading-5"]={5,771,404},
        ["heading-6"]={5,404,771},
        ["headphones"]={5,306,869},
        ["headset"]={5,257,918},
        ["heart"]={5,661,771},
        ["heart-crack"]={5,918,514},
        ["heart-handshake"]={5,869,563},
        ["heart-off"]={5,820,612},
        ["heart-pulse"]={5,771,661},
        ["heater"]={5,612,820},
        ["help-circle"]={5,563,869},
        ["helping-hand"]={5,514,918},
        ["hexagon"]={5,967,0},
        ["highlighter"]={5,918,49},
        ["history"]={5,869,98},
        ["home"]={5,820,147},
        ["hop"]={5,196,771},
        ["hop-off"]={5,771,196},
        ["hospital"]={5,147,820},
        ["hotel"]={5,98,869},
        ["hourglass"]={5,49,918},
        ["house"]={5,820,147},
        ["ice-cream"]={5,869,355},
        ["ice-cream-2"]={5,0,967},
        ["ice-cream-bowl"]={5,967,257},
        ["ice-cream-cone"]={5,918,306},
        ["image"]={5,306,918},
        ["image-down"]={5,820,404},
        ["image-minus"]={5,771,453},
        ["image-off"]={5,453,771},
        ["image-plus"]={5,404,820},
        ["image-up"]={5,355,869},
        ["images"]={5,257,967},
        ["import"]={5,967,514},
        ["inbox"]={5,918,563},
        ["indent"]={5,771,710},
        ["indent-decrease"]={5,869,612},
        ["indent-increase"]={5,820,661},
        ["indian-rupee"]={5,710,771},
        ["infinity"]={5,661,820},
        ["info"]={5,612,869},
        ["inspect"]={8,869,661},
        ["inspection-panel"]={5,563,918},
        ["instagram"]={5,514,967},
        ["italic"]={5,967,49},
        ["iteration-ccw"]={5,918,98},
        ["iteration-cw"]={5,869,147},
        ["japanese-yen"]={5,820,196},
        ["jersey-pound"]={5,820,196},
        ["joystick"]={5,196,820},
        ["kanban"]={5,49,967},
        ["kanban-square"]={5,98,918},
        ["kanban-square-dashed"]={5,147,869},
        ["key"]={5,869,404},
        ["key-round"]={5,967,306},
        ["key-square"]={5,918,355},
        ["keyboard"]={5,453,820},
        ["keyboard-music"]={5,820,453},
        ["lamp"]={5,869,661},
        ["lamp-ceiling"]={5,404,869},
        ["lamp-desk"]={5,355,918},
        ["lamp-floor"]={5,306,967},
        ["lamp-wall-down"]={5,967,563},
        ["lamp-wall-up"]={5,918,612},
        ["land-plot"]={5,820,710},
        ["landmark"]={5,771,759},
        ["languages"]={5,710,820},
        ["laptop"]={5,563,967},
        ["laptop-2"]={5,661,869},
        ["laptop-minimal"]={5,612,918},
        ["lasso"]={5,918,147},
        ["lasso-select"]={5,967,98},
        ["laugh"]={5,869,196},
        ["layers"]={5,98,967},
        ["layers-2"]={5,196,869},
        ["layers-3"]={5,147,918},
        ["layout"]={5,967,612},
        ["layout-dashboard"]={5,967,355},
        ["layout-grid"]={5,918,404},
        ["layout-list"]={5,869,453},
        ["layout-panel-left"]={5,453,869},
        ["layout-panel-top"]={5,404,918},
        ["layout-template"]={5,355,967},
        ["leaf"]={5,918,661},
        ["leafy-green"]={5,869,710},
        ["letter-b"]={2,355,771},
        ["library"]={5,710,869},
        ["library-big"]={5,820,759},
        ["library-square"]={5,771,808},
        ["life-buoy"]={5,661,918},
        ["ligature"]={5,612,967},
        ["lightbulb"]={5,918,196},
        ["lightbulb-off"]={5,967,147},
        ["line-chart"]={5,196,918},
        ["link"]={5,918,453},
        ["link-2"]={5,967,404},
        ["link-2-off"]={5,147,967},
        ["linkedin"]={5,453,918},
        ["list"]={5,869,808},
        ["list-checks"]={5,404,967},
        ["list-collapse"]={5,967,661},
        ["list-end"]={5,918,710},
        ["list-filter"]={5,869,759},
        ["list-minus"]={5,820,808},
        ["list-music"]={5,771,857},
        ["list-ordered"]={5,710,918},
        ["list-plus"]={5,661,967},
        ["list-restart"]={5,967,196},
        ["list-start"]={5,196,967},
        ["list-todo"]={5,967,453},
        ["list-tree"]={5,453,967},
        ["list-video"]={5,967,710},
        ["list-x"]={5,918,759},
        ["loader"]={5,710,967},
        ["loader-2"]={5,820,857},
        ["loader-circle"]={5,771,906},
        ["locate"]={5,869,857},
        ["locate-fixed"]={5,967,759},
        ["locate-off"]={5,918,808},
        ["lock"]={5,918,857},
        ["lock-keyhole"]={5,771,955},
        ["lock-keyhole-open"]={5,820,906},
        ["lock-open"]={5,967,808},
        ["log-in"]={5,869,906},
        ["log-out"]={5,820,955},
        ["lollipop"]={5,967,857},
        ["luggage"]={5,918,906},
        ["m-square"]={5,869,955},
        ["magnet"]={5,967,906},
        ["mail"]={6,820,0},
        ["mail-check"]={5,918,955},
        ["mail-exclamation-point"]={6,771,514},
        ["mail-minus"]={5,967,955},
        ["mail-open"]={6,771,0},
        ["mail-plus"]={6,0,771},
        ["mail-question"]={6,771,257},
        ["mail-question-mark"]={6,771,257},
        ["mail-search"]={6,257,771},
        ["mail-warning"]={6,771,514},
        ["mail-x"]={6,514,771},
        ["mailbox"]={6,771,49},
        ["mails"]={6,49,771},
        ["map"]={6,306,771},
        ["map-pin"]={6,820,257},
        ["map-pin-off"]={6,0,820},
        ["map-pinned"]={6,771,306},
        ["martini"]={6,257,820},
        ["maximize"]={6,771,563},
        ["maximize-2"]={6,820,514},
        ["medal"]={6,563,771},
        ["megaphone"]={6,869,0},
        ["megaphone-off"]={6,514,820},
        ["meh"]={6,820,49},
        ["memory-stick"]={6,771,98},
        ["menu"]={6,49,820},
        ["menu-square"]={6,98,771},
        ["merge"]={6,0,869},
        ["message-circle"]={6,563,820},
        ["message-circle-code"]={6,869,257},
        ["message-circle-dashed"]={6,820,306},
        ["message-circle-exclamation-point"]={6,771,612},
        ["message-circle-heart"]={6,771,355},
        ["message-circle-more"]={6,355,771},
        ["message-circle-off"]={6,306,820},
        ["message-circle-plus"]={6,257,869},
        ["message-circle-question"]={6,869,514},
        ["message-circle-question-mark"]={6,869,514},
        ["message-circle-reply"]={6,820,563},
        ["message-circle-warning"]={6,771,612},
        ["message-circle-x"]={6,612,771},
        ["message-square"]={6,355,820},
        ["message-square-code"]={6,514,869},
        ["message-square-dashed"]={6,918,0},
        ["message-square-diff"]={6,869,49},
        ["message-square-dot"]={6,820,98},
        ["message-square-exclamation-point"]={6,771,404},
        ["message-square-heart"]={6,771,147},
        ["message-square-more"]={6,147,771},
        ["message-square-off"]={6,98,820},
        ["message-square-plus"]={6,49,869},
        ["message-square-quote"]={6,0,918},
        ["message-square-reply"]={6,918,257},
        ["message-square-share"]={6,869,306},
        ["message-square-text"]={6,820,355},
        ["message-square-warning"]={6,771,404},
        ["message-square-x"]={6,404,771},
        ["messages-square"]={6,306,869},
        ["mic"]={6,820,612},
        ["mic-2"]={6,257,918},
        ["mic-off"]={6,918,514},
        ["mic-vocal"]={6,869,563},
        ["microscope"]={6,771,661},
        ["microwave"]={6,661,771},
        ["milestone"]={6,612,820},
        ["milk"]={6,514,918},
        ["milk-off"]={6,563,869},
        ["minimize"]={6,918,49},
        ["minimize-2"]={6,967,0},
        ["minus"]={6,771,196},
        ["minus-circle"]={6,869,98},
        ["minus-square"]={6,820,147},
        ["monitor"]={6,404,820},
        ["monitor-check"]={6,196,771},
        ["monitor-dot"]={6,147,820},
        ["monitor-down"]={6,98,869},
        ["monitor-off"]={6,49,918},
        ["monitor-pause"]={6,0,967},
        ["monitor-play"]={6,967,257},
        ["monitor-smartphone"]={6,918,306},
        ["monitor-speaker"]={6,869,355},
        ["monitor-stop"]={6,820,404},
        ["monitor-up"]={6,771,453},
        ["monitor-x"]={6,453,771},
        ["moon"]={6,306,918},
        ["moon-star"]={6,355,869},
        ["more-horizontal"]={6,257,967},
        ["more-vertical"]={6,967,514},
        ["mountain"]={6,869,612},
        ["mountain-snow"]={6,918,563},
        ["mouse"]={6,563,918},
        ["mouse-pointer"]={6,612,869},
        ["mouse-pointer-2"]={6,820,661},
        ["mouse-pointer-click"]={6,771,710},
        ["mouse-pointer-square"]={6,661,820},
        ["mouse-pointer-square-dashed"]={6,710,771},
        ["move"]={6,453,820},
        ["move-3-d"]={6,514,967},
        ["move-3d"]={6,514,967},
        ["move-diagonal"]={6,918,98},
        ["move-diagonal-2"]={6,967,49},
        ["move-down"]={6,196,820},
        ["move-down-left"]={6,869,147},
        ["move-down-right"]={6,820,196},
        ["move-horizontal"]={6,147,869},
        ["move-left"]={6,98,918},
        ["move-right"]={6,49,967},
        ["move-up"]={6,869,404},
        ["move-up-left"]={6,967,306},
        ["move-up-right"]={6,918,355},
        ["move-vertical"]={6,820,453},
        ["music"]={6,967,563},
        ["music-2"]={6,404,869},
        ["music-3"]={6,355,918},
        ["music-4"]={6,306,967},
        ["navigation"]={6,771,759},
        ["navigation-2"]={6,869,661},
        ["navigation-2-off"]={6,918,612},
        ["navigation-off"]={6,820,710},
        ["network"]={6,710,820},
        ["newspaper"]={6,661,869},
        ["nfc"]={6,612,918},
        ["notebook"]={6,869,196},
        ["notebook-pen"]={6,563,967},
        ["notebook-tabs"]={6,967,98},
        ["notebook-text"]={6,918,147},
        ["notepad-text"]={6,147,918},
        ["notepad-text-dashed"]={6,196,869},
        ["nut"]={6,967,355},
        ["nut-off"]={6,98,967},
        ["octagon"]={6,404,918},
        ["octagon-alert"]={6,918,404},
        ["octagon-exclamation-point"]={1,820,49},
        ["octagon-pause"]={6,869,453},
        ["octagon-x"]={6,453,869},
        ["option"]={6,355,967},
        ["orbit"]={6,967,612},
        ["outdent"]={6,918,661},
        ["package"]={6,918,196},
        ["package-2"]={6,869,710},
        ["package-check"]={6,820,759},
        ["package-minus"]={6,771,808},
        ["package-open"]={6,710,869},
        ["package-plus"]={6,661,918},
        ["package-search"]={6,612,967},
        ["package-x"]={6,967,147},
        ["paint-bucket"]={6,196,918},
        ["paint-roller"]={6,147,967},
        ["paintbrush"]={6,918,453},
        ["paintbrush-2"]={6,967,404},
        ["paintbrush-vertical"]={6,967,404},
        ["palette"]={6,453,918},
        ["palmtree"]={6,404,967},
        ["panel-bottom"]={6,771,857},
        ["panel-bottom-close"]={6,967,661},
        ["panel-bottom-dashed"]={6,918,710},
        ["panel-bottom-inactive"]={6,869,759},
        ["panel-bottom-open"]={6,820,808},
        ["panel-left"]={6,967,453},
        ["panel-left-close"]={6,710,918},
        ["panel-left-dashed"]={6,661,967},
        ["panel-left-inactive"]={6,967,196},
        ["panel-left-open"]={6,196,967},
        ["panel-right"]={6,820,857},
        ["panel-right-close"]={6,453,967},
        ["panel-right-dashed"]={6,967,710},
        ["panel-right-inactive"]={6,918,759},
        ["panel-right-open"]={6,869,808},
        ["panel-top"]={6,869,857},
        ["panel-top-close"]={6,771,906},
        ["panel-top-dashed"]={6,710,967},
        ["panel-top-inactive"]={6,967,759},
        ["panel-top-open"]={6,918,808},
        ["panels-left-bottom"]={6,820,906},
        ["panels-left-right"]={3,771,710},
        ["panels-right-bottom"]={6,771,955},
        ["panels-top-bottom"]={7,918,661},
        ["panels-top-left"]={6,967,808},
        ["paperclip"]={6,918,857},
        ["parentheses"]={6,869,906},
        ["parking-circle"]={6,967,857},
        ["parking-circle-off"]={6,820,955},
        ["parking-meter"]={6,918,906},
        ["parking-square"]={6,967,906},
        ["parking-square-off"]={6,869,955},
        ["party-popper"]={6,918,955},
        ["pause"]={7,0,771},
        ["pause-circle"]={6,967,955},
        ["pause-octagon"]={7,771,0},
        ["paw-print"]={7,771,257},
        ["pc-case"]={7,257,771},
        ["pen"]={7,771,49},
        ["pen-box"]={8,710,820},
        ["pen-line"]={7,771,514},
        ["pen-square"]={7,514,771},
        ["pen-tool"]={7,820,0},
        ["pencil"]={7,820,257},
        ["pencil-line"]={7,49,771},
        ["pencil-ruler"]={7,0,820},
        ["pentagon"]={7,771,306},
        ["percent"]={7,771,563},
        ["percent-circle"]={7,306,771},
        ["percent-diamond"]={7,257,820},
        ["percent-square"]={7,820,514},
        ["person-standing"]={7,563,771},
        ["phone"]={7,0,869},
        ["phone-call"]={7,514,820},
        ["phone-forwarded"]={7,869,0},
        ["phone-incoming"]={7,820,49},
        ["phone-missed"]={7,771,98},
        ["phone-off"]={7,98,771},
        ["phone-outgoing"]={7,49,820},
        ["pi"]={7,820,306},
        ["pi-square"]={7,869,257},
        ["piano"]={7,771,355},
        ["pickaxe"]={7,355,771},
        ["picture-in-picture"]={7,257,869},
        ["picture-in-picture-2"]={7,306,820},
        ["pie-chart"]={7,869,514},
        ["piggy-bank"]={7,820,563},
        ["pilcrow"]={7,612,771},
        ["pilcrow-square"]={7,771,612},
        ["pill"]={7,563,820},
        ["pin"]={7,918,0},
        ["pin-off"]={7,514,869},
        ["pipette"]={7,869,49},
        ["pizza"]={7,820,98},
        ["plane"]={7,98,820},
        ["plane-landing"]={7,771,147},
        ["plane-takeoff"]={7,147,771},
        ["play"]={7,918,257},
        ["play-circle"]={7,49,869},
        ["play-square"]={7,0,918},
        ["plug"]={7,404,771},
        ["plug-2"]={7,869,306},
        ["plug-zap"]={7,771,404},
        ["plug-zap-2"]={7,820,355},
        ["plus"]={7,257,918},
        ["plus-circle"]={7,355,820},
        ["plus-square"]={7,306,869},
        ["pocket"]={7,869,563},
        ["pocket-knife"]={7,918,514},
        ["podcast"]={7,820,612},
        ["pointer"]={7,661,771},
        ["pointer-off"]={7,771,661},
        ["popcorn"]={7,612,820},
        ["popsicle"]={7,563,869},
        ["pound-sterling"]={7,514,918},
        ["power"]={7,820,147},
        ["power-circle"]={7,967,0},
        ["power-off"]={7,918,49},
        ["power-square"]={7,869,98},
        ["presentation"]={7,771,196},
        ["printer"]={7,196,771},
        ["projector"]={7,147,820},
        ["proportions"]={7,98,869},
        ["puzzle"]={7,49,918},
        ["pyramid"]={7,0,967},
        ["qr-code"]={7,967,257},
        ["quote"]={7,918,306},
        ["rabbit"]={7,869,355},
        ["radar"]={7,820,404},
        ["radiation"]={7,771,453},
        ["radical"]={7,453,771},
        ["radio"]={7,306,918},
        ["radio-receiver"]={7,404,820},
        ["radio-tower"]={7,355,869},
        ["radius"]={7,257,967},
        ["rail-symbol"]={7,967,514},
        ["rainbow"]={7,918,563},
        ["rat"]={7,869,612},
        ["ratio"]={7,820,661},
        ["receipt"]={7,869,147},
        ["receipt-cent"]={7,771,710},
        ["receipt-euro"]={7,710,771},
        ["receipt-indian-rupee"]={7,661,820},
        ["receipt-japanese-yen"]={7,612,869},
        ["receipt-pound-sterling"]={7,563,918},
        ["receipt-russian-ruble"]={7,514,967},
        ["receipt-swiss-franc"]={7,967,49},
        ["receipt-text"]={7,918,98},
        ["rectangle-ellipsis"]={7,820,196},
        ["rectangle-horizontal"]={7,196,820},
        ["rectangle-vertical"]={7,147,869},
        ["recycle"]={7,98,918},
        ["redo"]={7,918,355},
        ["redo-2"]={7,49,967},
        ["redo-dot"]={7,967,306},
        ["refresh-ccw"]={7,820,453},
        ["refresh-ccw-dot"]={7,869,404},
        ["refresh-cw"]={7,404,869},
        ["refresh-cw-off"]={7,453,820},
        ["refrigerator"]={7,355,918},
        ["regex"]={7,306,967},
        ["remove-formatting"]={7,967,563},
        ["repeat"]={7,820,710},
        ["repeat-1"]={7,918,612},
        ["repeat-2"]={7,869,661},
        ["replace"]={7,710,820},
        ["replace-all"]={7,771,759},
        ["reply"]={7,612,918},
        ["reply-all"]={7,661,869},
        ["rewind"]={7,563,967},
        ["ribbon"]={7,967,98},
        ["rocket"]={7,918,147},
        ["rocking-chair"]={7,869,196},
        ["roller-coaster"]={7,196,869},
        ["rotate-3-d"]={7,147,918},
        ["rotate-3d"]={7,147,918},
        ["rotate-ccw"]={7,967,355},
        ["rotate-ccw-clock"]={5,869,98},
        ["rotate-ccw-square"]={7,98,967},
        ["rotate-cw"]={7,869,453},
        ["rotate-cw-square"]={7,918,404},
        ["route"]={7,404,918},
        ["route-off"]={7,453,869},
        ["router"]={7,355,967},
        ["rows"]={7,820,759},
        ["rows-2"]={7,967,612},
        ["rows-3"]={7,918,661},
        ["rows-4"]={7,869,710},
        ["rss"]={7,771,808},
        ["ruler"]={7,710,869},
        ["russian-ruble"]={7,661,918},
        ["sailboat"]={7,612,967},
        ["salad"]={7,967,147},
        ["sandwich"]={7,918,196},
        ["satellite"]={7,147,967},
        ["satellite-dish"]={7,196,918},
        ["save"]={7,918,453},
        ["save-all"]={7,967,404},
        ["scale"]={7,404,967},
        ["scale-3-d"]={7,453,918},
        ["scale-3d"]={7,453,918},
        ["scaling"]={7,967,661},
        ["scan"]={7,967,196},
        ["scan-barcode"]={7,918,710},
        ["scan-eye"]={7,869,759},
        ["scan-face"]={7,820,808},
        ["scan-line"]={7,771,857},
        ["scan-search"]={7,710,918},
        ["scan-text"]={7,661,967},
        ["scatter-chart"]={7,196,967},
        ["school"]={7,453,967},
        ["school-2"]={7,967,453},
        ["scissors"]={7,820,857},
        ["scissors-line-dashed"]={7,967,710},
        ["scissors-square"]={7,869,808},
        ["scissors-square-dashed-bottom"]={7,918,759},
        ["screen-share"]={7,710,967},
        ["screen-share-off"]={7,771,906},
        ["scroll"]={7,918,808},
        ["scroll-text"]={7,967,759},
        ["search"]={7,918,857},
        ["search-check"]={7,869,857},
        ["search-code"]={7,820,906},
        ["search-slash"]={7,771,955},
        ["search-x"]={7,967,808},
        ["send"]={7,967,857},
        ["send-horizonal"]={7,869,906},
        ["send-horizontal"]={7,869,906},
        ["send-to-back"]={7,820,955},
        ["separator-horizontal"]={7,918,906},
        ["separator-vertical"]={7,869,955},
        ["server"]={8,771,0},
        ["server-cog"]={7,967,906},
        ["server-crash"]={7,918,955},
        ["server-off"]={7,967,955},
        ["settings"]={8,771,257},
        ["settings-2"]={8,0,771},
        ["shapes"]={8,257,771},
        ["share"]={8,514,771},
        ["share-2"]={8,771,514},
        ["sheet"]={8,820,0},
        ["shell"]={8,771,49},
        ["shield"]={8,869,0},
        ["shield-alert"]={8,49,771},
        ["shield-ban"]={8,0,820},
        ["shield-check"]={8,820,257},
        ["shield-close"]={8,514,820},
        ["shield-ellipsis"]={8,771,306},
        ["shield-exclamation-point"]={8,49,771},
        ["shield-half"]={8,306,771},
        ["shield-minus"]={8,257,820},
        ["shield-off"]={8,820,514},
        ["shield-plus"]={8,771,563},
        ["shield-question"]={8,563,771},
        ["shield-question-mark"]={8,563,771},
        ["shield-x"]={8,514,820},
        ["ship"]={8,771,98},
        ["ship-wheel"]={8,820,49},
        ["shirt"]={8,98,771},
        ["shopping-bag"]={8,49,820},
        ["shopping-basket"]={8,0,869},
        ["shopping-cart"]={8,869,257},
        ["shovel"]={8,820,306},
        ["shower-head"]={8,771,355},
        ["shrink"]={8,355,771},
        ["shrub"]={8,306,820},
        ["shuffle"]={8,257,869},
        ["sidebar"]={6,967,453},
        ["sidebar-close"]={6,710,918},
        ["sidebar-open"]={6,196,967},
        ["sigma"]={8,820,563},
        ["sigma-square"]={8,869,514},
        ["signal"]={8,918,0},
        ["signal-high"]={8,771,612},
        ["signal-low"]={8,612,771},
        ["signal-medium"]={8,563,820},
        ["signal-zero"]={8,514,869},
        ["signpost"]={8,820,98},
        ["signpost-big"]={8,869,49},
        ["siren"]={8,771,147},
        ["skip-back"]={8,147,771},
        ["skip-forward"]={8,98,820},
        ["skull"]={8,49,869},
        ["slack"]={8,0,918},
        ["slash"]={8,918,257},
        ["slash-square"]={8,967,355},
        ["slice"]={8,869,306},
        ["sliders"]={8,404,771},
        ["sliders-horizontal"]={8,820,355},
        ["sliders-vertical"]={8,771,404},
        ["smartphone"]={8,257,918},
        ["smartphone-charging"]={8,355,820},
        ["smartphone-nfc"]={8,306,869},
        ["smile"]={8,869,563},
        ["smile-plus"]={8,918,514},
        ["snail"]={8,820,612},
        ["snowflake"]={8,771,661},
        ["sofa"]={8,661,771},
        ["sort-asc"]={1,612,918},
        ["sort-desc"]={1,563,918},
        ["soup"]={8,612,820},
        ["space"]={8,563,869},
        ["spade"]={8,514,918},
        ["sparkle"]={8,967,0},
        ["sparkles"]={8,918,49},
        ["speaker"]={8,869,98},
        ["speech"]={8,820,147},
        ["spell-check"]={8,196,771},
        ["spell-check-2"]={8,771,196},
        ["spline"]={8,147,820},
        ["split"]={8,0,967},
        ["split-square-horizontal"]={8,98,869},
        ["split-square-vertical"]={8,49,918},
        ["spray-can"]={8,967,257},
        ["sprout"]={8,918,306},
        ["square"]={8,869,710},
        ["square-activity"]={8,869,355},
        ["square-arrow-down"]={8,453,771},
        ["square-arrow-down-left"]={8,820,404},
        ["square-arrow-down-left-exit"]={8,355,869},
        ["square-arrow-down-right"]={8,771,453},
        ["square-arrow-down-right-exit"]={8,306,918},
        ["square-arrow-left"]={8,404,820},
        ["square-arrow-out-down-left"]={8,355,869},
        ["square-arrow-out-down-right"]={8,306,918},
        ["square-arrow-out-up-left"]={8,257,967},
        ["square-arrow-out-up-right"]={8,967,514},
        ["square-arrow-right"]={8,918,563},
        ["square-arrow-up"]={8,771,710},
        ["square-arrow-up-left"]={8,869,612},
        ["square-arrow-up-left-exit"]={8,257,967},
        ["square-arrow-up-right"]={8,820,661},
        ["square-arrow-up-right-exit"]={8,967,514},
        ["square-asterisk"]={8,710,771},
        ["square-bottom-dashed-scissors"]={8,661,820},
        ["square-centerline-dashed-horizontal"]={4,306,967},
        ["square-centerline-dashed-vertical"]={4,918,612},
        ["square-chart-gantt"]={4,918,808},
        ["square-check"]={8,563,918},
        ["square-check-big"]={8,612,869},
        ["square-chevron-down"]={8,514,967},
        ["square-chevron-left"]={8,967,49},
        ["square-chevron-right"]={8,918,98},
        ["square-chevron-up"]={8,869,147},
        ["square-code"]={8,820,196},
        ["square-dashed"]={2,820,147},
        ["square-dashed-bottom"]={8,147,869},
        ["square-dashed-bottom-code"]={8,196,820},
        ["square-dashed-kanban"]={8,98,918},
        ["square-dashed-mouse-pointer"]={8,49,967},
        ["square-dashed-text"]={9,820,49},
        ["square-divide"]={8,967,306},
        ["square-dot"]={8,918,355},
        ["square-equal"]={8,869,404},
        ["square-function"]={8,820,453},
        ["square-gantt"]={4,918,808},
        ["square-gantt-chart"]={8,453,820},
        ["square-kanban"]={8,404,869},
        ["square-kanban-dashed"]={8,98,918},
        ["square-letter-p-off"]={6,869,955},
        ["square-library"]={8,355,918},
        ["square-m"]={8,306,967},
        ["square-menu"]={8,967,563},
        ["square-minus"]={8,918,612},
        ["square-mouse-pointer"]={8,869,661},
        ["square-parking"]={8,771,759},
        ["square-parking-off"]={8,820,710},
        ["square-pen"]={8,710,820},
        ["square-percent"]={8,661,869},
        ["square-pi"]={8,612,918},
        ["square-pilcrow"]={8,563,967},
        ["square-play"]={8,967,98},
        ["square-plus"]={8,918,147},
        ["square-power"]={8,869,196},
        ["square-radical"]={8,196,869},
        ["square-scissors"]={8,147,918},
        ["square-sigma"]={8,98,967},
        ["square-slash"]={8,967,355},
        ["square-split-horizontal"]={8,918,404},
        ["square-split-vertical"]={8,869,453},
        ["square-stack"]={8,453,869},
        ["square-terminal"]={8,404,918},
        ["square-user"]={8,967,612},
        ["square-user-round"]={8,355,967},
        ["square-x"]={8,918,661},
        ["squircle"]={8,820,759},
        ["squirrel"]={8,771,808},
        ["stamp"]={8,710,869},
        ["star"]={8,967,147},
        ["star-half"]={8,661,918},
        ["star-off"]={8,612,967},
        ["stars"]={8,918,49},
        ["step-back"]={8,918,196},
        ["step-forward"]={8,196,918},
        ["stethoscope"]={8,147,967},
        ["sticker"]={8,967,404},
        ["sticky-note"]={8,918,453},
        ["stop-circle"]={8,453,918},
        ["store"]={8,404,967},
        ["stretch-horizontal"]={8,967,661},
        ["stretch-vertical"]={8,918,710},
        ["strikethrough"]={8,869,759},
        ["subscript"]={8,820,808},
        ["subtitles"]={8,771,857},
        ["sun"]={8,967,453},
        ["sun-dim"]={8,710,918},
        ["sun-medium"]={8,661,967},
        ["sun-moon"]={8,967,196},
        ["sun-snow"]={8,196,967},
        ["sunrise"]={8,453,967},
        ["sunset"]={8,967,710},
        ["superscript"]={8,918,759},
        ["swatch-book"]={8,869,808},
        ["swiss-franc"]={8,820,857},
        ["switch-camera"]={8,771,906},
        ["sword"]={8,710,967},
        ["swords"]={8,967,759},
        ["syringe"]={8,918,808},
        ["table"]={8,820,955},
        ["table-2"]={8,869,857},
        ["table-cells-merge"]={8,820,906},
        ["table-cells-split"]={8,771,955},
        ["table-columns-split"]={8,967,808},
        ["table-properties"]={8,918,857},
        ["table-rows-split"]={8,869,906},
        ["tablet"]={8,918,906},
        ["tablet-smartphone"]={8,967,857},
        ["tablets"]={8,869,955},
        ["tag"]={8,967,906},
        ["tags"]={8,918,955},
        ["tally-1"]={8,967,955},
        ["tally-2"]={9,771,0},
        ["tally-3"]={9,0,771},
        ["tally-4"]={9,771,257},
        ["tally-5"]={9,257,771},
        ["tangent"]={9,771,514},
        ["target"]={9,514,771},
        ["telescope"]={9,820,0},
        ["tent"]={9,49,771},
        ["tent-tree"]={9,771,49},
        ["terminal"]={9,820,257},
        ["terminal-square"]={9,0,820},
        ["test-tube"]={9,257,820},
        ["test-tube-2"]={9,771,306},
        ["test-tube-diagonal"]={9,306,771},
        ["test-tubes"]={9,820,514},
        ["text"]={9,771,98},
        ["text-cursor"]={9,563,771},
        ["text-cursor-input"]={9,771,563},
        ["text-quote"]={9,514,820},
        ["text-search"]={9,869,0},
        ["text-select"]={9,820,49},
        ["text-selection"]={9,820,49},
        ["theater"]={9,98,771},
        ["thermometer"]={9,869,257},
        ["thermometer-snowflake"]={9,49,820},
        ["thermometer-sun"]={9,0,869},
        ["thumbs-down"]={9,820,306},
        ["thumbs-up"]={9,771,355},
        ["ticket"]={9,612,771},
        ["ticket-check"]={9,355,771},
        ["ticket-minus"]={9,306,820},
        ["ticket-percent"]={9,257,869},
        ["ticket-plus"]={9,869,514},
        ["ticket-slash"]={9,820,563},
        ["ticket-x"]={9,771,612},
        ["timer"]={9,918,0},
        ["timer-off"]={9,563,820},
        ["timer-reset"]={9,514,869},
        ["toggle-left"]={9,869,49},
        ["toggle-right"]={9,820,98},
        ["tornado"]={9,771,147},
        ["torus"]={9,147,771},
        ["touchpad"]={9,49,869},
        ["touchpad-off"]={9,98,820},
        ["tower-control"]={9,0,918},
        ["toy-brick"]={9,918,257},
        ["tractor"]={9,869,306},
        ["traffic-cone"]={9,820,355},
        ["train"]={9,306,869},
        ["train-front"]={9,404,771},
        ["train-front-tunnel"]={9,771,404},
        ["train-track"]={9,355,820},
        ["tram-front"]={9,306,869},
        ["trash"]={9,918,514},
        ["trash-2"]={9,257,918},
        ["tree-deciduous"]={9,869,563},
        ["tree-palm"]={9,820,612},
        ["tree-pine"]={9,771,661},
        ["trees"]={9,661,771},
        ["trello"]={9,612,820},
        ["trending-down"]={9,563,869},
        ["trending-up"]={9,514,918},
        ["triangle"]={9,869,98},
        ["triangle-alert"]={9,967,0},
        ["triangle-exclamation-point"]={1,771,98},
        ["triangle-right"]={9,918,49},
        ["trophy"]={9,820,147},
        ["truck"]={9,771,196},
        ["turtle"]={9,196,771},
        ["tv"]={9,98,869},
        ["tv-2"]={9,147,820},
        ["tv-minimal"]={9,147,820},
        ["twitch"]={9,49,918},
        ["twitter"]={9,0,967},
        ["type"]={9,967,257},
        ["umbrella"]={9,869,355},
        ["umbrella-off"]={9,918,306},
        ["underline"]={9,820,404},
        ["undo"]={9,404,820},
        ["undo-2"]={9,771,453},
        ["undo-dot"]={9,453,771},
        ["unfold-horizontal"]={9,355,869},
        ["unfold-vertical"]={9,306,918},
        ["ungroup"]={9,257,967},
        ["university"]={9,967,514},
        ["unlink"]={9,869,612},
        ["unlink-2"]={9,918,563},
        ["unlock"]={9,771,710},
        ["unlock-keyhole"]={9,820,661},
        ["unplug"]={9,710,771},
        ["upload"]={9,612,869},
        ["upload-cloud"]={9,661,820},
        ["usb"]={9,563,918},
        ["user"]={9,661,869},
        ["user-2"]={9,514,967},
        ["user-check"]={9,918,98},
        ["user-check-2"]={9,967,49},
        ["user-circle"]={9,820,196},
        ["user-circle-2"]={9,869,147},
        ["user-cog"]={9,147,869},
        ["user-cog-2"]={9,196,820},
        ["user-minus"]={9,49,967},
        ["user-minus-2"]={9,98,918},
        ["user-plus"]={9,918,355},
        ["user-plus-2"]={9,967,306},
        ["user-round"]={9,967,563},
        ["user-round-check"]={9,869,404},
        ["user-round-cog"]={9,820,453},
        ["user-round-minus"]={9,453,820},
        ["user-round-plus"]={9,404,869},
        ["user-round-search"]={9,355,918},
        ["user-round-x"]={9,306,967},
        ["user-search"]={9,918,612},
        ["user-square"]={9,820,710},
        ["user-square-2"]={9,869,661},
        ["user-x"]={9,710,820},
        ["user-x-2"]={9,771,759},
        ["users"]={9,967,98},
        ["users-2"]={9,612,918},
        ["users-round"]={9,563,967},
        ["utensils"]={9,869,196},
        ["utensils-crossed"]={9,918,147},
        ["utility-pole"]={9,196,869},
        ["variable"]={9,147,918},
        ["vault"]={9,98,967},
        ["vegan"]={9,967,355},
        ["venetian-mask"]={9,918,404},
        ["verified"]={1,967,147},
        ["vibrate"]={9,453,869},
        ["vibrate-off"]={9,869,453},
        ["video"]={9,355,967},
        ["video-off"]={9,404,918},
        ["videotape"]={9,967,612},
        ["view"]={9,918,661},
        ["voicemail"]={9,869,710},
        ["volume"]={9,661,918},
        ["volume-1"]={9,820,759},
        ["volume-2"]={9,771,808},
        ["volume-x"]={9,710,869},
        ["vote"]={9,612,967},
        ["wallet"]={9,147,967},
        ["wallet-2"]={9,967,147},
        ["wallet-cards"]={9,918,196},
        ["wallet-minimal"]={9,196,918},
        ["wallpaper"]={9,967,404},
        ["wand"]={9,404,967},
        ["wand-2"]={9,918,453},
        ["wand-sparkles"]={9,453,918},
        ["warehouse"]={9,967,661},
        ["washing-machine"]={9,918,710},
        ["watch"]={9,869,759},
        ["waves"]={9,820,808},
        ["waypoints"]={9,771,857},
        ["webcam"]={9,710,918},
        ["webhook"]={9,967,196},
        ["webhook-off"]={9,661,967},
        ["weight"]={9,196,967},
        ["wheat"]={9,453,967},
        ["wheat-off"]={9,967,453},
        ["whole-word"]={9,967,710},
        ["wifi"]={9,869,808},
        ["wifi-off"]={9,918,759},
        ["wind"]={9,820,857},
        ["wine"]={9,710,967},
        ["wine-off"]={9,771,906},
        ["workflow"]={9,967,759},
        ["worm"]={9,918,808},
        ["wrap-text"]={9,869,857},
        ["wrench"]={9,820,906},
        ["x"]={9,869,906},
        ["x-circle"]={9,771,955},
        ["x-octagon"]={9,967,808},
        ["x-square"]={9,918,857},
        ["youtube"]={9,820,955},
        ["zap"]={9,918,906},
        ["zap-off"]={9,967,857},
        ["zoom-in"]={9,869,955},
        ["zoom-out"]={9,967,906},
    }
    function api.GetLucideIcons()
        local names={}
        for name in pairs(icons) do table.insert(names,name) end
        table.sort(names)
        return names
    end
    function api.SetTabIcon(first,tabName,iconName)
        if first~=api then iconName=tabName;tabName=first end
        if not alive then return false end
        local index=tonumber(tabName)
        if not index then
            if tabName=="Overview" then index=1
            elseif tabName=="Tab 2" then index=2
            else index=table.find(state.PageNames,tabName) end
        end
        local tab=index and tabButtons[index]
        if not tab then return false end
        local original=tab.DefaultIcon
        local image=tab.IconImage
        if iconName==nil then
            original.Visible=true
            if image then image.Visible=false;image.Image="" end
            return true
        end
        if type(iconName)~="string" then return false end
        local name=iconName:lower():gsub("^lucide%-","")
        local cell=icons[name]
        if not cell then return false end
        if not image then
            image=create("ImageLabel",{
                Name="LucideIcon",BackgroundTransparency=1,Active=false,
                Position=original.Position,Size=original.Size,ImageColor3=WHITE,
                ImageTransparency=state.TabDisabled[index] and 0.55 or 0,
                ImageRectSize=Vector2.new(48,48),ScaleType=Enum.ScaleType.Fit,
            },original.Parent)
            tab.IconImage=image
            connect(image:GetPropertyChangedSignal("IsLoaded"),function()
                original.Visible=image.Image=="" or not image.IsLoaded
            end,image)
        end
        image.ImageRectOffset=Vector2.new(cell[2],cell[3])
        image.Image="rbxassetid://"..sheets[cell[1]]
        image.Visible=true
        original.Visible=not image.IsLoaded
        return true
    end
end
function state.RefreshNavigation()
    local moving=preferences.Animations and not state.Hidden and not state.Minimized
    local signature=tostring(state.SelectedTab)..":"..tostring(moving)..":"..tostring(preferences.Animations)
    if state.NavigationSignature==signature then return end
    state.NavigationSignature=signature
    for index,tab in ipairs(tabButtons) do
        cancelTask(tab.FloatTask)
        if activeTweens[tab.FloatLayer] then activeTweens[tab.FloatLayer]:Cancel();activeTweens[tab.FloatLayer]=nil end
        local selected=index==state.SelectedTab
        tween(tab.IconScale,{Scale=selected and 1.25 or 1},0.22)
        if selected and moving then
            tween(tab.FloatLayer,{Rotation=-2.6},0.2)
            tab.FloatTask=schedule(0.22,function()
                if state.NavigationSignature~=signature or state.SelectedTab~=index then return end
                if activeTweens[tab.FloatLayer] then activeTweens[tab.FloatLayer]:Cancel() end
                local animation=TweenService:Create(tab.FloatLayer,
                    TweenInfo.new(1.5,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut,-1,true),
                    {Rotation=2.6})
                activeTweens[tab.FloatLayer]=animation
                animation:Play()
            end)
        else
            tween(tab.FloatLayer,{Rotation=0},0.18)
        end
    end
end
local edition = label(tabs, "Edition", "UI PREVIEW", 680, 0, 165, 40, 13, MUTED)
edition.TextXAlignment = Enum.TextXAlignment.Right
frame(content, "ToolbarDivider", 27, 66, W - 54, 1, rgb(111,165,183), 0.58)
frame(content, "ToolbarHighlight", 27, 67, W - 54, 1, WHITE, 0.08)

local pages = frame(content, "Pages", 27, 82, W - 54, 431, WHITE, 1)
local main = create("CanvasGroup", {
    Name = "MainPage", Size = UDim2.fromScale(1,1), BackgroundTransparency = 1,
    GroupTransparency = 0, Visible = true,
}, pages)
local second = create("CanvasGroup", {
    Name = "Tab2Page", Size = UDim2.fromScale(1,1), BackgroundTransparency = 1,
    GroupTransparency = 0, Visible = false,
}, pages)
local settingsPage = create("CanvasGroup", {
    Name = "SettingsPage", Size = UDim2.fromScale(1,1), BackgroundTransparency = 1,
    GroupTransparency = 0, Visible = false,
}, pages)
local visualsPage=create("CanvasGroup",{Name="VisualsPage",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,GroupTransparency=0,Visible=false},pages)
local automationPage=create("CanvasGroup",{Name="AutomationPage",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,GroupTransparency=0,Visible=false},pages)

local hero=frame(main,"Landscape",0,0,846,82,rgb(37,145,203),0,12)
hero.ClipsDescendants=true
gradient(hero,{{0,rgb(25,107,183)},{1,rgb(99,215,225)}},30)
stroke(hero,rgb(89,167,195),0.2)
local hill=frame(hero,"FallbackHill",420,45,500,120,rgb(139,206,53),0.1,120)
local asset
if type(getcustomasset) == "function" then
    local ok, result = pcall(function()
        if type(isfile) == "function" and not isfile(CONFIG.AssetPath) then return nil end
        return getcustomasset(CONFIG.AssetPath)
    end)
    if ok and type(result) == "string" and result ~= "" then asset = result end
end
if asset then create("ImageLabel",{Name="AeroWallpaper",Image=asset,Size=UDim2.fromScale(1,1),BackgroundTransparency=1,ScaleType=Enum.ScaleType.Crop},hero)
else warn("[Aero] Optional wallpaper missing.") end
local homeShade=frame(hero,"Shade",0,0,846,82,rgb(5,59,108),0)
gradient(homeShade,{{0,WHITE},{1,WHITE}},0,{{0,0.1},{0.6,0.5},{1,0.82}})
gloss(hero,2,1,842,24,10).BackgroundTransparency=0.65
label(hero,"Welcome","Overview",23,19,600,43,31,WHITE,true)
local function homeTile(name,text,detail,kind,x,color)
    local tile=button(main,name,"",x,100,272,177,false)
    tile:FindFirstChildOfClass("UICorner").CornerRadius=UDim.new(0,15)
    tile:FindFirstChildOfClass("UIGradient"):Destroy()
    gradient(tile,{{0,WHITE},{0.58,rgb(241,252,255)},{1,color}},90)
    orb(tile,"TileOrb",19,17,64,false,kind)
    label(tile,"Title",text,19,104,235,32,25,INK,true)
    label(tile,"Detail",detail,20,140,233,23,15,MUTED)
    return tile
end
local explore=homeTile("ExploreTab2","Player","Movement · Character","person",0,rgb(196,232,247))
local jumpVisuals=homeTile("OpenVisuals","Visuals","ESP · Color · Style","eye",287,rgb(217,240,192))
local jumpAutomation=homeTile("OpenAutomation","Automation","Combat · Tasks","bolt",574,rgb(226,211,246))
local configCard=frame(main,"ConfigCard",0,294,414,129,WHITE,0.1,13)
gradient(configCard,{{0,WHITE},{1,rgb(214,238,244)}})
stroke(configCard,rgb(143,190,207),0.35)
label(configCard,"Label","CONFIG",18,13,250,21,13,MUTED,true)
local presetNameLabel=label(configCard,"ConfigName","Default",17,42,258,37,27,INK,true)
local openConfig=button(configCard,"OpenConfig","Manage",294,45,101,35,false)
local selectedCard=frame(main,"SelectedCard",432,294,414,129,WHITE,0.1,13)
gradient(selectedCard,{{0,rgb(250,255,242)},{1,rgb(222,240,206)}})
stroke(selectedCard,rgb(160,189,136),0.35)
label(selectedCard,"Label","SELECTED OPTIONS",18,13,300,21,13,MUTED,true)
local previewCount=label(selectedCard,"Count","0",17,42,370,37,27,INK,true)
local empty=frame(second,"EmptyState",0,0,846,423,WHITE,1)
local goBack=button(empty,"BackToMain","Home",754,2,86,32,false)

frame(content, "StatusDivider", 27, 524, W - 54, 1, rgb(107,160,173), 0.6)
frame(content, "StatusHighlight", 27, 525, W - 54, 1, WHITE, 0.07)
frame(content, "StatusLight", 29, 541, 7, 7, rgb(113,176,53), 0, 4)
local pageStatus = label(content, "PageStatus", "Main", 44, 531, 190, 27, 14, MUTED)
state.RefreshNavigationLabel=function()
    pageStatus.Text=state.PageNames[state.SelectedTab or 1]
end
local shortcut = label(content, "Shortcut", "Right Shift  ·  Toggle menu", 280, 531, 566, 27, 14, MUTED)
shortcut.TextXAlignment = Enum.TextXAlignment.Right

local selectedPage = 1
local pageList = { main, second, settingsPage, visualsPage, automationPage }
local tabNames = state.PageNames
local function selectPage(index)
    if not alive then return end
    if index=="Tab 2" then index=2 end -- Legacy API alias.
    if type(index) == "string" then index = table.find(tabNames, index) end
    index = math.clamp(tonumber(index) or 1, 1, #pageList)
    index = math.floor(index)
    if state.TabDisabled and state.TabDisabled[index] then return false end
    if index~=selectedPage then
        cancelControlDrag()
        if state.CloseEditor then state.CloseEditor() end
    end
    selectedPage = index
    state.SelectedTab=index
    if index~=3 then state.CapturingKey=false;if state.RefreshSettings then state.RefreshSettings() end end
    state.Generation += 1
    local generation = state.Generation
    cancelTask(state.PageTask)
    for i, page in ipairs(pageList) do
        if activeTweens[page] then activeTweens[page]:Cancel() end
        page.Interactable = i == index
        page.ZIndex = i == index and 2 or 1
        if i == index then
            local entering = not page.Visible
            page.Visible = true
            if entering and preferences.Animations then
                page.GroupTransparency = 0.6
                page.Position = UDim2.fromOffset(12, 0)
            end
            tween(page, { GroupTransparency = 0, Position = UDim2.fromOffset(0,0) }, 0.18)
        elseif page.Visible and preferences.Animations then
            tween(page, { GroupTransparency = 1, Position = UDim2.fromOffset(-8,0) }, 0.12)
        else
            page.Visible = false
        end
    end
    state.RefreshNavigation()
    if preferences.Animations then
        state.PageTask = schedule(0.19, function()
            if state.Generation == generation then
                for i, page in ipairs(pageList) do page.Visible = i == index end
            end
        end)
    end
    pageStatus.Text = tabNames[index]
    return true
end
for index,tab in ipairs(tabButtons) do connect(tab.Button.Activated,function() selectPage(index) end) end
connect(explore.Activated, function() selectPage(2) end)
connect(jumpVisuals.Activated,function() selectPage(4) end)
connect(jumpAutomation.Activated,function() selectPage(5) end)
connect(openConfig.Activated,function() if state.OpenConfig then state.OpenConfig() end end)
connect(goBack.Activated, function() selectPage(1) end)
selectPage(1)

local minimized, hidden = false, false
local dragging, dragTouch, dragStart, initialPosition = false, nil, nil, nil
local cameraConnection
local function viewport()
    local camera = Workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(1280, 720)
end
local function clampPosition(x, y)
    local view = viewport()
    local width = W * uiScale.Scale
    local height = (minimized and 42 or H) * uiScale.Scale
    return math.clamp(x, 10, math.max(10, view.X - width - 10)),
        math.clamp(y, 10, math.max(10, view.Y - height - 10))
end
local function fitWindow(center)
    local view = viewport()
    if activeTweens[anchor] then activeTweens[anchor]:Cancel() end
    uiScale.Scale = math.min(preferences.Scale, (view.X - 28) / W, (view.Y - 28) / H)
    uiScale.Scale = math.max(0.1, uiScale.Scale)
    local x = center and (view.X - W * uiScale.Scale) / 2 or anchor.Position.X.Offset
    local y = center and (view.Y - H * uiScale.Scale) / 2 or anchor.Position.Y.Offset
    x, y = clampPosition(x, y)
    anchor.Position = UDim2.fromOffset(x, y)
    if state.RefreshToasts then state.RefreshToasts() end
end
fitWindow(true)
if state.SavedPosition then
    local x, y = clampPosition(state.SavedPosition.X, state.SavedPosition.Y)
    anchor.Position = UDim2.fromOffset(x,y)
end
local function watchCamera()
    if cameraConnection then disconnect(cameraConnection) end
    local camera = Workspace.CurrentCamera
    if camera then
        cameraConnection = connect(camera:GetPropertyChangedSignal("ViewportSize"), function() fitWindow(false) end)
    end
    fitWindow(false)
end
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), watchCamera)
watchCamera()

local function showWindow(show)
    if not alive then return end
    hidden = not show
    state.Hidden = hidden
    if hidden and state.CapturingKey then
        state.CapturingKey=false
        if state.RefreshSettings then state.RefreshSettings() end
    end
    state.RefreshNavigation()
    dragging, dragTouch = false, nil
    state.DragTarget=nil
    cancelControlDrag()
    if hidden and state.CloseEditor then state.CloseEditor() end
    if activeTweens[anchor] then activeTweens[anchor]:Cancel() end
    state.VisibilityGeneration=(state.VisibilityGeneration or 0)+1
    local generation=state.VisibilityGeneration
    cancelTask(state.VisibilityTask)
    visibilityGroup.Interactable=show
    dragSurface.Modal=preferences.FreeMouse and show
    if show and not anchor.Visible then
        visibilityGroup.GroupTransparency=1;visibilityOffset.Position=UDim2.fromOffset(0,-6)
    end
    anchor.Visible=true
    tween(visibilityGroup,{GroupTransparency=show and 0 or 1},show and 0.18 or 0.16)
    tween(visibilityOffset,{Position=UDim2.fromOffset(0,show and 0 or -6)},show and 0.22 or 0.18)
    if preferences.Animations then
        state.VisibilityTask=schedule(show and 0.23 or 0.19,function()
            if state.VisibilityGeneration~=generation then return end
            anchor.Visible=show
        end)
    else anchor.Visible=show end
    if state.RefreshToasts then state.RefreshToasts() end
end
state.SettleVisibility=function()
    state.VisibilityGeneration=(state.VisibilityGeneration or 0)+1
    cancelTask(state.VisibilityTask)
    for _,object in ipairs({visibilityGroup,visibilityOffset}) do
        if activeTweens[object] then activeTweens[object]:Cancel() end
    end
    anchor.Visible=not hidden
    visibilityGroup.GroupTransparency=hidden and 1 or 0
    visibilityGroup.Interactable=not hidden
    visibilityOffset.Position=UDim2.fromOffset(0,hidden and -6 or 0)
    dragSurface.Modal=preferences.FreeMouse and not hidden
end

local function shortcutBegan(input)
    if not alive or state.CapturingKey or state.KeyCapture or input.KeyCode~=Enum.KeyCode[preferences.ToggleKey] then return false end
    if state.TogglePressed==input.KeyCode then return not UIS:GetFocusedTextBox() end
    state.TogglePressed=input.KeyCode
    if UIS:GetFocusedTextBox() then return false end
    state.ShortcutHeld=preferences.ToggleMode=="Hold"
    showWindow(state.ShortcutHeld or hidden)
    return true
end
local function endShortcut(key)
    if key and state.TogglePressed~=key then return end
    state.TogglePressed=nil
    if state.ShortcutHeld then
        state.ShortcutHeld=false
        showWindow(false)
    end
end
connect(UIS.InputBegan, function(input, processed)
    if state.CapturingKey then
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        state.CapturingKey = false
        if input.KeyCode ~= Enum.KeyCode.Escape then api.SetSetting("ToggleKey", input.KeyCode.Name) end
        if input.KeyCode==Enum.KeyCode[preferences.ToggleKey] then state.TogglePressed=input.KeyCode end
        if state.RefreshSettings then state.RefreshSettings() end
        return
    end
    -- Only the explicitly selected shortcut bypasses gameProcessedEvent.
    local shortcutHandled=shortcutBegan(input)
    if state.OnKeyBegan then state.OnKeyBegan(input,processed or shortcutHandled) end
end)
do
    local ok,actions=pcall(function() return game:GetService("ContextActionService") end)
    if ok and actions then
        local actionName="Aero.Toggle."..HttpService:GenerateGUID(false)
        local boundKey
        state.UpdateBinding=function()
            if boundKey==preferences.ToggleKey then return end
            local key=preferences.ToggleKey
            local success=pcall(function()
                actions:UnbindAction(actionName)
                actions:BindActionAtPriority(actionName,function(_,inputState,input)
                    local handle=alive and not state.CapturingKey and not state.KeyCapture and not UIS:GetFocusedTextBox()
                    if inputState==Enum.UserInputState.Begin then handle=shortcutBegan(input)
                    elseif inputState==Enum.UserInputState.Cancel then endShortcut()
                    elseif inputState==Enum.UserInputState.End then endShortcut(input.KeyCode) end
                    -- Reserve only the chosen shortcut; do not open chat/camera actions with it.
                    return handle and Enum.ContextActionResult.Sink or Enum.ContextActionResult.Pass
                end,false,Enum.ContextActionPriority.High.Value+100,Enum.KeyCode[key])
            end)
            boundKey=success and key or nil
        end
        state.UnbindHotkey=function() pcall(function() actions:UnbindAction(actionName) end) end
        state.UpdateBinding()
    end
end
connect(dragSurface.InputBegan, function(input)
    if preferences.LockPosition or state.SliderDrag then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragTouch = input.UserInputType == Enum.UserInputType.Touch and input or nil
        dragStart = Vector2.new(input.Position.X, input.Position.Y)
        initialPosition = Vector2.new(anchor.Position.X.Offset, anchor.Position.Y.Offset)
    end
end)
connect(UIS.InputChanged, function(input)
    if state.UpdateSlider then state.UpdateSlider(input) end
    local accepted = input.UserInputType == Enum.UserInputType.MouseMovement and not dragTouch
        or input.UserInputType == Enum.UserInputType.Touch and input == dragTouch
    if not dragging or not accepted then return end
    local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
    local x, y = clampPosition(initialPosition.X + delta.X, initialPosition.Y + delta.Y)
    if preferences.SmoothDragging and preferences.Animations then
        tween(anchor, { Position = UDim2.fromOffset(x,y) }, 0.065)
    else anchor.Position = UDim2.fromOffset(x, y) end
    state.DragTarget = {X=x,Y=y}
end)
connect(UIS.InputEnded, function(input)
    endShortcut(input.KeyCode)
    if state.OnKeyEnded then state.OnKeyEnded(input) end
    if state.EndSlider then state.EndSlider(input) end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input == dragTouch then
        dragging, dragTouch = false, nil
        if state.DragTarget then
            if activeTweens[anchor] then activeTweens[anchor]:Cancel() end
            anchor.Position = UDim2.fromOffset(state.DragTarget.X, state.DragTarget.Y)
            state.DragTarget = nil
            if preferences.AutoSave and preferences.RememberPosition and api.SaveSettings then api.SaveSettings(true) end
        end
    end
end)
connect(UIS.WindowFocusReleased, function()
    dragging, dragTouch = false, nil
    cancelControlDrag()
    state.DragTarget = nil
    if activeTweens[anchor] then activeTweens[anchor]:Cancel() end
    state.CapturingKey = false
    endShortcut()
    if state.CloseEditor then state.CloseEditor() end
    if state.OnKeyFocusLost then state.OnKeyFocusLost() end
    if state.RefreshSettings then state.RefreshSettings() end
end)

local function setMinimized(value)
    if not alive then return end
    minimized=value==true
    if minimized then
        cancelControlDrag()
        if state.CloseEditor then state.CloseEditor() end
    end
    state.Minimized=minimized
    state.RefreshNavigation()
    state.MinimizeGeneration=(state.MinimizeGeneration or 0)+1
    local generation=state.MinimizeGeneration
    cancelTask(state.MinimizeTask)
    content.Interactable=not minimized
    content.Visible=true
    minimize:FindFirstChild("Icon_minus").Visible=not minimized
    restoreIcon.Visible=minimized
    local height = minimized and 42 or H
    fitWindow(false)
    tween(visibilityHost,{Position=UDim2.fromOffset(W/2,height/2),
        AnchorPoint=Vector2.new(0.5,(height/2+24)/(H+48))},0.22)
    tween(shell,{Size=UDim2.fromOffset(W,height)},0.22)
    tween(innerRim,{Size=UDim2.fromOffset(W-4,height-4)},0.22)
    tween(content,{GroupTransparency=minimized and 1 or 0,
        Position=UDim2.fromOffset(0,minimized and 34 or 42)},minimized and 0.12 or 0.18)
    for index = 1, 5 do
        local spread = index * 3
        tween(window["Shadow" .. index],{Size=UDim2.fromOffset(W+spread*2,height+spread*2)},0.22)
    end
    if preferences.Animations then
        state.MinimizeTask=schedule(0.23,function()
            if state.MinimizeGeneration==generation then content.Visible=not minimized end
        end)
    else content.Visible=not minimized end
end
state.SetMinimized=setMinimized
connect(minimize.Activated,function() setMinimized(not minimized) end)

function api.Destroy()
    if not alive then return end
    if preferences.AutoSave and api.SaveSettings then api.SaveSettings(true) end
    alive = false
    if state.UnbindHotkey then state.UnbindHotkey() end
    for connection in pairs(connections) do connection:Disconnect() end
    table.clear(connections)
    for ticket in pairs(pendingTasks) do cancelTask(ticket) end
    for _, animation in pairs(activeTweens) do animation:Cancel() end
    for _, control in pairs(state.Controls) do control:Destroy() end
    while #state.Toasts>0 do state.Toasts[1]:Dismiss() end
    if not state.ExternalDestroy then gui:Destroy() end
    if env.AeroUI == api then env.AeroUI = nil end
end
function api.Toggle() showWindow(hidden) end
function api.Show() showWindow(true) end
function api.Hide() showWindow(false) end
function api.SelectTab(first, secondIndex) return selectPage(first == api and secondIndex or first) end
function api.GetSelectedTab() return selectedPage end
function api.Unload() api.Destroy() end
function api.Minimize() setMinimized(true) end
function api.Restore() setMinimized(false) end
api.Gui = gui
connect(close.Activated, api.Destroy)

-- Notification cards live outside the window, so they can remain visible while hidden.
do
    local dock = frame(gui, "NotificationDock", 0, 0, 344, 600, WHITE, 1)
    dock.AnchorPoint = Vector2.new(1, 0)
    dock.Position = UDim2.new(1, -18, 0, 18)
    dock.ZIndex = 10
    local dockScale = create("UIScale", {Scale=1}, dock)
    local typeColors = {info=rgb(29,145,211), success=rgb(99,164,38), warning=rgb(207,151,36), error=rgb(207,80,70)}
    local function reflow()
        if not alive then return end
        dockScale.Scale = math.min(1, (viewport().X - 32) / 344,
            (viewport().Y-36)/math.max(96,#state.Toasts*108-12))
        dock.Visible = preferences.Notifications and (not state.Hidden or preferences.NotifyWhenHidden)
        for index, toast in ipairs(state.Toasts) do
            tween(toast.Instance, {Position=UDim2.fromOffset(0,(index-1)*108),GroupTransparency=0},0.16)
        end
    end
    state.RefreshToasts = reflow
    function api.Notify(first, secondOptions)
        local options = first == api and secondOptions or first
        if not alive or not preferences.Notifications then return nil end
        if type(options) == "string" then options = {Text=options} end
        options = type(options) == "table" and options or {}
        local id = options.Id and tostring(options.Id)
        if id and state.ToastIds[id] then state.ToastIds[id]:Update(options); return state.ToastIds[id] end
        local toast = {Dismissed=false}
        local card = create("CanvasGroup", {
            Name="Notification",Size=UDim2.fromOffset(344,96),Position=UDim2.fromOffset(20,0),
            BackgroundColor3=WHITE,BackgroundTransparency=0.03,GroupTransparency=0.45,
        },dock)
        round(card,10);stroke(card,rgb(116,169,187),0.14)
        gradient(card,{{0,rgb(245,254,255)},{1,rgb(211,235,239)}})
        local stripe=frame(card,"TypeStripe",0,10,4,76,WHITE,0,2)
        local heading=label(card,"Title","",17,8,278,26,19,INK,true)
        local message=label(card,"Message","",17,35,300,43,16,MUTED)
        message.TextWrapped=true;message.TextYAlignment=Enum.TextYAlignment.Top
        local dismiss=create("TextButton",{Name="Dismiss",Text="",AutoButtonColor=false,
            BackgroundTransparency=1,Position=UDim2.fromOffset(312,8),Size=UDim2.fromOffset(24,24)},card)
        icon(dismiss,"close",3,3,16,MUTED)
        toast.Instance=card
        function toast:Dismiss()
            if self.Dismissed then return end
            self.Dismissed=true;cancelTask(self.Timer)
            if id then state.ToastIds[id]=nil end
            local index=table.find(state.Toasts,self)
            if index then table.remove(state.Toasts,index) end
            releaseTree(card);card:Destroy();reflow()
        end
        function toast:Update(values)
            if self.Dismissed or not alive then return end
            heading.Text=tostring(values.Title or "Aero"):sub(1,65)
            message.Text=tostring(values.Text or values.Content or ""):sub(1,180)
            stripe.BackgroundColor3=typeColors[values.Type] or typeColors.info
            local duration=tonumber(values.Duration) or preferences.NotificationDuration
            if duration~=duration then duration=preferences.NotificationDuration end
            cancelTask(self.Timer)
            self.Timer=schedule(math.clamp(duration,1,30),function() self:Dismiss() end)
        end
        connect(dismiss.Activated,function() toast:Dismiss() end,card)
        table.insert(state.Toasts,toast)
        if id then state.ToastIds[id]=toast end
        while #state.Toasts>preferences.NotificationLimit do state.Toasts[1]:Dismiss() end
        toast:Update(options);reflow()
        tween(card,{GroupTransparency=0,Position=UDim2.fromOffset(0,(#state.Toasts-1)*108)},0.18)
        return toast
    end
end

-- Reusable controls. Each control owns its connections, animations and callback job.
do
    local featurePanel = frame(second,"FeaturePanel",0,0,846,423,WHITE,1)
    featurePanel.Visible=false
    label(featurePanel,"Heading","Player controls",4,0,700,35,27,INK,true)
    local featureScroller=create("ScrollingFrame",{
        Name="FeatureControls",Position=UDim2.fromOffset(0,48),Size=UDim2.fromOffset(846,375),
        BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.fromOffset(0,0),
        ScrollBarThickness=5,ScrollBarImageColor3=rgb(102,161,180),
        Active=true,ScrollingEnabled=true,
        ScrollingDirection=Enum.ScrollingDirection.Y,
    },featurePanel)
    local serial=0
    local function groupFor(parent,width)
        if not state.Groups[parent] then state.Groups[parent]={Root=parent,Width=width,Items={}} end
        return state.Groups[parent]
    end
    local function relayout(group)
        local cursor=0
        for _,item in ipairs(group.Items) do
            if item.Instance.Visible then
                item.Instance.Position=UDim2.fromOffset(0,cursor)
                cursor+=item.Height+8
            end
        end
        if group.Root:IsA("ScrollingFrame") then group.Root.CanvasSize=UDim2.fromOffset(0,cursor)
        else group.Root.Size=UDim2.fromOffset(group.Width,cursor) end
        if group.Changed then group.Changed() end
        if group.Root==featureScroller then
            featurePanel.Visible=cursor>0;empty.Visible=cursor==0
        end
    end
    state.GroupFor, state.Relayout = groupFor, relayout
    local editor
    local function closeEditor(owner)
        if not editor or (owner and owner~=editor) then return end
        local previous=editor
        editor=nil
        cancelControlDrag(previous.Handle)
        if state.KeyCapture==previous then state.KeyCapture=nil end
        previous.Refresh()
    end
    local function openEditor(data)
        local wasOpen=editor==data
        closeEditor()
        if not wasOpen then
            editor=data
            return true
        end
        return false
    end
    state.CloseEditor=closeEditor
    local function callbackError(message)
        warn("[Aero callback] "..tostring(message))
        api.Notify({Id="aero.callback-error",Title="That action hit a problem",Text="The rest of the interface is still available.",Type="error"})
    end
    local function makeControl(kind,options,height)
        assert(alive,"Aero has been destroyed")
        assert(type(options)=="table","Control options must be a table")
        serial+=1
        local id=options.Id or ("control."..serial)
        assert(type(id)=="string" and #id>0,"Control Id must be a nonempty string")
        local existing=state.Controls[id]
        if existing then
            assert(existing.Kind==kind,"Aero: Id '"..id.."' is already used by another control type")
            return existing,false
        end
        local parent=options.Parent or featureScroller
        assert(parent:IsDescendantOf(gui),"Control Parent must belong to this Aero interface")
        if not options.Parent then assert(options.Tab==nil or options.Tab==2 or options.Tab=="Tab 2" or options.Tab=="Player","Default controls target Player") end
        local width=options.Width or (parent==featureScroller and 834 or parent.Size.X.Offset)
        local group=groupFor(parent,width)
        local object=frame(parent,id,0,0,width,height,WHITE,0.12,8)
        gradient(object,{{0,rgb(250,255,255)},{1,rgb(225,241,243)}})
        gloss(object,3,1,width-6,12,7)
        stroke(object,rgb(141,183,194),0.4)
        local title=label(object,"ControlTitle",options.Text or options.Title or id,15,9,width-100,25,19,INK,true)
        local description=label(object,"ControlDescription",options.Description or "",15,35,width-98,24,14,MUTED)
        if options.Compact then
            title.TextSize=18;title.Position=UDim2.fromOffset(15,kind=="Slider" and 7 or math.floor((height-25)/2))
            description.Visible=false
        end
        -- Optional jobs and renderers are populated by each widget after creation.
        local data: {[string]: any}={Id=id,Kind=kind,Instance=object,Height=height,Disabled=options.Disabled==true,
            Visible=options.Visible~=false,Value=options.Default==true,Busy=false,Destroyed=false,
            Callback=options.Callback,Group=group,Text=title.Text,Description=description.Text,
            ButtonState="default",ButtonText=options.ButtonText or "Open"}
        local handle={}
        local methods={}
        function methods:SetDisabled(value)
            if not alive or data.Destroyed then return end
            data.Disabled=value==true
            if data.Disabled then
                cancelControlDrag(handle)
                closeEditor(data)
                if data.OnUnavailable then data.OnUnavailable() end
            end
            data.Refresh()
        end
        function methods:SetVisible(value)
            if not alive or data.Destroyed then return end
            data.Visible=value~=false
            if not data.Visible then
                cancelControlDrag(handle)
                closeEditor(data)
                if data.OnUnavailable then data.OnUnavailable() end
            end
            object.Visible=data.Visible;relayout(group)
        end
        function methods:GetValue() return data.Value end
        function methods:SetButtonState(value)
            assert(kind=="Button","SetButtonState is only available on buttons")
            assert(value=="default" or value=="waiting" or value=="success" or value=="error","Unknown button state")
            if not alive or data.Destroyed then return false end
            if data.ButtonState==value and not data.FeedbackState then return true end
            cancelTask(data.FeedbackTask);data.FeedbackState=nil
            data.ButtonState=value;data.Refresh();return true
        end
        function methods:SetValue(value,fireCallback)
            if not alive or data.Destroyed or (fireCallback and (data.Disabled or data.Busy)) then return false end
            if data.Normalize then value=data.Normalize(value) end
            if value==nil then return false end
            if data.Value==value then data.Refresh();return false end
            data.Value=value
            if data.OnValueChanged then data.OnValueChanged() end
            data.Refresh()
            if fireCallback then data.Invoke(value) end
            return true
        end
        function methods:Destroy()
            if data.Destroyed then return end
            data.Destroyed=true;cancelTask(data.Job);cancelTask(data.FeedbackTask)
            closeEditor(data)
            cancelControlDrag(handle)
            if data.OnDestroy then data.OnDestroy() end
            state.Controls[id]=nil
            local index=table.find(group.Items,handle)
            if index then table.remove(group.Items,index) end
            releaseTree(object);object:Destroy();relayout(group)
            if #group.Items==0 and group.Root~=featureScroller then state.Groups[group.Root]=nil end
        end
        function data.Invoke(value)
            if data.Destroyed or data.Disabled or data.Busy or not alive then return false end
            if type(data.Callback)~="function" then return true end
            cancelTask(data.FeedbackTask);data.FeedbackState=nil
            data.Busy=true;data.Refresh()
            local ticket={};data.Job=ticket
            pendingTasks[ticket]=task.defer(function()
                if not alive or data.Destroyed then pendingTasks[ticket]=nil;return end
                local ok,message=xpcall(function()
                    if kind=="Button" then return data.Callback(handle) else return data.Callback(value,handle) end
                end,debug.traceback)
                pendingTasks[ticket]=nil
                if not alive or data.Destroyed then return end
                data.Busy=false
                if kind=="Button" and data.ButtonState=="default" then
                    local success=ok and message~=false
                    if not success or options.SuccessFeedback~=false then
                        data.FeedbackState=success and "success" or "error"
                        data.FeedbackTask=schedule(success and 0.9 or 1.3,function()
                            if not data.Destroyed then data.FeedbackState=nil;data.Refresh() end
                        end)
                    end
                end
                data.Refresh()
                if not ok then callbackError(message) end
            end)
            return true
        end
        data.Refresh=function()
            if not alive or data.Destroyed then return end
            local disabled=data.Disabled or data.Busy
            title.Text=data.Text;description.Text=data.Description
            title.TextTransparency=disabled and 0.52 or 0
            description.TextTransparency=disabled and 0.48 or 0
            if data.Render then data.Render(disabled) end
        end
        setmetatable(handle,{
            __index=function(_,key) return methods[key] or data[key] end,
            __newindex=function(_,key,value)
                if key=="Disabled" then methods.SetDisabled(handle,value)
                elseif key=="Visible" then methods.SetVisible(handle,value)
                elseif key=="Value" then methods.SetValue(handle,value,false)
                elseif key=="Text" or key=="Description" then data[key]=tostring(value);data.Refresh()
                elseif key=="ButtonText" and kind=="Button" then data.ButtonText=tostring(value);data.Refresh()
                elseif key=="Mode" and methods.SetMode then methods.SetMode(handle,value)
                else error("Use control methods; '"..tostring(key).."' is read-only",2) end
            end,
        })
        data.Handle=handle;data.Title=title;data.DescriptionLabel=description;data.Methods=methods
        state.Controls[id]=handle
        table.insert(group.Items,handle)
        object.Visible=data.Visible
        relayout(group)
        return handle,true,data
    end
    local function arguments(first,secondOptions) return first==api and secondOptions or first end
    function api.AddButton(first,secondOptions)
        local options=arguments(first,secondOptions)
        local handle,fresh,data=makeControl("Button",options,options.Compact and 56 or 70)
        if not fresh then return handle end
        local actionWidth=96
        local action=button(data.Instance,"Action",options.ButtonText or "Open",data.Group.Width-actionWidth-15,math.floor((data.Height-35)/2),actionWidth,35,options.Green==true)
        local red=frame(action,"StateRed",0,0,actionWidth,35,WHITE,1,8)
        gradient(red,{{0,rgb(255,187,175)},{0.47,rgb(236,113,98)},{0.5,rgb(184,52,44)},{1,rgb(237,125,101)}})
        local green=frame(action,"StateGreen",0,0,actionWidth,35,WHITE,1,8)
        gradient(green,{{0,rgb(203,248,147)},{0.47,rgb(134,207,75)},{0.5,rgb(72,157,30)},{1,rgb(144,221,81)}})
        local caption=action:FindFirstChild("Caption")
        caption.ZIndex=3
        action:FindFirstChild("GlassReflection").ZIndex=2
        action:FindFirstChild("HoverGlow").ZIndex=4
        local disabledVeil=frame(action,"DisabledVeil",0,0,actionWidth,35,rgb(221,232,235),0.4,8)
        disabledVeil.ZIndex=5
        data.Title.Size=UDim2.fromOffset(data.Group.Width-actionWidth-45,25)
        data.DescriptionLabel.Size=UDim2.fromOffset(data.Group.Width-actionWidth-45,24)
        data.Render=function(disabled)
            local status=data.ButtonState~="default" and data.ButtonState or data.Busy and "busy" or data.FeedbackState or "default"
            caption.Text=status=="waiting" and (options.WaitingText or "Waiting…")
                or status=="busy" and (options.BusyText or "Working…")
                or status=="success" and (options.SuccessText or "Done")
                or status=="error" and (options.ErrorText or "Failed") or data.ButtonText
            tween(red,{BackgroundTransparency=(status=="waiting" or status=="error") and 0 or 1},0.16)
            tween(green,{BackgroundTransparency=status=="success" and 0 or 1},0.16)
            action.Active=not disabled;action.Selectable=not disabled;action.Interactable=not disabled
            disabledVeil.Visible=disabled
        end
        connect(action.Activated,function() data.Invoke() end,data.Instance)
        data.Refresh();return handle
    end
    function api.AddToggle(first,secondOptions)
        local options=arguments(first,secondOptions)
        local handle,fresh,data=makeControl("Toggle",options,options.Compact and 56 or 70)
        if not fresh then return handle end
        data.Normalize=function(value) if type(value)=="boolean" then return value end;return nil end
        local track=create("TextButton",{Name="Switch",Text="",AutoButtonColor=false,BorderSizePixel=0,
            Position=UDim2.fromOffset(data.Group.Width-70,math.floor((data.Height-28)/2)),Size=UDim2.fromOffset(52,28),BackgroundColor3=rgb(153,180,190)},data.Instance)
        round(track,14);stroke(track,rgb(88,136,153),0.26)
        gradient(track,{{0,rgb(240,255,255)},{0.47,rgb(212,236,242)},
            {0.5,rgb(161,200,212)},{1,rgb(224,247,250)}})
        local thumb=frame(track,"Thumb",3,3,22,22,WHITE,0,11)
        gradient(thumb,{{0,WHITE},{1,rgb(220,238,243)}})
        stroke(thumb,rgb(71,122,142),0.5)
        data.Render=function(disabled)
            track.Active=not disabled;track.Selectable=not disabled;track.Interactable=not disabled
            tween(track,{BackgroundColor3=data.Value and PALETTES[preferences.Accent][1] or rgb(153,180,190),
                BackgroundTransparency=disabled and 0.55 or 0},0.14)
            tween(thumb,{Position=UDim2.fromOffset(data.Value and 27 or 3,3),BackgroundTransparency=disabled and 0.35 or 0},0.14)
        end
        connect(track.Activated,function()
            if not data.Disabled and not data.Busy then handle:SetValue(not data.Value,true) end
        end,data.Instance)
        data.Refresh();return handle
    end
    function api.AddSlider(first,secondOptions)
        local options=arguments(first,secondOptions)
        assert(type(options)=="table","Slider options must be a table")
        local minimum,maximum,step=options.Min or 0,options.Max or 100,options.Step or 1
        assert(type(minimum)=="number" and type(maximum)=="number" and type(step)=="number"
            and minimum==minimum and maximum==maximum and step==step
            and math.abs(minimum)<math.huge and math.abs(maximum)<math.huge and step<math.huge
            and maximum>minimum and step>0,"Invalid slider range")
        local handle,fresh,data=makeControl("Slider",options,options.Compact and 72 or 89)
        if not fresh then return handle end
        data.Normalize=function(value)
            if type(value)~="number" or value~=value or math.abs(value)==math.huge then return nil end
            return math.clamp(minimum+math.floor((value-minimum)/step+0.5)*step,minimum,maximum)
        end
        data.Value=data.Normalize(options.Default) or minimum
        local valueLabel=label(data.Instance,"Value","",data.Group.Width-86,9,70,25,17,INK,true)
        valueLabel.TextXAlignment=Enum.TextXAlignment.Right
        local track=create("TextButton",{Name="SliderTrack",Text="",AutoButtonColor=false,BorderSizePixel=0,
            Position=UDim2.fromOffset(16,options.Compact and 42 or 54),Size=UDim2.fromOffset(data.Group.Width-110,26),BackgroundTransparency=1},data.Instance)
        local rail=frame(track,"Rail",0,10,data.Group.Width-110,7,rgb(182,209,216),0,4)
        local fill=frame(rail,"Fill",0,0,0,7,PALETTES[preferences.Accent][1],0,4)
        local thumb=frame(track,"SliderThumb",0,5,17,17,WHITE,0,9)
        thumb.AnchorPoint=Vector2.new(0.5,0)
        stroke(thumb,rgb(98,149,165),0.15)
        local minus=button(data.Instance,"Decrease","",data.Group.Width-78,options.Compact and 39 or 51,28,28,false)
        icon(minus,"minus",5,1,18,WHITE)
        local plus=button(data.Instance,"Increase","",data.Group.Width-43,options.Compact and 39 or 51,28,28,false)
        line(plus,14,14,12,0,WHITE,2);line(plus,14,14,12,90,WHITE,2)
        data.Render=function(disabled)
            local t=(data.Value-minimum)/(maximum-minimum)
            fill.BackgroundColor3=PALETTES[preferences.Accent][1]
            tween(fill,{Size=UDim2.new(t,0,0,7)},0.09)
            tween(thumb,{Position=UDim2.new(t,0,0,5)},0.09)
            local text=tostring(math.floor(data.Value*100+0.5)/100)
            if type(options.Format)=="function" then local ok,result=pcall(options.Format,data.Value);if ok then text=tostring(result) end end
            valueLabel.Text=text;valueLabel.TextTransparency=disabled and 0.5 or 0
            for _,object in ipairs({track,minus,plus}) do object.Active=not disabled;object.Selectable=not disabled;object.Interactable=not disabled end
            rail.BackgroundTransparency=disabled and 0.5 or 0
        end
        local function pointerValue(input)
            local size=track.AbsoluteSize.X
            if size>0 then handle:SetValue(minimum+math.clamp((input.Position.X-track.AbsolutePosition.X)/size,0,1)*(maximum-minimum),true) end
        end
        connect(track.InputBegan,function(input)
            if data.Disabled or data.Busy or state.SliderDrag then return end
            if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
                state.SliderDrag={Handle=handle,Touch=input.UserInputType==Enum.UserInputType.Touch and input or nil,Update=pointerValue}
                pointerValue(input)
            end
        end,data.Instance)
        connect(minus.Activated,function() handle:SetValue(data.Value-step,true) end,data.Instance)
        connect(plus.Activated,function() handle:SetValue(data.Value+step,true) end,data.Instance)
        data.Refresh();return handle
    end
    local function placeField(data, fraction)
        local width=data.Instance.Size.X.Offset
        local fieldWidth=math.min(174,math.floor(width*fraction))
        local x=width-fieldWidth-15
        data.Title.Size=UDim2.fromOffset(math.max(0,x-30),25)
        data.DescriptionLabel.Size=UDim2.fromOffset(math.max(0,x-30),24)
        return x,fieldWidth
    end
    local function enableWidget(object, enabled)
        object.Active=enabled
        object.Selectable=enabled
        object.Interactable=enabled
    end
    local function textField(parent,name,placeholder,x,y,width)
        local input=create("TextBox",{
            Name=name,Text="",PlaceholderText=placeholder,PlaceholderColor3=MUTED,
            ClearTextOnFocus=false,Font=Enum.Font.SourceSansSemibold,TextSize=16,TextColor3=INK,
            TextXAlignment=Enum.TextXAlignment.Left,BackgroundColor3=WHITE,BackgroundTransparency=0.25,
            BorderSizePixel=0,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(width,27),
        },parent)
        round(input,5);stroke(input,rgb(145,188,205),0.3)
        create("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},input)
        return input
    end
    local function renderTextField(input,disabled)
        enableWidget(input,not disabled)
        input.TextEditable=not disabled
        input.TextTransparency=disabled and 0.5 or 0
        input.BackgroundTransparency=disabled and 0.55 or 0.25
    end
    local function renderFieldButton(object,disabled)
        enableWidget(object,not disabled)
        local veil=object:FindFirstChild("DisabledVeil")
        if not veil then
            veil=frame(object,"DisabledVeil",0,0,object.Size.X.Offset,object.Size.Y.Offset,rgb(221,232,235),0.4,8)
            veil.ZIndex=5
        end
        veil.Visible=disabled
    end
    local function animatedEditor(data,panel,baseHeight,chevron)
        local object=data.Instance
        local width=object.Size.X.Offset
        local openHeight=baseHeight+panel.Size.Y.Offset+8
        local targetOpen=false
        local hideTask
        object.ClipsDescendants=true
        panel.Visible=false
        panel.Interactable=false
        local function syncHeight()
            local height=object.Size.Y.Offset
            if data.Height~=height then
                data.Height=height
                relayout(data.Group)
            end
        end
        connect(object:GetPropertyChangedSignal("Size"),syncHeight,object)
        data.OnDestroy=function() cancelTask(hideTask) end
        return function()
            local expanded=editor==data
            local animate=preferences.Animations and data.Visible
            if expanded==targetOpen and animate then return expanded end
            targetOpen=expanded
            cancelTask(hideTask)
            hideTask=nil
            local size=UDim2.fromOffset(width,expanded and openHeight or baseHeight)
            local rotation=expanded and 180 or 0
            panel.Interactable=expanded
            if animate then
                local duration=expanded and 0.22 or 0.18
                if expanded then panel.Visible=true end
                tween(object,{Size=size},duration)
                tween(chevron,{Rotation=rotation},duration)
                if not expanded then
                    hideTask=schedule(duration,function()
                        panel.Visible=false
                        hideTask=nil
                    end)
                end
            else
                for _,target in ipairs({object,chevron}) do
                    if activeTweens[target] then activeTweens[target]:Cancel();activeTweens[target]=nil end
                end
                object.Size=size
                chevron.Rotation=rotation
                panel.Visible=expanded
            end
            syncHeight()
            return expanded
        end
    end

    function api.AddDropdown(first,secondOptions)
        local options=arguments(first,secondOptions)
        assert(type(options)=="table" and type(options.Options)=="table","Dropdown requires an Options array")
        local choices, allowed={},{}
        for _,choice in ipairs(options.Options) do
            assert(type(choice)=="string" and choice~="","Dropdown options must be nonempty strings")
            if not allowed[choice] then
                allowed[choice]=true
                table.insert(choices,choice)
            end
        end
        local baseHeight=options.Compact and 56 or 70
        local handle,fresh,data=makeControl("Dropdown",options,baseHeight)
        if not fresh then return handle end
        local multi=options.Multi==true
        data.Multi=multi
        data.Normalize=function(value)
            if not multi then
                if type(value)=="string" and allowed[value] then return value end
                return nil
            end
            if type(value)~="table" then return nil end
            local selected={}
            local count=0
            local length=#value
            for index,choice in pairs(value) do
                if type(index)~="number" or index<1 or index>length or index%1~=0 then return nil end
                if type(choice)~="string" or not allowed[choice] then return nil end
                selected[choice]=true
                count+=1
            end
            if count~=length then return nil end
            local picks={}
            for _,choice in ipairs(choices) do
                if selected[choice] then table.insert(picks,choice) end
            end
            local previous=data.Value
            if type(previous)=="table" and #picks==#previous then
                local same=true
                for index,choice in ipairs(picks) do
                    if choice~=previous[index] then same=false;break end
                end
                if same then return previous end
            end
            return table.freeze(picks)
        end
        data.Value=data.Normalize(options.Default) or (multi and table.freeze({})) or choices[1] or ""
        local x,width=placeField(data,0.43)
        local action=button(data.Instance,"Dropdown","",x,math.floor((baseHeight-35)/2),width,35,false,"down")
        local caption=action.Caption
        caption.TextSize=16
        local panelWidth=data.Instance.Size.X.Offset-30
        local rows=math.min(#choices,4)
        local scrollable=#choices>rows
        local panel=create("ScrollingFrame",{
            Name="Options",Position=UDim2.fromOffset(15,baseHeight),
            Size=UDim2.fromOffset(panelWidth,rows*35),CanvasSize=UDim2.fromOffset(0,#choices*35),
            BackgroundTransparency=1,BorderSizePixel=0,Active=scrollable,ScrollingEnabled=scrollable,
            ScrollingDirection=Enum.ScrollingDirection.Y,ScrollBarThickness=5,ScrollBarImageColor3=rgb(102,161,180),
            Visible=false,
        },data.Instance)
        local renderEditor=animatedEditor(data,panel,baseHeight,action.Icon_down)
        local entries={}
        for index,choice in ipairs(choices) do
            local itemWidth=panelWidth-(scrollable and 10 or 2)
            local item=button(panel,"Option"..index,choice,1,(index-1)*35+2,itemWidth,29,false)
            item.Caption.Position=UDim2.fromOffset(12,0)
            item.Caption.Size=UDim2.fromOffset(itemWidth-(multi and 45 or 24),29)
            item.Caption.TextXAlignment=Enum.TextXAlignment.Left
            item.Caption.TextSize=16
            local check=multi and icon(item,"check",itemWidth-30,5,19,WHITE) or nil
            entries[choice]={Button=item,Check=check}
            connect(item.Activated,function()
                if editor~=data then return end
                if multi then
                    local picks=table.clone(data.Value)
                    local index=table.find(picks,choice)
                    if index then table.remove(picks,index) else table.insert(picks,choice) end
                    handle:SetValue(picks,true)
                else
                    closeEditor(data)
                    handle:SetValue(choice,true)
                end
            end,item)
        end
        connect(action.Activated,function()
            if data.Disabled or data.Busy or #choices==0 then return end
            local opened=openEditor(data)
            data.Refresh()
            if opened then
                local firstChoice=if multi then data.Value[1] else data.Value
                local selected=table.find(choices,firstChoice) or 1
                panel.CanvasPosition=Vector2.new(0,math.clamp(selected-1,0,#choices-rows)*35)
            end
        end,action)
        data.Render=function(disabled)
            local expanded=renderEditor()
            local placeholder=options.Placeholder or (#choices==0 and "No options" or "Select options")
            local selected={}
            if multi then
                local count=#data.Value
                caption.Text=count==0 and placeholder or count==1 and data.Value[1] or (count.." selected")
                for _,choice in ipairs(data.Value) do selected[choice]=true end
            else
                caption.Text=data.Value~="" and data.Value or placeholder
                selected[data.Value]=true
            end
            renderFieldButton(action,disabled or #choices==0)
            for choice,entry in pairs(entries) do
                local checked=selected[choice]==true
                entry.Button.BackgroundColor3=checked and PALETTES[preferences.Accent][3] or WHITE
                if entry.Check then entry.Check.Visible=checked end
                enableWidget(entry.Button,expanded and not disabled)
            end
        end
        data.Refresh()
        return handle
    end

    function api.AddTextInput(first,secondOptions)
        local options=arguments(first,secondOptions)
        local handle,fresh,data=makeControl("TextInput",options,options.Compact and 56 or 70)
        if not fresh then return handle end
        data.Normalize=function(value)
            if type(value)=="string" then return (value:gsub("[\r\n]","")) end
        end
        data.Value=data.Normalize(options.Default) or ""
        local x,width=placeField(data,0.43)
        local input=textField(data.Instance,"TextInput",options.Placeholder or "",x,math.floor((data.Height-27)/2),width)
        local renderedValue
        data.OnUnavailable=function()
            input.Text=data.Value
            if input:IsFocused() then input:ReleaseFocus(false) end
        end
        data.Render=function(disabled)
            if not input:IsFocused() or renderedValue~=data.Value then input.Text=data.Value end
            renderedValue=data.Value
            renderTextField(input,disabled)
        end
        connect(input.FocusLost,function(_,event)
            if data.Visible and not data.Disabled and not (event and event.KeyCode==Enum.KeyCode.Escape) then
                handle:SetValue(input.Text,true)
            end
            data.Refresh()
        end,input)
        data.Refresh()
        return handle
    end

    function api.AddColorPicker(first,secondOptions)
        local options=arguments(first,secondOptions)
        local baseHeight=options.Compact and 56 or 70
        local handle,fresh,data=makeControl("ColorPicker",options,baseHeight)
        if not fresh then return handle end
        data.Normalize=function(value)
            if typeof(value)=="Color3" then
                if value.R==value.R and value.G==value.G and value.B==value.B then
                    return Color3.new(math.clamp(value.R,0,1),math.clamp(value.G,0,1),math.clamp(value.B,0,1))
                end
            elseif type(value)=="string" then
                local r,g,b=value:match("^%s*#?(%x%x)(%x%x)(%x%x)%s*$")
                if r then return rgb(tonumber(r,16),tonumber(g,16),tonumber(b,16)) end
            end
        end
        data.Value=data.Normalize(options.Default) or PALETTES[preferences.Accent][1]
        local x,width=placeField(data,0.35)
        local chooser=button(data.Instance,"ColorPicker","",x,math.floor((baseHeight-35)/2),width,35,false,"down")
        local swatch=frame(chooser,"Swatch",8,8,22,19,data.Value,0,5)
        stroke(swatch,WHITE,0.15);gloss(swatch,2,1,18,8,4)
        local caption=chooser.Caption
        caption.Position=UDim2.fromOffset(37,0)
        caption.Size=UDim2.fromOffset(math.max(0,width-67),35)
        caption.TextSize=16

        local panelWidth=data.Instance.Size.X.Offset-30
        local panel=frame(data.Instance,"Picker",15,baseHeight,panelWidth,145,WHITE,1)
        local renderEditor=animatedEditor(data,panel,baseHeight,chooser.Icon_down)
        local hexWidth=math.min(114,math.floor(panelWidth*0.32))
        local shadeWidth=panelWidth-hexWidth-40
        local function surface(name,left,w)
            local target=create("TextButton",{
                Name=name,Text="",AutoButtonColor=false,BorderSizePixel=0,Selectable=false,
                Position=UDim2.fromOffset(left,2),Size=UDim2.fromOffset(w,139),
            },panel)
            round(target,6);stroke(target,rgb(145,188,205),0.3)
            return target
        end
        local shade=surface("SaturationValue",0,shadeWidth)
        local light=frame(shade,"Saturation",0,0,shadeWidth,139,WHITE,0,6)
        gradient(light,{{0,WHITE},{1,WHITE}},0,{{0,0},{1,1}})
        local dark=frame(shade,"Value",0,0,shadeWidth,139,rgb(0,0,0),0,6)
        dark.ZIndex=2
        gradient(dark,{{0,WHITE},{1,WHITE}},90,{{0,1},{1,0}})
        local marker=frame(shade,"Selection",0,0,12,12,WHITE,0,6)
        marker.AnchorPoint=Vector2.new(0.5,0.5);marker.ZIndex=3
        stroke(marker,WHITE,0,2)
        local hueBar=surface("Hue",shadeWidth+8,24)
        local hueColors={}
        for index=0,6 do table.insert(hueColors,{index/6,Color3.fromHSV(index/6,1,1)}) end
        gradient(hueBar,hueColors)
        local hueMarker=frame(hueBar,"Selection",0,0,24,6,WHITE,0.18,3)
        hueMarker.AnchorPoint=Vector2.new(0,0.5)
        stroke(hueMarker,rgb(88,136,153),0.26)
        local hex=textField(panel,"HexInput","#RRGGBB",panelWidth-hexWidth,2,hexWidth)
        hex.TextXAlignment=Enum.TextXAlignment.Center

        local hue,saturation,value=data.Value:ToHSV()
        local draft
        data.OnValueChanged=function()
            cancelControlDrag(handle)
            local nextHue,nextSaturation,nextValue=data.Value:ToHSV()
            if nextSaturation>0 then hue=nextHue end
            saturation,value=nextSaturation,nextValue
        end
        data.Render=function(disabled)
            local expanded=renderEditor()
            local color=draft or data.Value
            local formatted="#"..color:ToHex():upper()
            swatch.BackgroundColor3=color
            caption.Text=formatted
            shade.BackgroundColor3=Color3.fromHSV(hue,1,1)
            marker.BackgroundColor3=color
            marker.Position=UDim2.fromScale(saturation,1-value)
            hueMarker.Position=UDim2.fromScale(0,hue)
            if not expanded and hex:IsFocused() then hex:ReleaseFocus(false) end
            if not hex:IsFocused() then hex.Text=formatted end
            renderFieldButton(chooser,disabled)
            renderTextField(hex,disabled or not expanded)
        end
        local function startDrag(surfaceObject,input,isHue)
            if data.Disabled or data.Busy or editor~=data or state.SliderDrag then return end
            local touch=input.UserInputType==Enum.UserInputType.Touch
            if not touch and input.UserInputType~=Enum.UserInputType.MouseButton1 then return end
            local scroller=touch and surfaceObject:FindFirstAncestorWhichIsA("ScrollingFrame")
            local restoreScroll=scroller and scroller.ScrollingEnabled
            if restoreScroll then scroller.ScrollingEnabled=false end
            local startHue,startSaturation,startValue=hue,saturation,value
            local function update(position)
                local offset=surfaceObject.AbsolutePosition
                local size=surfaceObject.AbsoluteSize
                if size.X<=0 or size.Y<=0 then return end
                local across=math.clamp((position.Position.X-offset.X)/size.X,0,1)
                local down=math.clamp((position.Position.Y-offset.Y)/size.Y,0,1)
                if isHue then hue=math.min(down,0.999999)
                else saturation,value=across,1-down end
                draft=Color3.fromHSV(hue,saturation,value)
                data.Refresh()
            end
            state.SliderDrag={
                Handle=handle,Touch=touch and input or nil,Update=update,
                Finish=function()
                    if restoreScroll then scroller.ScrollingEnabled=true end
                    local result=draft
                    draft=nil
                    if result then handle:SetValue(result,true) end
                    data.Refresh()
                end,
                Cancel=function()
                    if restoreScroll then scroller.ScrollingEnabled=true end
                    draft=nil
                    hue,saturation,value=startHue,startSaturation,startValue
                    data.Refresh()
                end,
            }
            update(input)
        end
        connect(chooser.Activated,function()
            if data.Disabled or data.Busy then return end
            openEditor(data)
            data.Refresh()
        end,chooser)
        connect(shade.InputBegan,function(input) startDrag(shade,input,false) end,shade)
        connect(hueBar.InputBegan,function(input) startDrag(hueBar,input,true) end,hueBar)
        connect(hex.FocusLost,function(_,event)
            if editor==data and not (event and event.KeyCode==Enum.KeyCode.Escape) then
                handle:SetValue(hex.Text,true)
            end
            data.Refresh()
        end,hex)
        data.Refresh()
        return handle
    end

    local keybinds,pressedKeys={},{}
    local function keyCode(value)
        if type(value)=="string" then
            local ok,item=pcall(function() return Enum.KeyCode[value] end)
            value=ok and item or nil
        end
        if typeof(value)=="EnumItem" and value.EnumType==Enum.KeyCode and value~=Enum.KeyCode.Escape then
            return value
        end
    end
    function api.AddKeybind(first,secondOptions)
        local options=arguments(first,secondOptions)
        assert(type(options)=="table","Keybind options must be a table")
        local mode=options.Mode or "Toggle"
        assert(validateSetting("ToggleMode",mode),"Keybind Mode must be Toggle or Hold")
        local handle,fresh,data=makeControl("Keybind",options,options.Compact and 56 or 70)
        if not fresh then return handle end
        data.Normalize=keyCode
        data.Value=keyCode(options.Default or options.Key) or Enum.KeyCode.Unknown
        data.Mode=mode
        data.Active=false
        data.Callback=options.Changed
        local x,width=placeField(data,0.47)
        local y=math.floor((data.Height-35)/2)
        local modeWidth=math.min(65,math.floor(width*0.42))
        local keyButton=button(data.Instance,"Binding","",x,y,width-modeWidth-8,35,false)
        local modeButton=button(data.Instance,"Mode",mode,x+width-modeWidth,y,modeWidth,35,false)
        keyButton.Caption.TextSize=16
        modeButton.Caption.TextSize=16

        local transitions={}
        local activeJob
        function data.SetActive(active)
            if data.Active==active or data.Destroyed then return end
            data.Active=active
            data.Refresh()
            if type(options.Callback)~="function" then return end
            table.insert(transitions,active)
            if activeJob then return end
            local ticket={}
            activeJob=ticket
            pendingTasks[ticket]=task.defer(function()
                local index=1
                while alive and not data.Destroyed and transitions[index]~=nil do
                    local ok,message=xpcall(options.Callback,debug.traceback,transitions[index],handle)
                    if not ok and alive and not data.Destroyed then callbackError(message) end
                    index+=1
                end
                pendingTasks[ticket]=nil
                activeJob=nil
                table.clear(transitions)
            end)
        end
        data.OnValueChanged=function() data.SetActive(false) end
        data.OnUnavailable=data.OnValueChanged
        data.OnDestroy=function()
            keybinds[handle]=nil
            cancelTask(activeJob)
            table.clear(transitions)
            data.Active=false
        end
        function data.Methods:SetMode(nextMode)
            if not alive or data.Destroyed or not validateSetting("ToggleMode",nextMode) then return false end
            if data.Mode==nextMode then return true end
            closeEditor(data)
            data.Mode=nextMode
            data.SetActive(false)
            data.Refresh()
            return true
        end
        data.Render=function(disabled)
            keyButton.Caption.Text=state.KeyCapture==data and "Press key…" or data.Value.Name
            if data.Value==Enum.KeyCode.Unknown and state.KeyCapture~=data then keyButton.Caption.Text="Unbound" end
            keyButton.BackgroundColor3=data.Active and PALETTES[preferences.Accent][3] or WHITE
            modeButton.Caption.Text=data.Mode
            renderFieldButton(keyButton,disabled)
            renderFieldButton(modeButton,disabled)
        end
        connect(keyButton.Activated,function()
            if data.Disabled or data.Busy then return end
            if openEditor(data) then
                state.CapturingKey=false
                state.KeyCapture=data
                if state.RefreshSettings then state.RefreshSettings() end
            end
            data.Refresh()
        end,keyButton)
        connect(modeButton.Activated,function()
            if not data.Disabled and not data.Busy then
                handle:SetMode(data.Mode=="Hold" and "Toggle" or "Hold")
            end
        end,modeButton)
        keybinds[handle]=data
        data.Refresh()
        return handle
    end
    function state.OnKeyBegan(input,processed)
        if input.UserInputType~=Enum.UserInputType.Keyboard then return end
        local key=input.KeyCode
        if key==Enum.KeyCode.Unknown or pressedKeys[key] then return end
        pressedKeys[key]=true
        local capture=state.KeyCapture
        if capture then
            if UIS:GetFocusedTextBox() then return end
            if key==Enum.KeyCode[preferences.ToggleKey] then state.TogglePressed=key end
            closeEditor(capture)
            if key~=Enum.KeyCode.Escape then capture.Handle:SetValue(key,true) end
            return
        end
        if processed or UIS:GetFocusedTextBox() or key==Enum.KeyCode[preferences.ToggleKey] then return end
        for _,binding in pairs(keybinds) do
            if binding.Visible and not binding.Disabled and binding.Value==key then
                binding.SetActive(binding.Mode=="Hold" or not binding.Active)
            end
        end
    end
    function state.OnKeyEnded(input)
        if input.UserInputType~=Enum.UserInputType.Keyboard then return end
        local key=input.KeyCode
        pressedKeys[key]=nil
        for _,binding in pairs(keybinds) do
            if binding.Mode=="Hold" and binding.Value==key then binding.SetActive(false) end
        end
    end
    function state.OnKeyFocusLost()
        table.clear(pressedKeys)
        for _,binding in pairs(keybinds) do
            if binding.Mode=="Hold" then binding.SetActive(false) end
        end
    end

    function state.UpdateSlider(input)
        local active=state.SliderDrag
        if active and ((active.Touch and input==active.Touch) or (not active.Touch and input.UserInputType==Enum.UserInputType.MouseMovement)) then active.Update(input) end
    end
    function state.EndSlider(input)
        local active=state.SliderDrag
        if active and ((active.Touch and input==active.Touch) or (not active.Touch and input.UserInputType==Enum.UserInputType.MouseButton1)) then
            state.SliderDrag=nil
            if active.Finish then active.Finish() end
        end
    end
    function api.GetControl(first,id) return state.Controls[first==api and id or first] end
    function api.SetTabDisabled(first,index,value)
        if not alive then return false end
        if first~=api then value=index;index=first end
        index=tonumber(index)
        if not tabButtons[index] then return false end
        value=value==true
        state.TabDisabled=state.TabDisabled or {}
        if value and index==selectedPage then
            local replacement
            for i=1,#pageList do if i~=index and not state.TabDisabled[i] then replacement=i;break end end
            if not replacement then return false end
            selectPage(replacement)
        end
        state.TabDisabled[index]=value==true
        local tab=tabButtons[index].Button
        tab.Active=not value;tab.Interactable=not value;tab.Selectable=not value
        for _,entry in ipairs(tabButtons[index].AlphaObjects) do
            tween(entry.Object,{[entry.Property]=value and (1-(1-entry.Base)*0.45) or entry.Base},0.13)
        end
        local image=tabButtons[index].IconImage
        if image then tween(image,{ImageTransparency=value and 0.55 or 0},0.13) end
        return true
    end
end

-- Feature mockups. These callbacks update UI data and GUI objects only.
do
    state.Preview={EspColor={51,164,219}}
    state.PreviewDefaults={EspColor={51,164,219}}
    state.PreviewRules={};state.PreviewControls={}
    local function cloneValues(values)
        local result={}
        for key,value in pairs(values) do result[key]=type(value)=="table" and table.clone(value) or value end
        return result
    end
    local function panel(root,title,kind)
        local header=frame(root,"PageHeader",0,0,846,38,WHITE,0.08,10)
        gradient(header,{{0,rgb(249,255,255)},{0.48,rgb(225,247,250)},{1,rgb(191,230,236)}},85)
        stroke(header,WHITE,0.2)
        gloss(header,3,1,840,15,8).BackgroundTransparency=0.35
        label(header,"Heading",title,13,0,725,37,27,INK,true)
        orb(header,"PageOrb",804,4,30,false,kind)
        local wash=frame(root,"AeroWash",0,47,846,376,WHITE,0.35,12)
        wash.ClipsDescendants=true
        gradient(wash,{{0,rgb(241,253,255)},{1,rgb(158,222,223)}},70,{{0,0.98},{0.65,0.82},{1,0.58}})
        for index,bubble in ipairs({{735,278,104},{684,323,42},{801,251,27}}) do
            local pearl=frame(wash,"AeroBubble"..index,bubble[1],bubble[2],bubble[3],bubble[3],WHITE,0.89,bubble[3]/2)
            stroke(pearl,WHITE,0.45)
            gradient(pearl,{{0,WHITE},{0.46,rgb(205,250,252)},{1,rgb(115,205,221)}},115)
            gloss(pearl,5,3,bubble[3]-10,bubble[3]*0.38,bubble[3]/2).BackgroundTransparency=0.68
        end
        local scroll=create("ScrollingFrame",{Name=title.."Scroll",Position=UDim2.fromOffset(0,47),
            Size=UDim2.fromOffset(846,376),CanvasSize=UDim2.fromOffset(0,0),BackgroundTransparency=1,
            BorderSizePixel=0,Active=true,ScrollingEnabled=true,ScrollBarThickness=5,
            ScrollBarImageColor3=rgb(108,166,185),ScrollingDirection=Enum.ScrollingDirection.Y},root)
        local view={Left=frame(scroll,"LeftColumn",0,0,410,0,WHITE,1),Right=frame(scroll,"RightColumn",426,0,410,0,WHITE,1)}
        view.LeftGroup=state.GroupFor(view.Left,410);view.RightGroup=state.GroupFor(view.Right,410)
        local function canvas() scroll.CanvasSize=UDim2.fromOffset(0,math.max(view.Left.Size.Y.Offset,view.Right.Size.Y.Offset)+8) end
        view.LeftGroup.Changed=canvas;view.RightGroup.Changed=canvas
        return view
    end
    local function heading(parent,text)
        local item=frame(parent,"Section",0,0,410,27,WHITE,0.52,7)
        gradient(item,{{0,rgb(247,255,255)},{1,rgb(190,230,235)}},88)
        gloss(item,2,1,406,10,6).BackgroundTransparency=0.62
        frame(item,"Dot",1,10,5,5,rgb(112,183,50),0,3)
        label(item,"Text",text,14,0,390,27,14,MUTED,true)
        local group=state.GroupFor(parent,410)
        table.insert(group.Items,{Instance=item,Height=27});state.Relayout(group)
    end
    local function update()
        local count,total=0,0
        for _,value in pairs(state.Preview) do if type(value)=="boolean" then total+=1;if value then count+=1 end end end
        previewCount.Text=count.." / "..total
        if state.DrawEspPreview then state.DrawEspPreview() end
    end
    state.RefreshPreview=update
    local function toggle(parent,key,text,default)
        state.Preview[key]=default==true;state.PreviewDefaults[key]=default==true;state.PreviewRules[key]={Kind="boolean"}
        local control=api.AddToggle({Id="preview."..key,Parent=parent,Text=text,Compact=true,Default=default==true,
            Callback=function(value) state.Preview[key]=value;update() end})
        state.PreviewControls[key]=control;return control
    end
    local function slider(parent,key,text,minimum,maximum,step,default,suffix)
        state.Preview[key]=default;state.PreviewDefaults[key]=default
        state.PreviewRules[key]={Kind="number",Min=minimum,Max=maximum,Step=step}
        local control=api.AddSlider({Id="preview."..key,Parent=parent,Text=text,Compact=true,
            Min=minimum,Max=maximum,Step=step,Default=default,
            Format=function(value) return tostring(math.floor(value*100+0.5)/100)..(suffix or "") end,
            Callback=function(value) state.Preview[key]=value;update() end})
        state.PreviewControls[key]=control;return control
    end
    local player=panel(empty,"Player","person")
    heading(player.Left,"MOVEMENT")
    slider(player.Left,"WalkSpeed","Walk speed",0,100,1,16)
    slider(player.Left,"JumpPower","Jump power",0,150,1,50)
    slider(player.Left,"FlySpeed","Fly speed",0,150,1,50)
    heading(player.Right,"CHARACTER")
    toggle(player.Right,"SpeedOverride","Speed override",false)
    toggle(player.Right,"JumpOverride","Jump override",false)
    toggle(player.Right,"InfiniteJump","Infinite jump",false)
    toggle(player.Right,"Noclip","Noclip",false)
    toggle(player.Right,"Fly","Fly",false)

    local visuals=panel(visualsPage,"Visuals","eye")
    heading(visuals.Left,"ESP")
    toggle(visuals.Left,"EspEnabled","Enabled",false)
    toggle(visuals.Left,"EspBoxes","Boxes",true)
    toggle(visuals.Left,"EspNames","Names",true)
    toggle(visuals.Left,"EspDistance","Distance",true)
    toggle(visuals.Left,"EspHealth","Health bar",true)
    local preview=frame(visuals.Right,"EspPreview",0,0,410,194,WHITE,0.1,12)
    gradient(preview,{{0,rgb(246,254,255)},{1,rgb(207,235,241)}})
    stroke(preview,rgb(138,183,200),0.3)
    label(preview,"Label","PREVIEW",13,8,200,20,12,MUTED,true)
    local body={}
    for _,part in ipairs({{"Head",184,40,24,24,12},{"Torso",175,67,42,52,6},
        {"LeftArm",160,69,10,48,5},{"RightArm",222,69,10,48,5},
        {"LeftLeg",177,123,15,42,5},{"RightLeg",200,123,15,42,5}}) do
        table.insert(body,frame(preview,part[1],part[2],part[3],part[4],part[5],rgb(133,163,176),0.15,part[6]))
    end
    local box=frame(preview,"Box",151,34,87,136,WHITE,1,2)
    local boxLine=stroke(box,rgb(51,164,219),0,1.5)
    local nameTag=label(preview,"Name","Preview player",85,17,220,20,14,INK,true)
    nameTag.TextXAlignment=Enum.TextXAlignment.Center
    local distance=label(preview,"Distance","25 m",85,171,220,18,13,MUTED)
    distance.TextXAlignment=Enum.TextXAlignment.Center
    local health=frame(preview,"Health",141,42,4,124,rgb(53,90,72),0.2,2)
    frame(health,"Fill",0,31,4,93,rgb(121,211,58),0,2)
    local skeleton=frame(preview,"Skeleton",0,0,410,194,WHITE,1)
    local bones={}
    local function bone(x1,y1,x2,y2)
        local dx,dy=x2-x1,y2-y1
        table.insert(bones,line(skeleton,(x1+x2)/2,(y1+y2)/2,math.sqrt(dx*dx+dy*dy),math.deg(math.atan2(dy,dx)),WHITE,2))
    end
    bone(196,53,196,82);bone(170,80,225,80);bone(170,80,165,109);bone(225,80,227,109)
    bone(196,82,196,120);bone(196,120,184,157);bone(196,120,208,157)
    table.insert(visuals.RightGroup.Items,{Instance=preview,Height=194});state.Relayout(visuals.RightGroup)
    local colorRow=frame(visuals.Right,"EspColor",0,0,410,82,WHITE,0.1,9)
    stroke(colorRow,rgb(138,183,200),0.35)
    label(colorRow,"Title","Color",15,7,190,25,18,INK,true)
    local hex=create("TextBox",{Name="HexInput",Text="#33A4DB",ClearTextOnFocus=false,
        Font=Enum.Font.SourceSansSemibold,TextSize=16,TextColor3=INK,BackgroundColor3=WHITE,
        BackgroundTransparency=0.25,BorderSizePixel=0,Position=UDim2.fromOffset(281,7),Size=UDim2.fromOffset(114,27)},colorRow)
    round(hex,5);stroke(hex,rgb(145,188,205),0.3)
    local colors={{51,164,219},{112,205,61},{238,105,119},{177,128,225},{245,184,68},{255,255,255},{46,207,194},{231,110,185}}
    for index,color in ipairs(colors) do
        local swatch=create("TextButton",{Name="Color"..index,Text="",AutoButtonColor=false,BorderSizePixel=0,
            Position=UDim2.fromOffset(15+(index-1)*47,44),Size=UDim2.fromOffset(37,24),BackgroundColor3=rgb(table.unpack(color))},colorRow)
        round(swatch,6);stroke(swatch,WHITE,0.15);gloss(swatch,2,1,33,10,5)
        connect(swatch.Activated,function() state.Preview.EspColor=table.clone(color);update() end,colorRow)
    end
    connect(hex.FocusLost,function()
        local r,g,b=hex.Text:match("^#?(%x%x)(%x%x)(%x%x)$")
        if r then state.Preview.EspColor={tonumber(r,16),tonumber(g,16),tonumber(b,16)} end
        update()
    end,colorRow)
    table.insert(visuals.RightGroup.Items,{Instance=colorRow,Height=82});state.Relayout(visuals.RightGroup)
    toggle(visuals.Right,"EspSkeleton","Skeleton",false)
    toggle(visuals.Right,"EspChams","Chams",false)
    state.DrawEspPreview=function()
        local values=state.Preview
        local color=rgb(table.unpack(values.EspColor))
        hex.Text=string.format("#%02X%02X%02X",table.unpack(values.EspColor))
        box.Visible=values.EspEnabled and values.EspBoxes;boxLine.Color=color
        nameTag.Visible=values.EspEnabled and values.EspNames;nameTag.TextColor3=color
        distance.Visible=values.EspEnabled and values.EspDistance
        health.Visible=values.EspEnabled and values.EspHealth
        skeleton.Visible=values.EspEnabled and values.EspSkeleton
        for _,part in ipairs(body) do part.BackgroundColor3=values.EspEnabled and values.EspChams and color or rgb(133,163,176) end
        for _,part in ipairs(bones) do part.BackgroundColor3=values.EspChams and WHITE or color end
    end

    local automation=panel(automationPage,"Automation","bolt")
    heading(automation.Left,"COMBAT")
    toggle(automation.Left,"AutoParry","Auto-parry",false)
    slider(automation.Left,"ParryDelay","Reaction delay",0,1,0.01,0.15," s")
    slider(automation.Left,"ParryChance","Chance",0,100,1,100,"%")
    heading(automation.Right,"TASKS")
    toggle(automation.Right,"AutoMission","Auto mission",false)
    toggle(automation.Right,"AutoFarm","Auto farm",false)
    toggle(automation.Right,"AutoCollect","Auto collect",false)
    toggle(automation.Right,"AutoRetry","Auto retry",false)
    slider(automation.Right,"TaskInterval","Task interval",0.1,10,0.1,1," s")

    function api.GetPreviewState() return cloneValues(state.Preview) end
    function api.ApplyPreviewState(first,values)
        if first~=api then values=first end
        if not alive or type(values)~="table" then return false end
        for key,rule in pairs(state.PreviewRules) do
            local value=values[key]
            if rule.Kind=="boolean" and type(value)=="boolean" then state.Preview[key]=value
            elseif rule.Kind=="number" and type(value)=="number" and value==value and math.abs(value)<math.huge then
                state.Preview[key]=math.clamp(rule.Min+math.floor((value-rule.Min)/rule.Step+0.5)*rule.Step,rule.Min,rule.Max)
            end
            state.PreviewControls[key]:SetValue(state.Preview[key])
        end
        local color=values.EspColor
        if type(color)=="table" then
            local checked={}
            for index=1,3 do if type(color[index])~="number" or color[index]~=color[index] then return false end;checked[index]=math.clamp(math.floor(color[index]),0,255) end
            state.Preview.EspColor=checked
        end
        update();return true
    end
    function api.ResetPreviewState() return api.ApplyPreviewState(cloneValues(state.PreviewDefaults)) end
    update()
end

-- Preferences use the same reusable widgets as future user features.
do
    local banner=frame(settingsPage,"SettingsHeader",0,0,846,72,rgb(39,169,225),0,12)
    banner.ClipsDescendants=true;stroke(banner,rgb(57,142,180),0.2)
    gradient(banner,{{0,rgb(28,116,190)},{1,rgb(103,224,233)}},25)
    if asset then create("ImageLabel",{Name="SettingsScenery",Image=asset,Size=UDim2.fromScale(1,1),
        BackgroundTransparency=1,ScaleType=Enum.ScaleType.Crop,ImageTransparency=0.06},banner) end
    local shade=frame(banner,"BlueGlass",0,0,846,72,rgb(7,74,134),0)
    gradient(shade,{{0,WHITE},{1,WHITE}},0,{{0,0.04},{0.66,0.32},{1,0.75}})
    gloss(banner,3,2,840,31,11).BackgroundTransparency=0.6
    label(banner,"Eyebrow","INTERFACE",23,6,600,18,11,rgb(206,247,255),true)
    label(banner,"Heading","Settings",22,25,680,38,30,WHITE,true)
    orb(banner,"SettingsOrb",773,9,55,false,"gear")
    local statusBadge=frame(banner,"StatusBadge",622,36,126,22,WHITE,0.69,11)
    stroke(statusBadge,WHITE,0.6)
    local saveStatus=label(statusBadge,"SaveStatus","",0,0,126,22,13,WHITE,true)
    saveStatus.TextXAlignment=Enum.TextXAlignment.Center
    local unloadButton=button(settingsPage,"UnloadUI","Unload",751,86,88,32,false)
    unloadButton:FindFirstChildOfClass("UIGradient").Color=ColorSequence.new({
        ColorSequenceKeypoint.new(0,rgb(255,187,175)),ColorSequenceKeypoint.new(0.47,rgb(236,113,98)),
        ColorSequenceKeypoint.new(0.5,rgb(184,52,44)),ColorSequenceKeypoint.new(1,rgb(237,125,101))})
    local backdrop=frame(settingsPage,"SettingsGlass",0,129,846,294,WHITE,0.52,12)
    stroke(backdrop,WHITE,0.12)
    gradient(backdrop,{{0,rgb(225,250,255)},{1,rgb(208,239,233)}},65)
    local scroller=create("ScrollingFrame",{
        Name="SettingsScroll",Position=UDim2.fromOffset(7,138),Size=UDim2.fromOffset(832,277),
        CanvasSize=UDim2.fromOffset(0,0),BackgroundTransparency=1,BorderSizePixel=0,
        ScrollBarThickness=5,ScrollBarImageColor3=rgb(102,161,180),
        Active=true,ScrollingEnabled=true,
        ScrollingDirection=Enum.ScrollingDirection.Y,
    },settingsPage)
    local categories={}
    local categoryNames={"Look & feel","Window","Notifications","Config"}
    local selectedCategory=1
    local function canvas(view)
        local height=math.max(view.Left.Size.Y.Offset,view.Right.Size.Y.Offset)+8
        view.Root.Size=UDim2.fromOffset(820,height)
        if categories[selectedCategory]==view then scroller.CanvasSize=UDim2.fromOffset(0,height) end
    end
    for index,name in ipairs(categoryNames) do
        local root=create("CanvasGroup",{Name="Category"..index,Size=UDim2.fromOffset(820,0),
            BackgroundTransparency=1,GroupTransparency=0,Visible=index==1},scroller)
        local view={Root=root,Left=frame(root,"LeftColumn",0,0,402,0,WHITE,1),
            Right=frame(root,"RightColumn",418,0,402,0,WHITE,1)}
        view.LeftGroup=state.GroupFor(view.Left,402);view.RightGroup=state.GroupFor(view.Right,402)
        view.LeftGroup.Changed=function() canvas(view) end
        view.RightGroup.Changed=view.LeftGroup.Changed
        view.Button=button(settingsPage,"SettingsCategory"..index,name,(index-1)*131,86,122,32,false)
        view.Button:FindFirstChild("Caption").TextSize=16
        categories[index]=view
    end
    local function refreshCategories()
        local palette=PALETTES[preferences.Accent]
        for index,view in ipairs(categories) do
            local active=index==selectedCategory
            view.Button:FindFirstChildOfClass("UIGradient").Color=ColorSequence.new({
                ColorSequenceKeypoint.new(0,active and palette[3] or rgb(247,255,255)),
                ColorSequenceKeypoint.new(0.47,active and palette[1] or rgb(211,237,244)),
                ColorSequenceKeypoint.new(0.5,active and palette[2] or rgb(176,214,228)),
                ColorSequenceKeypoint.new(1,active and palette[1] or rgb(225,246,250)),
            })
            local caption=view.Button:FindFirstChild("Caption")
            caption.TextColor3=active and WHITE or INK
            caption.TextStrokeTransparency=active and 0.75 or 1
        end
    end
    local function selectCategory(index)
        if index~=selectedCategory then
            cancelControlDrag()
            state.CloseEditor()
        end
        selectedCategory=index;state.CapturingKey=false
        scroller.CanvasPosition=Vector2.new(0,0)
        for i,view in ipairs(categories) do
            if activeTweens[view.Root] then activeTweens[view.Root]:Cancel() end
            view.Root.Visible=i==index;view.Root.Interactable=i==index
            if i==index then
                view.Root.GroupTransparency=0.3;view.Root.Position=UDim2.fromOffset(8,0)
                tween(view.Root,{GroupTransparency=0,Position=UDim2.fromOffset(0,0)},0.16)
            end
        end
        canvas(categories[index]);refreshCategories()
        if state.RefreshSettings then state.RefreshSettings() end
    end
    for index,view in ipairs(categories) do connect(view.Button.Activated,function() selectCategory(index) end,view.Button) end
    local left,right=categories[1].Left,categories[1].Right
    local leftGroup=categories[1].LeftGroup
    local function heading(parent,text)
        local group=state.GroupFor(parent,402)
        local object=frame(parent,"Section",0,0,402,30,WHITE,1)
        frame(object,"Light",1,12,5,5,rgb(113,186,52),0,3)
        label(object,"Text",text,14,0,380,30,15,rgb(41,112,139),true)
        table.insert(group.Items,{Instance=object,Height=30})
        state.Relayout(group)
    end
    local function refreshSettings()
        for _,refresh in ipairs(state.Refreshers) do refresh() end
        saveStatus.Text=state.PersistenceError and "Session only" or state.Dirty and "Unsaved changes" or preferences.AutoSave and "Auto save on" or "Saved"
        refreshCategories()
    end
    state.RefreshSettings=refreshSettings
    local function saveSettings(silent)
        if not alive then return false end
        cancelTask(state.SaveTask);state.SaveTask=nil
        if type(writefile)~="function" then state.PersistenceError=true;refreshSettings();return false end
        local data=table.clone(preferences);data.Version=2
        if preferences.RememberPosition then
            data.Position={X=anchor.Position.X.Offset,Y=anchor.Position.Y.Offset}
        end
        local ok=pcall(function()
            if type(isfolder)=="function" and type(makefolder)=="function" and not isfolder("Aero") then makefolder("Aero") end
            writefile(CONFIG.SettingsPath,HttpService:JSONEncode(data))
        end)
        state.PersistenceError=not ok
        if ok then state.Dirty=false end
        refreshSettings()
        if not silent then api.Notify({Id="aero.settings-save",Title=ok and "Settings saved" or "Could not save settings",
            Text=ok and "Your atmosphere is ready for next time." or "Your changes still apply for this session.",Type=ok and "success" or "error"}) end
        return ok
    end
    function api.SaveSettings(first,silent)
        if first==api then first=silent end
        return saveSettings(first==true)
    end
    local appliedKey,appliedMode
    local function applySettings()
        shell.BackgroundTransparency=1-preferences.GlassOpacity
        paper.BackgroundTransparency=1-(0.55+0.43*preferences.GlassOpacity)
        local wallpaper=hero:FindFirstChild("AeroWallpaper")
        if wallpaper then wallpaper.Visible=preferences.Wallpaper end
        hill.Visible=preferences.Wallpaper
        for i=1,5 do window["Shadow"..i].Visible=preferences.Shadows end
        dragSurface.Modal=preferences.FreeMouse and not hidden
        if appliedKey~=preferences.ToggleKey or appliedMode~=preferences.ToggleMode then
            local pressed=state.TogglePressed
            endShortcut()
            if appliedKey==preferences.ToggleKey then state.TogglePressed=pressed end
            appliedKey,appliedMode=preferences.ToggleKey,preferences.ToggleMode
            if appliedMode=="Hold" and not hidden then showWindow(false) end
        end
        if state.UpdateBinding then state.UpdateBinding() end
        if preferences.LockPosition then dragging=false;state.DragTarget=nil end
        shortcut.Text=preferences.ToggleKey.."  ·  "..(preferences.ToggleMode=="Hold" and "Hold to show menu" or "Toggle menu")
        state.RefreshNavigation()
        if not preferences.Animations then
            state.SettleVisibility()
            state.Generation+=1;cancelTask(state.PageTask)
            for i,page in ipairs(pageList) do
                if activeTweens[page] then activeTweens[page]:Cancel() end
                page.Visible=i==selectedPage;page.GroupTransparency=0;page.Position=UDim2.fromOffset(0,0)
            end
            if state.SetMinimized then state.SetMinimized(minimized) end
            for _,view in ipairs(categories) do
                if activeTweens[view.Root] then activeTweens[view.Root]:Cancel() end
                view.Root.GroupTransparency=0;view.Root.Position=UDim2.fromOffset(0,0)
            end
        end
        fitWindow(false)
        while #state.Toasts>preferences.NotificationLimit or (not preferences.Notifications and #state.Toasts>0) do state.Toasts[1]:Dismiss() end
        state.RefreshToasts()
        for _,control in pairs(state.Controls) do if control.Refresh then control.Refresh() end end
        refreshSettings()
    end
    function api.GetSettings() return table.clone(preferences) end
    function api.SetSetting(first,key,value)
        if first~=api then value=key;key=first end
        if not alive then return false end
        local checked=validateSetting(key,value)
        if checked==nil then return false end
        if preferences[key]==checked then return true end
        preferences[key]=checked;state.Dirty=true;applySettings()
        if key=="AutoSave" then saveSettings(true)
        elseif preferences.AutoSave then
            cancelTask(state.SaveTask);state.SaveTask=schedule(0.35,function() saveSettings(true) end)
        end
        return true
    end
    function api.ResetSettings()
        if not alive then return end
        preferences=table.clone(DEFAULTS);state.Dirty=true;state.CapturingKey=false
        applySettings();fitWindow(true);saveSettings(true)
        api.Notify({Title="A fresh start",Text="UI settings have been reset.",Type="success"})
    end
    local function toggle(parent,key,text,description)
        local control=api.AddToggle({Id="settings."..key,Parent=parent,Text=text,Description=description,
            Default=preferences[key],Callback=function(value) api.SetSetting(key,value) end})
        table.insert(state.Refreshers,function() control:SetValue(preferences[key]) end)
        return control
    end
    local function slider(parent,key,text,description,suffix)
        local rule=numberRules[key]
        local control=api.AddSlider({Id="settings."..key,Parent=parent,Text=text,Description=description,
            Min=rule[1],Max=rule[2],Step=rule[3],Default=preferences[key],
            Format=function(value) return suffix=="%" and (math.floor(value*100+0.5).."%") or (tostring(math.floor(value+0.5))..suffix) end,
            Callback=function(value) api.SetSetting(key,value) end})
        table.insert(state.Refreshers,function() control:SetValue(preferences[key]) end)
        return control
    end
    heading(left,"COLOR & GLASS")
    local accent=frame(left,"AccentSelector",0,0,402,74,WHITE,0.12,10)
    stroke(accent,rgb(141,183,194),0.4)
    label(accent,"Title","Accent color",15,8,200,24,19,INK,true)
    local accentName=label(accent,"AccentName","",260,8,130,24,14,MUTED)
    accentName.TextXAlignment=Enum.TextXAlignment.Right
    local swatches={}
    for index,name in ipairs({"Ocean","Meadow","Iris","Rose"}) do
        local swatch=create("TextButton",{Name=name,Text=name,Font=Enum.Font.SourceSansSemibold,TextSize=14,
            TextXAlignment=Enum.TextXAlignment.Center,
            TextColor3=WHITE,AutoButtonColor=false,BorderSizePixel=0,Position=UDim2.fromOffset(15+(index-1)*96,39),
            Size=UDim2.fromOffset(88,25),BackgroundColor3=PALETTES[name][1]},accent)
        round(swatch,6);gloss(swatch,2,1,84,11,5)
        swatches[name]=stroke(swatch,PALETTES[name][2],0.3)
        connect(swatch.Activated,function() api.SetSetting("Accent",name) end,accent)
    end
    table.insert(leftGroup.Items,{Instance=accent,Height=74});state.Relayout(leftGroup)
    table.insert(state.Refreshers,function()
        accentName.Text=preferences.Accent
        for name,border in pairs(swatches) do border.Thickness=name==preferences.Accent and 2 or 1;border.Color=name==preferences.Accent and WHITE or PALETTES[name][2] end
    end)
    slider(left,"Scale","Interface size","Scales the window; fits your display.","%")
    slider(left,"GlassOpacity","Glass opacity","Adjust the transparency of the frame.","%")
    heading(right,"FINISHING TOUCHES")
    toggle(right,"Animations","Smooth animations","Fades, slides and animated switches.")
    local smooth=toggle(right,"SmoothDragging","Swift dragging","A short, smooth trail behind your pointer.")
    table.insert(state.Refreshers,function() smooth.Disabled=not preferences.Animations end)
    toggle(right,"Wallpaper","Landscape artwork","Show the landscape on the Main page.")
    toggle(right,"Shadows","Window shadow","Add a soft shadow beneath the glass.")
    left,right=categories[2].Left,categories[2].Right
    heading(left,"YOUR SHORTCUTS")
    local keyControl=api.AddButton({Id="settings.Shortcut",Parent=left,Text="Window shortcut",Description="RightShift",ButtonText="Change",SuccessFeedback=false,Callback=function()
        state.CloseEditor()
        state.CapturingKey=not state.CapturingKey;refreshSettings()
    end})
    table.insert(state.Refreshers,function()
        keyControl.Description=state.CapturingKey and "Press a key. Escape cancels." or preferences.ToggleKey
        keyControl:SetButtonState(state.CapturingKey and "waiting" or "default")
    end)
    local shortcutMode=api.AddDropdown({Id="settings.ShortcutMode",Parent=left,Text="Shortcut mode",
        Description="Press to toggle or hold to show.",Options={"Toggle","Hold"},Default=preferences.ToggleMode,
        Callback=function(mode) api.SetSetting("ToggleMode",mode) end})
    table.insert(state.Refreshers,function() shortcutMode:SetValue(preferences.ToggleMode) end)
    toggle(left,"LockPosition","Lock window position","Prevent accidental dragging.")
    toggle(left,"RememberPosition","Remember position","Reopen the UI where you left it.")
    heading(right,"YOUR WINDOW")
    toggle(right,"FreeMouse","Free the cursor","Use your mouse while the UI is open.")
    toggle(right,"AutoSave","Save interface changes","Remember interface preferences.")
    api.AddButton({Id="settings.Center",Parent=right,Text="Center the window",Description="Bring your window back to the middle.",ButtonText="Center",SuccessText="Centered",Callback=function() fitWindow(true);if preferences.AutoSave then saveSettings(true) end end})
    left,right=categories[3].Left,categories[3].Right
    heading(left,"A LITTLE HEADS-UP")
    toggle(left,"Notifications","Enable notifications","Allow Aero notification cards.")
    local hiddenNotifications=toggle(left,"NotifyWhenHidden","Show while hidden","Keep notifications when the UI is hidden.")
    local duration=slider(left,"NotificationDuration","Display duration","Time before a notification disappears."," sec")
    heading(right,"JUST THE RIGHT AMOUNT")
    local limit=slider(right,"NotificationLimit","Stack limit","Maximum visible cards at one time."," cards")
    local preview=api.AddButton({Id="settings.Preview",Parent=right,Text="Try a notification",Description="A little hello from your atmosphere.",ButtonText="Preview",Green=true,SuccessText="Sent",
        Callback=function() api.Notify({Title="Looking good!",Text="Your notifications are ready whenever you are.",Type="success"}) end})
    table.insert(state.Refreshers,function()
        for _,control in ipairs({hiddenNotifications,duration,limit,preview}) do control.Disabled=not preferences.Notifications end
    end)
    left,right=categories[4].Left,categories[4].Right
    heading(left,"CONFIG")
    heading(right,"SAVED CONFIGS")
    local store={Version=1,Profiles={}}
    if type(isfile)=="function" and type(readfile)=="function" then
        local ok,result=pcall(function()
            if isfile(CONFIG.ConfigsPath) then return HttpService:JSONDecode(readfile(CONFIG.ConfigsPath)) end
            return nil
        end)
        if ok and type(result)=="table" and type(result.Profiles)=="table" then store=result end
    end
    local refreshConfigs=function() end
    local nameBox
    local editingName,deleteName,deleteTask,restoreDelete
    local function clearDelete()
        cancelTask(deleteTask);deleteTask=nil;deleteName=nil
        if restoreDelete then restoreDelete();restoreDelete=nil end
    end
    local function cleanName(name)
        if type(name)~="string" then return nil end
        name=name:match("^%s*(.-)%s*$")
        local length=utf8.len(name)
        if not length or length<1 or length>48 or name:find("%c") then return nil end
        return name
    end
    store.Active=cleanName(store.Active)
    if store.Active then
        local current=store.Profiles[store.Active]
        if type(current)~="table" or type(current.Settings)~="table" then store.Active=nil end
    end
    local function writeConfigs()
        if type(writefile)~="function" then return false end
        return pcall(function()
            if type(isfolder)=="function" and type(makefolder)=="function" and not isfolder("Aero") then makefolder("Aero") end
            writefile(CONFIG.ConfigsPath,HttpService:JSONEncode(store))
        end)
    end
    function api.ListConfigs()
        local names={}
        for name,profile in pairs(store.Profiles) do if cleanName(name) and type(profile)=="table" and type(profile.Settings)=="table" then table.insert(names,name) end end
        table.sort(names);return names
    end
    function api.SaveConfig(first,name)
        if first~=api then name=first end
        name=cleanName(name)
        if not alive then return false end
        if not name then api.Notify({Title="Config name required",Text="Enter a name with up to 48 characters.",Type="warning"});return false end
        local previous=store.Profiles[name]
        local previousActive=store.Active
        store.Profiles[name]={Settings=table.clone(preferences),Preview=api.GetPreviewState(),
            Position={X=anchor.Position.X.Offset,Y=anchor.Position.Y.Offset}}
        store.Active=name
        local ok=writeConfigs()
        if not ok then
            store.Profiles[name]=previous;store.Active=previousActive
            api.Notify({Title="Config not saved",Text="The config file could not be written.",Type="error"})
        end
        refreshConfigs();return ok
    end
    function api.LoadConfig(first,name,silent)
        if first~=api then silent=name;name=first end
        name=cleanName(name)
        local profile=name and store.Profiles[name]
        if not alive or type(profile)~="table" or type(profile.Settings)~="table" then return false end
        preferences=table.clone(DEFAULTS)
        for key,value in pairs(profile.Settings) do
            local checked=validateSetting(key,value)
            if checked~=nil then preferences[key]=checked end
        end
        state.CapturingKey=false;state.Dirty=true
        api.ResetPreviewState()
        if type(profile.Preview)=="table" then api.ApplyPreviewState(profile.Preview) end
        applySettings()
        local position=profile.Position
        if preferences.RememberPosition and type(position)=="table" and type(position.X)=="number" and type(position.Y)=="number"
            and position.X==position.X and position.Y==position.Y and math.abs(position.X)<100000 and math.abs(position.Y)<100000 then
            local x,y=clampPosition(position.X,position.Y);anchor.Position=UDim2.fromOffset(x,y)
        end
        store.Active=name;writeConfigs();saveSettings(true);refreshConfigs()
        if not silent then api.Notify({Title="Config loaded",Text=name,Type="success"}) end
        return true
    end
    function api.GetActiveConfig() return store.Active end
    function api.RenameConfig(first,oldName,newName)
        if first~=api then newName=oldName;oldName=first end
        oldName,newName=cleanName(oldName),cleanName(newName)
        local profile=oldName and store.Profiles[oldName]
        if not alive or type(profile)~="table" or type(profile.Settings)~="table" then return false end
        if not newName then
            api.Notify({Title="Invalid config name",Text="Use a name with 1–48 characters.",Type="warning"});return false
        end
        if newName~=oldName and store.Profiles[newName]~=nil then
            api.Notify({Title="Name already exists",Text="Choose another config name.",Type="warning"});return false
        end
        if newName~=oldName then
            local previousActive=store.Active
            store.Profiles[newName]=profile;store.Profiles[oldName]=nil
            if store.Active==oldName then store.Active=newName end
            if not writeConfigs() then
                store.Profiles[oldName]=profile;store.Profiles[newName]=nil;store.Active=previousActive
                api.Notify({Title="Config not renamed",Text="The config file could not be written.",Type="error"});return false
            end
        end
        if nameBox and cleanName(nameBox.Text)==oldName then nameBox.Text=newName end
        editingName=nil;refreshConfigs()
        api.Notify({Title="Config renamed",Text=newName,Type="success"})
        return true
    end
    function api.DeleteConfig(first,name)
        if first~=api then name=first end
        name=cleanName(name)
        local profile=name and store.Profiles[name]
        if not alive or type(profile)~="table" or type(profile.Settings)~="table" then return false end
        local previousActive=store.Active
        store.Profiles[name]=nil
        if store.Active==name then store.Active=nil end
        if not writeConfigs() then
            store.Profiles[name]=profile;store.Active=previousActive
            api.Notify({Title="Config not deleted",Text="The config file could not be written.",Type="error"})
            refreshConfigs();return false
        end
        if nameBox and cleanName(nameBox.Text)==name then nameBox.Text=store.Active or api.ListConfigs()[1] or "Default" end
        editingName=nil;refreshConfigs()
        api.Notify({Title="Config deleted",Text=name,Type="success"})
        return true
    end
    local nameRow=frame(left,"ConfigNameRow",0,0,402,84,WHITE,0.1,9)
    stroke(nameRow,rgb(138,183,200),0.35)
    label(nameRow,"Title","Config name",15,7,365,25,18,INK,true)
    nameBox=create("TextBox",{Name="ConfigNameInput",Text=cleanName(store.Active) or "Default",PlaceholderText="Config name",
        ClearTextOnFocus=false,Font=Enum.Font.SourceSans,TextSize=18,TextColor3=INK,BackgroundColor3=WHITE,
        BackgroundTransparency=0.2,BorderSizePixel=0,Position=UDim2.fromOffset(15,39),Size=UDim2.fromOffset(372,31)},nameRow)
    round(nameBox,6);stroke(nameBox,rgb(142,188,203),0.35)
    table.insert(categories[4].LeftGroup.Items,{Instance=nameRow,Height=84});state.Relayout(categories[4].LeftGroup)
    api.AddButton({Id="config.Save",Parent=left,Text="Save config",ButtonText="Save",Compact=true,SuccessText="Saved",
        Callback=function() return api.SaveConfig(nameBox.Text) end})
    local loadButton=api.AddButton({Id="config.Load",Parent=left,Text="Load config",ButtonText="Load",Compact=true,SuccessText="Loaded",
        Callback=function() return api.LoadConfig(nameBox.Text) end})
    api.AddButton({Id="settings.Reset",Parent=left,Text="Reset interface",ButtonText="Reset",Compact=true,Callback=api.ResetSettings})
    local list=create("ScrollingFrame",{Name="ConfigList",Size=UDim2.fromOffset(402,176),BackgroundTransparency=1,
        BorderSizePixel=0,Active=true,ScrollingEnabled=true,ScrollBarThickness=4,ScrollBarImageColor3=rgb(108,166,185),
        CanvasSize=UDim2.fromOffset(0,0),ScrollingDirection=Enum.ScrollingDirection.Y},right)
    table.insert(categories[4].RightGroup.Items,{Instance=list,Height=176})
    local activeLabel=label(right,"ActiveConfig","",0,0,402,28,16,MUTED,true)
    table.insert(categories[4].RightGroup.Items,{Instance=activeLabel,Height=28})
    refreshConfigs=function()
        clearDelete()
        for _,child in ipairs(list:GetChildren()) do releaseTree(child);child:Destroy() end
        local names=api.ListConfigs()
        for index,name in ipairs(names) do
            local row=frame(list,"ConfigRow"..index,1,(index-1)*44,390,36,WHITE,0.12,8)
            row:SetAttribute("ConfigName",name)
            gradient(row,{{0,rgb(249,255,255)},{1,name==store.Active and rgb(192,230,243) or rgb(220,240,243)}})
            stroke(row,rgb(143,190,207),0.4)
            local pick=create("TextButton",{Name="SelectConfig",Text=name,Font=Enum.Font.SourceSansSemibold,
                TextSize=17,TextColor3=INK,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,
                BackgroundTransparency=1,AutoButtonColor=false,Position=UDim2.fromOffset(12,0),Size=UDim2.fromOffset(225,36)},row)
            local editing=editingName==name
            pick.Visible=not editing
            local editBox
            if editing then
                editBox=create("TextBox",{Name="RenameInput",Text=name,ClearTextOnFocus=false,Font=Enum.Font.SourceSans,
                    TextSize=17,TextColor3=INK,TextXAlignment=Enum.TextXAlignment.Left,BackgroundColor3=WHITE,
                    BackgroundTransparency=0.12,BorderSizePixel=0,Position=UDim2.fromOffset(8,4),Size=UDim2.fromOffset(224,28)},row)
                round(editBox,5);stroke(editBox,rgb(126,182,203),0.25)
                connect(editBox.FocusLost,function(enter) if enter then api.RenameConfig(name,editBox.Text) end end,row)
                connect(UIS.InputBegan,function(input)
                    if input.KeyCode==Enum.KeyCode.Escape then editingName=nil;refreshConfigs() end
                end,row)
                editBox:CaptureFocus()
            end
            local rename=button(row,"RenameConfig",editing and "Save" or "Rename",240,4,68,28,false)
            local remove=button(row,"DeleteConfig",editing and "Cancel" or "Delete",314,4,68,28,false)
            rename:FindFirstChild("Caption").TextSize=14;remove:FindFirstChild("Caption").TextSize=14
            local red=frame(remove,"ConfirmRed",0,0,68,28,WHITE,1,8)
            gradient(red,{{0,rgb(255,187,175)},{0.47,rgb(236,113,98)},{0.5,rgb(184,52,44)},{1,rgb(237,125,101)}})
            remove:FindFirstChild("Caption").ZIndex=3
            remove:FindFirstChild("GlassReflection").ZIndex=2
            remove:FindFirstChild("HoverGlow").ZIndex=4
            connect(pick.Activated,function() clearDelete();nameBox.Text=name;loadButton.Disabled=false end,row)
            connect(rename.Activated,function()
                if editing then api.RenameConfig(name,editBox.Text)
                else editingName=name;refreshConfigs() end
            end,row)
            connect(remove.Activated,function()
                if editing then editingName=nil;refreshConfigs();return end
                if deleteName==name then api.DeleteConfig(name);return end
                clearDelete();deleteName=name
                remove:FindFirstChild("Caption").Text="Confirm"
                tween(red,{BackgroundTransparency=0},0.16)
                restoreDelete=function()
                    remove:FindFirstChild("Caption").Text="Delete"
                    tween(red,{BackgroundTransparency=1},0.16)
                end
                deleteTask=schedule(3,clearDelete)
            end,row)
        end
        if #names==0 then label(list,"Empty","No saved configs",12,8,370,28,17,MUTED) end
        list.CanvasSize=UDim2.fromOffset(0,math.max(36,#names*44))
        loadButton.Disabled=store.Profiles[cleanName(nameBox.Text)]==nil
        activeLabel.Text=store.Active and ("Active: "..store.Active) or "No active config"
        presetNameLabel.Text=store.Active or "Default"
    end
    connect(nameBox:GetPropertyChangedSignal("Text"),function() loadButton.Disabled=store.Profiles[cleanName(nameBox.Text)]==nil end,nameRow)
    state.OpenConfig=function() selectPage(3);selectCategory(4) end
    local autoConfigName=cleanName(store.Active)
    connect(unloadButton.Activated,api.Unload,unloadButton)
    for _,view in ipairs(categories) do state.Relayout(view.LeftGroup);state.Relayout(view.RightGroup) end
    applySettings()
    selectCategory(1)
    refreshConfigs()
    if autoConfigName and store.Profiles[autoConfigName] then api.LoadConfig(autoConfigName,true) end
end
connect(gui.Destroying,function() state.ExternalDestroy=true;api.Destroy() end)
api.Version="3.3.0"
env.AeroUI=api
-- See Aero-Examples.luau for a standalone raw-loaded demo.
return api
