--[[
    ClassicAPI.lua - ClassicAPI Integration Layer

    ClassicAPI is a client mod (sibling to Nampower/SuperWoW) that backports the
    modern C_* API into the 1.12.1 Lua environment. This module provides feature
    detection and thin wrappers so every ClassicAPI-backed code path can fall
    back gracefully when the DLL is absent, mirroring NampowerAPI's
    HasMinimumVersion pattern.

    Detection: the global CLASSIC_API_VERSION is defined once the client has
    booted, encoded as X*10000 + Y*100 + Z for a vX.Y.Z tag (untagged dev builds
    report the sentinel 99999999). See ClassicAPI docs/API.md.

    Currently used for:
    - C_UnitAuras: dispel-type detection (Magic/Curse/Disease/Poison) on any unit,
      powering the [magic]/[curse]/[disease]/[poison]/[dispellable] conditionals.
]]

local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids

-- Force table creation if not already a table (guards against addon conflicts)
if type(CleveRoids.ClassicAPI) ~= "table" then
    CleveRoids.ClassicAPI = {}
end
local API = CleveRoids.ClassicAPI

--------------------------------------------------------------------------------
-- VERSION DETECTION
--------------------------------------------------------------------------------

-- Returns the encoded version number (X*10000 + Y*100 + Z), or 0 if absent.
function API.GetVersionNumber()
    return CLASSIC_API_VERSION or 0
end

-- True if the ClassicAPI client mod is loaded at all.
function API.IsAvailable()
    return CLASSIC_API_VERSION ~= nil
end

-- Check if the loaded ClassicAPI meets a minimum version (major, minor, patch).
function API.HasMinimumVersion(reqMajor, reqMinor, reqPatch)
    local v = CLASSIC_API_VERSION
    if not v then return false end
    local req = (reqMajor or 0) * 10000 + (reqMinor or 0) * 100 + (reqPatch or 0)
    return v >= req
end

--------------------------------------------------------------------------------
-- C_UnitAuras
--------------------------------------------------------------------------------

-- Cached capability flag (C_UnitAuras is injected by the DLL before addons load).
local _hasUnitAuras = nil
function API.HasUnitAuras()
    if _hasUnitAuras == nil then
        _hasUnitAuras = (type(C_UnitAuras) == "table"
            and type(C_UnitAuras.GetDebuffDataByIndex) == "function"
            and type(C_UnitAuras.GetBuffDataByIndex) == "function") or false
    end
    return _hasUnitAuras
end

-- Module-level scan (passed to pcall with args to avoid per-call closure alloc).
-- indexFn is C_UnitAuras.GetBuffDataByIndex or GetDebuffDataByIndex.
-- Vanilla descriptors hold 32 helpful / 16 harmful slots; cap as a backstop.
local function scanDispel(indexFn, unit, dispelType, wantAny)
    local i = 1
    while i <= 48 do
        local data = indexFn(unit, i)
        if not data then return false end
        local dn = data.dispelName
        if dn and dn ~= "" and (wantAny or dn == dispelType) then
            return true
        end
        i = i + 1
    end
    return false
end

-- True if `unit` has an aura of the given dispel type.
--   dispelType: "Magic" | "Curse" | "Disease" | "Poison", or "any"/nil for any
--               dispellable aura (any non-empty dispelName).
--   helpful:    true  -> scan buffs   (offensive dispel / strip / purge)
--               false -> scan debuffs (defensive cleanse, default)
-- Returns false (never errors) when ClassicAPI/C_UnitAuras is unavailable or the
-- unit doesn't exist, so callers degrade gracefully.
function API.UnitHasDispelType(unit, dispelType, helpful)
    if not unit then return false end
    if not API.HasUnitAuras() then return false end
    if not UnitExists(unit) then return false end

    local indexFn = helpful and C_UnitAuras.GetBuffDataByIndex
        or C_UnitAuras.GetDebuffDataByIndex
    local wantAny = (dispelType == nil or dispelType == "any")
    local ok, found = pcall(scanDispel, indexFn, unit, dispelType, wantAny)
    return (ok and found) or false
end
