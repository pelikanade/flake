local terminal = @terminal@
local ipc = @ipc@
local logout = @logout@
local reload = @reload@

local function bind(keys, dispatcher, options)
    hl.bind(keys, dispatcher, options or {})
end

local function shell(keys, command, options)
    bind(keys, hl.dsp.exec_cmd(ipc .. command), options)
end

local repeating = { repeating = true }
local directions = {
    { "H", "Left", "l", -10, 0 },
    { "J", "Down", "d", 0, 10 },
    { "K", "Up", "u", 0, -10 },
    { "L", "Right", "r", 10, 0 },
}

for _, direction in ipairs(directions) do
    for _, key in ipairs({ direction[1], direction[2] }) do
        bind("SUPER + " .. key, hl.dsp.focus({ direction = direction[3] }), repeating)
        bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ direction = direction[3] }), repeating)
    end
end

for workspace = 1, 10 do
    local key = tostring(workspace % 10)
    bind("SUPER + " .. key, hl.dsp.focus({ workspace = workspace }))
    -- Sway's move-to-workspace leaves focus on the current workspace.
    bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = workspace, follow = false }))
end

bind("SUPER + B", hl.dsp.layout("preselect r"))
bind("SUPER + E", function()
    local active = hl.get_active_window()
    if active and active.group then
        hl.dispatch(hl.dsp.group.toggle())
    else
        hl.dispatch(hl.dsp.layout("togglesplit"))
    end
end)
bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + R", hl.dsp.submap("resize"))

hl.define_submap("resize", function()
    for _, direction in ipairs(directions) do
        for _, key in ipairs({ direction[1], direction[2] }) do
            bind(key, hl.dsp.window.resize({ x = direction[4], y = direction[5], relative = true }), repeating)
        end
    end
    for _, key in ipairs({ "Escape", "Return" }) do
        bind(key, hl.dsp.submap("reset"))
    end
end)

-- Native Hyprland groups approximate Sway's tabbed/stacked containers.
-- The groupbar style applies to all groups; Hyprland has no parent focus.
local function group_layout(stacked)
    local active = hl.get_active_window()
    if not active then return end
    hl.config({ group = { groupbar = { stacked = stacked } } })
    if not active.group then
        hl.dispatch(hl.dsp.group.toggle())
    end
end
bind("SUPER + W", function() group_layout(false) end)
bind("SUPER + S", function() group_layout(true) end)

local function focus_other_layer()
    local active = hl.get_active_window()
    local workspace = hl.get_active_workspace()
    if not active or not workspace then return end
    local target
    for _, window in ipairs(hl.get_workspace_windows(workspace)) do
        if window.mapped and window.floating ~= active.floating then
            if not target or window.focus_history_id < target.focus_history_id then
                target = window
            end
        end
    end
    if target then hl.dispatch(hl.dsp.focus({ window = target })) end
end
bind("SUPER + ALT + Space", focus_other_layer)
bind("SUPER + SHIFT + Space", hl.dsp.window.float())

bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

bind("SUPER + minus", hl.dsp.workspace.toggle_special("scratchpad"))
bind("SUPER + SHIFT + minus", function()
    hl.dispatch(hl.dsp.window.float({ action = "set" }))
    hl.dispatch(hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))
end)

bind("SUPER + Q", hl.dsp.exec_cmd(terminal))
bind("SUPER + C", hl.dsp.window.close())
shell("SUPER + D", "panel-toggle launcher")
shell("SUPER + V", "panel-toggle clipboard")
shell("SUPER + SHIFT + S", "screenshot-region")
shell("SUPER + SHIFT + A", "screenshot-annotate")
shell("SUPER + SHIFT + P", "screenshot-fullscreen")
shell("SUPER + Escape", "session lock", { dont_inhibit = true, submap_universal = true })
shell("switch:on:Lid Switch", "session lock-and-suspend", { locked = true })
bind("SUPER + SHIFT + C", hl.dsp.exec_cmd(reload))
bind("SUPER + SHIFT + E", hl.dsp.exec_cmd(logout))

local media = {
    XF86AudioRaiseVolume = "volume-up",
    XF86AudioLowerVolume = "volume-down",
    XF86AudioMute = "volume-mute",
    XF86AudioMicMute = "mic-mute",
    XF86AudioPlay = "media toggle",
    XF86AudioStop = "media stop",
    XF86AudioPrev = "media previous",
    XF86AudioNext = "media next",
    XF86MonBrightnessUp = "brightness-up",
    XF86MonBrightnessDown = "brightness-down",
}
for key, command in pairs(media) do
    local repeat_key = key == "XF86AudioRaiseVolume" or key == "XF86AudioLowerVolume"
        or key == "XF86MonBrightnessUp" or key == "XF86MonBrightnessDown"
    shell(key, command, { locked = true, repeating = repeat_key, submap_universal = true })
end
