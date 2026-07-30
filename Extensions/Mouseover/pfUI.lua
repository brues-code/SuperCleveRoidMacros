--[[
  Author: Dennis Werner Garske (DWG) / brian / Mewtiny
  License: MIT License

  pfUI integration. pfUI's own unitframes now set the native mouseover unit
  (Nampower SetMouseoverUnit, via pfUI.uf.OnEnter bound in pfUI.uf:EnableScripts
  on every unitframe), so [@mouseover]/[mouseover] resolve against pfUI frames
  through the native "mouseover" token -- every consumer checks UnitExists(
  "mouseover") before the CleveRoids.mouseoverUnit fallback, so no per-frame
  hooking is needed here anymore. What remains is the two things pfUI doesn't
  cover:
  - Raid-marker rows: NOT unitframes (never go through EnableScripts), so pfUI
    sets no mouseover for them. Hooked so hovering registers "mark1".."mark8"
    via CleveRoids.mouseoverUnit.
  - /pfcast: wrapped so its argument runs through CleveRoids conditionals.
]]
local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}

CleveRoids.mouseoverUnit = CleveRoids.mouseoverUnit or nil

local Extension = CleveRoids.RegisterExtension("pfUI")
Extension.RegisterEvent("PLAYER_ENTERING_WORLD", "PLAYER_ENTERING_WORLD")

function Extension.OnLoad()
end

-- Resolve a pfUI unitframe (focus / focustarget and fallback for party/raid)
local function ResolvePfUnit(frame, fallbackName)
  if not frame then return nil end
  if frame.label and frame.id then
    return frame.label .. frame.id
  end

  local name = fallbackName or frame.unitname
  if not name or name == "" then return nil end
  name = strlower(name)

  local candidates = { "target", "targettarget", "player", "pet" }
  local i
  for i = 1, 4 do
    table.insert(candidates, "party"..i)
    table.insert(candidates, "partypet"..i)
  end
  for i = 1, 40 do
    table.insert(candidates, "raid"..i)
    table.insert(candidates, "raidpet"..i)
  end

  for _,u in ipairs(candidates) do
    if UnitExists(u) and strlower(UnitName(u) or "") == name then
      return u
    end
  end

  return nil
end

-- Unique key per pfUI frame so leave events can't clear another frame's hover
local function PfSourceKey(frame)
  if not frame then return "pfui:unknown" end
  if frame.label and frame.id then
    return "pfui:" .. frame.label .. frame.id
  end
  if frame.unit and frame.unit ~= "" then
    return "pfui:" .. frame.unit
  end
  return "pfui:" .. tostring(frame) -- stable per-frame string in 1.12
end

-- Resolve a *real* UnitID for a pfUI frame
local function PfResolveUnit(frame, defaultUnit)
  if frame and frame.unit and frame.unit ~= "" then
    return frame.unit
  end
  if frame and frame.label and frame.id then
    return frame.label .. frame.id
  end
  return ResolvePfUnit(frame) or defaultUnit
end

-- Helper to set with per-frame key
local function PfSet(frame, defaultUnit)
  local key  = PfSourceKey(frame)
  local unit = PfResolveUnit(frame, defaultUnit)
  if unit then
    frame.__cr_src = key
    CleveRoids.SetMouseoverFrom(key, unit)
  end
end

-- Helper to clear with the same per-frame key
local function PfClear(frame)
  if frame and frame.__cr_src then
    CleveRoids.ClearMouseoverFrom(frame.__cr_src)
    frame.__cr_src = nil
    -- Also clear "native" source to prevent sticky highlights.
    -- When SetMouseoverUnit("") is called, UPDATE_MOUSEOVER_UNIT fires but
    -- selfTriggered causes it to skip, leaving "native" stale.
    CleveRoids.ClearMouseoverFrom("native")
  end
end

-- RAID MARKERS (pfUI raidmarkers module)
-- Rows are plain Buttons with label="mark" and id=1-8. They have no OnEnter/OnLeave
-- by default, so [mouseover] macros are blind to them. We hook each row so hovering
-- registers "mark1".."mark8" through the normal priority system. pfUI's own
-- SetMouseoverUnit path only covers unitframes, so this stays.
function Extension.RegisterRaidMarkScripts()
  if not pfUI or not pfUI.raidmarkers or not pfUI.raidmarkers.rows then return end

  local i
  for i = 1, 8 do
    local row = pfUI.raidmarkers.rows[i]
    if row then
      local onEnterFunc = row:GetScript("OnEnter")
      local onLeaveFunc = row:GetScript("OnLeave")

      row:SetScript("OnEnter", function()
        PfSet(this)  -- resolves to "mark1".."mark8" via label..id
        if onEnterFunc then onEnterFunc(this) end
      end)

      row:SetScript("OnLeave", function()
        PfClear(this)
        if onLeaveFunc then onLeaveFunc(this) end
      end)
    end
  end
end

-- /pfcast hook: deferred until PLAYER_ENTERING_WORLD because pfUI defines SlashCmdList.PFCAST
-- inside pfUI:RegisterModule() which runs during pfUI's PLAYER_LOGIN init, after our addon loads.
-- Guard ensures we only hook once across multiple zone transitions.
function Extension.HookPfCast()
  if not SlashCmdList.PFCAST then return end
  if CleveRoids.Hooks.PFCAST_SlashCmd then return end  -- already hooked
  CleveRoids.Hooks.PFCAST_SlashCmd = SlashCmdList.PFCAST
  SlashCmdList.PFCAST = function(msg)
    if CleveRoids.stopMacroFlag or CleveRoids.skipMacroFlag then return end
    if msg and string.find(msg, "[%[%?!~{]") then
      CleveRoids.DoPfCast(msg)
    else
      CleveRoids.Hooks.PFCAST_SlashCmd(msg)
    end
  end
end

function Extension.PLAYER_ENTERING_WORLD()
  if not pfUI then return end
  Extension.RegisterRaidMarkScripts()
  Extension.HookPfCast()
end
