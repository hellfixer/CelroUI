-- Run this file on its own to load Aero and add examples to the Player page.
-- loadstring(game:HttpGet("https://raw.githubusercontent.com/hellfixer/CelroUI/refs/heads/main/Aero-Examples.luau"))()
-- These examples affect the interface only.
local AERO_URL = "https://raw.githubusercontent.com/hellfixer/CelroUI/refs/heads/main/Aero.luau"
local env = (type(getgenv) == "function" and getgenv()) or _G
local function supportsExamples(ui)
    return type(ui) == "table" and ui.Gui ~= nil
        and type(ui.AddDropdown) == "function" and type(ui.AddTextInput) == "function"
        and type(ui.AddColorPicker) == "function" and type(ui.AddKeybind) == "function"
        and type(ui.SetTabIcon) == "function"
end
local UI = env.AeroUI
if not supportsExamples(UI) then
    local downloaded, source = pcall(function() return game:HttpGet(AERO_URL) end)
    assert(downloaded, "Could not download Aero.luau: " .. tostring(source))
    local chunk, compileError = loadstring(source, "@Aero.luau")
    assert(chunk, compileError)
    UI = chunk()
    assert(supportsExamples(UI), "The raw Aero.luau must include the v3.3 controls")
end
local playerScroll = assert(UI.Gui:FindFirstChild("PlayerScroll", true), "Player panel missing")
local demoParent = assert(playerScroll:FindFirstChild("LeftColumn"), "Player column missing")
local right = assert(playerScroll:FindFirstChild("RightColumn"), "Right Player column missing")

local action = UI:AddButton({
    Id = "demo.action", -- Unique IDs prevent accidental duplicate controls.
    Parent = demoParent,
    Text = "A glossy button",
    Description = "Enable the toggle below to use this button.",
    ButtonText = "Try it",
    Disabled = true,
    Callback = function()
        UI:Notify({
            Id = "demo.button-result", -- Reuses this notification instead of stacking copies.
            Title = "Hello from Aero!",
            Text = "Your button callback is working.",
            Type = "success", -- info, success, warning, error
            Duration = 4,
        })
    end,
})

local enabled = UI:AddToggle({
    Id = "demo.enabled",
    Parent = demoParent,
    Text = "Enable the example button",
    Description = "A smooth switch with a boolean callback.",
    Default = false,
    Disabled = false,
    Callback = function(value)
        action.Disabled = not value
        -- Equivalent: action:SetDisabled(not value)
    end,
})

local slider = UI:AddSlider({
    Id = "demo.slider",
    Parent = demoParent,
    Text = "Example amount",
    Description = "Drag the slider or use its plus and minus buttons.",
    Min = 0, Max = 100, Step = 5, Default = 50,
    Format = function(value) return value .. "%" end,
    Callback = function(value)
        UI:Notify({Id="demo.slider-result",Title="Amount changed",Text="Current value: " .. value})
    end,
})

local dropdown = UI:AddDropdown({
    Id = "demo.dropdown",
    Parent = right,
    Text = "Example preset",
    Description = "Choose one preset.",
    Multi = false, -- Single-pick is also the default when Multi is omitted.
    Options = {"Ocean", "Meadow", "Iris", "Rose"},
    Default = "Ocean",
    Callback = function(value)
        UI:Notify({Id = "demo.dropdown-result", Title = "Preset selected", Text = value})
    end,
})

local multiDropdown = UI:AddDropdown({
    Id = "demo.multi-dropdown",
    Parent = right,
    Text = "Example layers",
    Description = "Pick any number of layers.",
    Multi = true,
    Options = {"Glass", "Wallpaper", "Shadows"},
    Default = {"Glass"},
    Callback = function(values)
        UI:Notify({
            Id = "demo.multi-dropdown-result",
            Title = "Layers selected",
            Text = #values == 0 and "None" or table.concat(values, ", "),
        })
    end,
})

local textInput = UI:AddTextInput({
    Id = "demo.text",
    Parent = right,
    Text = "Example label",
    Description = "Press Enter or click away to save your text.",
    Placeholder = "Type a label",
    Callback = function(value)
        action.Text = value == "" and "A glossy button" or value
    end,
})

local colorPicker = UI:AddColorPicker({
    Id = "demo.color",
    Parent = right,
    Text = "Example color",
    Description = "Pick a shade or enter a hex color.",
    Default = "#33A4DB",
    Callback = function(color)
        UI:Notify({Id = "demo.color-result", Title = "Color selected", Text = "#" .. color:ToHex():upper()})
    end,
})

local keybind = UI:AddKeybind({
    Id = "demo.keybind",
    Parent = right,
    Text = "Example shortcut",
    Description = "Click the key to rebind or the mode to switch.",
    Default = Enum.KeyCode.K,
    Mode = "Toggle",
    Callback = function(active, control)
        UI:Notify({
            Id = "demo.keybind-result",
            Title = active and "Shortcut active" or "Shortcut released",
            Text = control.Value.Name .. " · " .. control.Mode,
        })
    end,
})

UI:SetTabIcon("Player", "circle-user-round")
UI:SetTabIcon("Visuals", "scan-eye")
UI:SelectTab(2)

-- Runtime changes:
-- action.Disabled = true
-- action:SetDisabled(false)
-- action.Visible = false              -- Removes the row and closes the layout gap.
-- action:SetVisible(true)
-- action.Text = "A different title"
-- enabled:SetValue(true, true)          -- Set value AND invoke its callback.
-- enabled.Value = false                -- Silent programmatic change.
-- slider:SetValue(75)                   -- Clamps and snaps to the declared range.
-- UI:GetControl("demo.action")         -- Look up a handle by ID.
-- action:Destroy()                     -- Cancels its callback and releases its listeners.
-- UI:SetTabDisabled(2, true)
-- UI:SetTabDisabled(2, false)
-- UI:SetSetting("Accent", "Meadow")
-- UI:SaveSettings()
-- UI:SaveConfig("My config")            -- Saves interface and built-in preview values.
-- UI:LoadConfig("My config")
-- dropdown:SetValue("Iris", true)        -- Select and invoke the callback.
-- multiDropdown:SetValue({"Glass", "Shadows"}, true)
-- multiDropdown:SetValue({})           -- Clears the selection.
-- local picks = multiDropdown:GetValue() -- Read-only array in option order.
-- local icons = UI:GetLucideIcons()     -- Lists the bundled icon names.
-- UI:SetTabIcon("Player", "user")
-- UI:SetTabIcon("Player", nil)          -- Restores the original icon.
-- textInput.Value = "Aero label"        -- Set silently.
-- colorPicker:SetValue("#74BE37")       -- Also accepts Color3.
-- keybind.Value = Enum.KeyCode.J        -- Set the key silently.
-- keybind:SetMode("Hold")              -- Active from press to release.
-- keybind.Mode = "Toggle"              -- A press flips the active state.
-- UI:SetSetting("ToggleMode", "Hold")   -- Changes the window shortcut in Settings → Window.
-- UI:GetControl("demo.color"):Destroy()
-- UI:SelectTab("Visuals")
-- UI:SelectTab("Automation")
-- UI:Unload()

return {
    Button = action, Toggle = enabled, Slider = slider,
    Dropdown = dropdown, MultiDropdown = multiDropdown,
    TextInput = textInput, ColorPicker = colorPicker, Keybind = keybind,
}
