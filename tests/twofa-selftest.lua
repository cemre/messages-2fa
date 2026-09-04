-- Assertions for the paste-target denylist in hammerspoon/twofa.lua.
--
-- This one needs a Lua with the hs modules on its path, so run it from the
-- Hammerspoon Console (menu bar icon -> Console):
--
--     dofile("/absolute/path/to/tests/twofa-selftest.lua")
--
-- It prints a summary and returns the number of failures.
--
-- What it guards: a code typed into Messages and followed by Return is not
-- filled into a login form, it is sent to whoever texted it to you. The rest of
-- the module has to be exercised by hand; this part does not.

local t = require("twofa")
local pass, fail = 0, 0

local function check(desc, got, want)
  if got == want then
    pass = pass + 1
    print("ok    " .. desc)
  else
    fail = fail + 1
    print(("FAIL  %s\n        want: %s\n        got:  %s")
      :format(desc, tostring(want), tostring(got)))
  end
end

local b = t.blockedTargetName

check("Messages is refused",           b("com.apple.MobileSMS"),         "Messages")
check("legacy iChat id is refused",    b("com.apple.iChat"),             "Messages")
check("Hammerspoon itself is refused", b("org.hammerspoon.Hammerspoon"), "Hammerspoon")
check("Slack is refused",              b("com.tinyspeck.slackmacgap"),   "Slack")
check("Signal is refused",             b("org.whispersystems.signal-desktop"), "Signal")
check("a browser is allowed",          b("com.google.Chrome"),           nil)
check("TextEdit is allowed",           b("com.apple.TextEdit"),          nil)

-- Deliberate: an app that reports no bundle id is allowed rather than refused.
-- Every real GUI app has one, and failing closed here would break typing for a
-- hypothetical app while preventing nothing that actually happens.
check("missing bundle id is allowed",  b(nil),                           nil)

print(("\n%d passed, %d failed"):format(pass, fail))
return fail
