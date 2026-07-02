-- Lasso - Hammerspoon prototype runtime
-- Watches ~/.lasso for tiny event files and routes focus away/back.
-- Public build is adapter-neutral: any local tool can write the event files.

local HOME        = os.getenv("HOME")
local RUNTIME_DIR  = HOME .. "/.lasso/"
local CONFIG_PATH = RUNTIME_DIR .. "config.json"
local AWAY_FLAG   = RUNTIME_DIR .. ".switch-away"
local BACK_FLAG   = RUNTIME_DIR .. ".switch-back"

require("hs.ipc")  -- enable the `hs` CLI so we can test focus calls directly (debug)

-- Long-lived watchers/eventtaps MUST be retained or Hammerspoon garbage-
-- collects them and they silently stop firing. A file-local is NOT enough:
-- nothing references these as an upvalue, so the object becomes collectable
-- once init.lua finishes. We pin each one in this GLOBAL table, which the Lua
-- state keeps alive forever. (This is the real fix the forward-decls only faked.)
_G.AR_RETAIN = {}

local defaults = {
    enabled    = true,
    awayApp    = "Google Chrome",  -- where to send focus after you submit
    returnApp = "Terminal",       -- app to return to by default
    chatApp    = "Assistant",      -- desktop app whose chat generation we detect via AX
    delay      = 1.5,              -- seconds before the away switch
    chatDetect = false,            -- BETA: route regular chats too (AX-based). Off by default.
    debug      = false,            -- show what the chat detector sees (alerts + console)
    awayWinId    = false,          -- pinned Chrome window id to fly to (false = any window)
    awayWinTitle = false,          -- its title, for display + fallback matching
    awaySpaceId  = false,          -- set when the pinned target is a fullscreen Chrome Space
}

-- forward declarations (Lua needs these defined before use in closures)
-- NOTE: pathWatcher MUST be kept in a long-lived variable. Hammerspoon
-- garbage-collects watchers with no retained reference, which makes them
-- silently stop firing after a while. Same applies to menubar / hotkeys.
local config, menubar, switchTimer, cancelHotkey, pathWatcher, reloadWatcher
local sendKeyTap, chatWatcher  -- chat detector: must be retained or GC stops them
local iconOn, iconOff            -- menu-bar lasso icons (on = full, off = dimmed)
-- The RETURN TARGET captured at send-time (while chat app is still on-screen), so
-- switchBack can return explicitly instead of relying on fragile live AX/window
-- enumeration from inside the away Space. Fields: appName, bundleId, win (hs.window),
-- winId, winTitle, space (hs.spaces id), awayApp, awayBundle.
local lastReturn
-- PER-SESSION return targets, keyed by hook-driven workflow session_id (the hooks write it
-- into the flag files). So "submit in session A, drift into B, A finishes" returns
-- to A's OWN window - instead of one shared slot that B's submit would overwrite.
-- Chat / anything with no session_id still uses lastReturn.
local tasks = {}
local lastAwayArm    -- timestamp of last away-arm, to dedup hook + AX double-fire
local lastHookSubmit -- timestamp of the last hook-driven workflow (hook) submit, so the chat
                     -- detector can skip a hook Enter instead of polling it for seconds
local loadConfig, saveConfig, updateMenu, toggleEnabled, chooseApp, chooseChromeWindow, armSwitch, switchBack, focusAway

loadConfig = function()
    config = hs.json.read(CONFIG_PATH) or {}
    for k, v in pairs(defaults) do
        if config[k] == nil then config[k] = v end
    end
end

saveConfig = function()
    hs.json.write(config, CONFIG_PATH, true, true)  -- prettyprint, replace
end

-- hs.application.get/find can match window titles; "chat app" can accidentally
-- resolve to a Chrome window titled "... hook-driven workflow ...". For app routing and
-- AX access, only accept real application objects with an exact app name/bundle.
local function applicationByName(name)
    if not name or name == "" then return nil end
    for _, app in ipairs(hs.application.runningApplications()) do
        if app:name() == name or app:bundleID() == name then return app end
    end
    return nil
end

