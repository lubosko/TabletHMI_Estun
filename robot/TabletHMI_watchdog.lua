-- ============================================================================
-- TabletHMI watchdog for ESTUN Codroid (Gen1 + Gen2)
--
-- Runs as a THREAD inside every project that the Tablet HMI may start.
-- Threads must not contain motion commands; this script has none.
--
-- Where to put it (see SETUP.md):
--   * Recommended: create Module "TabletHMI", method "watchdog", paste this
--     whole file as the method body, then add a Thread to each project whose
--     body is:   callModule("TabletHMI", "watchdog")
--   * Alternative: paste this whole file directly into the project's Thread.
--
-- Behaviour (checked every CYCLE_MS):
--   owner  = tablet if HMI_TABLET_START was set by the tablet when it started
--            this project, otherwise pendant/web UI.
--   supervised = enable DI is ON  or  owner is tablet
--   * owner is tablet and enable DI is OFF          -> stopProject()
--   * supervised and heartbeat unchanged > TIMEOUT  -> stopProject()
--   * enable DI OFF and owner is pendant            -> idle (no supervision)
-- On every heartbeat change the counter is echoed back so the tablet can see
-- that this watchdog is alive.
-- ============================================================================

-- ---- Configuration: confirm addresses on Configuration > Communication >
-- ---- Register for each controller (PRD Phase 0) and keep them identical to
-- ---- the tablet's controller profile.
local HMI_ENABLE_DI    = 15        -- DI port: HMI ON/OFF key switch or forced DI
local REG_HB           = "49000"   -- Int (DInt) rw: heartbeat counter from tablet
local REG_HB_ECHO      = "49002"   -- Int (DInt): last counter seen by watchdog
local REG_ENABLED      = "9900"    -- Bool: mirror of the enable DI
local REG_WD_TRIPPED   = "9901"    -- Bool: latched when the watchdog stops the project
local REG_TABLET_START = "9902"    -- Bool rw: set by tablet right before it starts a project
local TIMEOUT_MS       = 1500      -- heartbeat timeout (1000..3000)
local CYCLE_MS         = 50        -- watchdog loop period

-- ---- Start of project: take ownership flag and reset state -----------------
local ownerIsTablet = getRegisterBool(REG_TABLET_START) == true
setRegisterBool(REG_TABLET_START, 0)   -- consume the flag; pendant starts leave it 0
setRegisterBool(REG_WD_TRIPPED, 0)

local lastHb = getRegisterInt(REG_HB)
local lastChange = systemTime()        -- grace period of TIMEOUT_MS after start

local function trip(reason)
  setRegisterBool(REG_WD_TRIPPED, 1)
  print("TabletHMI watchdog: " .. reason .. " -> stopProject()")
  stopProject()
end

while true do
  local now = systemTime()
  local enabled = getDI(HMI_ENABLE_DI) == 1
  setRegisterBool(REG_ENABLED, enabled and 1 or 0)

  local hb = getRegisterInt(REG_HB)
  if hb ~= lastHb then
    lastHb = hb
    lastChange = now
    setRegisterInt(REG_HB_ECHO, hb)
  end

  if ownerIsTablet and not enabled then
    trip("Tablet HMI switched OFF on robot while tablet owns the program")
  elseif (enabled or ownerIsTablet) and (now - lastChange > TIMEOUT_MS) then
    trip("tablet heartbeat lost for " .. (now - lastChange) .. " ms")
  end

  wait(CYCLE_MS)
end
