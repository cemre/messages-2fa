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

local lastRowId = 0
local nextAllowedPoll = 0
local dbErrorNotified = false
local debounceTimer, safetyTimer, pathWatcher

-- Whatever was in front when the code arrived, which is where the login field
-- almost certainly is. Only used to undo the focus change that clicking a
-- notification causes -- see pasteCode.
local appAtArrival

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

local function copyCode(code)
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
  hs.alert.show("2FA code copied")
  log("copied " .. #code .. "-digit code")
end

local function emitKeys(code)
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

  -- Clicking a notification's body activates the app that posted it, so a click
  -- on this one can pull Hammerspoon in front of the login window and swallow
  -- the keystrokes. Clicking an action button does not. Rather than assume
  -- which happened, look: Hammerspoon in front is never where a code should be
  -- typed, so in that one case hand focus back to where the code arrived.
  -- Any other frontmost app means the user moved there deliberately -- type
  -- into it and leave the window order alone.
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == HAMMERSPOON_BUNDLE_ID and appAtArrival then
    appAtArrival:activate()
    log("restoring focus to " .. (appAtArrival:name() or "?"))
    hs.timer.doAfter(config.refocusDelay, function() emitKeys(code) end)
  else
    emitKeys(code)
  end
end

local function notifyCode(code, sender)
  -- Captured before the notification exists, so it reflects where you were
  -- working when the text landed rather than anything the click changed.
  appAtArrival = hs.application.frontmostApplication()

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
    subTitle = (sender ~= "" and sender ~= nil) and ("from " .. sender) or nil,
    informativeText = "Click to type it into " ..
      ((appAtArrival and appAtArrival:name()) or "the front app") .. ".",
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

  for line in (out or ""):gmatch("[^\n]+") do
    local rowid, code, sender = line:match("^(%d+)\t(%d+)\t(.*)$")
    if rowid then
      -- Advance the floor before notifying, so a failure in the notification
      -- path can't leave this code to fire again on the next poll.
      lastRowId = math.max(lastRowId, tonumber(rowid))
      notifyCode(code, sender)
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

  log("started at rowid " .. lastRowId)
  return M
end

function M.stop()
  if pathWatcher then pathWatcher:stop(); pathWatcher = nil end
  if safetyTimer then safetyTimer:stop(); safetyTimer = nil end
  if debounceTimer then debounceTimer:stop(); debounceTimer = nil end
  return M
end

-- Exercises the notification and both buttons without waiting for a real text:
--   twofa.testNotify()
function M.testNotify(code, sender)
  notifyCode(code or "123456", sender or "+15550000000")
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
