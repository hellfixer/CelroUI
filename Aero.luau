-- AERO | Visual-only control panel. Feature controls change UI state only.
-- Potassium: run this script after attaching to a Roblox client.
-- Local artwork: workspace/Aero/aero-landscape.png
-- Right Shift: show / hide. Drag the title bar to move.
-- v3.1: named config management, Aero details and explicit runtime table types.

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
    ToggleKey = "RightShift", Notifications = true, NotifyWhenHidden = true,
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
    UpdateBinding: any, UnbindHotkey: any,
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
    tabButtons[index] = { Button=tab, Visual=visual, Orb=tabOrb, IconScale=iconScale,
        FloatLayer=floatLayer,AlphaObjects=alphaObjects }
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
    state.DragTarget, state.SliderDrag = nil, nil
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
    if not alive or state.CapturingKey or input.KeyCode~=Enum.KeyCode[preferences.ToggleKey] then return false end
    if state.TogglePressed==input.KeyCode then return not UIS:GetFocusedTextBox() end
    state.TogglePressed=input.KeyCode
    if UIS:GetFocusedTextBox() then return false end
    showWindow(hidden)
    return true
end
connect(UIS.InputBegan, function(input, _processed)
    if state.CapturingKey then
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        state.CapturingKey = false
        if input.KeyCode ~= Enum.KeyCode.Escape then api.SetSetting("ToggleKey", input.KeyCode.Name) end
        state.TogglePressed=input.KeyCode -- A captured key must be released before it can toggle.
        if state.RefreshSettings then state.RefreshSettings() end
        return
    end
    -- Only the explicitly selected shortcut bypasses gameProcessedEvent.
    shortcutBegan(input)
end)
do
    local ok,actions=pcall(function() return game:GetService("ContextActionService") end)
    if ok and actions then
        local actionName="Aero.Toggle."..HttpService:GenerateGUID(false)
        local boundKey
        state.UpdateBinding=function()
            if boundKey==preferences.ToggleKey then return end
            state.TogglePressed=nil
            local key=preferences.ToggleKey
            local success=pcall(function()
                actions:UnbindAction(actionName)
                actions:BindActionAtPriority(actionName,function(_,inputState,input)
                    local handle=alive and not state.CapturingKey and not UIS:GetFocusedTextBox()
                    if inputState==Enum.UserInputState.Begin then handle=shortcutBegan(input)
                    elseif inputState==Enum.UserInputState.Cancel then state.TogglePressed=nil
                    elseif inputState==Enum.UserInputState.End and state.TogglePressed==input.KeyCode then state.TogglePressed=nil end
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
    if state.TogglePressed==input.KeyCode then state.TogglePressed=nil end
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
    state.SliderDrag = nil
    state.DragTarget = nil
    if activeTweens[anchor] then activeTweens[anchor]:Cancel() end
    state.CapturingKey = false
    state.TogglePressed=nil
    if state.RefreshSettings then state.RefreshSettings() end
end)

local function setMinimized(value)
    if not alive then return end
    minimized=value==true
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
env.AeroUI = api
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
            if data.Disabled and state.SliderDrag and state.SliderDrag.Handle==handle then state.SliderDrag=nil end
            data.Refresh()
        end
        function methods:SetVisible(value)
            if not alive or data.Destroyed then return end
            data.Visible=value~=false;object.Visible=data.Visible;relayout(group)
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
            data.Value=value;data.Refresh()
            if fireCallback then data.Invoke(value) end
            return true
        end
        function methods:Destroy()
            if data.Destroyed then return end
            data.Destroyed=true;cancelTask(data.Job);cancelTask(data.FeedbackTask)
            if state.SliderDrag and state.SliderDrag.Handle==handle then state.SliderDrag=nil end
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
                else error("Use control methods; '"..tostring(key).."' is read-only",2) end
            end,
        })
        data.Handle=handle;data.Title=title;data.DescriptionLabel=description
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
            if data.Disabled or data.Busy then return end
            if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
                state.SliderDrag={Handle=handle,Touch=input.UserInputType==Enum.UserInputType.Touch and input or nil,Update=pointerValue}
                pointerValue(input)
            end
        end,data.Instance)
        connect(minus.Activated,function() handle:SetValue(data.Value-step,true) end,data.Instance)
        connect(plus.Activated,function() handle:SetValue(data.Value+step,true) end,data.Instance)
        data.Refresh();return handle
    end
    function state.UpdateSlider(input)
        local active=state.SliderDrag
        if active and ((active.Touch and input==active.Touch) or (not active.Touch and input.UserInputType==Enum.UserInputType.MouseMovement)) then active.Update(input) end
    end
    function state.EndSlider(input)
        local active=state.SliderDrag
        if active and (input==active.Touch or input.UserInputType==Enum.UserInputType.MouseButton1) then state.SliderDrag=nil end
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
    local function applySettings()
        shell.BackgroundTransparency=1-preferences.GlassOpacity
        paper.BackgroundTransparency=1-(0.55+0.43*preferences.GlassOpacity)
        local wallpaper=hero:FindFirstChild("AeroWallpaper")
        if wallpaper then wallpaper.Visible=preferences.Wallpaper end
        hill.Visible=preferences.Wallpaper
        for i=1,5 do window["Shadow"..i].Visible=preferences.Shadows end
        dragSurface.Modal=preferences.FreeMouse and not hidden
        if state.UpdateBinding then state.UpdateBinding() end
        if preferences.LockPosition then dragging=false;state.DragTarget=nil end
        shortcut.Text=preferences.ToggleKey.."  ·  Toggle menu"
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
    local keyControl=api.AddButton({Id="settings.Shortcut",Parent=left,Text="Toggle shortcut",Description="RightShift",ButtonText="Change",SuccessFeedback=false,Callback=function()
        state.CapturingKey=not state.CapturingKey;refreshSettings()
    end})
    table.insert(state.Refreshers,function()
        keyControl.Description=state.CapturingKey and "Press a key. Escape cancels." or preferences.ToggleKey
        keyControl:SetButtonState(state.CapturingKey and "waiting" or "default")
    end)
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
api.Version="3.1.0"
-- See API-Examples.luau for independent, copyable extension examples.
return api
