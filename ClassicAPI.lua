--[[
    ClassicAPI.lua - ClassicAPI Integration Layer

    ClassicAPI is a client mod (sibling to Nampower/SuperWoW) that backports the
    modern C_* API into the 1.12.1 Lua environment. It is a HARD REQUIREMENT of
    this addon, so the wrappers below call the API directly — no fallbacks. The
    load-time requirement check (Core.lua) uses IsAvailable() to warn when the
    DLL is missing; users who don't want ClassicAPI should run the upstream addon.

    Detection: the global CLASSIC_API_VERSION is defined once the client has
    booted, encoded as X*10000 + Y*100 + Z for a vX.Y.Z tag (untagged dev builds
    report the sentinel 99999999). See ClassicAPI docs/API.md.

    Currently used for:
    - C_UnitAuras: dispel-type detection (Magic/Curse/Disease/Poison) on any unit,
      powering the [magic]/[curse]/[disease]/[poison]/[dispellable] conditionals.
    - GetUnitSpeed / IsFalling: the [moving] conditional.
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

-- Scan a unit's auras (indexFn = C_UnitAuras.GetBuffDataByIndex or
-- GetDebuffDataByIndex) for one matching the dispel type. Vanilla descriptors
-- hold 32 helpful / 16 harmful slots; cap as a backstop.
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
function API.UnitHasDispelType(unit, dispelType, helpful)
    if not unit or not UnitExists(unit) then return false end
    local indexFn = helpful and C_UnitAuras.GetBuffDataByIndex
        or C_UnitAuras.GetDebuffDataByIndex
    local wantAny = (dispelType == nil or dispelType == "any")
    return scanDispel(indexFn, unit, dispelType, wantAny)
end

--------------------------------------------------------------------------------
-- GetUnitSpeed
--------------------------------------------------------------------------------

-- Normal unmounted run speed in yards/second; treated as 100% on the speed
-- scale used by the [moving] conditional.
local BASE_RUN_SPEED = 7.0

-- Current speed of `unit` in yards/second (0 when stationary or the token
-- doesn't resolve).
function API.GetUnitCurrentSpeed(unit)
    return GetUnitSpeed(unit or "player") or 0
end

-- Player's current speed as a percentage of normal run speed (100 = run).
function API.GetPlayerSpeedPercent()
    return (API.GetUnitCurrentSpeed("player") / BASE_RUN_SPEED) * 100
end

-- True if the player is mid-jump or falling. GetUnitSpeed's currentSpeed is
-- horizontal-only, so this catches vertical movement it would report as 0.
function API.IsPlayerFalling()
    return IsFalling()
end

--------------------------------------------------------------------------------
-- Action
--------------------------------------------------------------------------------

-- Action descriptor for a 1-based action-bar slot: actionType, id, subType.
--   actionType: "spell" (id = spellID) | "macro" (id = macroSlot) |
--               "item" (id = itemID, or nil for a bag-instance item)
--   nil for an empty slot.
function API.GetActionInfo(slot)
    return GetActionInfo(slot)
end

--------------------------------------------------------------------------------
-- Container
--------------------------------------------------------------------------------

-- Base itemID in (bagID, slot), or nil for an empty/invalid slot. Same value
-- the "item:(%d+)" parse of GetContainerItemLink yields, but resolved straight
-- from the CGItem -- no link string built, no Lua pattern match.
function API.GetContainerItemID(bagID, slot)
    return C_Container.GetContainerItemID(bagID, slot)
end

-- Base itemID equipped in `unit`'s 1-based inventory `slot` (1-19), or nil for
-- an empty slot / NPC unit. Same arg shape as GetInventoryItemLink and the same
-- value its "item:(%d+)" parse yields, resolved straight from the item instance.
function API.GetInventoryItemID(unit, slot)
    return GetInventoryItemID(unit, slot)
end

--------------------------------------------------------------------------------
-- Spell
--------------------------------------------------------------------------------

-- WoW SpellMechanic enum ID for a spell, read straight from Spell.dbc -- covers
-- every spell the client knows, not just the spellbook (1=Charm, 5=Fear,
-- 7=Root, 12=Stun, 17=Polymorph, ...). Returns (mechanicID, enUS name); the ID
-- is 0 for a known spell with no mechanic, and the whole call is nil for an
-- invalid spell ID. Replaces hand-maintained spellID -> mechanic tables.
function API.GetSpellMechanicByID(spellID)
    return C_Spell.GetSpellMechanicByID(spellID)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- True if the player is in Stealth (Rogue) or Prowl (Druid).
function API.IsStealthed()
    return IsStealthed()
end

-- True if the player is currently swimming.
function API.IsSwimming()
    return IsSwimming() and true or false
end

--------------------------------------------------------------------------------
-- Cursor
--------------------------------------------------------------------------------

function API.GetCursorInfo()
    return GetCursorInfo()
end

-- Tri-state check of whether the cursor holds the item with `itemID`:
--   true  -> cursor holds exactly that item
--   false -> cursor holds a DIFFERENT item
--   nil   -> can't tell (cursor empty / not an item / itemID unknown)
-- Callers should only act on an explicit `false`, leaving the nil case to the
-- existing CursorHasItem() behavior.
function API.CursorHoldsItemID(itemID)
    if not itemID then return nil end
    local kind, id = GetCursorInfo()
    if kind ~= "item" then return nil end
    if not id then return nil end
    return id == itemID
end

--------------------------------------------------------------------------------
-- NamePlate
--------------------------------------------------------------------------------

-- 1-based table of GUID strings (0x... format) for every unit with an allocated
-- nameplate, including default vanilla nameplates. Order isn't stable.
function API.GetNamePlateGUIDs()
    return C_NamePlate.GetNamePlateGUIDs()
end