updateMenu = function()
    if not menubar then return end
    -- Lasso icon: full when on, dimmed when off. Falls back to a coloured dot
    -- if the icons didn't load (e.g. older macOS without SVG support).
    if iconOn and iconOff then
        menubar:setTitle("")
        menubar:setIcon(config.enabled and iconOn or iconOff)
    else
        menubar:setTitle(config.enabled and "ON" or "OFF")
    end
    menubar:setTooltip("Lasso: " .. (config.enabled and "on" or "off"))
    menubar:setMenu({
        { title = "Lasso", disabled = true },
        { title = "-" },
        { title = (config.enabled and "Enabled" or "Enable") .. "   (Ctrl+Alt+Cmd+A)", fn = toggleEnabled },
        { title = "-" },
        { title = "Away app:  " .. config.awayApp,           fn = function() chooseApp("awayApp",    "Away app") end },
        { title = "Away window:  " .. (config.awayWinTitle or "any Chrome window"), fn = chooseChromeWindow },
        { title = "Return app:  " .. config.returnApp, fn = function() chooseApp("returnApp", "Return app") end },
        { title = "Delay:  " .. config.delay .. "s",         fn = function()
            local opts = {0.5, 1.0, 1.5, 2.0, 3.0}
            local i = 1
            for n, v in ipairs(opts) do if v == config.delay then i = n end end
            config.delay = opts[(i % #opts) + 1]
            saveConfig(); updateMenu()
            hs.alert.show("Away delay: " .. config.delay .. "s")
        end },
        { title = "-" },
        { title = (config.chatDetect and "[x] " or "") .. "Chat detect (beta)", fn = function()
            config.chatDetect = not config.chatDetect
            saveConfig(); updateMenu()
            hs.alert.show("Chat detect " .. (config.chatDetect and "ON" or "OFF"))
        end },
        { title = (config.debug and "[x] " or "") .. "Debug detector", fn = function()
            config.debug = not config.debug
            saveConfig(); updateMenu()
            hs.alert.show("Debug " .. (config.debug and "ON" or "OFF"))
        end },
        { title = "-" },
        { title = "Reload config", fn = function() hs.reload() end },
    })
end

toggleEnabled = function()
    config.enabled = not config.enabled
    saveConfig()
    updateMenu()
    hs.alert.show("Lasso " .. (config.enabled and "ON" or "OFF"))
end

chooseApp = function(key, label)
    local seen, choices = {}, {}
    for _, app in ipairs(hs.application.runningApplications()) do
        local name = app:name()
        -- kind() == 1 means a normal GUI app with a Dock icon
        if name and name ~= "" and not seen[name] and app:kind() == 1 then
            seen[name] = true
            table.insert(choices, { text = name })
        end
    end
    table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
    local chooser = hs.chooser.new(function(choice)
        if choice then
            config[key] = choice.text
            saveConfig(); updateMenu()
            hs.alert.show(label .. ": " .. choice.text)
        end
    end)
    chooser:choices(choices)
    chooser:placeholderText("Choose " .. label)
    chooser:show()
end

-- Pick exactly which Chrome window the away-switch flies to. We store its
-- window id (stable while the window exists) + title (fallback + display).
chooseChromeWindow = function()
    local app = hs.application.get("Google Chrome")
    if not app then hs.alert.show("Chrome isn't running"); return end
    local choices = { { text = "Any Chrome window", subText = "don't pin a window", winId = false } }
    for _, w in ipairs(app:allWindows()) do
        local t = w:title()
        if t and t ~= "" then
            local scr = (w:screen() and w:screen():name()) or "?"
            local ok, sp = pcall(hs.spaces.windowSpaces, w)
            local spc = (ok and type(sp) == "table" and sp[1]) and ("  - Space " .. tostring(sp[1])) or ""
            choices[#choices + 1] = {
                text    = t,
                subText = (w:isMinimized() and "minimized - " or "") .. scr .. spc,
                winId   = w:id(),
            }
        end
    end
    local chooser = hs.chooser.new(function(c)
        if not c then return end
        config.awayWinId    = c.winId or false
        config.awayWinTitle = c.winId and c.text or false
        config.awaySpaceId  = false        -- never pin a fullscreen Space
        saveConfig(); updateMenu()
        hs.alert.show("Away: " .. (config.awayWinTitle or "any Chrome window"))
    end)
    chooser:choices(choices)
    chooser:placeholderText("Pick the Chrome window to switch to")
    chooser:show()
end

-- Find the pinned Chrome window by id (then title), even if minimised / on
-- another Space or screen. Returns the hs.window or nil.
local function chromeWindowById(id, titleHint)
    local app = hs.application.get("Google Chrome")
    if not app then return nil end
    if id then
        local w = hs.window.get(id)
        if w and w:application() and w:application():name() == "Google Chrome" then return w end
        for _, ww in ipairs(app:allWindows()) do if ww:id() == id then return ww end end
    end
    if titleHint and titleHint ~= "" then
        for _, ww in ipairs(app:allWindows()) do if ww:title() == titleHint then return ww end end
    end
    return nil
end

-- Bring a window fully forward: un-minimise it, hop to its Space if it's on a
-- different one (the three-finger swipe, done for you via hs.spaces), then
-- focus + raise. Returns false only if the window is gone/invalid.
local function summonWindow(win)
    if not win then return false end
    if not pcall(function() return win:id() end) then return false end  -- stale window
    pcall(function() if win:isMinimized() then win:unminimize() end end)
    local hopped = false
    if hs.spaces then
        local ok, wspaces = pcall(hs.spaces.windowSpaces, win)
        if ok and type(wspaces) == "table" and #wspaces > 0 then
            local cur, onCur = hs.spaces.focusedSpace(), false
            for _, s in ipairs(wspaces) do if s == cur then onCur = true end end
            if not onCur then pcall(hs.spaces.gotoSpace, wspaces[1]); hopped = true end
        end
    end
    local function land() pcall(function() win:focus(); win:raise() end) end
    if hopped then hs.timer.doAfter(0.35, land) else land() end  -- let the Space settle
    return true
end

-- A normal (non-minimised, non-fullscreen) Chrome window, preferring one on the
-- CURRENT Space so the away-switch is an instant in-place flip - never a hop into
-- a fullscreen Space. (Fullscreen Spaces are what hid chat app from the detection /
-- switch-back APIs and caused every "won't come back" bug; we never go there now.)
local function normalChromeWindow()
    local app = hs.application.get("Google Chrome")
    if not app then return nil end
    local cur = hs.spaces and hs.spaces.focusedSpace()
    local onCur, anyWin
    for _, w in ipairs(app:allWindows()) do          -- fullscreen windows aren't even in allWindows()
        if w:isStandard() and not w:isMinimized() then
            local sp = nil
            if hs.spaces then local ok, v = pcall(hs.spaces.windowSpaces, w); if ok then sp = v end end
            local isFS = (sp and sp[1] and hs.spaces.spaceType and hs.spaces.spaceType(sp[1]) == "fullscreen") or false
            if not isFS then
                anyWin = anyWin or w
                if cur and type(sp) == "table" then
                    for _, s in ipairs(sp) do if s == cur then onCur = onCur or w end end
                end
            end
        end
    end
    return onCur or anyWin
end

-- Quick, in-place switch to the away target - NEVER a fullscreen Space hop.
-- Chrome: a pinned normal window if one is set, else any normal window (preferring
-- the current Space, so it's instant); otherwise just activate the app.
focusAway = function()
    local function go(how, fn) if config.debug then hs.printf("[router] focusAway: %s", how) end; fn() end
    if config.awayApp == "Google Chrome" then
        if config.awayWinId then
            local win = chromeWindowById(config.awayWinId, config.awayWinTitle)
            if win then go("summon pinned window " .. tostring(config.awayWinId), function() summonWindow(win) end); return end
        end
        local win = normalChromeWindow()
        if win then go("focus normal Chrome window " .. tostring(win:id()), function() summonWindow(win) end); return end
    end
    go("launchOrFocus " .. tostring(config.awayApp), function() hs.application.launchOrFocus(config.awayApp) end)
end

armSwitch = function(sid)
    if not config.enabled then return end
    -- Dedup: a hook-driven workflow submit fires BOTH the hook and the AX key-detector.
    -- Ignore a second arm within 2s so we don't show the alert / switch twice.
    local now = hs.timer.secondsSinceEpoch()
    if lastAwayArm and (now - lastAwayArm) < 2.0 then return end
    lastAwayArm = now
    -- Capture the RETURN TARGET now, while the submitting window is still frontmost.
    -- Saved by app identity (name + bundle id) AND window ref/id/title AND Space, so
    -- switchBack can return precisely later. Also stored under the session_id (when
    -- the hook gives one) so each session returns to its OWN window.
    local fw      = hs.window.focusedWindow()
    local fapp    = (fw and fw:application()) or hs.application.frontmostApplication()
    local awayObj = hs.application.get(config.awayApp)
    lastReturn = {
        appName    = (fapp and fapp:name()) or config.returnApp,
        bundleId   = fapp and fapp:bundleID() or nil,
        win        = fw or nil,
        winId      = fw and fw:id() or nil,
        winTitle   = fw and fw:title() or nil,
        space      = (hs.spaces and hs.spaces.focusedSpace()) or nil,
        awayApp    = config.awayApp,
        awayBundle = awayObj and awayObj:bundleID() or nil,
    }
    if sid then tasks[sid] = lastReturn; lastHookSubmit = now end   -- per-session target + mark a hook submit
    if config.debug then
        hs.printf("[router] arm capture: sid=%s app=%s winId=%s title=%q space=%s away=%s",
            tostring(sid), tostring(lastReturn.appName), tostring(lastReturn.winId),
            tostring(lastReturn.winTitle or ""), tostring(lastReturn.space), tostring(lastReturn.awayApp))
    end
    if switchTimer then switchTimer:stop() end
    cancelHotkey:enable()
    hs.alert.show("Switching away in " .. config.delay .. "s - Cmd+Shift+. to cancel", config.delay - 0.1)
    local submitApp = lastReturn.appName   -- the app we submitted from (auto-detected)
    switchTimer = hs.timer.doAfter(config.delay, function()
        switchTimer = nil
        cancelHotkey:disable()
        -- Anti-yank: only fire the away if you're STILL in the app you submitted
        -- from. Auto-detected from the capture above, so this works for the chat app
        -- desktop app AND any terminal (iTerm/Terminal/VS Code) - no fixed setting.
        local f = hs.application.frontmostApplication()
        if f and submitApp and f:name() ~= submitApp then
            if config.debug then hs.printf("[router] away SKIPPED (front=%s submittedFrom=%s)", f:name(), tostring(submitApp)) end
            return
        end
        focusAway()
    end)
end

switchBack = function(sid)
    if switchTimer then switchTimer:stop(); switchTimer = nil end
    if cancelHotkey then cancelHotkey:disable() end

    -- Per-session: a hook-driven workflow Stop names its session_id, so return to THAT
    -- session's captured window (submit in A, drift to B, A finishes -> back to A).
    -- Falls back to the last target for chat / anything with no session_id.
    local ret = (sid and tasks[sid]) or lastReturn
    if sid then tasks[sid] = nil end
    if not ret then return end

    local fapp       = hs.application.frontmostApplication()
    local fname      = fapp and fapp:name() or ""
    local fbund      = fapp and fapp:bundleID() or ""
    local awayName   = ret.awayApp or config.awayApp
    local awayBundle = ret.awayBundle

    -- Anti-yank: proceed only if you're still in the away app (the expected away
    -- state) or already back in chat app. A third app = you wandered off on purpose.
    local inAway   = (awayName ~= "" and fname == awayName)
                        or (awayBundle and fbund ~= "" and fbund == awayBundle) or false
    local inchat app = (fname == ret.appName
                        or (ret.bundleId and fbund == ret.bundleId)) or false
    if not (inAway or inchat app) then
        if config.debug then hs.printf("[router] switchBack sid=%s BLOCKED (front=%s not away/chat)", tostring(sid), fname) end
        return
    end

    local function winValid()
        if not ret.win then return false end
        local ok, id = pcall(function() return ret.win:id() end)
        return ok and id ~= nil
    end
    local function backApp()
        if ret.win then local ok, a = pcall(function() return ret.win:application() end); if ok and a then return a end end
        if ret.appName then local a = applicationByName(ret.appName); if a then return a end end
        if ret.bundleId then
            local a = applicationByName(ret.bundleId)
            if not a then local l = hs.application.applicationsForBundleID(ret.bundleId); a = l and l[1] or nil end
            if a then return a end
        end
        return applicationByName(config.returnApp)
    end

    -- Is the saved window on ANOTHER Space? (cheap; only then do we hop - same-Space
    -- is the common case now and must NOT gotoSpace, or you get the F3 swoosh.)
    local hop = nil
    if winValid() and hs.spaces then
        local ok, wsp = pcall(hs.spaces.windowSpaces, ret.win)
        if ok and type(wsp) == "table" and wsp[1] then
            local curS, onCur = hs.spaces.focusedSpace(), false
            for _, s in ipairs(wsp) do if s == curS then onCur = true end end
            if not onCur then hop = wsp[1] end
        end
    end

    -- Land focus on chat app. ALWAYS activate the owning app (an Electron window will
    -- NOT reliably come forward from window:focus() alone - that was the "doesn't
    -- come back" bug) AND focus the exact window we left.
    local function land()
        local app = backApp()
        if app then pcall(function() app:activate(true) end) end
        if winValid() then
            pcall(function()
                if ret.win:isMinimized() then ret.win:unminimize() end
                ret.win:focus(); ret.win:raise()
            end)
        elseif not app then
            hs.application.launchOrFocus(config.returnApp)
        end
        if config.debug then
            hs.printf("[router] switchBack sid=%s frontWas=%s hop=%s winValid=%s -> activate+focus",
                tostring(sid), fname, tostring(hop), tostring(winValid()))
        end
    end

    -- Same Space (common) -> instant. Another Space -> hop first, then land.
    if hop then pcall(hs.spaces.gotoSpace, hop); hs.timer.doAfter(0.3, land) else land() end
end

-- Cancel the away countdown (only enabled during the countdown).
cancelHotkey = hs.hotkey.new({"cmd", "shift"}, ".", function()
    if switchTimer then switchTimer:stop(); switchTimer = nil end
    cancelHotkey:disable()
    hs.alert.show("Switch cancelled", 1)
end)
cancelHotkey:disable()

-- Global toggle for the whole router.
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "A", function() toggleEnabled() end)

-- Each flag's CONTENT is the hook-driven workflow session_id (the hooks write it), so we can
-- route each session back to its OWN window. Empty content = chat / no id -> fallback.
local function readFlag(path)
    local f = io.open(path, "r"); if not f then return nil end
    local s = f:read("*a") or ""; f:close()
    s = s:gsub("%s+", "")
    if s == "" then return nil end
    return s
end
pathWatcher = hs.pathwatcher.new(RUNTIME_DIR, function(paths)
    for _, p in ipairs(paths) do
        if p:match("%.switch%-away$") and hs.fs.attributes(AWAY_FLAG) then
            local sid = readFlag(AWAY_FLAG)
            os.remove(AWAY_FLAG)
            if config.enabled then armSwitch(sid) end
        elseif p:match("%.switch%-back$") and hs.fs.attributes(BACK_FLAG) then
            local sid = readFlag(BACK_FLAG)
            os.remove(BACK_FLAG)
            if config.enabled then switchBack(sid) end
        end
    end
end)
pathWatcher:start()
AR_RETAIN.pathWatcher = pathWatcher

-- Auto-reload this config whenever init.lua changes, so edits take effect
-- without manually clicking "Reload config". (Retained, per the GC note above.)
reloadWatcher = hs.pathwatcher.new(HOME .. "/.hammerspoon/", function(files)
    for _, f in ipairs(files) do
        if f:sub(-4) == ".lua" then hs.reload(); return end
    end
end)
reloadWatcher:start()
AR_RETAIN.reloadWatcher = reloadWatcher

loadConfig()
saveConfig()  -- materialise defaults on first run
menubar = hs.menubar.new()
-- Load the lasso menu-bar icons as template images (auto-adapt to light/dark).
local function loadIcon(file)
    local img = hs.image.imageFromPath(HOME .. "/.hammerspoon/" .. file)
    if img then img:template(true); img:size({ w = 20, h = 20 }) end
    return img
end
iconOn  = loadIcon("lasso.svg")
iconOff = loadIcon("lasso-off.svg")
updateMenu()

-- Precise window-return (and the hotkeys) need Accessibility. Prompt for it.
local ax = hs.accessibilityState()
if not ax then hs.accessibilityState(true) end  -- opens the System Settings pane
hs.alert.show("Lasso loaded  (" .. (config.enabled and "on" or "off")
    .. ", accessibility " .. (ax and "ok" or "NEEDED") .. ")")

-- Regular chats don't fire hooks. While a CHAT generates, its composer button
-- is labelled "Stop response" (it toggles Send <-> Stop response). A chat app
-- hook-driven session instead shows plain "Stop", so matching "Stop response" ONLY
-- auto-scopes us to chats and ignores the hook-driven session entirely (the hooks
-- already handle hook-driven workflows) -- no false switch-back from another surface's button.
-- Electron hides its a11y tree until asked, so we set AXManualAccessibility.
-- Everything here is gated by config.chatDetect (off by default).
local CHAT_STOP = "Stop response"   -- the chat's generating indicator (NOT plain "Stop")
local NEAR = 140                    -- px tolerance for "same composer = same surface"
local chatActive = false
local chatStopBtn, chatStopX, chatStopY = nil, nil, nil
local chatWin                       -- RETAINED chat-window AX element (see captureChatWindow)
local staleStopHits = 0             -- retained AX nodes can outlive the real button
local lastChatArm = 0               -- debounce rapid re-arms from retries / limit errors
local doneTimer, confirmTimer

local function dbg(msg)
    if config.debug then hs.printf("[router] %s", msg); hs.alert.show(msg, 1.5) end
end

-- the chat app's AX app element. We force the a11y tree open ONCE (it's sticky), not
-- every call: re-poking AXManualAccessibility on each poll grabs focus and
-- yanks you off the fullscreen Space when a chat finishes.
local axManualSet = false
local function chatAX()
    local app = applicationByName(config.chatApp)
    if not app then return nil end
    local axapp = hs.axuielement.applicationElement(app)
    if axapp and not axManualSet then
        pcall(function() axapp:setAttributeValue("AXManualAccessibility", true) end)
        axManualSet = true
    end
    return axapp
end

-- Grab a RETAINED reference to the chat's window AX element while chat app is still
-- on-screen (call this at send-time). THIS is the fix for fullscreen / 2nd-display
-- away targets: once we park on the away Space, the chat app's window is occluded and a
-- fresh axapp:AXWindows() query returns ZERO windows - so the done-poll goes blind
-- and never fires switchBack. A window reference held from on-screen stays fully
-- walkable off-Space (verified: same node/button counts on- and off-Space), so the
-- poll can keep watching the "Stop response" -> "Send" flip from the away Space.
local function focusedChatWindow()
    local axapp = chatAX()
    if not axapp then return nil end
    local ok, fw = pcall(function() return axapp:attributeValue("AXFocusedWindow") end)
    if ok and fw then return fw end
    local wins = axapp:attributeValue("AXWindows") or {}
    return wins[1]
end

local function captureChatWindow(win)
    chatWin = win or focusedChatWindow()
end

local function composerLooksFocused()
    local axapp = chatAX()
    if not axapp then return false end
    local ok, el = pcall(function() return axapp:attributeValue("AXFocusedUIElement") end)
    if not ok or not el then return false end
    local role = el:attributeValue("AXRole")
    if role ~= "AXTextArea" and role ~= "AXTextField" then return false end
    local value = el:attributeValue("AXValue")
    if type(value) == "string" and value:gsub("%s+", "") == "" then return false end
    return true
end

-- The retained window, but only if it's still a walkable handle (nil otherwise).
local function liveChatWin()
    if not chatWin then return nil end
    local ok, kids = pcall(function() return chatWin:attributeValue("AXChildren") end)
    if ok and kids then return chatWin end
    return nil
end

-- One walk of the chat app's windows. Returns: stopEl, stopX, stopY, sendPresent,
-- queuePresent, sendEnabled.
-- stopEl = the chat's "Stop response" button (present = generating).
-- sendPresent = a "Send" button exists (composer idle). They're mutually
-- exclusive, so that Send<->Stop toggle is our corroborating second signal.
-- queuePresent = "Queue message", which is also a live generating signal.
local function scanChatApp(scope)
    local axapp = chatAX()
    if not axapp then return nil end
    local stopEl, sx, sy, sendPresent, queuePresent, sendEnabled = nil, nil, nil, false, false, false
    local n = 0
    local function isSendLabel(lab)
        return lab == "Send" or lab == "Send message" or lab == "Send Message"
    end
    local function isQueueLabel(lab)
        return lab == "Queue message" or lab == "Queue Message"
    end
    local function walk(el, depth)
        if n > 9000 or depth > 90 then return end
        n = n + 1
        if el:attributeValue("AXRole") == "AXButton" then
            local lab = el:attributeValue("AXDescription") or el:attributeValue("AXTitle")
            if lab == CHAT_STOP and not stopEl then
                stopEl = el
                local p = el:attributeValue("AXPosition")
                if p then sx, sy = p.x, p.y end
            elseif isSendLabel(lab) then
                sendPresent = true
                sendEnabled = sendEnabled or (el:attributeValue("AXEnabled") == true)
            elseif isQueueLabel(lab) then
                queuePresent = true
            end
        end
        for _, k in ipairs(el:attributeValue("AXChildren") or {}) do walk(k, depth + 1) end
    end
    -- Prefer the retained window (walkable even when occluded on another Space);
    -- fall back to the live window list on-screen / when we have no retained ref.
    local liveOnly = scope == true
    local win = (type(scope) == "userdata") and scope or ((not liveOnly) and liveChatWin() or nil)
    if win then walk(win, 0)
    else for _, w in ipairs(axapp:attributeValue("AXWindows") or {}) do walk(w, 0) end end
    return stopEl, sx, sy, sendPresent, queuePresent, sendEnabled
end

-- Is the SPECIFIC tracked "Stop response" button still live? (cheap, ~2 AX calls)
local function trackedAlive()
    if not chatStopBtn then return false end
    local okR, role = pcall(function() return chatStopBtn:attributeValue("AXRole") end)
    local okL, lab  = pcall(function() return chatStopBtn:attributeValue("AXDescription")
        or chatStopBtn:attributeValue("AXTitle") end)
    return okR and role == "AXButton" and okL and lab == CHAT_STOP
end

-- Is OUR chat still generating? True if the tracked "Stop response" is alive, or
-- a "Stop response" reappeared near where ours was (Chromium recreates the node
-- mid-stream). A "Stop response" FAR from ours = a different chat surface and is
-- ignored (position scoping, on top of the label scoping from CHAT_STOP).
local function stillGenerating()
    -- CHEAP path: the tracked "Stop response" button is ~2 AX calls. While it's
    -- alive we're probably generating. Electron can keep removed AX nodes alive
    -- after generation ends, though, so corroborate with one full scan: if Send is
    -- visible again, the tracked Stop node is stale and Chat is done.
    if trackedAlive() then
        local _, _, _, sendPresent = scanChatApp()
        if sendPresent then return false end
        local liveStop, _, _, liveSend, liveQueue = scanChatApp(true)
        if liveSend then return false end
        if liveStop or liveQueue then staleStopHits = 0; return true end
        staleStopHits = staleStopHits + 1
        if staleStopHits >= 3 then return false end
        return true
    end
    -- Tracked button gone -> ONE full scan to catch a recreated node (Chromium
    -- rebuilds it mid-stream); a "Stop response" near ours = still generating.
    local stopEl, sx, sy = scanChatApp()
    if stopEl and ((not chatStopX) or
        (math.abs(sx - chatStopX) <= NEAR and math.abs(sy - chatStopY) <= NEAR)) then
        chatStopBtn, chatStopX, chatStopY = stopEl, sx, sy   -- re-track recreated node
        staleStopHits = 0
        return true
    end
    return false
end

-- While generating (we're away), poll until "Stop response" is gone, then back.
local function startDonePoll()
    if doneTimer then doneTimer:stop() end
    local idleHits = 0   -- consecutive "not generating" polls - debounces false dones
    doneTimer = hs.timer.doEvery(0.4, function()
        if config.debug then   -- cheap: trackedAlive() is ~2 AX calls, NOT a full walk
            hs.printf("[router] poll tracked=%s idle=%d", tostring(trackedAlive()), idleHits)
        end
        -- Still generating? reset the idle counter and keep waiting.
        if stillGenerating() then idleHits = 0; return end
        -- Not generating - but a SINGLE blank read can be a momentary off-Space
        -- tree-blank, not a real finish ("Send" rarely reappears off-Space to
        -- corroborate). Require 2 consecutive idle reads before declaring done, so
        -- one glitch doesn't yank you back to chat app mid-generation.
        idleHits = idleHits + 1
        if idleHits < 2 then return end
        if config.debug then hs.printf("[router] done -> back (cur=%s)", tostring(hs.spaces and hs.spaces.focusedSpace())) end
        doneTimer:stop(); doneTimer = nil
        chatActive, chatStopBtn, chatStopX, chatStopY = false, nil, nil, nil
        staleStopHits = 0
        chatWin = nil                                         -- drop the retained window ref
        switchBack()                                          -- anti-yank lives inside
    end)
end

-- After a likely send, confirm a generation actually started before arming away.
local function onSend()
    if not config.chatDetect or chatActive or confirmTimer then return end
    local now = hs.timer.secondsSinceEpoch()
    if lastChatArm and (now - lastChatArm) < 4.0 then
        dbg("Enter ignored; recent chat route still cooling down")
        return
    end
    if not composerLooksFocused() then
        dbg("Enter ignored; composer is not focused")
        return
    end
    local sendWin = focusedChatWindow()
    local beforeStop, _, _, beforeSend, beforeQueue, beforeSendEnabled = scanChatApp(sendWin)
    if not sendWin or not beforeSend or not beforeSendEnabled or beforeStop or beforeQueue then
        dbg("Enter ignored; active chat is not at Send-ready state")
        return
    end
    local tries, stopHits = 0, 0
    confirmTimer = hs.timer.doEvery(0.4, function()
        -- If a hook-driven workflow hook fired around this Enter (session_id present), it was
        -- a hook submit, not a chat - the hook already routes it. Bail BEFORE any
        -- tree walk, so hook submits cost the chat detector nothing.
        if lastHookSubmit and (hs.timer.secondsSinceEpoch() - lastHookSubmit) < 2.0 then
            confirmTimer:stop(); confirmTimer = nil
            return
        end
        tries = tries + 1
        local stopEl, sx, sy, sendPresent, queuePresent = scanChatApp(sendWin)
        if stopEl then
            stopHits = stopHits + 1
            if stopHits >= 2 then
                confirmTimer:stop(); confirmTimer = nil
                chatActive = true
                chatStopBtn, chatStopX, chatStopY = stopEl, sx, sy
                staleStopHits = 0
                lastChatArm = hs.timer.secondsSinceEpoch()
                captureChatWindow(sendWin)   -- retain THIS window so the poll can see it off-Space
                dbg(string.format("chat-desktop -> away (Stop response @ %s,%s)", tostring(sx), tostring(sy)))
                armSwitch()                                      -- anti-yank lives inside
                startDonePoll()
            end
        elseif queuePresent and not sendPresent then
            confirmTimer:stop(); confirmTimer = nil
            dbg("Queue appeared, but no Stop response; ignored")
        elseif sendPresent then
            stopHits = 0
        elseif tries >= 6 then                               -- ~2.4s, nothing -> not a chat send
            confirmTimer:stop(); confirmTimer = nil
            dbg("Enter, but no chat generation (ignored)")
        end
    end)
end

-- Return / keypad-Enter (no Shift) while the desktop chat app (chatApp) is
-- frontmost = a likely chat send. Gated to chatApp (not returnApp) so a
-- terminal's Enter keys never trigger this - terminal hook-driven workflow routes via
-- hooks, not AX detection.
sendKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if not config.enabled or not config.chatDetect then return false end
    local front = hs.application.frontmostApplication()
    if not front or front:name() ~= config.chatApp then return false end
    local code = e:getKeyCode()
    if (code == 36 or code == 76) and not e:getFlags().shift then onSend() end
    return false  -- never consume the keystroke
end)
sendKeyTap:start()
AR_RETAIN.sendKeyTap = sendKeyTap

-- Re-assert the a11y tree whenever chat app launches or comes forward, and once now.
chatWatcher = hs.application.watcher.new(function(name, event)
    if name == config.chatApp and (event == hs.application.watcher.launched
        or event == hs.application.watcher.activated) then
        if event == hs.application.watcher.launched then axManualSet = false end  -- re-arm after a restart
        chatAX()
    end
end)
chatWatcher:start()
AR_RETAIN.chatWatcher = chatWatcher
chatAX()  -- expose the tree for the already-running chat app

-- CLI inspector for tuning on a real chat:  hs -c 'arInspect()'
function _G.arInspect()
    local stopEl, sx, sy, sendPresent, queuePresent, sendEnabled = scanChatApp()
    return string.format(
        "chatDetect=%s  chatActive=%s\n  StopResponse=%s  Send=%s  SendEnabled=%s  Queue=%s  trackedAlive=%s  staleStopHits=%s",
        tostring(config.chatDetect), tostring(chatActive),
        stopEl and ("@" .. tostring(sx) .. "," .. tostring(sy)) or "no",
        tostring(sendPresent), tostring(sendEnabled), tostring(queuePresent), tostring(trackedAlive()), tostring(staleStopHits))
end

hs.alert.show("Lasso: chat-detect "
    .. (config.chatDetect and "ON" or "OFF (flag)")
    .. (config.debug and " [debug]" or "")
    .. "  (keytap " .. (sendKeyTap:isEnabled() and "ok" or "BLOCKED") .. ")")
