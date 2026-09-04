-- Watches Messages for incoming verification codes and offers them as a
-- notification with Paste and Copy actions.
--
-- Detection lives in find-2fa-codes.sh, not here -- this module only handles
-- state, the notification, and the two actions. Both files are symlinked into
-- ~/.hammerspoon from the project checkout.
--
-- Hammerspoon needs Full Disk Access (to read chat.db) and Accessibility (to
-- type the code). Its notification style must be "Alerts", not "Banners", or
-- the buttons disappear after a few seconds.

local M = {}

local config = {
  -- Type Return after the code. Turn this off if a site auto-submits on the
  -- last digit and the extra Return does something unwanted.
  pressReturn = true,

  -- Codes older than this are ignored -- they have almost certainly expired.
  maxAgeMinutes = 15,

  -- FSEvents drives the normal path; this timer is just a safety net in case a
  -- filesystem event is ever missed.
  safetyPollSeconds = 15,

  -- A single message can produce several writes to the WAL, so wait for them
  -- to settle before querying.
  debounceSeconds = 0.4,

  -- How long to stay quiet after a database read failure, so a missing
  -- permission produces one notification rather than a stream of them.
  errorBackoffSeconds = 60,

  -- Time for the previous app to come back to the front and restore its text
  -- cursor before keystrokes are sent. Too short and the first digits land in
  -- the wrong window.
  refocusDelay = 0.15,

  finder = os.getenv("HOME") .. "/.hammerspoon/find-2fa-codes.sh",
  logFile = os.getenv("HOME") .. "/Library/Logs/2fa-watch.log",
}

local HAMMERSPOON_BUNDLE_ID = "org.hammerspoon.Hammerspoon"

-- Apps that transmit what you type. Typing a code into one of these and pressing
-- Return does not fill a login form, it broadcasts the code -- to the very
-- sender it came from, in the case of Messages.
--
-- Messages is not a hypothetical here. If you are still reading the conversation
-- the code arrived in when you click, Messages is the app the keystrokes would
-- go to -- into the compose field, with Return sending the code to its sender.
--
-- Add any other app you would not want a live code typed into.
local NEVER_TYPE_INTO = {
  ["com.apple.MobileSMS"]              = "Messages",
  ["com.apple.iChat"]                  = "Messages",     -- pre-Sierra bundle id
  ["com.tinyspeck.slackmacgap"]        = "Slack",
  ["net.whatsapp.WhatsApp"]            = "WhatsApp",
  ["ru.keepcoder.Telegram"]            = "Telegram",
  ["com.hnc.Discord"]                  = "Discord",
  ["org.whispersystems.signal-desktop"]= "Signal",
  [HAMMERSPOON_BUNDLE_ID]              = "Hammerspoon",  -- no text field to hit
}

-- Display name when this bundle id must never receive a typed code, nil when it
-- is safe. Pure, and exported so it can be asserted against directly.
function M.blockedTargetName(bundleID)
  if not bundleID then return nil end
  return NEVER_TYPE_INTO[bundleID]
end

local lastRowId = 0
local nextAllowedPoll = 0
local dbErrorNotified = false
local debounceTimer, safetyTimer, pathWatcher

-- The app you were last using, Hammerspoon excluded. Kept current by an
-- application watcher rather than sampled when the code arrives, because the
-- target that matters is where you are when you CLICK -- you may well read the
-- notification, switch to the login window, and only then click.
--
-- It cannot be read at click time instead: clicking a notification's body
-- activates the app that posted it, so by the time the callback runs the
-- frontmost app is Hammerspoon. This record is the only thing that still knows.
--
-- Messages and friends are tracked here like any other app. Excluding them would
-- silently retarget to whatever you used before them; better to remember the
-- truth and refuse at the point of typing.
local lastActiveApp
local appWatcher

local function onAppActivated(_, event, app)
  if event ~= hs.application.watcher.activated then return end
  if not app or app:bundleID() == HAMMERSPOON_BUNDLE_ID then return end
  lastActiveApp = app
end

