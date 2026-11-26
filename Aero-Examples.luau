-- OPTIONAL: run AFTER Aero.luau to try the reusable controls on the Player page.
-- These examples affect the interface only.
local UI = assert(getgenv().AeroUI, "Run Aero.luau first")
local playerScroll = assert(UI.Gui:FindFirstChild("PlayerScroll", true), "Player panel missing")
local demoParent = assert(playerScroll:FindFirstChild("LeftColumn"), "Player column missing")

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
-- UI:SelectTab("Visuals")
-- UI:SelectTab("Automation")
-- UI:Unload()

return { Button = action, Toggle = enabled, Slider = slider }