-- Name of the app a click would type into, for diagnostics from the Console.
function M.lastActiveAppName()
  return lastActiveApp and lastActiveApp:name() or nil
end

-- Records what happened and when, never the code itself.
local function log(message)
  local f = io.open(config.logFile, "a")
  if not f then return end
  f:write(os.date("%Y-%m-%d %H:%M:%S ") .. message .. "\n")
  f:close()
end

-- Quoting matters: the finder path contains no spaces by construction (it is a
-- symlink in ~/.hammerspoon), but quote it anyway so a renamed home directory
-- can't turn into two arguments.
local function runFinder(args)
  local cmd = string.format("'%s' %s", config.finder, args)
  local out, ok, _, rc = hs.execute(cmd)
  return out, ok, rc
end

-- quiet suppresses the confirmation, for callers that show their own.
local function copyCode(code, quiet)
  -- org.nspasteboard.ConcealedType is the convention clipboard managers watch
  -- to keep an entry out of their history. Raycast honours it.
  local wrote = pcall(function()
    hs.pasteboard.writeAllData(nil, {
      ["public.utf8-plain-text"] = code,
      ["org.nspasteboard.ConcealedType"] = code,
    })
  end)
  -- Verify rather than trust: a clipboard that silently stayed empty would be
  -- worse than one without the concealed marker.
  if not wrote or hs.pasteboard.getContents() ~= code then
    hs.pasteboard.setContents(code)
  end
  if not quiet then hs.alert.show("2FA code copied") end
  log("copied " .. #code .. "-digit code")
end

local function emitKeys(code)
  -- The last line of defence, and the only one that sees the truth: it runs
  -- after any activation has settled, so it inspects the window actually about
  -- to receive the keystrokes rather than one predicted earlier. Every path
  -- into typing goes through here, including the user switching apps between
  -- the notification appearing and clicking it.
  local front = hs.application.frontmostApplication()
  local blocked = M.blockedTargetName(front and front:bundleID())
  if blocked then
    copyCode(code, true)
    hs.alert.show("2FA: won't type into " .. blocked .. " -- copied instead")
    log("refused to type into " .. blocked .. "; copied to clipboard instead")
    return
  end

  hs.eventtap.keyStrokes(code)
  if config.pressReturn then
    -- Let the field process the digits before submitting; some inputs move
    -- focus between boxes as you type.
    hs.timer.doAfter(0.05, function()
      hs.eventtap.keyStroke({}, "return", 0)
    end)
  end
  log("typed " .. #code .. "-digit code")
end

local function pasteCode(code)
  if not hs.accessibilityState() then
    hs.alert.show("2FA: Hammerspoon needs Accessibility to type the code")
    log("paste-blocked-no-accessibility")
    return
  end

  -- Clicking the body activates Hammerspoon; clicking an action button does not.
  -- So the frontmost app is the right target when it is anything else, and the
  -- watcher's record is the right target when Hammerspoon has just taken over.
  local front = hs.application.frontmostApplication()
  local target = front
  if not front or front:bundleID() == HAMMERSPOON_BUNDLE_ID then
    target = lastActiveApp
  end

  if not target or not target:isRunning() then
    copyCode(code, true)
    hs.alert.show("2FA: no app to type into -- copied instead")
    log("no paste target; copied to clipboard instead")
    return
  end

  -- Named here as well as in emitKeys so the message can say Messages rather
  -- than Hammerspoon, and so a blocked app is never pulled to the front first.
  local blocked = M.blockedTargetName(target:bundleID())
  if blocked then
    copyCode(code, true)
    hs.alert.show("2FA: won't type into " .. blocked .. " -- copied instead")
    log("refused to type into " .. blocked .. "; copied to clipboard instead")
    return
  end

  if front and front:pid() == target:pid() then
    emitKeys(code)
  else
    target:activate()
    log("restoring focus to " .. (target:name() or "?"))
    hs.timer.doAfter(config.refocusDelay, function() emitKeys(code) end)
  end
end

-- The sender is deliberately not shown. It is almost always a bare short code
-- like "36397", which names no recognisable service and reads as noise next to
-- the thing you actually came for.
local function notifyCode(code)
  local n = hs.notify.new(function(notification)
    local kind = notification:activationType()
    local types = hs.notify.activationTypes
    if kind == types.contentsClicked or kind == types.actionButtonClicked then
      pasteCode(code)
    elseif kind == types.additionalActionClicked then
      -- macOS puts every action behind the Options menu, the primary one
      -- included, so identify this one by title rather than by position.
      local chosen = notification:additionalActivationAction()
      if chosen == "Copy" then copyCode(code) else pasteCode(code) end
    end
  end, {
    title = "2FA code: " .. code,
    -- Deliberately names no app. The target is decided when you click, which
    -- may be several app switches after this text was written.
    informativeText = "Click to type it into the app you're using.",
    hasActionButton = true,
    actionButtonTitle = "Paste",
    additionalActions = { "Copy" },
    withdrawAfter = 0,
  })
  n:send()
  log("notified for " .. #code .. "-digit code")
end

local function handleDbError(rc)
  nextAllowedPoll = os.time() + config.errorBackoffSeconds
  if dbErrorNotified then return end
  dbErrorNotified = true
  hs.notify.new({
    title = "2FA watcher can't read Messages",
    informativeText = "Give Hammerspoon Full Disk Access in System Settings > Privacy & Security, then reload the config.",
    withdrawAfter = 0,
  }):send()
  log("db-error rc=" .. tostring(rc))
end

local function poll()
  if os.time() < nextAllowedPoll then return end

  local out, ok, rc = runFinder(string.format(
    "--since-rowid %d --max-age %d", lastRowId, config.maxAgeMinutes))

  if not ok then
    handleDbError(rc)
    return
  end
  dbErrorNotified = false

  -- The finder also emits the sender as a third field; it is matched past but
  -- not captured, since nothing downstream displays it.
  for line in (out or ""):gmatch("[^\n]+") do
    local rowid, code = line:match("^(%d+)\t(%d+)\t")
    if rowid then
      -- Advance the floor before notifying, so a failure in the notification
      -- path can't leave this code to fire again on the next poll.
      lastRowId = math.max(lastRowId, tonumber(rowid))
      notifyCode(code)
    end
  end
end

local function schedulePoll()
  if debounceTimer then debounceTimer:stop() end
  debounceTimer = hs.timer.doAfter(config.debounceSeconds, poll)
end

function M.start()
  M.stop()

  if not hs.fs.attributes(config.finder) then
    hs.alert.show("2FA: find-2fa-codes.sh not found at " .. config.finder)
    log("missing-finder")
    return M
  end

  -- Start from the current end of the table so loading or reloading the config
  -- never replays codes that already arrived.
  local out, ok = runFinder("--max-rowid")
  if not ok then
    handleDbError("init")
    return M
  end
  lastRowId = tonumber((out or ""):match("%d+")) or 0

  -- FSEvents on the Messages directory catches the WAL write for each new
  -- message, so the notification lands about as fast as Messages' own.
  pathWatcher = hs.pathwatcher.new(
    os.getenv("HOME") .. "/Library/Messages", schedulePoll):start()
  safetyTimer = hs.timer.doEvery(config.safetyPollSeconds, poll)

  -- Seed from the current frontmost app, since no activation event will fire
  -- for an app that was already in front when this loaded.
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() ~= HAMMERSPOON_BUNDLE_ID then lastActiveApp = front end
  appWatcher = hs.application.watcher.new(onAppActivated):start()

  log("started at rowid " .. lastRowId)
  return M
end

function M.stop()
  if pathWatcher then pathWatcher:stop(); pathWatcher = nil end
  if safetyTimer then safetyTimer:stop(); safetyTimer = nil end
  if debounceTimer then debounceTimer:stop(); debounceTimer = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  return M
end

-- Exercises the notification and both buttons without waiting for a real text:
--   twofa.testNotify()
function M.testNotify(code)
  notifyCode(code or "123456")
  return M
end

-- Forces an immediate check, ignoring any error backoff.
function M.checkNow()
  nextAllowedPoll = 0
  poll()
  return M
end

M.config = config

return M
