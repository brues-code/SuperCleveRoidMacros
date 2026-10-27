--[[
	Author: Dennis Werner Garske (DWG) / brian / Mewtiny
	License: MIT License
]]
local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}
local _G = getfenv(0)
local strfind = string.find
local find = string.find  -- Add this line
local gsub = string.gsub
local lower = string.lower
local floor = math.floor
local pairs = pairs
local ipairs = ipairs
local type = type
local tonumber = tonumber
local tostring = tostring
local GetTime = GetTime

--------------------------------------------------------------------------------
-- PERFORMANCE: Memoized rank-stripping function
-- Caches results to avoid repeated string.gsub + string allocation on every call.
-- Two patterns are used across the codebase; we handle both with one function.
-- Cache grows with unique spell names (~200-300 total), negligible memory.
--------------------------------------------------------------------------------
local _stripRankCache = {}
local _STRIP_RANK_CACHE_MAX = 512

function CleveRoids.StripRank(name)
    if not name then return nil end
    local cached = _stripRankCache[name]
    if cached then return cached end
    -- Handles both "Spell (Rank 4)" and "Spell(Rank 4)" with flexible whitespace
    cached = gsub(name, "%s*%(%s*Rank%s+%d+%s*%)", "")
    _stripRankCache[name] = cached
    return cached
end

function CleveRoids.ClearStripRankCache()
    _stripRankCache = {}
end

-- Spells with physical damage + resistable CC effect (weapon-dependent)
-- These spells deal physical damage that ALWAYS lands (unless dodged/parried/blocked),
-- but apply a CC effect that can be resisted independently.
-- When the CC is resisted, we should NOT record physical immunity.
--
-- Master Strike (Warrior): 35% weapon damage + weapon-dependent CC
--   Mace: Disorient (3s)    Sword: Disarm (3s)      Axe: Immobilize (4s)
--   Polearm: Dismount       Fist: Knockdown (2s)    Dagger: Silence (3s)
--   Staff: Self-buff (parry, no CC)
local SPLIT_CC_SPELLS = {
    [54016] = true,  -- Master Strike (Mace) - Disorient
    [54017] = true,  -- Master Strike (Sword) - Disarm
    [54018] = true,  -- Master Strike (Axe) - Immobilize
    [54019] = true,  -- Master Strike (Polearm) - Dismount
    [54020] = true,  -- Master Strike (Fist) - Knockdown
    [54021] = true,  -- Master Strike (Staff) - Parry buff
    [54022] = true,  -- Master Strike (Dagger) - Silence
    [54023] = true,  -- Master Strike (Base)
    [54024] = true,  -- Master Strike (Level 0 variant)
}

-- Name-based lookup for split CC spells (for combat log parsing where only name is available)
-- All weapon variants share the same display name, so we need to check by name too
local SPLIT_CC_SPELL_NAMES = {
    ["Master Strike"] = true,
}

-- GUID normalization: ensure all GUIDs are strings for consistent table key lookups
-- In Lua, table["123"] is different from table[123], so we must normalize
function CleveRoids.NormalizeGUID(guid)
    if not guid then return nil end
    return tostring(guid)
end

-- Get GUID for a unit token via Nampower GetUnitGUID (v3.0+)
-- Returns: normalized GUID string, or nil
function CleveRoids.GetGUID(unit)
    local guid = GetUnitGUID(unit)
    if guid then return tostring(guid) end
    return nil
end

-- Check if a unit is truly dead using Nampower health (sees through feign death)
-- Returns: true if unit HP is 0 (truly dead), false if alive or feigning
function CleveRoids.IsUnitDead(unit)
    if CleveRoids.NampowerAPI then
        local hp = CleveRoids.NampowerAPI.GetUnitHealth(unit)
        if hp ~= nil then
            return hp == 0
        end
    end
    return UnitIsDead(unit)
end

-- Check if a unit is truly dead or a ghost using Nampower health
-- Returns: true if unit HP is 0 or unit is a ghost
function CleveRoids.IsUnitDeadOrGhost(unit)
    return CleveRoids.IsUnitDead(unit) or UnitIsGhost(unit)
end

if type(hooksecurefunc) ~= "function" then
  function hooksecurefunc(arg1, arg2, arg3)
    local tgt, fname, post

    if type(arg1) == "string" and type(arg2) == "function" and arg3 == nil then
      fname, post = arg1, arg2
      local orig = _G[fname]
      if type(orig) ~= "function" then return end
      _G[fname] = function(...)
        local args = arg or {}
        local n = (type(args) == "table" and args.n) or 0
        local r = { orig(unpack(args, 1, n)) }
        post(unpack(args, 1, n))
        return unpack(r, 1, table.getn(r))
      end
      return
    end

    if type(arg1) == "table" and type(arg2) == "string" and type(arg3) == "function" then
      tgt, fname, post = arg1, arg2, arg3
      local orig = tgt[fname]
      if type(orig) ~= "function" then return end
      tgt[fname] = function(...)
        local args = arg or {}
        local n = (type(args) == "table" and args.n) or 0
        local r = { orig(unpack(args, 1, n)) }
        post(unpack(args, 1, n))
        return unpack(r, 1, table.getn(r))
      end
      return
    end
  end
end



function CleveRoids.Seq(_, i)
    return (i or 0) + 1
end

-- PERFORMANCE: Trim cache to avoid repeated gsub pattern matching
local _trimCache = {}
local _trimCacheSize = 0
local _TRIM_CACHE_MAX = 512

function CleveRoids.Trim(str)
    if not str then
        return nil
    end

    -- PERFORMANCE: Check cache first
    local cached = _trimCache[str]
    if cached ~= nil then
        return cached
    end

    local result = string.gsub(str, "^%s*(.-)%s*$", "%1")

    -- Cache the result (limit cache size)
    if _trimCacheSize < _TRIM_CACHE_MAX then
        _trimCache[str] = result
        _trimCacheSize = _trimCacheSize + 1
    end

    return result
end

do
  local _G = _G or getfenv(0)
  local CleveRoids = _G.CleveRoids or {}
  _G.CleveRoids = CleveRoids

  CleveRoids.__mo = CleveRoids.__mo or { sources = {}, current = nil, selfTriggered = false }

  -- Priority levels for mouseover sources (higher = takes precedence)
  -- All unit frame addons get priority 3, native event gets 2, tooltip fallback gets 1
  local PRIORITY = {
    -- Unit frame addons (priority 3)
    pfui    = 3,
    blizz   = 3,
    aguf    = 3,  -- ag_UnitFrames
    ctra    = 3,  -- CT_RaidAssist
    ctuf    = 3,  -- CT_UnitFrames
    cursive = 3,  -- Cursive DoT tracker bars
    duf     = 3,  -- DiscordUnitFrames
    focus   = 3,  -- FocusFrame
    grid    = 3,  -- Grid
    ngrid   = 3,  -- NotGrid
    praid   = 3,  -- PerfectRaid
    sraid   = 3,  -- sRaidFrames
    xperl   = 3,  -- X-Perl UnitFrames
    luna    = 3,  -- LunaUnitFrames
    dfr     = 3,  -- DragonflightReloaded
    df3     = 3,  -- Dragonflight3
    -- Fallbacks (lower priority)
    native  = 2,
    tooltip = 1,
  }

  -- Get priority for a source, handling prefixed keys like "pfui:player"
  local function getPriority(source)
    if PRIORITY[source] then
      return PRIORITY[source]
    end
    -- Check for prefixed sources (e.g., "pfui:player" -> "pfui")
    -- Using string.find with captures for Lua 5.0 compatibility
    local _, _, prefix = string.find(source, "^(%w+):")
    if prefix and PRIORITY[prefix] then
      return PRIORITY[prefix]
    end
    return 0
  end

  local function getBest()
    local bestSource, bestUnit, bestP = nil, nil, -1
    for source, unit in pairs(CleveRoids.__mo.sources) do
      if unit and unit ~= "" then
        local p = getPriority(source)
        if p > bestP then
          bestP, bestSource, bestUnit = p, source, unit
        end
      end
    end
    return bestSource, bestUnit
  end

  -- Re-entrancy guard to prevent stack overflow from UI update cascades
  local isUpdatingMouseover = false

  local function apply(unit)
    if _G.SetMouseoverUnit then
      local resolved = unit
      -- "focus" is not a valid unit token in 1.12.1; resolve to real token
      if unit == "focus" then
        if pfUI and pfUI.uf and pfUI.uf.focus and pfUI.uf.focus.label and pfUI.uf.focus.id
           and UnitExists(pfUI.uf.focus.label .. pfUI.uf.focus.id) then
          resolved = pfUI.uf.focus.label .. pfUI.uf.focus.id
        else
          -- No resolvable unit token; use fallback path
          CleveRoids.mouseoverUnit = unit
          if CleveRoids.QueueActionUpdate then CleveRoids.QueueActionUpdate() end
          return
        end
      end
      -- Available via SuperWoW or Nampower v2.37+
      -- Set flag so UPDATE_MOUSEOVER_UNIT handler knows we triggered this
      CleveRoids.__mo.selfTriggered = true
      -- Use empty string instead of nil to properly clear mouseover.
      -- SetMouseoverUnit(nil) doesn't properly clear the game's internal state,
      -- causing UnitIsPlayer("mouseover") to return stale data (TurtleRP bug).
      _G.SetMouseoverUnit(resolved or "")
    else
      CleveRoids.mouseoverUnit = unit
    end
    if CleveRoids.QueueActionUpdate then CleveRoids.QueueActionUpdate() end
  end

  function CleveRoids.SetMouseoverFrom(source, unit)
    if not source or isUpdatingMouseover then return end
    CleveRoids.__mo.sources[source] = unit
    local _, bestUnit = getBest()
    if bestUnit ~= CleveRoids.__mo.current then
      CleveRoids.__mo.current = bestUnit
      isUpdatingMouseover = true
      apply(bestUnit)
      isUpdatingMouseover = false
    end
  end

  function CleveRoids.ClearMouseoverFrom(source, unitIfMatch)
    if not source or isUpdatingMouseover then return end
    if unitIfMatch and CleveRoids.__mo.sources[source] ~= unitIfMatch then
      return
    end
    CleveRoids.__mo.sources[source] = nil
    local _, bestUnit = getBest()
    if bestUnit ~= CleveRoids.__mo.current then
      CleveRoids.__mo.current = bestUnit
      isUpdatingMouseover = true
      apply(bestUnit)
      isUpdatingMouseover = false
    end
  end
end

-- TODO: Get rid of one Split function.  CleveRoids.splitString is ~10% slower
function CleveRoids.Split(s, p, trim)
    local r, o = {}, 1

    if not p or p == "" then
        if trim then
            s = CleveRoids.Trim(s)
        end
        for i = 1, string.len(s) do
            table.insert(r, string.sub(s, i, 1))
        end
        return r
    end

    repeat
        local b, e = string.find(s, p, o)
        if b == nil then
            local sub = string.sub(s, o)
            table.insert(r, trim and CleveRoids.Trim(sub) or sub)
            return r
        end
        if b > 1 then
            local sub = string.sub(s, o, b - 1)
            table.insert(r, trim and CleveRoids.Trim(sub) or sub)
        else
            table.insert(r, "")
        end
        o = e + 1
    until false
end

function CleveRoids.splitString(str, seperatorPattern)
    local tbl = {}
    if not str then
        return tbl
    end
    local pattern = "(.-)" .. seperatorPattern
    local lastEnd = 1
    local s, e, cap = string.find(str, pattern, 1)

    while s do
        if s ~= 1 or cap ~= "" then
            table.insert(tbl,cap)
        end
        lastEnd = e + 1
        s, e, cap = string.find(str, pattern, lastEnd)
    end

    if lastEnd <= string.len(str) then
        cap = string.sub(str, lastEnd)
        table.insert(tbl, cap)
    end

    return tbl
end

-- PERFORMANCE: Cache for splitStringIgnoringQuotes results
-- Key: str .. "|" .. separator_key, Value: result table
local _splitCache = {}
local _splitCacheSize = 0
local _SPLIT_CACHE_MAX = 256  -- Limit cache size to prevent unbounded growth

-- PERFORMANCE: Pre-built separator tables for common cases
local _defaultSeparator = { [";"] = ";" }
local _commaSeparator = { [","] = ",", [" "] = " " }
local _colonSeparator = { [":"] = ":" }

-- PERFORMANCE: Reusable result table pool
local _splitResultPool = {}
local _splitResultPoolSize = 0

local function getSplitResult()
    if _splitResultPoolSize > 0 then
        local r = _splitResultPool[_splitResultPoolSize]
        _splitResultPool[_splitResultPoolSize] = nil
        _splitResultPoolSize = _splitResultPoolSize - 1
        -- Clear the table for reuse
        for k in pairs(r) do r[k] = nil end
        return r
    end
    return {}
end

-- Return a result to the pool (call when done iterating)
function CleveRoids.ReleaseSplitResult(result)
    if result and _splitResultPoolSize < 16 then
        _splitResultPoolSize = _splitResultPoolSize + 1
        _splitResultPool[_splitResultPoolSize] = result
    end
end

function CleveRoids.splitStringIgnoringQuotes(str, separator)
    if not str then return {""} end

    -- PERFORMANCE: Build cache key and check cache
    local sepKey
    if separator == nil then
        sepKey = ";"
    elseif type(separator) == "table" then
        -- For table separators, use a simple identifier
        if separator[1] == "," and separator[2] == " " then
            sepKey = ",_"
        else
            sepKey = "t"
        end
    else
        sepKey = separator
    end

    local cacheKey = str .. "|" .. sepKey
    local cached = _splitCache[cacheKey]
    if cached then
        -- PERFORMANCE: Return cached result directly - callers should only iterate, not mutate
        -- This avoids table allocation on every cache hit
        return cached
    end

    local result = getSplitResult()
    local temp = ""
    local insideQuotes = false
    local separators

    -- PERFORMANCE: Use pre-built separator tables when possible
    if separator == nil then
        separators = _defaultSeparator
    elseif type(separator) == "table" then
        if separator[1] == "," and separator[2] == " " then
            separators = _commaSeparator
        elseif separator[1] == ":" then
            separators = _colonSeparator
        else
            separators = {}
            for _, s in separator do
                separators[s] = s
            end
        end
    else
        if separator == ";" then
            separators = _defaultSeparator
        elseif separator == ":" then
            separators = _colonSeparator
        else
            separators = { [separator] = separator }
        end
    end

    -- PERFORMANCE: Use local references and avoid repeated function calls
    local strlen = string.len(str)
    local strsub = string.sub
    local Trim = CleveRoids.Trim
    local tinsert = table.insert

    for i = 1, strlen do
        local char = strsub(str, i, i)

        if char == "\"" then
            insideQuotes = not insideQuotes
            temp = temp .. char
        elseif separators[char] and not insideQuotes then
            temp = Trim(temp)
            if temp ~= "" then tinsert(result, temp) end
            temp = ""
        else
            temp = temp .. char
        end
    end

    if temp ~= "" then
        temp = Trim(temp)
        tinsert(result, temp)
    end

    if not next(result) then
        result[1] = ""
    end

    -- PERFORMANCE: Cache the result (store a copy)
    if _splitCacheSize < _SPLIT_CACHE_MAX then
        local cacheCopy = {}
        for i = 1, table.getn(result) do
            cacheCopy[i] = result[i]
        end
        _splitCache[cacheKey] = cacheCopy
        _splitCacheSize = _splitCacheSize + 1
    end

    return result
end

-- Splits a macro clause into its leading run of [group] blocks and the action
-- that follows, Blizzard-style: `[a][b] Spell` is two groups sharing one action.
-- Returns prefix (the leading whitespace and ? ! ~ flag characters, kept so a
-- variant re-parses exactly like the original), groups (array with .n, each
-- entry including its brackets) and restStart (index of the action text; 1 when
-- there are no groups). Quote-aware for " so a ] inside a quoted argument does
-- not close a group; not nesting-aware. An unclosed [ ends the scan at that [,
-- which is what the old greedy "%[(.+)%]" produced for such input.
function CleveRoids.ScanBracketGroups(msg)
    local groups = { n = 0 }
    if not msg then return "", groups, 1 end

    local len = string.len(msg)
    local _, prefixEnd = string.find(msg, "^[%s%?!~]*")
    local prefix = string.sub(msg, 1, prefixEnd)
    local i = prefixEnd + 1

    while i <= len and string.sub(msg, i, i) == "[" do
        local close = nil
        local inQuotes = false
        for j = i + 1, len do
            local c = string.sub(msg, j, j)
            if c == "\"" then
                inQuotes = not inQuotes
            elseif c == "]" and not inQuotes then
                close = j
                break
            end
        end
        if not close then break end

        groups.n = groups.n + 1
        groups[groups.n] = string.sub(msg, i, close)
        local _, wsEnd = string.find(msg, "^%s*", close + 1)
        i = wsEnd + 1
    end

    if groups.n == 0 then
        return prefix, groups, 1
    end
    return prefix, groups, i
end

-- Single-group variants of a multi-group clause: `[a][b] Spell` becomes
-- { "[a] Spell", "[b] Spell", n = 2 }. nil for anything with fewer than two
-- groups so callers take their normal path without allocating. Memoised per
-- clause string in CleveRoids.ExpandedGroups (false marks "nothing to expand").
function CleveRoids.ExpandBracketGroups(msg)
    if not msg or not string.find(msg, "%[") then return nil end

    local cached = CleveRoids.ExpandedGroups[msg]
    if cached ~= nil then
        return cached or nil
    end

    local variants = nil
    local prefix, groups, restStart = CleveRoids.ScanBracketGroups(msg)
    if groups.n > 1 then
        local rest = string.sub(msg, restStart)
        if rest ~= "" then rest = " " .. rest end
        variants = { n = groups.n }
        for i = 1, groups.n do
            variants[i] = prefix .. groups[i] .. rest
        end
    end

    CleveRoids.ExpandedGroups[msg] = variants or false
    return variants
end

function CleveRoids.Print(...)
    local c = "|cFF4477FFCleveR|r|cFFFFFFFFoid :: |r"
    local out = ""

    for i=1, arg.n, 1 do
        out = out..tostring(arg[i]).."  "
    end
    if WowLuaFrameOutput then
        WowLuaFrameOutput:AddMessage(out)
    else
        if not DEFAULT_CHAT_FRAME:IsVisible() then
            FCF_SelectDockFrame(DEFAULT_CHAT_FRAME)
        end
        DEFAULT_CHAT_FRAME:AddMessage(c..out)
    end
end

function CleveRoids.PrintI(msg, depth)
    depth = depth or 0
    msg = string.rep("    ", depth) .. tostring(msg)
    CleveRoids.Print(msg)
end

function CleveRoids.PrintT(t, depth)
    depth = depth or 0
    local cs = "|cffc8c864"
    local ce = "|r"

    if t == nil or type(t) ~= "table" then
        CleveRoids.PrintI(t, depth)
    else
        for k, v in pairs(t) do
            if type(v) == "table" then
                CleveRoids.PrintI(cs..tostring(k)..":"..ce.." <TABLE>", depth)
                CleveRoids.PrintT(v, depth + 1)
            else
                CleveRoids.PrintI(cs..tostring(k)..ce..": "..tostring(v), depth)
            end
        end
    end
end

CleveRoids.buttons = {
    ['1'] = 'LeftButton',
    ['2'] = 'RightButton',
    ['3'] = 'MiddleButton',
    ['4'] = 'Button4',
    ['5'] = 'Button5',
}

-- The button that invoked the action now running, as retail's [button:N] means
-- it. ClassicAPI v1.15.8+ scopes GetMouseButtonClicked to the click dispatch, so
-- it reads the button of the handler this macro is running under -- through the
-- helpers the handler calls, not just the handler itself -- and nil at any other
-- time. A held button no longer keeps it set, which is what made mouse-turning
-- poison every keybind press before v1.15.8.
--
-- nil outside a click dispatch, so the tooltip resolves as button 1 and sits
-- still rather than tracking the mouse. Button:Click() with no argument reports
-- LeftButton, which is how a keybind comes out as button 1 on retail.
function CleveRoids.GetActivatingButton()
    return GetMouseButtonClicked() or "LeftButton"
end

-- True while a click dispatch is what is running this action. Backs bare
-- [button] / [nobutton], which retail has no equivalent for.
function CleveRoids.WasClickActivated()
    return GetMouseButtonClicked() ~= nil
end

CleveRoids.kmods = {
    ctrl   = IsControlKeyDown,
    lctrl  = IsLeftControlKeyDown,
    rctrl  = IsRightControlKeyDown,
    alt    = IsAltKeyDown,
    lalt   = IsLeftAltKeyDown,
    ralt   = IsRightAltKeyDown,
    shift  = IsShiftKeyDown,
    lshift = IsLeftShiftKeyDown,
    rshift = IsRightShiftKeyDown,
    mod    = IsModifierKeyDown,
    nomod  = function() return not IsModifierKeyDown() end,
}

-- Key code lookup table for [keydown:X] conditional (Nampower v2.41+)
-- Maps lowercase name -> integer key code from the Nampower KEY_DOWN/KEY_UP enum
CleveRoids.KEY_NAMES = {
    -- Printable ASCII
    space=32,
    ["0"]=48,["1"]=49,["2"]=50,["3"]=51,["4"]=52,
    ["5"]=53,["6"]=54,["7"]=55,["8"]=56,["9"]=57,
    a=65,b=66,c=67,d=68,e=69,f=70,g=71,h=72,i=73,j=74,k=75,l=76,
    m=77,n=78,o=79,p=80,q=81,r=82,s=83,t=84,u=85,v=86,w=87,x=88,y=89,z=90,
    -- Special
    tilde=256,
    -- Numpad
    numpad0=257,numpad1=258,numpad2=259,numpad3=260,numpad4=261,
    numpad5=262,numpad6=263,numpad7=264,numpad8=265,numpad9=266,
    -- Control keys
    escape=512,enter=513,
    -- Function keys
    f1=768,f2=769,f3=770,f4=771,f5=772,f6=773,
    f7=774,f8=775,f9=776,f10=777,f11=778,f12=779,
}

CleveRoids.operators = {
    ["<"] = "lt",
    ["lt"] = "<",
    [">"] = "gt",
    ["gt"] = ">",
    ["="] = "eq",
    ["eq"] = "=",
    ["<="] = "lte",
    ["lte"] = "<=",
    [">="] = "gte",
    ["gte"] = ">=",
    ["~="] = "ne",
    ["ne"] = "~=",
}

CleveRoids.comparators = {
    lt  = function(a, b) return (a <  b) end,
    gt  = function(a, b) return (a >  b) end,
    eq  = function(a, b) return (a == b) end,
    lte = function(a, b) return (a <= b) end,
    gte = function(a, b) return (a >= b) end,
    ne  = function(a, b) return (a ~= b) end,
}
CleveRoids.comparators["<"]  = CleveRoids.comparators.lt
CleveRoids.comparators[">"]  = CleveRoids.comparators.gt
CleveRoids.comparators["="]  = CleveRoids.comparators.eq
CleveRoids.comparators["<="] = CleveRoids.comparators.lte
CleveRoids.comparators[">="] = CleveRoids.comparators.gte
CleveRoids.comparators["~="] = CleveRoids.comparators.ne


_G["CleveRoids"] = CleveRoids

local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}
_G.CleveRoids = CleveRoids

CleveRoids.libdebuff = CleveRoids.libdebuff or {}
local lib = CleveRoids.libdebuff

lib.guidToName = lib.guidToName or {}

lib.recentDeaths = lib.recentDeaths or {}   -- [targetGUID] = GetTime() timestamp of UNIT_DIED (prevents false immunity on dead targets)
local DR_RESET_WINDOW = 20
lib.recentCCHits = lib.recentCCHits or {}   -- [targetGUID][drType] = {count, lastHitTime} for NPC DR safeguard

-- PERSONAL DEBUFFS: Each player can have their own instance of these debuffs on the same target
-- These are DoTs, poisons, stings, and most CC effects
lib.personalDebuffs = lib.personalDebuffs or {
  -- WARRIOR
  [772] = 9,      -- Rend (Rank 1)
  [6546] = 12,    -- Rend (Rank 2)
  [6547] = 15,    -- Rend (Rank 3)
  [6548] = 18,    -- Rend (Rank 4)
  [11572] = 21,   -- Rend (Rank 5)
  [11573] = 21,   -- Rend (Rank 6)
  [11574] = 21,   -- Rend (Rank 7)

  [7372] = 15,    -- Hamstring (Rank 1)
  [7373] = 15,    -- Hamstring (Rank 2)
  [1715] = 15,    -- Hamstring (Rank 3)

  [12323] = 6,    -- Piercing Howl

  -- ROGUE
  [2094] = 10,    -- Blind
  [21060] = 10,   -- Blind (alternate?)

  [6770] = 25,    -- Sap (Rank 1)
  [2070] = 35,    -- Sap (Rank 2)
  [11297] = 45,   -- Sap (Rank 3)

  [1776] = 4,     -- Gouge (Rank 1) - Scales with talent
  [1777] = 4,     -- Gouge (Rank 2)
  [8629] = 4,     -- Gouge (Rank 3)
  [11285] = 4,    -- Gouge (Rank 4)
  [11286] = 4,    -- Gouge (Rank 5)

  [1943] = 8,     -- Rupture Rank 1
  [8639] = 8,     -- Rupture Rank 2
  [8640] = 8,     -- Rupture Rank 3
  [11273] = 8,    -- Rupture Rank 4
  [11274] = 8,    -- Rupture Rank 5
  [11275] = 8,    -- Rupture Rank 6

  [703] = 18,     -- Garrote (Rank 1)
  [8631] = 18,    -- Garrote (Rank 2)
  [8632] = 18,    -- Garrote (Rank 3)
  [8633] = 18,    -- Garrote (Rank 4)
  [11289] = 18,   -- Garrote (Rank 5)
  [11290] = 18,   -- Garrote (Rank 6)

  [2818] = 12,    -- Deadly Poison (Rank 1)
  [2819] = 12,    -- Deadly Poison II (Rank 2)
  [11353] = 12,   -- Deadly Poison III (Rank 3)
  [11354] = 12,   -- Deadly Poison IV (Rank 4)
  [25349] = 12,   -- Deadly Poison V (Rank 5)

  [16511] = 15,   -- Hemorrhage

  [1833] = 4,     -- Cheap Shot
  [14902] = 4,    -- Cheap Shot (alternate?)

  -- Rogue poisons (not in Cursive, estimates):
  [3409] = 12,    -- Crippling Poison
  [5760] = 16,    -- Mind-numbing Poison (Rank 1)
  [8694] = 16,    -- Mind-numbing Poison (Rank 2)
  [11399] = 16,   -- Mind-numbing Poison (Rank 3)
  [13218] = 15,   -- Wound Poison (Rank 1)
  [13222] = 15,   -- Wound Poison (Rank 2)
  [13223] = 15,   -- Wound Poison (Rank 3)
  [13224] = 15,   -- Wound Poison (Rank 4)

  -- HUNTER
  [3043] = 20,    -- Scorpid Sting (Rank 1)
  [14275] = 20,   -- Scorpid Sting (Rank 2)
  [14276] = 20,   -- Scorpid Sting (Rank 3)
  [14277] = 20,   -- Scorpid Sting (Rank 4)

  [1978] = 15,    -- Serpent Sting (Rank 1)
  [13549] = 15,   -- Serpent Sting (Rank 2)
  [13550] = 15,   -- Serpent Sting (Rank 3)
  [13551] = 15,   -- Serpent Sting (Rank 4)
  [13552] = 15,   -- Serpent Sting (Rank 5)
  [13553] = 15,   -- Serpent Sting (Rank 6)
  [13554] = 15,   -- Serpent Sting (Rank 7)
  [13555] = 15,   -- Serpent Sting (Rank 8)
  [25295] = 15,   -- Serpent Sting (Rank 9)

  [3034] = 8,     -- Viper Sting (Rank 1)
  [14279] = 8,    -- Viper Sting (Rank 2)
  [14280] = 8,    -- Viper Sting (Rank 3)

  [2974] = 10,    -- Wing Clip (Rank 1)
  [14267] = 10,   -- Wing Clip (Rank 2)
  [14268] = 10,   -- Wing Clip (Rank 3)

  [5116] = 4,     -- Concussive Shot

  [19386] = 12,   -- Wyvern Sting (Rank 1)
  [24132] = 12,   -- Wyvern Sting (Rank 2)
  [24133] = 12,   -- Wyvern Sting (Rank 3)

  [19306] = 5,    -- Counterattack (Rank 1)
  [20909] = 5,    -- Counterattack (Rank 2)
  [20910] = 5,    -- Counterattack (Rank 3)

  [1130] = 120,   -- Hunter's Mark (Rank 1)
  [14323] = 120,  -- Hunter's Mark (Rank 2)
  [14324] = 120,  -- Hunter's Mark (Rank 3)
  [14325] = 120,  -- Hunter's Mark (Rank 4)

  -- DRUID
  [339] = 12,     -- Entangling Roots (Rank 1)
  [1062] = 15,    -- Entangling Roots (Rank 2)
  [5195] = 18,    -- Entangling Roots (Rank 3)
  [5196] = 21,    -- Entangling Roots (Rank 4)
  [9852] = 24,    -- Entangling Roots (Rank 5)
  [9853] = 27,    -- Entangling Roots (Rank 6)

  [700] = 20,     -- Sleep (Rank 1)
  [1090] = 30,    -- Sleep (Rank 2)
  [2937] = 40,    -- Sleep (Rank 3)

  [770] = 40,     -- Faerie Fire (Rank 1)
  [778] = 40,     -- Faerie Fire (Rank 2)
  [9749] = 40,    -- Faerie Fire (Rank 3)
  [9907] = 40,    -- Faerie Fire (Rank 4)

  [16855] = 40,   -- Faerie Fire (Bear) (Rank 1)
  [17387] = 40,   -- Faerie Fire (Bear) (Rank 2)
  [17388] = 40,   -- Faerie Fire (Bear) (Rank 3)
  [17389] = 40,   -- Faerie Fire (Bear) (Rank 4)

  [16857] = 40,   -- Faerie Fire (Feral) (Rank 1)
  [17390] = 40,   -- Faerie Fire (Feral) (Rank 2)
  [17391] = 40,   -- Faerie Fire (Feral) (Rank 3)
  [17392] = 40,   -- Faerie Fire (Feral) (Rank 4)

  [2637] = 20,    -- Hibernate (Rank 1)
  [18657] = 30,   -- Hibernate (Rank 2)
  [18658] = 40,   -- Hibernate (Rank 3)

  [5570] = 18,    -- Insect Swarm (Rank 1)
  [24974] = 18,   -- Insect Swarm (Rank 2)
  [24975] = 18,   -- Insect Swarm (Rank 3)
  [24976] = 18,   -- Insect Swarm (Rank 4)
  [24977] = 18,   -- Insect Swarm (Rank 5)

  [8921] = 9,     -- Moonfire (Rank 1)
  [8924] = 18,    -- Moonfire (Rank 2)
  [8925] = 18,    -- Moonfire (Rank 3)
  [8926] = 18,    -- Moonfire (Rank 4)
  [8927] = 18,    -- Moonfire (Rank 5)
  [8928] = 18,    -- Moonfire (Rank 6)
  [8929] = 18,    -- Moonfire (Rank 7)
  [9833] = 18,    -- Moonfire (Rank 8)
  [9834] = 18,    -- Moonfire (Rank 9)
  [9835] = 18,    -- Moonfire (Rank 10)

  [1822] = 9,     -- Rake (Rank 1)
  [1823] = 9,     -- Rake (Rank 2)
  [1824] = 9,     -- Rake (Rank 3)
  [9904] = 9,     -- Rake (Rank 4)

  -- NOTE: Rip is a combo-scaling personal debuff (base 10s + 2s per CP)
  [1079] = 10,    -- Rip (Rank 1)
  [9492] = 10,    -- Rip (Rank 2)
  [9493] = 10,    -- Rip (Rank 3)
  [9752] = 10,    -- Rip (Rank 4)
  [9894] = 10,    -- Rip (Rank 5)
  [9896] = 10,    -- Rip (Rank 6)

  [2908] = 15,    -- Soothe Animal (Rank 1)
  [8955] = 15,    -- Soothe Animal (Rank 2)
  [9901] = 15,    -- Soothe Animal (Rank 3)

  [5211] = 2,     -- Bash (Rank 1)
  [6798] = 3,     -- Bash (Rank 2)
  [8983] = 4,     -- Bash (Rank 3)

  [9007] = 18,    -- Pounce Bleed (Rank 1) - triggered by Pounce 9005
  [9824] = 18,    -- Pounce Bleed (Rank 2) - triggered by Pounce 9823
  [9826] = 18,    -- Pounce Bleed (Rank 3) - triggered by Pounce 9827

  -- WARLOCK
  [172] = 12,     -- Corruption (Rank 1)
  [6222] = 15,    -- Corruption (Rank 2)
  [6223] = 18,    -- Corruption (Rank 3)
  [7648] = 18,    -- Corruption (Rank 4)
  [11671] = 18,   -- Corruption (Rank 5)
  [11672] = 18,   -- Corruption (Rank 6)
  [25311] = 18,   -- Corruption (Rank 7)

  [980] = 24,     -- Curse of Agony (Rank 1)
  [1014] = 24,    -- Curse of Agony (Rank 2)
  [6217] = 24,    -- Curse of Agony (Rank 3)
  [11711] = 24,   -- Curse of Agony (Rank 4)
  [11712] = 24,   -- Curse of Agony (Rank 5)
  [11713] = 24,   -- Curse of Agony (Rank 6)

  [18265] = 30,   -- Siphon Life (Rank 1)
  [18879] = 30,   -- Siphon Life (Rank 2)
  [18880] = 30,   -- Siphon Life (Rank 3)
  [18881] = 30,   -- Siphon Life (Rank 4)

  [52550] = 8,    -- Dark Harvest (Rank 1)
  [52551] = 8,    -- Dark Harvest (Rank 2)
  [52552] = 8,    -- Dark Harvest (Rank 3)

  [603] = 60,     -- Curse of Doom

  [704] = 120,    -- Curse of Recklessness (Rank 1)
  [7658] = 120,   -- Curse of Recklessness (Rank 2)
  [7659] = 120,   -- Curse of Recklessness (Rank 3)
  [11717] = 120,  -- Curse of Recklessness (Rank 4)

  [17862] = 300,  -- Curse of Shadow (Rank 1)
  [17937] = 300,  -- Curse of Shadow (Rank 2)

  [1490] = 300,   -- Curse of Elements (Rank 1)
  [11721] = 300,  -- Curse of Elements (Rank 2)
  [11722] = 300,  -- Curse of Elements (Rank 3)

  [1714] = 30,    -- Curse of Tongues (Rank 1)
  [11719] = 30,   -- Curse of Tongues (Rank 2)

  [702] = 120,    -- Curse of Weakness (Rank 1)
  [1108] = 120,   -- Curse of Weakness (Rank 2)
  [6205] = 120,   -- Curse of Weakness (Rank 3)
  [7646] = 120,   -- Curse of Weakness (Rank 4)
  [11707] = 120,  -- Curse of Weakness (Rank 5)
  [11708] = 120,  -- Curse of Weakness (Rank 6)

  [18223] = 12,   -- Curse of Exhaustion

  [348] = 15,     -- Immolate (Rank 1)
  [707] = 15,     -- Immolate (Rank 2)
  [1094] = 15,    -- Immolate (Rank 3)
  [2941] = 15,    -- Immolate (Rank 4)
  [11665] = 15,   -- Immolate (Rank 5)
  [11667] = 15,   -- Immolate (Rank 6)
  [11668] = 15,   -- Immolate (Rank 7)
  [25309] = 15,   -- Immolate (Rank 8)

  [6789] = 3,     -- Death Coil (Rank 1)
  [17925] = 3,    -- Death Coil (Rank 2)
  [17926] = 3,    -- Death Coil (Rank 3)

  [710] = 20,     -- Banish (Rank 1)
  [18647] = 30,   -- Banish (Rank 2)

  [5782] = 10,    -- Fear (Rank 1)
  [6213] = 15,    -- Fear (Rank 2)
  [6215] = 20,    -- Fear (Rank 3)

  -- MAGE
  [118] = 20,     -- Polymorph (Rank 1)
  [12824] = 30,   -- Polymorph (Rank 2)
  [12825] = 40,   -- Polymorph (Rank 3)
  [12826] = 50,   -- Polymorph (Rank 4)

  [28270] = 50,   -- Polymorph: Cow
  [28271] = 50,   -- Polymorph: Turtle
  [28272] = 50,   -- Polymorph: Pig

  [116] = 5,      -- Frostbolt slow
  [120] = 5,      -- Cone of Cold slow
  [6136] = 15,    -- Chilled
  [12484] = 15,   -- Improved Blizzard slow
  [12486] = 15,   -- Blizzard slow

  -- PRIEST
  [1425] = 30,    -- Shackle Undead (Rank 1)
  [9486] = 40,    -- Shackle Undead (Rank 2)
  [10956] = 50,   -- Shackle Undead (Rank 3)

  [453] = 15,     -- Mind Soothe (Rank 1)
  [8192] = 15,    -- Mind Soothe (Rank 2)
  [10953] = 15,   -- Mind Soothe (Rank 3)

  [605] = 60,     -- Mind Control (Rank 1)
  [10911] = 30,   -- Mind Control (Rank 2)
  [10912] = 30,   -- Mind Control (Rank 3)

  [2944] = 24,    -- Devouring Plague (Rank 1)
  [19276] = 24,   -- Devouring Plague (Rank 2)
  [19277] = 24,   -- Devouring Plague (Rank 3)
  [19278] = 24,   -- Devouring Plague (Rank 4)
  [19279] = 24,   -- Devouring Plague (Rank 5)
  [19280] = 24,   -- Devouring Plague (Rank 6)

  [9035] = 120,   -- Hex of Weakness (Rank 1)
  [19281] = 120,  -- Hex of Weakness (Rank 2)
  [19282] = 120,  -- Hex of Weakness (Rank 3)
  [19283] = 120,  -- Hex of Weakness (Rank 4)
  [19284] = 120,  -- Hex of Weakness (Rank 5)
  [19285] = 120,  -- Hex of Weakness (Rank 6)

  [589] = 18,     -- Shadow Word: Pain (Rank 1)
  [594] = 18,     -- Shadow Word: Pain (Rank 2)
  [970] = 18,     -- Shadow Word: Pain (Rank 3)
  [992] = 18,     -- Shadow Word: Pain (Rank 4)
  [2767] = 18,    -- Shadow Word: Pain (Rank 5)
  [10892] = 18,   -- Shadow Word: Pain (Rank 6)
  [10893] = 18,   -- Shadow Word: Pain (Rank 7)
  [10894] = 18,   -- Shadow Word: Pain (Rank 8)

  [15286] = 60,   -- Vampiric Embrace

  [14914] = 10,   -- Holy Fire (Rank 1)
  [15262] = 10,   -- Holy Fire (Rank 2)
  [15263] = 10,   -- Holy Fire (Rank 3)
  [15264] = 10,   -- Holy Fire (Rank 4)
  [15265] = 10,   -- Holy Fire (Rank 5)
  [15266] = 10,   -- Holy Fire (Rank 6)
  [15267] = 10,   -- Holy Fire (Rank 7)
  [15261] = 10,   -- Holy Fire (Rank 8)

  -- Mind Flay
  [15407] = 3,    -- Mind Flay (Rank 1)
  [17311] = 3,    -- Mind Flay (Rank 2)
  [17312] = 3,    -- Mind Flay (Rank 3)
  [17313] = 3,    -- Mind Flay (Rank 4)
  [17314] = 3,    -- Mind Flay (Rank 5)
  [18807] = 3,    -- Mind Flay (Rank 6)

  -- PALADIN
  [853] = 6,      -- Hammer of Justice (Rank 1)
  [5588] = 6,     -- Hammer of Justice (Rank 2)
  [5589] = 6,     -- Hammer of Justice (Rank 3)
  [10308] = 6,    -- Hammer of Justice (Rank 4)

  -- NOTE: Judgements moved to sharedDebuffs for proper target scanning
  -- NOTE: 51750 is the CAST spell for Turtle WoW, not a debuff (debuff is 51752)

  -- SHAMAN
  -- NOTE: Flame Shock is 15s in Turtle WoW (was 12s in vanilla)
  [8050] = 15,    -- Flame Shock (Rank 1)
  [8052] = 15,    -- Flame Shock (Rank 2)
  [8053] = 15,    -- Flame Shock (Rank 3)
  [10447] = 15,   -- Flame Shock (Rank 4)
  [10448] = 15,   -- Flame Shock (Rank 5)
  [29228] = 15,   -- Flame Shock (Rank 6)

  -- Frost Shock
  [8056] = 8,     -- Frost Shock (Rank 1)
  [8058] = 8,     -- Frost Shock (Rank 2)
  [10472] = 8,    -- Frost Shock (Rank 3)
  [10473] = 8,    -- Frost Shock (Rank 4)
}

-- SHARED DEBUFFS: Only one instance exists on a target, shared/refreshed by all players
-- These are armor reductions, attack power reductions, and marks
lib.sharedDebuffs = lib.sharedDebuffs or {
  -- PALADIN JUDGEMENTS (tracked as shared so SeedUnit picks them up from target scanning)
  [20184] = 10,   -- Judgement of Justice
  [20185] = 10,   -- Judgement of Light (Rank 1)
  [20267] = 10,   -- Judgement of Light (Rank 2)
  [20268] = 10,   -- Judgement of Light (Rank 3)
  [20271] = 10,   -- Judgement of Light (Rank 4)
  [20186] = 10,   -- Judgement of Wisdom (Rank 1)
  [20354] = 10,   -- Judgement of Wisdom (Rank 2)
  [20355] = 10,   -- Judgement of Wisdom (Rank 3)
  [51751] = 10,   -- Judgement of Wisdom (Rank 4) - Turtle WoW
  [51752] = 10,   -- Judgement of Wisdom (Rank 5) - Turtle WoW
  [21183] = 10,   -- Judgement of the Crusader (Rank 1)
  [20183] = 10,   -- Judgement of the Crusader (Rank 2)
  [20300] = 10,   -- Judgement of the Crusader (Rank 3)
  [20301] = 10,   -- Judgement of the Crusader (Rank 4)
  [20302] = 10,   -- Judgement of the Crusader (Rank 5)
  [20303] = 10,   -- Judgement of the Crusader (Rank 6)
  [51752] = 10,   -- Turtle WoW: Judgement of Wisdom debuff

  -- WARRIOR
  [7386] = 30,    -- Sunder Armor (Rank 1)
  [7405] = 30,    -- Sunder Armor (Rank 2)
  [8380] = 30,    -- Sunder Armor (Rank 3)
  [8647] = 30,    -- Sunder Armor (Rank 4)
  [11597] = 30,   -- Sunder Armor (Rank 5)

  [6343] = 10,    -- Thunder Clap (Rank 1)
  [8198] = 14,    -- Thunder Clap (Rank 2)
  [8205] = 18,    -- Thunder Clap (Rank 3)
  [11580] = 22,   -- Thunder Clap (Rank 4)
  [11581] = 26,   -- Thunder Clap (Rank 5)
  [13532] = 30,   -- Thunder Clap (Rank 6)

  [1160] = 30,    -- Demoralizing Shout (Rank 1)
  [6190] = 30,    -- Demoralizing Shout (Rank 2)
  [11554] = 30,   -- Demoralizing Shout (Rank 3)
  [11555] = 30,   -- Demoralizing Shout (Rank 4)
  [11556] = 30,   -- Demoralizing Shout (Rank 5)

  -- ROGUE
  [8647] = 30,    -- Expose Armor (Rank 1)
  [8649] = 30,    -- Expose Armor (Rank 2)
  [8650] = 30,    -- Expose Armor (Rank 3)
  [11197] = 30,   -- Expose Armor (Rank 4)
  [11198] = 30,   -- Expose Armor (Rank 5)

  -- HUNTER
  [1130] = 120,   -- Hunter's Mark (Rank 1)
  [14323] = 120,  -- Hunter's Mark (Rank 2)
  [14324] = 120,  -- Hunter's Mark (Rank 3)
  [14325] = 120,  -- Hunter's Mark (Rank 4)

  -- DRUID
  [770] = 40,     -- Faerie Fire (Rank 1)
  [778] = 40,     -- Faerie Fire (Rank 2)
  [9749] = 40,    -- Faerie Fire (Rank 3)
  [9907] = 40,    -- Faerie Fire (Rank 4)

  [16855] = 40,   -- Faerie Fire (Bear) (Rank 1)
  [17387] = 40,   -- Faerie Fire (Bear) (Rank 2)
  [17388] = 40,   -- Faerie Fire (Bear) (Rank 3)
  [17389] = 40,   -- Faerie Fire (Bear) (Rank 4)

  [16857] = 40,   -- Faerie Fire (Feral) (Rank 1)
  [17390] = 40,   -- Faerie Fire (Feral) (Rank 2)
  [17391] = 40,   -- Faerie Fire (Feral) (Rank 3)
  [17392] = 40,   -- Faerie Fire (Feral) (Rank 4)

  [99] = 30,      -- Demoralizing Roar (Rank 1)
  [1735] = 30,    -- Demoralizing Roar (Rank 2)
  [9490] = 30,    -- Demoralizing Roar (Rank 3)
  [9747] = 30,    -- Demoralizing Roar (Rank 4)
  [9898] = 30,    -- Demoralizing Roar (Rank 5)

  [5209] = 6,     -- Challenging Roar
}

-- Helper function to check if a debuff is personal (returns true) or shared (returns false)
function lib:IsPersonalDebuff(spellID)
  if lib.personalDebuffs[spellID] then
    return true
  elseif lib.sharedDebuffs[spellID] then
    return false
  end
  -- Unknown debuffs are treated as personal by default (safer for multi-player scenarios)
  return true
end

-- Helper function to extract numeric rank from spell ID
-- Returns rank number (1, 2, 3, etc.) or 0 if no rank found
function lib:GetSpellRank(spellID)
  if not spellID then return 0 end
  local name = C_Spell.GetSpellName(spellID)
  local rankStr = C_Spell.GetSpellSubtext(spellID)
  if not rankStr or rankStr == "" then return 0 end

  -- Handle different rank formats
  -- Could be: "Rank 9", "9", or number 9
  local rankType = type(rankStr)

  if rankType == "number" then
    return rankStr
  elseif rankType == "string" then
    -- Try to extract number from "Rank X" format or just "X"
    local _, _, rank = string.find(rankStr, "(%d+)")
    return tonumber(rank) or 0
  end

  return 0
end

-- Helper function to get spell base name (without rank)
function lib:GetSpellBaseName(spellID)
  if not spellID then return nil end
  local name = C_Spell.GetSpellName(spellID)
  if not name then return nil end

  -- Remove rank suffix
  return CleveRoids.StripRank(name)
end

-- Reverse lookup: spell NAME -> immunity type for combat log tracking
-- Used by HandleAffliction to confirm spells landed (SPELL_AURA_APPLIED)
-- Format: { ["SpellName"] = { type = "cc" or "school", value = "stun" or "bleed" } }
lib.trackedAfflictions = {
  -- Hidden CC effects (no visible debuff, must use combat log)
  ["Pounce"] = { type = "cc", value = "stun" },

  -- Bleed effects (visible debuff, but combat log is more reliable)
  ["Pounce Bleed"] = { type = "school", value = "bleed" },
  ["Rake"] = { type = "school", value = "bleed" },
  ["Rip"] = { type = "school", value = "bleed" },
  ["Lacerate"] = { type = "school", value = "bleed" },
  ["Garrote"] = { type = "school", value = "bleed" },
  ["Rupture"] = { type = "school", value = "bleed" },
  ["Deep Wound"] = { type = "school", value = "bleed" },
  ["Deep Wounds"] = { type = "school", value = "bleed" },
  ["Rend"] = { type = "school", value = "bleed" },
}

-- Spells with INVULNERABILITY mechanic (mechanic 25) from BuffLib SpellData DBC
-- These grant temporary immunity and should not trigger permanent immunity recording
-- Source: BuffLib/SpellData.lua - extracted from DBC files
local INVULNERABILITY_SPELL_IDS = {
    -- Paladin
    [498] = true,    -- Divine Protection (Rank 1)
    [642] = true,    -- Divine Shield (Rank 1)
    [1020] = true,   -- Divine Shield (Rank 2)
    [1022] = true,   -- Blessing of Protection (Rank 1)
    [5573] = true,   -- Divine Protection (Rank 2)
    [5599] = true,   -- Blessing of Protection (Rank 2)
    [10278] = true,  -- Blessing of Protection (Rank 3)
    [25771] = true,  -- Forbearance (debuff after immunity)
    -- Old/Unused Paladin
    [1052] = true,   -- zzOLDBlessing of Righteousness
    [5601] = true,   -- zzOLDBlessing of Righteousness
    [5602] = true,   -- zzOLDBlessing of Righteousness
    [10280] = true,  -- zzOLDBlessing of Righteousness
    [10281] = true,  -- zzOLDBlessing of Righteousness
    -- Rogue
    [6770] = true,   -- Sap (invuln during effect)
    -- NPC/Misc
    [7992] = true,   -- Slowing Poison
    [11638] = true,  -- Radiation Poisoning
    [14897] = true,  -- Slowing Poison
    [16603] = true,  -- Demonfork
    [16791] = true,  -- Furious Anger
    [17407] = true,  -- Wound
    [18208] = true,  -- Poison
    [23230] = true,  -- Blood Fury
    [24005] = true,  -- Food
    [24707] = true,  -- Food
    [24865] = true,  -- Sanctified Orb
    [26263] = true,  -- Dim Sum
    [28522] = true,  -- Icebolt
    [29055] = true,  -- Refreshing Red Apple
    [29325] = true,  -- Acid Volley
    [29330] = true,  -- Sapphiron's Wing Buffet Despawn
    -- Spell Reflection (no DBC mechanic, but grants immunity to reflected schools)
    [9941] = true,   -- Spell Reflection
    [9943] = true,   -- Spell Reflection
    [10074] = true,  -- Spell Reflection
    [11818] = true,  -- Spell Reflection
    [21118] = true,  -- Spell Reflection
    -- School-specific Reflectors (Engineering items)
    [23097] = true,  -- Fire Reflector
    [23131] = true,  -- Frost Reflector
    [23132] = true,  -- Shadow Reflector
    [23178] = true,  -- Nature Reflector
    [23216] = true,  -- Arcane Reflector
    -- Multi-school Reflect (NPC abilities)
    [13022] = true,  -- Fire and Arcane Reflect
    [19595] = true,  -- Shadow and Frost Reflect
    -- Generic Reflection buffs
    [3651] = true,   -- Shield of Reflection
    [9906] = true,   -- Reflection
    [10831] = true,  -- Reflection Field
    [17106] = true,  -- Reflection
    [17107] = true,  -- Reflection
    [17108] = true,  -- Reflection
    [20223] = true,  -- Magic Reflection
    [20619] = true,  -- Magic Reflection
    [22067] = true,  -- Reflection
    [23920] = true,  -- Shield Reflection
    [23921] = true,  -- Shield Reflection
    [27564] = true,  -- Reflection
}

-- Check if a unit has any immunity-granting buff active
-- Uses only spell IDs from DBC mechanic 25 (INVULNERABILITY) for reliability
-- Returns the buff name if found, nil otherwise
local function HasImmunityGrantingBuff(unit)
    if not UnitExists(unit) then return nil end

    for i = 1, 32 do
        local texture, stacks, spellID = UnitBuff(unit, i)
        if not texture then break end

        if spellID and INVULNERABILITY_SPELL_IDS[spellID] then
            local buffName = C_Spell.GetSpellName(spellID) or ("SpellID:" .. spellID)
            return buffName
        end
    end

    return nil
end

-- Enemy and name bookkeeping: seed knownEnemyGuids from targeting, and wipe the
-- GUID caches on a zone change (GUIDs are reused across zones).
local unitTrackingFrame = CreateFrame("Frame", "CleveRoidsUnitTrackingFrame")
unitTrackingFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
unitTrackingFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
unitTrackingFrame:SetScript("OnEvent", function()
  if event == "ZONE_CHANGED_NEW_AREA" then
    if CleveRoids.knownEnemyGuids then
      for k in pairs(CleveRoids.knownEnemyGuids) do
        CleveRoids.knownEnemyGuids[k] = nil
      end
    end
    for k in pairs(lib.guidToName) do
      lib.guidToName[k] = nil
    end
    -- DR state is invalid in a new zone
    for k in pairs(lib.recentCCHits) do
      lib.recentCCHits[k] = nil
    end
  elseif UnitExists("target") and UnitCanAttack("player", "target") and CleveRoids.knownEnemyGuids then
    local guid = CleveRoids.GetGUID("target")
    if guid then
      CleveRoids.knownEnemyGuids[guid] = true
    end
  end
end)

-- Every 5s: forget a dead unit's name once the immunity checks no longer need it
-- (queued by HandleUnitDied), and age out the recent-death guard.
CleveRoids._cleanupTicker = C_Timer.NewTicker(5, function()
  if CleveRoids.isShuttingDown then return end
  local now = GetTime()
  local queue = lib._guidNameCleanupQueue
  if queue then
    local i = 1
    while i <= table.getn(queue) do
      if now >= queue[i].expiry then
        lib.guidToName[queue[i].guid] = nil
        table.remove(queue, i)
      else
        i = i + 1
      end
    end
  end
  for guid, deathTime in pairs(lib.recentDeaths) do
    if now - deathTime > 10 then
      lib.recentDeaths[guid] = nil
    end
  end
end)

-- Instant cleanup when a unit dies (UNIT_DIED, from the combat log dispatcher)
local function HandleUnitDied(guid)
  if not guid then return end

  -- Get unit name before cleanup (for debug output)
  local unitName = lib.guidToName[guid]

  -- Track recent death to prevent false immunity recording
  -- (dead targets report SPELL_MISSED IMMUNE for in-flight spells)
  lib.recentDeaths[guid] = GetTime()

  lib.recentCCHits[guid] = nil

  -- Clean up overflow buff tracking (death removes all buffs)
  local playerGUID = CleveRoids.GetGUID("player")
  if playerGUID and guid == playerGUID then
    -- Player died: clear all overflow buff entries and reset cap status
    if CleveRoids.OverflowBuffs then
      for k in pairs(CleveRoids.OverflowBuffs) do
        CleveRoids.OverflowBuffs[k] = nil
      end
    end
    if CleveRoids.AuraCapStatus then
      CleveRoids.AuraCapStatus.playerBuffCapped = false
      CleveRoids.AuraCapStatus.playerDebuffCapped = false
    end
  end
  -- Clean up all-caster aura tracking for the dead unit
  if CleveRoids.AllCasterAuraTracking and CleveRoids.AllCasterAuraTracking[guid] then
    CleveRoids.AllCasterAuraTracking[guid] = nil
  end
  -- Remove from known enemy GUID tracker
  if CleveRoids.knownEnemyGuids then
    CleveRoids.knownEnemyGuids[guid] = nil
  end

  -- Deferred GUID-to-name cleanup (5s delay to allow immunity detection lookups)
  lib._guidNameCleanupQueue = lib._guidNameCleanupQueue or {}
  table.insert(lib._guidNameCleanupQueue, { guid = guid, expiry = GetTime() + 5 })

  if CleveRoids.debug and unitName then
    DEFAULT_CHAT_FRAME:AddMessage(
      string.format("|cffff6600[UNIT_DIED]|r Cleaned up tracking data for %s (%s)",
        unitName, guid)
    )
  end
end

-- TALENT MODIFIER SYSTEM

-- Database of talent modifiers for debuff durations
-- Structure: [spellID] = {
--   talent = "Talent Name" (optional, for name-based lookup),
--   tab = talentTab (preferred, for direct position lookup),
--   id = talentID (preferred, for direct position lookup),
--   modifier = function(baseDuration, talentRank)
-- }
CleveRoids.talentModifiers = CleveRoids.talentModifiers or {}

-- ROGUE talent modifiers
-- Taste for Blood: Increases Rupture duration by 2 seconds per rank (3 ranks max)
-- Talent Position: Tab 1, Talent 10 (Assassination tree)
-- Talent Spell IDs: 14174 (Rank 1), 14175 (Rank 2), 14176 (Rank 3)
CleveRoids.talentModifiers[1943] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end }  -- Rupture Rank 1
CleveRoids.talentModifiers[8639] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end }  -- Rupture Rank 2
CleveRoids.talentModifiers[8640] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end }  -- Rupture Rank 3
CleveRoids.talentModifiers[11273] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end } -- Rupture Rank 4
CleveRoids.talentModifiers[11274] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end } -- Rupture Rank 5
CleveRoids.talentModifiers[11275] = { tab = 1, id = 10, talent = "Taste for Blood", modifier = function(base, rank) return base + (rank * 2) end } -- Rupture Rank 6

-- Improved Gouge: Increases Gouge duration by 0.5 seconds per rank (3 ranks max)
-- Talent Position: Tab 3, Talent 3 (Subtlety tree)
-- Talent Spell IDs: 13741 (Rank 1), 13793 (Rank 2), 13792 (Rank 3)
CleveRoids.talentModifiers[1776] = { tab = 3, id = 3, talent = "Improved Gouge", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Gouge Rank 1
CleveRoids.talentModifiers[1777] = { tab = 3, id = 3, talent = "Improved Gouge", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Gouge Rank 2
CleveRoids.talentModifiers[8629] = { tab = 3, id = 3, talent = "Improved Gouge", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Gouge Rank 3
CleveRoids.talentModifiers[11285] = { tab = 3, id = 3, talent = "Improved Gouge", modifier = function(base, rank) return base + (rank * 0.5) end } -- Gouge Rank 4
CleveRoids.talentModifiers[11286] = { tab = 3, id = 3, talent = "Improved Gouge", modifier = function(base, rank) return base + (rank * 0.5) end } -- Gouge Rank 5

-- PRIEST talent modifiers
-- Improved Shadow Word: Pain: Increases SW:P duration by 3 seconds per rank (2 ranks max)
-- Talent Position: Tab 3 (Shadow), Talent 4
-- Talent Spell IDs: 15275 (Rank 1), 15317 (Rank 2)
CleveRoids.talentModifiers[589] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }    -- SW:P Rank 1
CleveRoids.talentModifiers[594] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }    -- SW:P Rank 2
CleveRoids.talentModifiers[970] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }    -- SW:P Rank 3
CleveRoids.talentModifiers[992] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }    -- SW:P Rank 4
CleveRoids.talentModifiers[2767] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }   -- SW:P Rank 5
CleveRoids.talentModifiers[10892] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }  -- SW:P Rank 6
CleveRoids.talentModifiers[10893] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }  -- SW:P Rank 7
CleveRoids.talentModifiers[10894] = { tab = 3, id = 4, talent = "Improved Shadow Word: Pain", modifier = function(base, rank) return base + (rank * 3) end }  -- SW:P Rank 8

-- DRUID talent modifiers
-- Brutal Impact: Increases Bash and Pounce stun duration by 0.5 seconds per rank (2 ranks max)
-- Talent Position: Tab 2 (Feral Combat), Talent 4
-- Talent Spell IDs: 16940 (Rank 1), 16941 (Rank 2)
CleveRoids.talentModifiers[5211] = { tab = 2, id = 4, talent = "Brutal Impact", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Bash Rank 1
CleveRoids.talentModifiers[6798] = { tab = 2, id = 4, talent = "Brutal Impact", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Bash Rank 2
CleveRoids.talentModifiers[8983] = { tab = 2, id = 4, talent = "Brutal Impact", modifier = function(base, rank) return base + (rank * 0.5) end }  -- Bash Rank 3

-- NOTE: Brutal Impact affects the STUN portion of Pounce (cast spell IDs 9005, 9823, 9827)
-- The BLEED portion (triggered spell IDs 9007, 9824, 9826) is NOT affected by Brutal Impact
-- We track the bleed for immunity detection, not the stun, so no talent modifiers needed here

-- WARRIOR talent modifiers
-- Booming Voice: Increases duration of Battle Shout and Demoralizing Shout by 12% per rank (5 ranks max)
-- Talent Position: Tab 2 (Fury), Talent 1
-- Talent Spell IDs: 12321 (Rank 1), 12835 (Rank 2), 12836 (Rank 3), 12837 (Rank 4), 12838 (Rank 5)
local boomingVoiceModifier = function(base, rank) return base * (1 + rank * 0.12) end  -- 12% per rank, 60% at rank 5
CleveRoids.talentModifiers[1160] = { tab = 2, id = 1, talent = "Booming Voice", modifier = boomingVoiceModifier }   -- Demoralizing Shout Rank 1
CleveRoids.talentModifiers[6190] = { tab = 2, id = 1, talent = "Booming Voice", modifier = boomingVoiceModifier }   -- Demoralizing Shout Rank 2
CleveRoids.talentModifiers[11554] = { tab = 2, id = 1, talent = "Booming Voice", modifier = boomingVoiceModifier }  -- Demoralizing Shout Rank 3
CleveRoids.talentModifiers[11555] = { tab = 2, id = 1, talent = "Booming Voice", modifier = boomingVoiceModifier }  -- Demoralizing Shout Rank 4
CleveRoids.talentModifiers[11556] = { tab = 2, id = 1, talent = "Booming Voice", modifier = boomingVoiceModifier }  -- Demoralizing Shout Rank 5

-- Function to get talent rank
-- Supports both position-based (tab, id) and name-based lookup
-- Position-based is preferred as it's more reliable and locale-independent (like Cursive addon)
-- Parameters: talentName OR (tab, id)
-- Returns: Talent rank (0 if not found or not learned)
function CleveRoids.GetTalentRank(talentName, tab, id)
    -- Method 1: Direct position lookup (preferred, like Cursive)
    if tab and id then
        local _, _, _, _, rank = GetTalentInfo(tab, id)
        return tonumber(rank) or 0
    end

    -- Method 2: Name-based lookup (fallback for backwards compatibility)
    if not talentName then return 0 end

    -- Ensure talents are indexed
    if not CleveRoids.Talents or table.getn(CleveRoids.Talents) == 0 then
        if CleveRoids.IndexTalents then
            CleveRoids.IndexTalents()
        end
    end

    local rank = CleveRoids.Talents[talentName]
    return (rank and tonumber(rank)) or 0
end

-- Apply talent modifiers to a debuff duration
-- Parameters:
--   spellID: The spell ID
--   baseDuration: The base duration (after combo points if applicable)
-- Returns: Modified duration, or baseDuration if no talent modifier applies
function CleveRoids.ApplyTalentModifier(spellID, baseDuration)
    if not spellID or not baseDuration then
        return baseDuration
    end

    local modifier = CleveRoids.talentModifiers[spellID]
    if not modifier then
        return baseDuration
    end

    local talentRank = 0
    local lookupMethod = "none"

    -- Method 1: Position-based lookup (preferred, locale-independent)
    if modifier.tab and modifier.id then
        local _, _, _, _, rank = GetTalentInfo(modifier.tab, modifier.id)
        talentRank = tonumber(rank) or 0
        if talentRank > 0 then
            lookupMethod = "position"
        end
    end

    -- Method 2: Name-based lookup (fallback for backwards compatibility)
    if talentRank == 0 and modifier.talent then
        talentRank = CleveRoids.GetTalentRank(modifier.talent)
        if talentRank > 0 then
            lookupMethod = "name"
        end
    end

    if talentRank == 0 then
        return baseDuration
    end

    local modifiedDuration = modifier.modifier(baseDuration, talentRank)

    if CleveRoids.debug then
        local talentName = modifier.talent or ("Tab " .. modifier.tab .. " ID " .. modifier.id)
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff00ff[Talent Modifier]|r %s (ID:%d): %ds -> %ds (talent: %s rank %d, %s)",
                C_Spell.GetSpellName(spellID) or "Unknown", spellID, baseDuration, modifiedDuration,
                talentName, talentRank, lookupMethod)
        )
    end

    return modifiedDuration
end

-- Helper function to register a talent modifier
-- Usage: CleveRoids.RegisterTalentModifier(spellID, talentName, modifierFunction)
function CleveRoids.RegisterTalentModifier(spellID, talentName, modifierFunc)
    if not spellID or not talentName or not modifierFunc then
        return false
    end

    CleveRoids.talentModifiers[spellID] = {
        talent = talentName,
        modifier = modifierFunc
    }

    return true
end

-- Diagnostic function to check talent modifier system
-- Usage: CleveRoids.DiagnoseTalentModifier(spellID, baseDuration)
function CleveRoids.DiagnoseTalentModifier(spellID, baseDuration)
    baseDuration = baseDuration or 10 -- Default test duration

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== Talent Modifier Diagnostic ===|r")

    -- Check if spellID is valid
    local spellName = C_Spell.GetSpellName(spellID)
    if not spellName then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ERROR: Invalid spell ID " .. tostring(spellID) .. "|r")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("Spell: " .. spellName .. " (ID: " .. spellID .. ")")

    -- Check if talents are indexed
    if not CleveRoids.Talents then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ERROR: Talents table doesn't exist!|r")
        DEFAULT_CHAT_FRAME:AddMessage("Attempting to index talents...")
        if CleveRoids.IndexTalents then
            CleveRoids.IndexTalents()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Talents indexed.|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ERROR: IndexTalents function not found!|r")
            return
        end
    end

    local talentCount = 0
    for k, v in pairs(CleveRoids.Talents) do
        if type(k) == "string" and type(v) == "number" and v > 0 then
            talentCount = talentCount + 1
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("Talents indexed: " .. talentCount .. " talents found")

    -- Check if modifier is registered
    local modifier = CleveRoids.talentModifiers[spellID]
    if not modifier then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000No talent modifier registered for this spell|r")
        return
    end

    local talentDesc = modifier.talent or ("Tab " .. tostring(modifier.tab) .. " ID " .. tostring(modifier.id))
    DEFAULT_CHAT_FRAME:AddMessage("Modifier registered: " .. talentDesc)

    -- Check talent rank using BOTH methods
    local talentRank = 0
    local lookupMethod = "none"

    if modifier.tab and modifier.id then
        -- Position-based lookup (preferred)
        local _, name, _, _, rank = GetTalentInfo(modifier.tab, modifier.id)
        talentRank = tonumber(rank) or 0
        lookupMethod = "position"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Position lookup (Tab " .. modifier.tab .. ", ID " .. modifier.id .. "):|r")
        DEFAULT_CHAT_FRAME:AddMessage("  Talent name: " .. tostring(name))
        DEFAULT_CHAT_FRAME:AddMessage("  Rank: " .. talentRank)
    end

    if modifier.talent then
        -- Name-based lookup (fallback)
        local nameRank = CleveRoids.GetTalentRank(modifier.talent)
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaa00Name lookup (" .. modifier.talent .. "):|r")
        DEFAULT_CHAT_FRAME:AddMessage("  Rank: " .. nameRank)

        -- Use name rank if position didn't work
        if talentRank == 0 and nameRank > 0 then
            talentRank = nameRank
            lookupMethod = "name"
        end

        -- Check if talent exists in table
        local directLookup = CleveRoids.Talents[modifier.talent]
        DEFAULT_CHAT_FRAME:AddMessage("  Direct table lookup: " .. tostring(directLookup))
    end

    DEFAULT_CHAT_FRAME:AddMessage("Final rank: " .. talentRank .. " (via " .. lookupMethod .. ")")

    if talentRank == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000You don't have " .. talentDesc .. "!|r")
        -- Show available talents for debugging
        DEFAULT_CHAT_FRAME:AddMessage("Available talents with ranks:")
        local shown = 0
        for name, rank in pairs(CleveRoids.Talents) do
            if type(name) == "string" and type(rank) == "number" and rank > 0 then
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. name .. ": " .. rank)
                shown = shown + 1
                if shown >= 10 then
                    DEFAULT_CHAT_FRAME:AddMessage("  ... (showing first 10)")
                    break
                end
            end
        end
    else
        -- Test the modifier
        local modifiedDuration = modifier.modifier(baseDuration, talentRank)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Test calculation:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  Base: " .. baseDuration .. "s")
        DEFAULT_CHAT_FRAME:AddMessage("  Modified: " .. modifiedDuration .. "s")
        DEFAULT_CHAT_FRAME:AddMessage("  Bonus: +" .. (modifiedDuration - baseDuration) .. "s")

        -- Test actual application
        local applied = CleveRoids.ApplyTalentModifier(spellID, baseDuration)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Via ApplyTalentModifier:|r " .. applied .. "s")
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== End Diagnostic ===|r")
end

-- EQUIPMENT MODIFIER SYSTEM

-- Database of equipment modifiers for debuff durations
-- Structure: [spellID] = { slot = invSlotID, items = { [itemID] = modifierFunction } }
CleveRoids.equipmentModifiers = CleveRoids.equipmentModifiers or {}

-- DRUID equipment modifiers
-- Idol of Savagery (Black Morass Idol): Reduces Rip and Rake duration by 10% (multiplicative)
-- Item ID: 61699, Slot: 18 (Ranged/Relic)
local ripRakeIdolModifier = function(duration, itemID)
    if itemID == 61699 then
        -- Idol of Savagery: 10% reduction (multiply by 0.9)
        return duration * 0.9
    end
    return duration
end

-- Rip (all ranks)
CleveRoids.equipmentModifiers[1079] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 1
CleveRoids.equipmentModifiers[9492] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 2
CleveRoids.equipmentModifiers[9493] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 3
CleveRoids.equipmentModifiers[9752] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 4
CleveRoids.equipmentModifiers[9894] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 5
CleveRoids.equipmentModifiers[9896] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rip Rank 6

-- Rake (all ranks)
CleveRoids.equipmentModifiers[1822] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rake Rank 1
CleveRoids.equipmentModifiers[1823] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rake Rank 2
CleveRoids.equipmentModifiers[1824] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rake Rank 3
CleveRoids.equipmentModifiers[9904] = { slot = 18, modifier = ripRakeIdolModifier }   -- Rake Rank 4

-- Function to get equipped item ID in a specific slot
function CleveRoids.GetEquippedItemID(slotID)
    return CleveRoids.ClassicAPI.GetInventoryItemID("player", slotID)
end

-- Apply equipment modifiers to a debuff duration
-- Parameters:
--   spellID: The spell ID
--   baseDuration: The base duration (after combo points and talents)
-- Returns: Modified duration, or baseDuration if no equipment modifier applies
function CleveRoids.ApplyEquipmentModifier(spellID, baseDuration)
    if not spellID or not baseDuration then
        return baseDuration
    end

    local modifier = CleveRoids.equipmentModifiers[spellID]
    if not modifier then
        return baseDuration
    end

    local itemID = CleveRoids.GetEquippedItemID(modifier.slot)
    if not itemID then
        return baseDuration
    end

    local modifiedDuration = modifier.modifier(baseDuration, itemID)

    if modifiedDuration ~= baseDuration and CleveRoids.debug then
        local itemName = C_Item.GetItemName({ equipmentSlotIndex = modifier.slot }) or "Unknown"

        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff00ff[Equipment Modifier]|r %s (ID:%d): %ds -> %ds (item: %s [%d])",
                C_Spell.GetSpellName(spellID) or "Unknown", spellID, baseDuration, modifiedDuration,
                itemName, itemID)
        )
    end

    return modifiedDuration
end

-- Helper function to register an equipment modifier
-- Usage: CleveRoids.RegisterEquipmentModifier(spellID, slotID, modifierFunction)
function CleveRoids.RegisterEquipmentModifier(spellID, slotID, modifierFunc)
    if not spellID or not slotID or not modifierFunc then
        return false
    end

    CleveRoids.equipmentModifiers[spellID] = {
        slot = slotID,
        modifier = modifierFunc
    }

    return true
end

-- NAMPOWER SPELL MODIFIERS INTEGRATION (v2.18+)

-- Try to get duration modifiers from Nampower's GetSpellModifiers
-- This function supplements (not replaces) the talent/equipment modifier system
-- Returns: Modified duration, or nil if no Nampower modifier applies
-- Parameters:
--   spellID: The spell ID
--   baseDuration: The base duration before modifiers
function CleveRoids.ApplyNampowerDurationModifier(spellID, baseDuration)
    if not spellID or not baseDuration then
        return nil
    end

    -- Check if Nampower API is available with GetSpellModifiers
    local API = CleveRoids.NampowerAPI
    if not API or not GetSpellModifiers then
        return nil
    end

    -- MODIFIER_DURATION = 1
    local flat, percent, hasModifier = GetSpellModifiers(spellID, 1)

    if not hasModifier or (flat == 0 and percent == 0) then
        return nil
    end

    -- Apply flat modifier first, then percentage
    -- Nampower returns percent as final multiplier (90 = 90% of original, not -10% change)
    local modified = baseDuration + (flat or 0)
    if percent and percent ~= 0 then
        modified = modified * (percent / 100)
    end

    if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff00ff[Nampower Duration Modifier]|r %s (ID:%d): %ds -> %ds (flat: %+d, percent: %d%%)",
                C_Spell.GetSpellName(spellID) or "Unknown", spellID, baseDuration, modified,
                flat or 0, percent or 0)
        )
    end

    return modified
end

-- Comprehensive duration modifier function that combines all sources
-- Logic:
--   1. If Nampower GetSpellModifiers available: use it exclusively (includes talents, buffs, equipment)
--   2. Otherwise fallback: apply manual talent modifiers, then equipment modifiers
--   3. Always apply set bonus modifiers last
-- Parameters:
--   spellID: The spell ID
--   baseDuration: The base duration (after combo points if applicable)
-- Returns: Fully modified duration
function CleveRoids.ApplyAllDurationModifiers(spellID, baseDuration)
    if not spellID or not baseDuration then
        return baseDuration
    end

    local duration = baseDuration

    -- Try Nampower's GetSpellModifiers first (includes dynamic modifiers from buffs/talents/equipment)
    local nampowerDuration = CleveRoids.ApplyNampowerDurationModifier(spellID, duration)
    if nampowerDuration then
        -- Nampower handled all modifiers (talents, buffs, equipment effects like Idol of Savagery)
        -- Do NOT apply equipment modifiers again - Nampower already includes them
        duration = nampowerDuration
    else
        -- Fallback: use manual talent and equipment modifiers when Nampower unavailable
        if CleveRoids.ApplyTalentModifier then
            duration = CleveRoids.ApplyTalentModifier(spellID, duration)
        end
        if CleveRoids.ApplyEquipmentModifier then
            duration = CleveRoids.ApplyEquipmentModifier(spellID, duration)
        end
    end

    -- Always apply set bonus modifiers last
    if CleveRoids.ApplySetBonusModifier then
        duration = CleveRoids.ApplySetBonusModifier(spellID, duration)
    end

    return duration
end

-- SET BONUS MODIFIER SYSTEM

-- Database of set bonus modifiers for debuff durations
-- Structure: [spellID] = { items = {itemID1, itemID2, ...}, threshold = X, modifier = function(baseDuration) }
-- When a setId is given, items can be omitted and resolved from ItemSet.dbc
CleveRoids.setbonusModifiers = CleveRoids.setbonusModifiers or {}

-- Cache: setId -> { itemId1, itemId2, ... } (resolved from ItemSet.dbc or hardcoded)
local setItemCache = {}

-- Resolve set items: use the ItemSet.dbc lookup when a setId is given, otherwise
-- fall back to the hardcoded list on the modifier.
local function ResolveSetItems(modifier)
    -- If items are already provided (hardcoded), use them directly
    if modifier.items and table.getn(modifier.items) > 0 then
        return modifier.items
    end

    -- DBC lookup by setId via ClassicAPI
    if modifier.setId then
        -- Check cache first
        if setItemCache[modifier.setId] then
            return setItemCache[modifier.setId]
        end

        local info = CleveRoids.ClassicAPI.GetItemSetInfo(modifier.setId)
        local items = info and info.items
        if items and table.getn(items) > 0 then
            setItemCache[modifier.setId] = items
            return items
        end
    end

    return nil
end

-- Function to count how many items from a set are currently equipped
-- Accepts either a direct items table or a modifier entry with setId for DBC lookup
function CleveRoids.CountEquippedSetItems(items)
    if not items or type(items) ~= "table" then return 0 end

    local count = 0
    -- Check all equipment slots (1-19)
    for slot = 1, 19 do
        local itemID = CleveRoids.GetEquippedItemID(slot)
        if itemID then
            -- Check if this item is in the set
            for _, setItemID in ipairs(items) do
                if itemID == setItemID then
                    count = count + 1
                    break
                end
            end
        end
    end

    return count
end

-- Count equipped set items by set ID, comparing each equipped slot's own set
-- membership (ClassicAPI GetItemSetIDByID) against the target set.
function CleveRoids.CountEquippedSetItemsBySetId(setId)
    if not setId then return 0 end

    local count = 0
    for slot = 1, 19 do
        local itemID = CleveRoids.GetEquippedItemID(slot)
        if itemID and CleveRoids.ClassicAPI.GetItemSetIDByID(itemID) == setId then
            count = count + 1
        end
    end
    return count
end

-- Apply set bonus modifiers to a debuff duration
-- Parameters:
--   spellID: The spell ID
--   baseDuration: The base duration (after combo points, talents, and equipment)
-- Returns: Modified duration, or baseDuration if no set bonus modifier applies
function CleveRoids.ApplySetBonusModifier(spellID, baseDuration)
    if not spellID or not baseDuration then
        return baseDuration
    end

    local modifier = CleveRoids.setbonusModifiers[spellID]
    if not modifier then
        return baseDuration
    end

    -- Count equipped pieces: use setId for fast Nampower lookup, or resolve item list
    local equippedCount
    if modifier.setId then
        equippedCount = CleveRoids.CountEquippedSetItemsBySetId(modifier.setId)
    else
        local items = ResolveSetItems(modifier)
        if not items then return baseDuration end
        equippedCount = CleveRoids.CountEquippedSetItems(items)
    end

    if equippedCount < modifier.threshold then
        return baseDuration
    end

    local modifiedDuration = modifier.modifier(baseDuration)

    if modifiedDuration ~= baseDuration and CleveRoids.debug then
        local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ffff[Set Bonus Modifier]|r %s (ID:%d): %.1fs -> %.1fs (%d/%d pieces)",
                spellName, spellID, baseDuration, modifiedDuration,
                equippedCount, modifier.threshold)
        )
    end

    return modifiedDuration
end

-- Helper function to register a set bonus modifier
-- Usage: CleveRoids.RegisterSetBonusModifier(spellID, itemsTable, threshold, modifierFunction)
-- With a setId: CleveRoids.RegisterSetBonusModifier(spellID, nil, threshold, modifierFunction, setId)
function CleveRoids.RegisterSetBonusModifier(spellID, items, threshold, modifierFunc, setId)
    if not spellID or not threshold or not modifierFunc then
        return false
    end
    if not items and not setId then
        return false
    end

    CleveRoids.setbonusModifiers[spellID] = {
        items = items,
        setId = setId,
        threshold = threshold,
        modifier = modifierFunc
    }

    return true
end

-- Get info about an equipped item's set (from ItemSet.dbc via ClassicAPI)
-- Returns: setName, setId, equippedCount, totalPieces, items or nil
function CleveRoids.GetEquippedItemSetInfo(itemId)
    if not itemId then return nil end

    local setId = CleveRoids.ClassicAPI.GetItemSetIDByID(itemId)
    if not setId then return nil end

    local info = CleveRoids.ClassicAPI.GetItemSetInfo(setId)
    local setName = info and info.name or nil
    local items = info and info.items or nil
    local totalPieces = items and table.getn(items) or 0
    local equippedCount = CleveRoids.CountEquippedSetItemsBySetId(setId)

    return setName, setId, equippedCount, totalPieces, items
end

-- Count equipped pieces of a named or ID-referenced item set
-- nameOrId: set name (string, e.g. "Judgement Battlegear") or set ID (number)
-- Returns: equipped count (number), setId (number or nil)
-- Both name and ID lookups resolve from ItemSet.dbc via ClassicAPI
function CleveRoids.GetEquippedSetPieceCount(nameOrId)
    if not nameOrId then return 0, nil end

    -- Numeric: treat as set ID directly
    local numericId = tonumber(nameOrId)
    if numericId then
        return CleveRoids.CountEquippedSetItemsBySetId(numericId), numericId
    end

    -- String: scan equipped items and match by set name from ItemSet.dbc
    local lowerName = string.lower(nameOrId)

    for slot = 1, 19 do
        local itemID = CleveRoids.GetEquippedItemID(slot)
        if itemID then
            local setId = CleveRoids.ClassicAPI.GetItemSetIDByID(itemID)
            if setId then
                local info = CleveRoids.ClassicAPI.GetItemSetInfo(setId)
                if info and info.name and string.lower(info.name) == lowerName then
                    return CleveRoids.CountEquippedSetItemsBySetId(setId), setId
                end
            end
        end
    end

    return 0, nil
end

-- DRUID set bonus modifiers
-- Dreamwalker Regalia (4/9): Increases Moonfire duration by 3 seconds and Insect Swarm by 2 seconds
-- setId 536 = Dreamwalker Regalia; hardcoded items as fallback when DBC lookup unavailable
local DREAMWALKER_SET_ID = 536
local dreamwalkerItems = { 47372, 47373, 47374, 47375, 47376, 47377, 47378, 47379, 47380 }
local dreamwalkerMoonfireModifier = function(base) return base + 3 end
local dreamwalkerInsectSwarmModifier = function(base) return base + 2 end

-- Moonfire (all ranks)
CleveRoids.setbonusModifiers[8921] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 1
CleveRoids.setbonusModifiers[8924] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 2
CleveRoids.setbonusModifiers[8925] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 3
CleveRoids.setbonusModifiers[8926] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 4
CleveRoids.setbonusModifiers[8927] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 5
CleveRoids.setbonusModifiers[8928] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 6
CleveRoids.setbonusModifiers[8929] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 7
CleveRoids.setbonusModifiers[9833] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 8
CleveRoids.setbonusModifiers[9834] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 9
CleveRoids.setbonusModifiers[9835] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerMoonfireModifier }   -- Moonfire Rank 10

-- Insect Swarm (all ranks)
CleveRoids.setbonusModifiers[5570] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerInsectSwarmModifier }   -- Insect Swarm Rank 1
CleveRoids.setbonusModifiers[24974] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerInsectSwarmModifier }  -- Insect Swarm Rank 2
CleveRoids.setbonusModifiers[24975] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerInsectSwarmModifier }  -- Insect Swarm Rank 3
CleveRoids.setbonusModifiers[24976] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerInsectSwarmModifier }  -- Insect Swarm Rank 4
CleveRoids.setbonusModifiers[24977] = { setId = DREAMWALKER_SET_ID, items = dreamwalkerItems, threshold = 4, modifier = dreamwalkerInsectSwarmModifier }  -- Insect Swarm Rank 5

-- Haruspex's Garb (3/5): Increases Faerie Fire duration by 5 seconds
-- setId 474 = Haruspex's Garb; hardcoded items as fallback when DBC lookup unavailable
local HARUSPEX_SET_ID = 474
local haruspexItems = { 19613, 19955, 19840, 19839, 19838 }
local haruspexFaerieFireModifier = function(base) return base + 5 end

-- Faerie Fire (non-feral, all ranks)
CleveRoids.setbonusModifiers[770] = { setId = HARUSPEX_SET_ID, items = haruspexItems, threshold = 3, modifier = haruspexFaerieFireModifier }    -- Faerie Fire Rank 1
CleveRoids.setbonusModifiers[778] = { setId = HARUSPEX_SET_ID, items = haruspexItems, threshold = 3, modifier = haruspexFaerieFireModifier }    -- Faerie Fire Rank 2
CleveRoids.setbonusModifiers[9749] = { setId = HARUSPEX_SET_ID, items = haruspexItems, threshold = 3, modifier = haruspexFaerieFireModifier }   -- Faerie Fire Rank 3
CleveRoids.setbonusModifiers[9907] = { setId = HARUSPEX_SET_ID, items = haruspexItems, threshold = 3, modifier = haruspexFaerieFireModifier }   -- Faerie Fire Rank 4

-- IMMUNITY TRACKING SYSTEM
-- Initialize SavedVariables for immunity tracking
CleveRoids_ImmunityData = CleveRoids_ImmunityData or {}

-- Spell school constants
local IMMUNITY_SCHOOLS = {
    physical = 1,
    holy = 2,
    fire = 3,
    nature = 4,
    frost = 5,
    shadow = 6,
    arcane = 7,
    bleed = 8,
    unknown = 9,  -- For spells where we can't determine the school
}

-- CC (Crowd Control) immunity types
-- These are stored with "cc_" prefix in CleveRoids_ImmunityData to avoid collision with damage schools
local CC_IMMUNITY_TYPES = {
    stun = true,       -- Mechanic 12: Cheap Shot, Kidney Shot, Hammer of Justice
    freeze = true,     -- Mechanic 13: frozen effects
    knockout = true,   -- Mechanic 14: Gouge, Repentance, Blast Wave
    sap = true,        -- Mechanic 30: Sap
    fear = true,       -- Fear, Psychic Scream, Howl of Terror
    root = true,       -- Entangling Roots, Frost Nova
    silence = true,    -- Silence, Counterspell
    sleep = true,      -- Hibernate, Wyvern Sting
    charm = true,      -- Mind Control, Seduction
    polymorph = true,  -- Polymorph (all variants)
    banish = true,     -- Banish
    shackle = true,    -- Shackle Undead
    horror = true,     -- Death Coil
    disorient = true,  -- Scatter Shot, Blind
    daze = true,       -- Daze mechanic
    snare = true,      -- Hamstring, Wing Clip
}

local CC_IMMUNITY_ALIASES = {
    incap = "knockout",
    incapacitate = "knockout",
    incapacitated = "knockout",
}

local function NormalizeCCImmunityType(ccType)
    if not ccType then return nil end
    local normalized = string.lower(ccType)
    return CC_IMMUNITY_ALIASES[normalized] or normalized
end

-- Maps DBC mechanic IDs back to CC type names for immunity recording
-- Inverse of CleveRoids.CCMechanics (defined in Conditionals.lua)
local MECHANIC_TO_CC_TYPE = {
    [1] = "charm",
    [2] = "disorient",
    [5] = "fear",
    [7] = "root",
    [9] = "silence",
    [10] = "sleep",
    [11] = "snare",
    [12] = "stun",
    [13] = "freeze",
    [14] = "knockout",
    [17] = "polymorph",
    [18] = "banish",
    [20] = "shackle",
    [24] = "horror",
    [27] = "daze",
    [30] = "sap",
}

-- Mechanic-precise mapping used only for learned NPC immunity. Keep it
-- one-to-one: Vanilla can distinguish Stun (12), Freeze (13), Knockout (14)
-- and Sap (30) immunities independently, so never fold them together here.
local MECHANIC_TO_IMMUNITY_TYPE = {
    [1] = "charm",
    [2] = "disorient",
    [5] = "fear",
    [7] = "root",
    [9] = "silence",
    [10] = "sleep",
    [11] = "snare",
    [12] = "stun",
    [13] = "freeze",
    [14] = "knockout",
    [17] = "polymorph",
    [18] = "banish",
    [20] = "shackle",
    [24] = "horror",
    [27] = "daze",
    [30] = "sap",
}

-- Spells with split damage types (initial hit vs DoT/debuff)
-- GetSpellSchool() returns the debuff school by default for these spells
-- Users can explicitly check the initial damage school with [noimmune:physical]
local SPLIT_DAMAGE_SPELLS = {
    ["Rake"] = { initial = "physical", debuff = "bleed" },
    ["Pounce"] = { initial = "physical", debuff = "bleed" },
    ["Garrote"] = { initial = "physical", debuff = "bleed" },
}

-- Known non-damaging spells that won't be learned via combat log damage events
-- These need explicit school mapping to avoid pattern matching errors
-- (e.g., "Faerie Fire" contains "fire" but is actually arcane)
--
-- Add spells here if:
--   1. They don't deal damage (so won't trigger a damage event)
--   2. Their name causes false positives in pattern matching
--   3. You need accurate school detection for immunity checking
--
-- Format: ["Spell Name"] = "school" (without rank)
local KNOWN_NON_DAMAGING_SPELLS = {
    -- Druid
    ["Faerie Fire"] = "nature",
    ["Faerie Fire (Feral)"] = "nature",
    ["Faerie Fire (Bear)"] = "nature",
    ["Moonfire"] = "arcane",  -- Initial hit deals damage, but debuff is arcane
    ["Insect Swarm"] = "nature",
    ["Abolish Poison"] = "nature",
    ["Remove Curse"] = "arcane",
    ["Pounce Bleed"] = "bleed",  -- Triggered by Pounce (9005→9007, 9823→9824, 9827→9826)

    -- Mage
    ["Amplify Magic"] = "arcane",
    ["Dampen Magic"] = "arcane",
    ["Remove Lesser Curse"] = "arcane",
    ["Slow Fall"] = "arcane",
    ["Detect Magic"] = "arcane",

    -- Priest
    ["Dispel Magic"] = "holy",
    ["Cure Disease"] = "holy",
    ["Abolish Disease"] = "holy",
    ["Power Word: Fortitude"] = "holy",
    ["Power Word: Shield"] = "holy",
    ["Divine Spirit"] = "holy",
    ["Fear Ward"] = "holy",
    ["Resurrection"] = "holy",

    -- Paladin
    ["Cleanse"] = "holy",
    ["Purify"] = "holy",
    ["Divine Protection"] = "holy",
    ["Divine Shield"] = "holy",
    ["Blessing of Protection"] = "holy",
    ["Blessing of Freedom"] = "holy",
    ["Blessing of Sacrifice"] = "holy",
    ["Redemption"] = "holy",

    -- Warlock
    ["Banish"] = "shadow",
    ["Curse of Weakness"] = "shadow",
    ["Curse of Recklessness"] = "shadow",
    ["Curse of Tongues"] = "shadow",
    ["Amplify Curse"] = "shadow",
    ["Death Coil"] = "shadow",  -- Has damage component but often used for CC

    -- Shaman
    ["Cure Poison"] = "nature",
    ["Cure Disease"] = "nature",
    ["Purge"] = "nature",
    ["Ancestral Spirit"] = "nature",

    -- Hunter
    ["Aspect of the Hawk"] = "nature",
    ["Aspect of the Monkey"] = "nature",
    ["Aspect of the Cheetah"] = "nature",
    ["Aspect of the Pack"] = "nature",
    ["Aspect of the Wild"] = "nature",
}

-- Spell school mapping learned from combat log damage events
-- This table maps spell IDs to their damage school (fire, frost, nature, shadow, arcane, holy, physical, bleed)
-- Persisted via SavedVariable (CleveRoids_SpellSchools) for accuracy across sessions
CleveRoids_SpellSchools = CleveRoids_SpellSchools or {}
CleveRoids.spellSchoolMapping = CleveRoids_SpellSchools  -- Alias for easier access

-- Spell.dbc school enum to school name
-- Based on WoW 1.12.1 SpellSchools enum values (NOT bitmasks)
local SCHOOL_NAMES = {
    [0] = "physical",  -- SPELL_SCHOOL_NORMAL (Physical/Armor)
    [1] = "holy",      -- SPELL_SCHOOL_HOLY
    [2] = "fire",      -- SPELL_SCHOOL_FIRE
    [3] = "nature",    -- SPELL_SCHOOL_NATURE
    [4] = "frost",     -- SPELL_SCHOOL_FROST
    [5] = "shadow",    -- SPELL_SCHOOL_SHADOW
    [6] = "arcane"     -- SPELL_SCHOOL_ARCANE
}

-- Combat log school bitmask to school name
local SCHOOL_MASK_NAMES = {
    [1] = "physical",
    [2] = "holy",
    [4] = "fire",
    [8] = "nature",
    [16] = "frost",
    [32] = "shadow",
    [64] = "arcane",
}

-- Learn a spell's school from its damage (SPELL_DAMAGE / SPELL_PERIODIC_DAMAGE
-- / RANGE_DAMAGE, from the combat log dispatcher). This is the most accurate
-- school source and the only one that tells a bleed from plain physical damage:
-- periodic physical damage is a bleed.
local function LearnSpellSchool(spellId, schoolMask, periodic)
    if not spellId or not schoolMask then return end

    -- PERFORMANCE: Skip if already learned and finalized
    local currentSchool = CleveRoids.spellSchoolMapping[spellId]
    if currentSchool then
        -- If already learned as anything other than physical, we're done (can't be upgraded)
        if currentSchool ~= "physical" then
            return
        end
        -- If learned as physical, continue processing - might upgrade to bleed
    end

    local schoolName = SCHOOL_MASK_NAMES[schoolMask] or "physical"
    if schoolName == "physical" and periodic then
        schoolName = "bleed"
    end

    -- Check if this is a known bleed spell by name (fallback) - only if physical
    if schoolName == "physical" then
        local spellName = C_Spell.GetSpellName(spellId)
        if spellName then
            local baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
            local lower = string.lower(baseName)
            if string.find(lower, "rip") or string.find(lower, "rake") or string.find(lower, "rupture") or
               string.find(lower, "garrote") or string.find(lower, "rend") or string.find(lower, "deep wound") or
               string.find(lower, "hemorrhage") or string.find(lower, "pounce") then
                schoolName = "bleed"
            end
        end
    end

    -- PERFORMANCE: Skip if the detected school matches what we already know
    if currentSchool == schoolName then
        return  -- No change needed
    end

    -- Only update if not already known or if upgrading from physical to bleed
    if not currentSchool or (currentSchool == "physical" and schoolName == "bleed") then
        CleveRoids.spellSchoolMapping[spellId] = schoolName

        if CleveRoids.debug then
            local spellName = C_Spell.GetSpellName(spellId) or "Unknown"
            CleveRoids.Print(string.format("|cff88ff88[School Learned]|r %s (ID:%d) = %s (mask:%d)",
                spellName, spellId, schoolName, schoolMask))
        end
    end
end

-- Cache for spell school lookups
local spellSchoolCache = {}

-- Get the damage school of a spell
-- Parameters:
--   spellName: The name of the spell (with or without rank)
--   spellID: Optional spell ID for more accurate lookups
-- Returns: School name (fire, frost, nature, shadow, arcane, holy, physical, bleed) or nil
-- Priority:
--   0. Split damage spell table (e.g., Rake = bleed debuff)
--   1. Learned from combat log damage events (most accurate for bleed detection)
--   2. Name-to-ID resolution + learned mapping
--   3. DBC spell school via GetSpellRecField (authoritative for non-bleed spells)
--   4. Cached lookups
--   6. Known non-damaging spells table (e.g., Faerie Fire = arcane)
--   7. Tooltip scanning (player's spellbook only)
--   8. Name pattern matching (fallback, least accurate)
--   Returns nil if school cannot be determined (not cached)
-- Authoritative bleed test from Spell.dbc mechanics. A bleed carries
-- SpellMechanic 15 either at the spell level (Garrote/Rupture/Rend/Rip/Pounce/
-- Deep Wounds) OR on an effect (Rake: spell-level 0, EffectMechanic[2]=15), so
-- both must be checked -- GetSpellMechanicByID alone misses the effect-level case.
local SPELL_MECHANIC_BLEED = 15
local function IsBleedByMechanic(spellID)
    if not spellID then return false end
    local API = CleveRoids.ClassicAPI
    if API.GetSpellMechanicByID(spellID) == SPELL_MECHANIC_BLEED then
        return true
    end
    local em = API.GetSpellEffectMechanics(spellID)
    if em then
        for i = 1, 3 do
            if em[i] == SPELL_MECHANIC_BLEED then return true end
        end
    end
    return false
end

local function GetSpellSchool(spellName, spellID)
    if not spellName and not spellID then return nil end

    -- Get base name early for split damage spell check
    local baseName = nil
    if spellName then
        baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
    elseif spellID then
        local fullName = C_Spell.GetSpellName(spellID)
        if fullName then
            baseName = string.gsub(fullName, "%s*%(.-%)%s*$", "")
        end
    end

    -- PRIORITY 0 (HIGHEST): Split damage spells ALWAYS use their debuff school for immunity checks
    -- This prevents the initial physical hit from being learned and masking bleed immunity.
    -- Example: Rake's initial hit is physical, but the DoT is bleed. On bleed-immune targets,
    -- the DoT never ticks, so spellSchoolMapping stays "physical" - which would miss bleed immunity!
    if baseName and SPLIT_DAMAGE_SPELLS[baseName] then
        local school = SPLIT_DAMAGE_SPELLS[baseName].debuff
        return school
    end

    -- PRIORITY 0.5: DBC bleed mechanic (authoritative, proactive). Catches bleeds
    -- before any damage event is seen, incl. effect-level ones like Rake, and
    -- correctly excludes non-bleeds the name patterns would false-positive (e.g.
    -- Hemorrhage). Only bleed is decided here; other schools fall through.
    if spellID and IsBleedByMechanic(spellID) then
        return "bleed"
    end

    -- PRIORITY 1: Use learned school from combat log damage events (most accurate)
    if spellID and CleveRoids.spellSchoolMapping[spellID] then
        return CleveRoids.spellSchoolMapping[spellID]
    end

    -- PRIORITY 2: If we have name but no ID, try to find ID and check mapping
    if spellName and not spellID then
        if CleveRoids.GetSpellIdForName then
            spellID = CleveRoids.GetSpellIdForName(spellName)
            if spellID and CleveRoids.spellSchoolMapping[spellID] then
                return CleveRoids.spellSchoolMapping[spellID]
            end
        end
    end

    -- PRIORITY 3: DBC spell school lookup via Nampower (authoritative for non-bleed spells)
    -- Note: DBC school field returns 0 (physical) for bleed spells too, so learned mapping
    -- from damage events (priority 1-2) takes precedence for bleed detection
    if spellID and GetSpellRecField then
        local dbcSchool = GetSpellRecField(spellID, "school")
        if dbcSchool and SCHOOL_NAMES[dbcSchool] then
            local school = SCHOOL_NAMES[dbcSchool]
            -- Don't cache physical from DBC - it might be bleed (learned later from damage events)
            if school ~= "physical" then
                if not baseName and spellName then
                    baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
                end
                if baseName then
                    spellSchoolCache[baseName] = school
                end
                return school
            end
        end
    end

    -- If we only have spellID but no name, try to get name from GetSpellRecField
    if spellID and not spellName then
        spellName = C_Spell.GetSpellName(spellID)
    end

    if not spellName then return nil end

    -- Remove rank information for cache consistency (may already be set from above)
    if not baseName then
        baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
    end

    -- PRIORITY 4: Check cache
    if spellSchoolCache[baseName] then
        return spellSchoolCache[baseName]
    end

    -- PRIORITY 5: SPLIT_DAMAGE_SPELLS already checked at Priority 0

    -- PRIORITY 6: Check known non-damaging spells
    -- These won't be learned via damage events and need explicit mapping
    if KNOWN_NON_DAMAGING_SPELLS[baseName] then
        local school = KNOWN_NON_DAMAGING_SPELLS[baseName]
        spellSchoolCache[baseName] = school
        return school
    end

    -- PRIORITY 7: Try to find spell in player's spellbook and scan tooltip
    local school = nil
    local spell = CleveRoids.GetSpell(baseName)

    if spell then
        -- Create tooltip if needed
        if not CleveRoidsSchoolTooltip then
            CreateFrame("GameTooltip", "CleveRoidsSchoolTooltip", nil, "GameTooltipTemplate")
            CleveRoidsSchoolTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
        end

        CleveRoidsSchoolTooltip:ClearLines()
        CleveRoidsSchoolTooltip:SetSpell(spell.spellSlot, spell.bookType)

        -- Scan tooltip for school keywords
        for i = 1, CleveRoidsSchoolTooltip:NumLines() do
            local line = _G["CleveRoidsSchoolTooltipTextLeft" .. i]
            if line then
                local text = string.lower(line:GetText() or "")

                if string.find(text, "bleed") then
                    school = "bleed"
                    break
                elseif string.find(text, "fire") or string.find(text, "flame") then
                    school = "fire"
                    break
                elseif string.find(text, "frost") or
                       string.find(text, "^ice[^%a]") or string.find(text, "[^%a]ice[^%a]") or string.find(text, "[^%a]ice$") then
                    school = "frost"
                    break
                elseif string.find(text, "nature") or string.find(text, "poison") then
                    school = "nature"
                    break
                elseif string.find(text, "shadow") or string.find(text, "dark") then
                    school = "shadow"
                    break
                elseif string.find(text, "arcane") then
                    school = "arcane"
                    break
                elseif string.find(text, "holy") or string.find(text, "divine") then
                    school = "holy"
                    break
                end
            end
        end
    end

    -- PRIORITY 8: Fallback pattern matching for common spell name patterns
    -- NOTE: This is the lowest priority fallback - be specific to avoid false positives
    -- (e.g., "Faerie Fire" should not match as "fire" school)
    if not school then
        local lower = string.lower(baseName)

        -- Bleed effects (DoTs that ignore armor)
        if string.find(lower, "rip") or string.find(lower, "rake") or string.find(lower, "rupture") or
           string.find(lower, "garrote") or string.find(lower, "rend") or string.find(lower, "deep wound") or
           string.find(lower, "pounce") then
            -- NOTE: Hemorrhage intentionally excluded -- Spell.dbc gives it no bleed
            -- mechanic (its damage is physical), so bleed-immune mobs don't resist it.
            school = "bleed"

        -- Arcane
        elseif string.find(lower, "arcane") or string.find(lower, "polymorph") or
               string.find(lower, "mana burn") then
            school = "arcane"

        -- Nature: Faerie Fire (check before "fire" to avoid false positive)
        elseif string.find(lower, "faerie") then
            school = "nature"

        -- Fire (specific patterns to avoid false positives)
        elseif string.find(lower, "^fire") or string.find(lower, " fire") or  -- Starts with or contains " fire"
               string.find(lower, "flame") or string.find(lower, "immolat") or
               string.find(lower, "scorch") or string.find(lower, "pyroblast") or
               string.find(lower, "ignite") or string.find(lower, "combustion") then
            school = "fire"

        -- Frost (use word-boundary matching for "ice" to avoid false positives
        -- from spell names like "Slice and Dice" containing "ice" as substring)
        elseif string.find(lower, "frost") or
               string.find(lower, "^ice[^%a]") or string.find(lower, "[^%a]ice[^%a]") or string.find(lower, "[^%a]ice$") or
               string.find(lower, "blizzard") or string.find(lower, "freeze") or
               string.find(lower, "chill") then
            school = "frost"

        -- Nature
        elseif string.find(lower, "nature") or string.find(lower, "poison") or
               string.find(lower, "sting") or string.find(lower, "wrath") or
               string.find(lower, "starfire") or string.find(lower, "thorns") then
            school = "nature"

        -- Shadow
        elseif string.find(lower, "shadow") or string.find(lower, "curse") or
               string.find(lower, "corruption") or string.find(lower, "drain") or
               string.find(lower, "vampir") or string.find(lower, "affliction") then
            school = "shadow"

        -- Holy
        elseif string.find(lower, "holy") or string.find(lower, "smite") or
               string.find(lower, "exorcism") or string.find(lower, "consecrat") or
               string.find(lower, "judgment") or string.find(lower, "hammer of wrath") then
            school = "holy"

        -- No default fallback - return nil for unknown schools
        -- RecordImmunity() will classify nil as "unknown" rather than
        -- incorrectly attributing physical immunity
        end
    end

    -- Cache the result (only cache if we actually determined a school)
    if school then
        spellSchoolCache[baseName] = school
    end
    return school
end

-- Public API: Get spell school by name and/or ID
-- Usage: CleveRoids.GetSpellSchool("Fireball") or CleveRoids.GetSpellSchool(nil, 133)
CleveRoids.GetSpellSchool = GetSpellSchool

-- Public API: Get spell school by ID only (convenience wrapper)
-- Usage: CleveRoids.GetSpellSchoolByID(133)
function CleveRoids.GetSpellSchoolByID(spellID)
    return GetSpellSchool(nil, spellID)
end

-- Get current buffs on a unit
local function GetUnitBuffs(unit)
    local buffs = {}

    for i = 1, 32 do
        local texture, stacks, spellID = UnitBuff(unit, i)
        if not texture then break end

        if spellID then
            local buffName = C_Spell.GetSpellName(spellID)
            if buffName then
                buffs[buffName] = true
            end
        end
    end

    return buffs
end

-- CC IMMUNITY TRACKING

-- Get CC type from a spell ID via DBC mechanic lookup (nampower, then ClassicAPI)
-- Returns: CC type name (e.g., "stun", "fear") or nil if not a CC spell
-- EffectApplyAuraName → CC type mapping (fallback when mechanics are unset)
-- Uses vanilla 1.12.1 aura type enum values
-- Note: some CC types share aura IDs (e.g., sleep uses MOD_STUN + sleep mechanic,
-- horror uses MOD_FEAR + horror mechanic). Those are caught by mechanic lookup;
-- this table handles spells where mechanics are 0 but the aura effect is CC.
local AURA_NAME_TO_CC_TYPE = {
    [1]  = "charm",     -- SPELL_AURA_BIND_SIGHT
    [2]  = "charm",     -- SPELL_AURA_MOD_POSSESS_PET
    [5]  = "polymorph", -- SPELL_AURA_MOD_CONFUSE (disorient/polymorph)
    [7]  = "fear",      -- SPELL_AURA_MOD_FEAR (also horror with mechanic 24)
    [11] = "root",      -- SPELL_AURA_MOD_ROOT
    [12] = "stun",      -- SPELL_AURA_MOD_STUN (also sleep/sap/banish with their mechanics)
    [27] = "silence",   -- SPELL_AURA_MOD_SILENCE
    [31] = "charm",     -- SPELL_AURA_MOD_POSSESS
    [33] = "snare",     -- SPELL_AURA_MOD_DECREASE_SPEED
}

local function GetSpellCCType(spellID)
    if not spellID or spellID <= 0 then return nil end

    -- Priority 1: DBC mechanic lookup (authoritative, covers all spells)
    if GetSpellRecField then
        -- Check spell-level mechanic first
        local mechanic = GetSpellRecField(spellID, "mechanic")
        if mechanic and mechanic > 0 and MECHANIC_TO_CC_TYPE[mechanic] then
            return MECHANIC_TO_CC_TYPE[mechanic]
        end

        -- Check per-effect mechanics (array of 3 effects)
        local effectMechanics = GetSpellRecField(spellID, "effectMechanic")
        if effectMechanics then
            for i = 1, 3 do
                local em = effectMechanics[i]
                if em and em > 0 and MECHANIC_TO_CC_TYPE[em] then
                    return MECHANIC_TO_CC_TYPE[em]
                end
            end
        end

        -- Priority 1b: effectApplyAuraName fallback (catches spells with CC aura
        -- effects but no mechanic set, e.g., Repentance applying MOD_STUN)
        local auraNames = GetSpellRecField(spellID, "effectApplyAuraName")
        if auraNames then
            for i = 1, 3 do
                local an = auraNames[i]
                if an and an > 0 and AURA_NAME_TO_CC_TYPE[an] then
                    return AURA_NAME_TO_CC_TYPE[an]
                end
            end
        end
    end

    -- Priority 2: ClassicAPI Spell.dbc reader (always present; covers every spell).
    -- A subset of Priority 1's per-effect/aura checks, used when nampower's
    -- GetSpellRecField is unavailable.
    local mechanic = CleveRoids.ClassicAPI.GetSpellMechanicByID(spellID)
    if mechanic and mechanic > 0 and MECHANIC_TO_CC_TYPE[mechanic] then
        return MECHANIC_TO_CC_TYPE[mechanic]
    end

    return nil
end

-- Expose publicly for use by other modules
CleveRoids.GetSpellCCType = GetSpellCCType

-- Resolve the mechanic bucket used for learned NPC immunity. DBC spell/effect
-- mechanics are authoritative; aura type is only a fallback for spells whose
-- mechanic fields are empty.
local function GetSpellImmunityType(spellID)
    if not spellID or spellID <= 0 then return nil end

    if GetSpellRecField then
        local mechanic = GetSpellRecField(spellID, "mechanic")
        if mechanic and mechanic > 0 and MECHANIC_TO_IMMUNITY_TYPE[mechanic] then
            return MECHANIC_TO_IMMUNITY_TYPE[mechanic]
        end

        local effectMechanics = GetSpellRecField(spellID, "effectMechanic")
        if effectMechanics then
            for i = 1, 3 do
                local em = effectMechanics[i]
                if em and em > 0 and MECHANIC_TO_IMMUNITY_TYPE[em] then
                    return MECHANIC_TO_IMMUNITY_TYPE[em]
                end
            end
        end

        local auraNames = GetSpellRecField(spellID, "effectApplyAuraName")
        if auraNames then
            for i = 1, 3 do
                local an = auraNames[i]
                if an and an > 0 and AURA_NAME_TO_CC_TYPE[an] then
                    return AURA_NAME_TO_CC_TYPE[an]
                end
            end
        end
    end

    local mechanic = CleveRoids.ClassicAPI.GetSpellMechanicByID(spellID)
    if mechanic and mechanic > 0 and MECHANIC_TO_IMMUNITY_TYPE[mechanic] then
        return MECHANIC_TO_IMMUNITY_TYPE[mechanic]
    end

    return nil
end

CleveRoids.GetSpellImmunityType = GetSpellImmunityType

-- NPC immunity learning only needs DR groups that can actually diminish creatures.
-- vMaNGOS 1.12 marks controlled stun, triggered stun, and Kidney Shot as DRTYPE_ALL;
-- the other staged DR groups are player-only and must not suppress NPC immunity learning.
local STUN_CONTROL_DR_OVERRIDES = {
    [7922] = true,   -- Charge Stun
    [20253] = true,  -- Intercept Stun Rank 1
    [20614] = true,  -- Intercept Stun Rank 2
    [20615] = true,  -- Intercept Stun Rank 3
}
local KIDNEY_SHOT_IDS = {
    [408] = true,
    [8643] = true,
}

local function IsKidneyShotSpell(spellID)
    if KIDNEY_SHOT_IDS[spellID] then return true end

    -- Vanilla Rogue family bit 21 (0x00200000) is Kidney Shot. Prefer the
    -- family mask so custom ranks that preserve DBC family data also classify correctly.
    if GetSpellRecField then
        local familyName = GetSpellRecField(spellID, "spellFamilyName")
        local familyFlags = GetSpellRecField(spellID, "spellFamilyFlags")
        if familyName == 8 and familyFlags then -- SPELLFAMILY_ROGUE
            local kidneyBit = 2097152 -- 0x00200000
            if math.mod(math.floor(familyFlags / kidneyBit), 2) == 1 then
                return true
            end
        end
    end

    return false
end

local function WasClientInitiatedSpell(spellID)
    -- UNIT_SPELLCAST_SENT fires only for spells initiated by the client.
    -- Proc/trigger spell IDs reach the server without their own entry.
    local cast = CleveRoids.sentCasts and CleveRoids.sentCasts[spellID]
    if not cast or not cast.timestamp then return false end
    local age = GetTime() - cast.timestamp
    return age >= 0 and age <= 5
end

local function GetSpellImmunityDRType(spellID)
    if GetSpellCCType(spellID) ~= "stun" then return nil end

    if IsKidneyShotSpell(spellID) then
        return "stun_kidneyshot"
    end

    -- These stun subspells are internally triggered but explicitly belong to
    -- controlled-stun DR in Vanilla.
    if STUN_CONTROL_DR_OVERRIDES[spellID] then
        return "stun_control"
    end

    if WasClientInitiatedSpell(spellID) then
        return "stun_control"
    end

    return "stun_trigger"
end

CleveRoids.GetSpellImmunityDRType = GetSpellImmunityDRType

-- Record a CC immunity (permanent or buff-based)
-- Parameters:
--   npcName: Name of the NPC that is immune
--   ccType: CC type name (e.g., "stun", "fear", "root")
--   conditionalBuff: Optional buff name required for the immunity
--   spellName: Optional spell name for debug output
local function RecordCCImmunity(npcName, ccType, conditionalBuff, spellName)
    if not npcName or not ccType or npcName == "" then
        return
    end

    ccType = NormalizeCCImmunityType(ccType)

    -- Validate CC type
    if not CC_IMMUNITY_TYPES[ccType] then
        if CleveRoids.debug then
            CleveRoids.Print("|cffff0000[CC Immunity]|r Unknown CC type: " .. tostring(ccType))
        end
        return
    end

    -- Store with "cc_" prefix to avoid collision with damage schools
    local key = "cc_" .. ccType

    -- Initialize CC type table
    if not CleveRoids_ImmunityData[key] then
        CleveRoids_ImmunityData[key] = {}
    end

    -- Don't overwrite existing immunity with same data
    local existing = CleveRoids_ImmunityData[key][npcName]

    -- Record immunity
    if conditionalBuff then
        -- Buff-based immunity
        local immunityData = { buff = conditionalBuff }
        if existing and type(existing) == "table" and existing.buff == conditionalBuff then
            return  -- Already recorded
        end
        CleveRoids_ImmunityData[key][npcName] = immunityData

        if CleveRoids.debug then
            local spellInfo = spellName and (" (" .. spellName .. ")") or ""
            CleveRoids.Print("|cff00ff00[CC Immunity]|r " .. npcName .. " is immune to " .. ccType .. spellInfo .. " when buffed with: " .. conditionalBuff)
        end
    else
        -- Permanent immunity
        if existing == true then
            return  -- Already recorded
        end
        CleveRoids_ImmunityData[key][npcName] = true

        if CleveRoids.debug then
            local spellInfo = spellName and (" (" .. spellName .. ")") or ""
            CleveRoids.Print("|cff00ff00[CC Immunity]|r " .. npcName .. " is permanently immune to " .. ccType .. spellInfo)
        end
    end
end

-- Expose publicly
CleveRoids.RecordCCImmunity = RecordCCImmunity

-- Remove a CC immunity record when a spell successfully lands
-- This is called when we verify that a CC effect actually landed on a previously-immune NPC
-- Parameters:
--   npcName: Name of the NPC
--   ccType: CC type name (e.g., "stun", "fear", "root")
local function RemoveCCImmunity(npcName, ccType)
    if not npcName or not ccType or npcName == "" then
        return
    end

    ccType = NormalizeCCImmunityType(ccType)

    local key = "cc_" .. ccType

    if CleveRoids_ImmunityData[key] and CleveRoids_ImmunityData[key][npcName] then
        CleveRoids_ImmunityData[key][npcName] = nil

        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[CC Immunity Removed]|r " .. npcName .. " is no longer immune to " .. ccType .. " (spell landed successfully)")
        end
    end
end

-- Expose publicly
CleveRoids.RemoveCCImmunity = RemoveCCImmunity

-- Check if a unit is immune to a specific CC type
-- Parameters:
--   unitId: WoW unit ID (e.g., "target", "focus")
--   ccType: CC type name (e.g., "stun", "fear")
-- Returns: true if immune, false otherwise
local function CheckCCImmunity(unitId, ccType)
    if not unitId or not UnitExists(unitId) then
        return false
    end

    ccType = NormalizeCCImmunityType(ccType)

    -- CC immunity only tracked for NPCs
    if UnitIsPlayer(unitId) then
        return false
    end

    local targetName = UnitName(unitId)
    -- Fallback to GUID->name cache if UnitName fails
    -- This happens when multiscan passes a GUID that isn't the current target
    if not targetName or targetName == "" or targetName == "Unknown" then
        local normalizedGuid = CleveRoids.NormalizeGUID(unitId)
        if normalizedGuid and lib and lib.guidToName then
            targetName = lib.guidToName[normalizedGuid]
        end
    end
    if not targetName or targetName == "" then
        return false
    end

    -- Look up CC immunity with "cc_" prefix
    local key = "cc_" .. ccType
    local immunityData = CleveRoids_ImmunityData[key] and CleveRoids_ImmunityData[key][targetName]

    if not immunityData then
        return false
    end

    if immunityData == true then
        -- Permanent immunity
        return true
    elseif type(immunityData) == "table" and immunityData.buff then
        -- Buff-based immunity: check if the buff is currently active
        local buffs = GetUnitBuffs(unitId)
        return buffs[immunityData.buff] == true
    end

    return false
end

-- Expose publicly
CleveRoids.CheckCCImmunity = CheckCCImmunity

-- DAMAGE SCHOOL IMMUNITY RECORDING

-- Record an immunity (permanent or buff-based)
-- Parameters:
--   npcName: Name of the NPC that is immune
--   spellName: Name of the spell that was resisted/immune
--   conditionalBuff: Optional buff name required for the immunity
--   spellID: Optional spell ID for more accurate school detection
local function RecordImmunity(npcName, spellName, conditionalBuff, spellID)
    if not npcName or (not spellName and not spellID) or npcName == "" then
        return
    end

    -- Determine school: DBC lookup by spellID is authoritative for immunity recording.
    -- Unlike GetSpellSchool() (designed for debuff tracking, skips physical to detect bleed),
    -- immunity recording needs the actual DBC school — physical immunity IS a real thing.
    local school = nil

    -- SPLIT DAMAGE SPELLS: Use initial hit school, not the debuff school.
    -- e.g., Pounce stun-immune doesn't mean bleed-immune.
    if spellName then
        local baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
        if SPLIT_DAMAGE_SPELLS[baseName] then
            school = SPLIT_DAMAGE_SPELLS[baseName].initial
            if CleveRoids.debug then
                CleveRoids.Print("|cff00aaff[Split Damage]|r " .. baseName .. " immunity recorded as '" .. school .. "' (initial), not '" .. SPLIT_DAMAGE_SPELLS[baseName].debuff .. "' (debuff)")
            end
        end
    end

    -- Direct DBC lookup: spellID → GetSpellRecField → school enum → name
    if not school and spellID and GetSpellRecField then
        local dbcSchool = GetSpellRecField(spellID, "school")
        if dbcSchool and SCHOOL_NAMES[dbcSchool] then
            school = SCHOOL_NAMES[dbcSchool]
        end
        -- Bleed spells have DBC school=0 (physical) but immunity should be "bleed", not "physical"
        -- Split damage spells (Rake/Pounce/Garrote) are already handled above — their cast spell
        -- triggers IMMUNE for the initial physical hit, so "physical" is correct for those.
        -- Pure bleed spells (Rip, etc.) that reach this path need the override.
        if school == "physical" and CleveRoids.BleedSpellIDs and CleveRoids.BleedSpellIDs[spellID] then
            school = "bleed"
            if CleveRoids.debug then
                CleveRoids.Print("|cff00aaff[Bleed Override]|r " .. (spellName or tostring(spellID)) .. " immunity recorded as 'bleed' (DBC school=physical, but spell is a bleed)")
            end
        end
    end

    -- Fallback: try learned mapping from damage events
    if not school and spellID and CleveRoids.spellSchoolMapping[spellID] then
        school = CleveRoids.spellSchoolMapping[spellID]
    end

    -- Last resort: name-based lookup (no spellID available)
    if not school and spellName then
        school = GetSpellSchool(spellName, nil)
    end

    if not school then
        school = "unknown"
        if CleveRoids.debug then
            CleveRoids.Print("|cffff9900[Unknown School]|r Could not determine school for: " .. (spellName or tostring(spellID)))
        end
    end

    -- Initialize school table
    if not CleveRoids_ImmunityData[school] then
        CleveRoids_ImmunityData[school] = {}
    end

    -- Record immunity
    if conditionalBuff then
        -- Buff-based immunity
        local immunityData = { buff = conditionalBuff }
        if school == "unknown" then
            immunityData.spell = spellName
        end
        CleveRoids_ImmunityData[school][npcName] = immunityData

        if CleveRoids.debug then
            if school == "unknown" then
                CleveRoids.Print("|cffff6600Immunity:|r " .. npcName .. " is immune to '" .. spellName .. "' (unknown school) when buffed with: " .. conditionalBuff)
            else
                CleveRoids.Print("|cffff6600Immunity:|r " .. npcName .. " is immune to " .. school .. " when buffed with: " .. conditionalBuff)
            end
        end
    else
        -- Permanent immunity
        local immunityData
        if school == "unknown" then
            -- Store spell name for unknown school immunities
            immunityData = { spell = spellName }
        else
            immunityData = true
        end

        if CleveRoids_ImmunityData[school][npcName] ~= immunityData then
            CleveRoids_ImmunityData[school][npcName] = immunityData
            if CleveRoids.debug then
                if school == "unknown" then
                    CleveRoids.Print("|cffff6600Immunity:|r " .. npcName .. " is permanently immune to '" .. spellName .. "' (unknown school)")
                else
                    CleveRoids.Print("|cffff6600Immunity:|r " .. npcName .. " is permanently immune to " .. school)
                end
            end
        end
    end
end

-- Expose RecordImmunity globally for use by debuff verification (bleed immunity detection)
CleveRoids.RecordImmunity = RecordImmunity

-- Remove a spell/school immunity record when a spell successfully lands
-- This is called when we verify that a debuff actually landed on a previously-immune NPC
-- Parameters:
--   npcName: Name of the NPC
--   school: Damage school (e.g., "fire", "bleed") or spell name for unknown schools
local function RemoveSpellImmunity(npcName, school)
    if not npcName or not school or npcName == "" then
        return
    end

    if CleveRoids_ImmunityData[school] and CleveRoids_ImmunityData[school][npcName] then
        CleveRoids_ImmunityData[school][npcName] = nil

        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[Immunity Removed]|r " .. npcName .. " is no longer immune to " .. school .. " (spell landed successfully)")
        end
    end
end

-- Expose publicly
CleveRoids.RemoveSpellImmunity = RemoveSpellImmunity

-- AURA EXPECTATIONS
-- When the player's personal-debuff, shared-debuff or CC spell hits a unit, the
-- aura it applies is expected there. SPELL_AURA_APPLIED, or a C_UnitAuras check,
-- clears the expectation, and a miss cancels it; meanwhile [nodebuff] treats the
-- debuff as in flight (CleveRoids.IsAuraExpected). A personal debuff still missing
-- after AURA_EXPECT_DELAY is an immunity the server never reports: when a target
-- ignores one effect of a spell (Rake's bleed, Hamstring's snare) the server drops
-- that effect silently, and the damage still lands, so no IMMUNE miss is sent.
local AURA_EXPECT_DELAY = 0.4
local DEBUFF_CAP_THRESHOLD = 47  -- of 48 aura slots: a debuff this crowded was pushed off
local auraExpectations = {}      -- [guid .. ":" .. auraID] = expectation

-- The aura a spell applies: Pounce applies Pounce Bleed; most apply themselves
local function ExpectedAuraID(spellID)
    return CleveRoids.PounceToBleedMapping and CleveRoids.PounceToBleedMapping[spellID] or spellID
end

-- The expected aura is on the unit, as a new application or a refresh (which
-- fires no SPELL_AURA_APPLIED). Any rank counts, so a lower rank blocked by an
-- active higher one is not taken for immunity.
local function AuraLanded(unit, e)
    local i = 1
    while true do
        local name, _, _, _, _, _, source, _, _, spellId = C_UnitAuras.UnitAura(unit, i, "HARMFUL")
        if not name then return false end
        if (spellId == e.auraID or string.lower(name) == e.auraName)
            and (source == "player" or source == "pet") then
            return true
        end
        i = i + 1
    end
end

-- A personal debuff that never appeared: record the immunity, unless something
-- else explains the absence.
local function ResolveMissingAura(e)
    local unit = UnitTokenFromGUID(e.guid)
    -- No token (despawned, out of range), dead, or a player: inconclusive
    if not unit or UnitIsDead(unit) or UnitIsPlayer(unit) then return end
    if AuraLanded(unit, e) then return end
    if not e.name or e.name == "" then return end

    local immunityBuff = HasImmunityGrantingBuff(unit)
    if immunityBuff then
        if CleveRoids.debug then
            CleveRoids.Print("|cffaaaaaa[Aura Missing]|r " .. e.name .. " has " .. immunityBuff .. " - not recording immunity")
        end
        return
    end

    local debuffCount = 0
    while C_UnitAuras.UnitAura(unit, debuffCount + 1, "HARMFUL") do
        debuffCount = debuffCount + 1
    end
    if debuffCount >= DEBUFF_CAP_THRESHOLD then
        if CleveRoids.debug then
            CleveRoids.Print(string.format("|cffaaaaaa[Aura Missing]|r %s not on %s - pushed off (%d debuffs)",
                e.auraName, e.name, debuffCount))
        end
        return
    end

    if CleveRoids.BleedSpellIDs and CleveRoids.BleedSpellIDs[e.auraID] then
        -- Bosses known to take bleeds hit the debuff cap often; never record them
        if CleveRoids.MobsThatBleed and CleveRoids.MobsThatBleed[e.guid] then return end
        -- Recorded as bleed directly: RecordImmunity would use Rake's initial
        -- (physical) school, but it is the bleed that did not land
        CleveRoids_ImmunityData["bleed"] = CleveRoids_ImmunityData["bleed"] or {}
        CleveRoids_ImmunityData["bleed"][e.name] = true
        if CleveRoids.debug then
            CleveRoids.Print("|cffff6600[Bleed Immunity]|r " .. e.name .. " is immune to bleed (" .. e.auraName .. ")")
        end
    else
        RecordImmunity(e.name, nil, nil, e.auraID)
    end
end

-- The player's spell hit a unit: expect the debuff it applies
local function ExpectAura(spellID, guid, targetName)
    local auraID = ExpectedAuraID(spellID)
    local personal = lib.personalDebuffs[auraID] ~= nil
    if not (personal or lib.sharedDebuffs[auraID] or GetSpellCCType(spellID)) then return end
    local auraName = C_Spell.GetSpellName(auraID)
    if not auraName then return end

    local key = guid .. ":" .. auraID
    local e = {
        guid = guid,
        name = targetName,
        auraID = auraID,
        auraName = string.lower(CleveRoids.StripRank(auraName)),
    }
    auraExpectations[key] = e
    C_Timer.After(AURA_EXPECT_DELAY, function()
        if auraExpectations[key] ~= e then return end  -- landed, missed, or recast
        auraExpectations[key] = nil
        if personal then
            ResolveMissingAura(e)
        end
    end)
end

-- The player's spell missed the unit: its debuff will not come
local function CancelAuraExpectation(spellID, guid)
    auraExpectations[guid .. ":" .. ExpectedAuraID(spellID)] = nil
end

-- One of the player's debuffs landed on a unit. A CC counts toward the NPC
-- diminishing-returns safeguard, and disproves any CC immunity recorded for it.
local function PlayerAuraApplied(spellID, guid, targetName)
    auraExpectations[guid .. ":" .. spellID] = nil

    local drType = GetSpellImmunityDRType(spellID)
    if drType then
        local now = GetTime()
        lib.recentCCHits[guid] = lib.recentCCHits[guid] or {}
        local entry = lib.recentCCHits[guid][drType]
        local count = 1
        if entry and (now - entry.lastHitTime) < DR_RESET_WINDOW then
            count = entry.count + 1
        end
        lib.recentCCHits[guid][drType] = { count = count, lastHitTime = now }
    end

    local immunityType = GetSpellImmunityType(spellID) or GetSpellCCType(spellID)
    if immunityType and targetName then
        RemoveCCImmunity(targetName, immunityType)
    end
end

-- Whether the player's `spellName` debuff (lowercase, no rank) is in flight to
-- the unit with this GUID: it hit, and its aura has not appeared yet.
function CleveRoids.IsAuraExpected(guid, spellName)
    for _, e in pairs(auraExpectations) do
        if e.guid == guid and e.auraName == spellName then
            return true
        end
    end
    return false
end

-- A debuff landed on a unit (SPELL_AURA_APPLIED), from any caster. For a tracked
-- CC effect or bleed, this confirms the effect works on that NPC and removes any
-- false immunity record.
local function HandleAffliction(targetName, spellName)
    if not targetName or not spellName then return end

    local affliction = lib.trackedAfflictions[spellName]
    if not affliction then return end

    if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ff00[Affliction Landed]|r %s afflicted by %s (%s)",
                targetName, spellName, affliction.value)
        )
    end
    if affliction.type == "cc" then
        RemoveCCImmunity(targetName, affliction.value)
    else
        RemoveSpellImmunity(targetName, affliction.value)
    end
end

-- True if the recorded immunity data makes `targetName` immune to `school` right
-- now: outright when the entry is permanent, or only while it holds the buff the
-- entry names. The buff test is one by-name lookup across the unit's auras via
-- C_UnitAuras -- no slot scan, and it finds the aura wherever it sits.
local function SchoolImmune(unitId, school, targetName)
    local schoolData = school and CleveRoids_ImmunityData[school]
    local data = schoolData and schoolData[targetName]
    if not data then return false end
    if data == true then return true end
    if type(data) ~= "table" then return false end
    if not data.buff then return true end
    return CleveRoids.ClassicAPI.GetAuraDataBySpellName(unitId, data.buff, "HELPFUL") and true or false
end

-- Check if a unit is immune to a spell, damage school, or CC type
-- Supports: CheckImmunity(unitId, "Flame Shock") or CheckImmunity(unitId, "fire") or CheckImmunity(unitId, "stun")
function CleveRoids.CheckImmunity(unitId, spellOrSchool)
    if not unitId or not UnitExists(unitId) then
        return false
    end

    if not spellOrSchool or spellOrSchool == "" then
        return false
    end

    -- Check if input is a CC type (stun, fear, root, etc.)
    local inputLower = string.lower(spellOrSchool)
    local ccInput = NormalizeCCImmunityType(inputLower)
    if CC_IMMUNITY_TYPES[ccInput] then
        return CheckCCImmunity(unitId, ccInput)
    end

    -- Spell-name queries should honour mechanic immunity as well as school
    -- immunity. This makes bare [immune]/[noimmune] accurate for CC spells.
    local ccSpellName = CleveRoids.StripRank(spellOrSchool)
    if ccSpellName then
        ccSpellName = string.gsub(ccSpellName, "_", " ")
    end
    local ccSpellID = GetSpellIdForName and GetSpellIdForName(ccSpellName)
    if ccSpellID then
        local immunityType = GetSpellImmunityType(ccSpellID)
        if immunityType and CheckCCImmunity(unitId, immunityType) then
            return true
        end
    end

    -- Universal debuff-based immunities (Banish, etc.)
    -- Banish makes target immune to most damage schools (not all spells)
    do
        -- Banish: 710 = Rank 1, 18647 = Rank 2. One by-spellID lookup each --
        -- C_UnitAuras walks the whole aura array, so it finds the debuff even when
        -- it has overflowed into an NPC's buff slots (no manual slot scan / overflow gate).
        local API = CleveRoids.ClassicAPI
        local hasBanish = (API.GetUnitAuraBySpellID(unitId, 710)
            or API.GetUnitAuraBySpellID(unitId, 18647)) and true or false

        -- If Banished, check what's being tested for immunity
        if hasBanish then
            -- Banished targets are immune to all damage schools
            -- (but Banish itself can be recast immediately)
            local banishImmuneSchools = {
                fire = true,
                frost = true,
                nature = true,
                shadow = true,
                arcane = true,
                holy = true,
                physical = true,
                bleed = true
            }

            if banishImmuneSchools[inputLower] then
                return true
            end

            -- For specific spells, determine their school and check
            if not IMMUNITY_SCHOOLS[inputLower] then
                local spellSchool = GetSpellSchool(spellOrSchool)
                if spellSchool and banishImmuneSchools[spellSchool] then
                    return true
                end
            end
        end
    end

    -- Only works on NPCs for NPC-specific immunities
    if UnitIsPlayer(unitId) then
        return false
    end

    local targetName = UnitName(unitId)
    -- Fallback to GUID->name cache if UnitName fails
    -- This happens when multiscan passes a GUID that isn't the current target
    if not targetName or targetName == "" or targetName == "Unknown" then
        local normalizedGuid = CleveRoids.NormalizeGUID(unitId)
        if normalizedGuid and lib and lib.guidToName then
            targetName = lib.guidToName[normalizedGuid]
        end
    end
    if not targetName or targetName == "" then
        return false
    end

    -- Check if input is a spell school name directly
    -- (inputLower already defined above for CC type check)
    local school = nil
    local checkSpellName = nil  -- For unknown school, we need to match spell name too

    if IMMUNITY_SCHOOLS[inputLower] then
        -- Input is a damage school name (fire, frost, nature, etc.)
        school = inputLower
    else
        -- Input is a spell name, need to determine its school
        checkSpellName = spellOrSchool  -- Save the spell name for unknown school check

        -- Get base name for split damage spell check
        local baseName = string.gsub(spellOrSchool, "%s*%(.-%)%s*$", "")

        -- SPLIT DAMAGE SPELLS: Check BOTH initial and debuff schools
        -- If target is immune to EITHER component, skip the spell
        if SPLIT_DAMAGE_SPELLS[baseName] then
            local splitData = SPLIT_DAMAGE_SPELLS[baseName]
            local initialSchool = splitData.initial
            local debuffSchool = splitData.debuff

            -- Initial school (e.g. physical for Rake's opening hit), then the DoT's
            -- school (e.g. bleed). Immunity to either component skips the spell.
            local initialImmune = SchoolImmune(unitId, initialSchool, targetName)
            local debuffImmune = SchoolImmune(unitId, debuffSchool, targetName)

            -- Return true if immune to EITHER component
            if initialImmune or debuffImmune then
                if CleveRoids.debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                        string.format("|cffff6600[Immunity Check]|r %s on %s: initial(%s)=%s, debuff(%s)=%s",
                            baseName, targetName,
                            initialSchool, initialImmune and "IMMUNE" or "ok",
                            debuffSchool, debuffImmune and "IMMUNE" or "ok")
                    )
                end
                return true
            end
            return false
        end

        school = GetSpellSchool(spellOrSchool)
        if not school then
            school = "unknown"  -- If we can't determine school, check unknown category
        end
    end

    -- Check immunity data for this school
    if not CleveRoids_ImmunityData[school] then
        return false
    end

    local immunityData = CleveRoids_ImmunityData[school][targetName]

    -- No immunity data for this NPC
    if not immunityData then
        return false
    end

    -- Permanent immunity
    if immunityData == true then
        return true
    end

    -- Table-based immunity data (buff-based or unknown school with spell name)
    if type(immunityData) == "table" then
        -- For unknown school, check if spell name matches
        if school == "unknown" and immunityData.spell and checkSpellName then
            if immunityData.spell ~= checkSpellName then
                return false  -- NPC is immune to a different spell, not this one
            end
        end

        -- Check buff-based immunity (if NPC has the required buff). One by-name
        -- lookup across the unit's buffs via C_UnitAuras -- no 32-slot scan.
        if immunityData.buff then
            if CleveRoids.ClassicAPI.GetAuraDataBySpellName(unitId, immunityData.buff, "HELPFUL") then
                return true
            end
            -- Buff not found, not currently immune
            return false
        end

        -- Unknown school permanent immunity (has spell name, no buff requirement)
        if immunityData.spell and not immunityData.buff then
            return true  -- Permanent immunity to this specific spell
        end
    end

    return false
end

-- Management functions for immunity data
function CleveRoids.ListImmunities(school)
    if school then
        school = string.lower(school)
        if not CleveRoids_ImmunityData[school] then
            CleveRoids.Print("No immunity data for school: " .. school)
            return
        end

        CleveRoids.Print("|cff00ff00" .. school .. " immunities:|r")
        local count = 0
        for npc, data in pairs(CleveRoids_ImmunityData[school]) do
            if data == true then
                CleveRoids.Print("  - " .. npc .. " (permanent)")
            elseif type(data) == "table" then
                if data.buff and data.spell then
                    -- Unknown school with conditional buff
                    CleveRoids.Print("  - " .. npc .. " immune to '" .. data.spell .. "' (when buffed: " .. data.buff .. ")")
                elseif data.buff then
                    -- Known school with conditional buff
                    CleveRoids.Print("  - " .. npc .. " (when buffed: " .. data.buff .. ")")
                elseif data.spell then
                    -- Unknown school, permanent
                    CleveRoids.Print("  - " .. npc .. " immune to '" .. data.spell .. "' (permanent)")
                end
            end
            count = count + 1
        end
        CleveRoids.Print("Total: " .. count)
    else
        -- List all schools
        CleveRoids.Print("|cff00ff00Immunity Data by School:|r")
        for schoolName, npcs in pairs(CleveRoids_ImmunityData) do
            local count = 0
            for _ in pairs(npcs) do
                count = count + 1
            end
            if count > 0 then
                CleveRoids.Print("  " .. schoolName .. ": " .. count .. " NPCs")
            end
        end
    end
end

function CleveRoids.ClearImmunities(school)
    if school then
        school = string.lower(school)
        CleveRoids_ImmunityData[school] = {}
        CleveRoids.Print("Cleared " .. school .. " immunity data")
    else
        CleveRoids_ImmunityData = {}
        CleveRoids.Print("Cleared all immunity data")
    end
end

function CleveRoids.AddImmunity(npcName, school, buffName)
    if not npcName or not school then
        CleveRoids.Print("Usage: /cleveroid addimmune <npc name> <school> [buff name]")
        CleveRoids.Print("Schools: fire, frost, nature, shadow, arcane, holy, physical, bleed, unknown")
        return
    end

    school = string.lower(school)
    if not IMMUNITY_SCHOOLS[school] then
        CleveRoids.Print("Invalid school. Use: fire, frost, nature, shadow, arcane, holy, physical, bleed, unknown")
        return
    end

    if not CleveRoids_ImmunityData[school] then
        CleveRoids_ImmunityData[school] = {}
    end

    if buffName and buffName ~= "" then
        CleveRoids_ImmunityData[school][npcName] = { buff = buffName }
        CleveRoids.Print("Added: " .. npcName .. " is immune to " .. school .. " when buffed with: " .. buffName)
    else
        CleveRoids_ImmunityData[school][npcName] = true
        CleveRoids.Print("Added: " .. npcName .. " is permanently immune to " .. school)
    end
end

function CleveRoids.RemoveImmunity(npcName, school)
    if not npcName or not school then
        CleveRoids.Print("Usage: /cleveroid removeimmune <npc name> <school>")
        return
    end

    school = string.lower(school)
    if CleveRoids_ImmunityData[school] and CleveRoids_ImmunityData[school][npcName] then
        CleveRoids_ImmunityData[school][npcName] = nil
        CleveRoids.Print("Removed: " .. npcName .. " from " .. school .. " immunities")
    else
        CleveRoids.Print("Not found: " .. npcName .. " in " .. school .. " immunities")
    end
end

-- CC IMMUNITY MANAGEMENT COMMANDS

-- List CC immunities
function CleveRoids.ListCCImmunities(ccType)
    if ccType then
        ccType = NormalizeCCImmunityType(ccType)
        local key = "cc_" .. ccType

        if not CC_IMMUNITY_TYPES[ccType] then
            CleveRoids.Print("Invalid CC type. Use: stun, freeze, knockout, sap, fear, root, silence, sleep, charm, polymorph, banish, shackle, horror, disorient, daze, snare")
            return
        end

        if not CleveRoids_ImmunityData[key] then
            CleveRoids.Print("No " .. ccType .. " immunity data recorded")
            return
        end

        CleveRoids.Print("|cff00ff00" .. ccType .. " immunities:|r")
        local count = 0
        for npc, data in pairs(CleveRoids_ImmunityData[key]) do
            if data == true then
                CleveRoids.Print("  - " .. npc .. " (permanent)")
            elseif type(data) == "table" and data.buff then
                CleveRoids.Print("  - " .. npc .. " (when buffed: " .. data.buff .. ")")
            end
            count = count + 1
        end
        CleveRoids.Print("Total: " .. count)
    else
        -- List all CC types
        CleveRoids.Print("|cff00ff00CC Immunity Data by Type:|r")
        local found = false
        for key, npcs in pairs(CleveRoids_ImmunityData) do
            -- Only show CC immunity keys (prefixed with "cc_")
            if string.sub(key, 1, 3) == "cc_" then
                local count = 0
                for _ in pairs(npcs) do
                    count = count + 1
                end
                if count > 0 then
                    local ccName = string.sub(key, 4)  -- Remove "cc_" prefix
                    CleveRoids.Print("  " .. ccName .. ": " .. count .. " NPCs")
                    found = true
                end
            end
        end
        if not found then
            CleveRoids.Print("  No CC immunity data recorded")
        end
    end
end

-- Clear CC immunities
function CleveRoids.ClearCCImmunities(ccType)
    if ccType then
        ccType = NormalizeCCImmunityType(ccType)
        local key = "cc_" .. ccType

        if not CC_IMMUNITY_TYPES[ccType] then
            CleveRoids.Print("Invalid CC type. Use: stun, freeze, knockout, sap, fear, root, silence, sleep, charm, polymorph, banish, shackle, horror, disorient, daze, snare")
            return
        end

        CleveRoids_ImmunityData[key] = {}
        CleveRoids.Print("Cleared " .. ccType .. " immunity data")
    else
        -- Clear all CC immunities (only cc_ prefixed keys)
        local cleared = 0
        for key, _ in pairs(CleveRoids_ImmunityData) do
            if string.sub(key, 1, 3) == "cc_" then
                CleveRoids_ImmunityData[key] = nil
                cleared = cleared + 1
            end
        end
        CleveRoids.Print("Cleared all CC immunity data (" .. cleared .. " types)")
    end
end

-- Manually add CC immunity
function CleveRoids.AddCCImmunity(npcName, ccType, buffName)
    if not npcName or not ccType then
        CleveRoids.Print("Usage: /cleveroid addccimmune <npc name> <cctype> [buff name]")
        CleveRoids.Print("CC Types: stun, freeze, knockout, sap, fear, root, silence, sleep, charm, polymorph, banish, shackle, horror, disorient, daze, snare")
        return
    end

    ccType = NormalizeCCImmunityType(ccType)
    if not CC_IMMUNITY_TYPES[ccType] then
        CleveRoids.Print("Invalid CC type. Use: stun, freeze, knockout, sap, fear, root, silence, sleep, charm, polymorph, banish, shackle, horror, disorient, daze, snare")
        return
    end

    local key = "cc_" .. ccType
    if not CleveRoids_ImmunityData[key] then
        CleveRoids_ImmunityData[key] = {}
    end

    if buffName and buffName ~= "" then
        CleveRoids_ImmunityData[key][npcName] = { buff = buffName }
        CleveRoids.Print("Added: " .. npcName .. " is immune to " .. ccType .. " when buffed with: " .. buffName)
    else
        CleveRoids_ImmunityData[key][npcName] = true
        CleveRoids.Print("Added: " .. npcName .. " is permanently immune to " .. ccType)
    end
end

-- Remove a CC immunity (command handler with user feedback)
-- NOTE: Do not use for automatic removal - use CleveRoids.RemoveCCImmunity instead
function CleveRoids.RemoveCCImmunityCommand(npcName, ccType)
    if not npcName or not ccType then
        CleveRoids.Print("Usage: /cleveroid removeccimmune <npc name> <cctype>")
        return
    end

    ccType = NormalizeCCImmunityType(ccType)
    local key = "cc_" .. ccType
    if CleveRoids_ImmunityData[key] and CleveRoids_ImmunityData[key][npcName] then
        CleveRoids_ImmunityData[key][npcName] = nil
        CleveRoids.Print("Removed: " .. npcName .. " from " .. ccType .. " immunities")
    else
        CleveRoids.Print("Not found: " .. npcName .. " in " .. ccType .. " immunities")
    end
end

-- REACTIVE ABILITY PROC TRACKING SYSTEM
-- Tracks reactive ability procs independently of stance/usability
-- Allows detection of Overpower/Revenge/Riposte procs even when not in correct stance

-- Table to store reactive proc states with expiry times and target GUIDs
-- Structure: { spellName = { expiry = time, targetGUID = guid } }
CleveRoids.reactiveProcs = CleveRoids.reactiveProcs or {}

-- Table to track which reactive spells we've seen proc at least once
-- This helps us decide whether to use combat log tracking vs fallback methods
CleveRoids.reactiveProcsEverSeen = CleveRoids.reactiveProcsEverSeen or {}

-- Proc durations (in seconds)
-- Overpower and Revenge: 4 seconds
-- Riposte: 5 seconds (keeping at 5 for safety, can be adjusted)
local REACTIVE_PROC_DURATION = 4.0

-- Set a reactive proc state with optional target GUID
function CleveRoids.SetReactiveProc(spellName, duration, targetGUID)
    duration = duration or REACTIVE_PROC_DURATION
    CleveRoids.reactiveProcs[spellName] = {
        expiry = GetTime() + duration,
        targetGUID = targetGUID
    }
    -- Mark that we've seen this reactive spell proc at least once
    CleveRoids.reactiveProcsEverSeen[spellName] = true
end

-- Check if a reactive proc is active (with optional GUID check)
function CleveRoids.HasReactiveProc(spellName)
    local procData = CleveRoids.reactiveProcs[spellName]
    if not procData or not procData.expiry then
        return false
    end

    local now = GetTime()
    if now >= procData.expiry then
        -- Expired, clear it
        if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cffff9900[HasReactiveProc]|r %s: EXPIRED - clearing and queuing update", spellName)
            )
        end
        CleveRoids.reactiveProcs[spellName] = nil
        -- Queue action update to refresh icon state
        CleveRoids.QueueActionUpdate()
        if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cffff9900[HasReactiveProc]|r Action update queued, isActionUpdateQueued = %s", tostring(CleveRoids.isActionUpdateQueued))
            )
        end
        return false
    end

    -- If proc has a target GUID requirement, check if current target matches
    if procData.targetGUID then
        local targetGUID = CleveRoids.GetGUID("target")
        if not targetGUID or targetGUID ~= procData.targetGUID then
            return false
        end
    end

    return true
end

-- Clear a reactive proc
function CleveRoids.ClearReactiveProc(spellName)
    CleveRoids.reactiveProcs[spellName] = nil
end

-- Removed: ClearReactiveProcOnCast plus wrappers around Frame.UNIT_CASTEVENT and
-- Frame.SPELL_START_SELF that tried to clear a reactive proc when its spell was cast.
-- The feature never worked, for three independent reasons:
--   1. Both wrappers guarded on `CleveRoids.Frame and CleveRoids.Frame.<handler>`,
--      but CleveRoids.Frame is created in Core.lua, which loads AFTER this file, so
--      the guard was always false and neither wrapper was ever installed.
--   2. The UNIT_CASTEVENT wrapper tested arg2 == "START", but that signature is
--      (caster, target, action, spell_id, cast_time) -- the action is arg3, so it was
--      comparing the target.
--   3. Both passed a spell *ID* to a function that looks the name up in
--      CleveRoids.reactiveSpells, which is keyed by name, so nothing could match.
-- They also each allocated an `arg` table per call and unpack()'d it. Deleting is
-- behaviour-preserving; if clearing a reactive proc on cast is still wanted it needs
-- to be written fresh against the real handler signatures.

-- REACTIVE PROCS AND IMMUNITY FROM THE COMBAT LOG
-- Fed by the COMBAT_LOG_EVENT_UNFILTERED dispatcher at the end of this file.

-- Set a reactive proc if the player uses that ability. Returns true when set.
local function ProcReactive(spellName, targetGUID)
    if not CleveRoids.reactiveSpells[spellName] then return false end
    CleveRoids.SetReactiveProc(spellName, 4.0, targetGUID)
    if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reactive]|r " .. spellName .. " proc")
    end
    return true
end

-- A swing or ability that was avoided. When the player's attack is dodged,
-- Overpower and Surprise Attack proc on that target. When the player parries,
-- Riposte procs on the attacker; a dodge, parry or block (full, or a hit that
-- lost `blocked` to one) procs Revenge on any target. missType is nil for a hit.
local function ProcessAvoidance(sourceGUID, destGUID, playerGUID, missType, blocked)
    if not CleveRoids.reactiveSpells or not playerGUID then return end

    local procced = false
    if sourceGUID == playerGUID then
        if missType == "DODGE" then
            procced = ProcReactive("Overpower", destGUID)
            procced = ProcReactive("Surprise Attack", destGUID) or procced
        end
    elseif destGUID == playerGUID then
        if missType == "PARRY" then
            procced = ProcReactive("Riposte", sourceGUID)
        end
        if missType == "DODGE" or missType == "PARRY" or missType == "BLOCK" or (blocked and blocked > 0) then
            procced = ProcReactive("Revenge", nil) or procced
        end
    end

    if procced then
        CleveRoids.QueueActionUpdate()
    end
end

-- The player's spell missed. A RESIST sets [resisted]; an IMMUNE records the
-- target's immunity unless something temporary explains it.
local function ProcessSpellMissSelf(spellId, targetGuid, targetName, missType)
    if missType == "RESIST" then
        CleveRoids.SetResistState("full", targetGuid)
        return
    end
    if missType ~= "IMMUNE" then return end

    local spellName = C_Spell.GetSpellName(spellId)
    if not spellName or not targetName then return end
    lib.guidToName[targetGuid] = targetName
    local baseName = string.gsub(spellName, "%s*%(.-%)%s*$", "")

    if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff6600[SPELL_MISSED]|r IMMUNE - %s on %s (spellId=%d)",
                spellName, targetName, spellId)
        )
    end

    -- Skip split CC spells (physical damage + resistable CC)
    if SPLIT_CC_SPELLS[spellId] or SPLIT_CC_SPELL_NAMES[baseName] then
        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[SPELL_MISSED Split CC Skip]|r " .. spellName .. " CC immune on " .. targetName)
        end
        return
    end

    -- Skip if target recently died (dead targets report IMMUNE for in-flight spells)
    if lib.recentDeaths[targetGuid] and (GetTime() - lib.recentDeaths[targetGuid]) < 3 then
        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[SPELL_MISSED Dead Skip]|r " .. targetName .. " recently died - ignoring immunity")
        end
        return
    end

    -- The buff and death checks need a unit token for the target. Without one
    -- (despawned/phased/out of every token) the miss is inconclusive.
    local queryUnit = UnitTokenFromGUID(targetGuid)
    if not queryUnit then
        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[SPELL_MISSED Inconclusive]|r Cannot query " .. targetName .. " for buffs - not recording immunity")
        end
        return
    end

    if UnitIsDead(queryUnit) then
        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[SPELL_MISSED Dead Skip]|r " .. targetName .. " is dead - ignoring immunity")
        end
        -- Record the death for later spells in the same volley
        lib.recentDeaths[targetGuid] = GetTime()
        return
    end

    -- Skip if target has temporary immunity buff (Divine Shield, etc.)
    local immunityBuff = HasImmunityGrantingBuff(queryUnit)
    if immunityBuff then
        if CleveRoids.debug then
            CleveRoids.Print("|cff00aaff[SPELL_MISSED Temp Skip]|r " .. targetName .. " has " .. immunityBuff)
        end
        return
    end

    -- Check NPC-applicable DR before recording permanent CC immunity.
    local ccType = GetSpellCCType(spellId)
    local immunityType = GetSpellImmunityType(spellId) or ccType
    local drType = GetSpellImmunityDRType(spellId)
    if drType then
        local drEntry = lib.recentCCHits[targetGuid] and lib.recentCCHits[targetGuid][drType]
        if drEntry and (GetTime() - drEntry.lastHitTime) < DR_RESET_WINDOW and drEntry.count >= 3 then
            if CleveRoids.debug then
                CleveRoids.Print("|cff00aaff[SPELL_MISSED DR Skip]|r " .. targetName .. " - likely " .. drType .. " DR immunity, not recording")
            end
            return
        end
    end

    -- Record as permanent immunity
    if immunityType then
        RecordCCImmunity(targetName, immunityType, nil, spellName)
    else
        RecordImmunity(targetName, spellName, nil, spellId)
    end
end

-- RESIST TRACKING SYSTEM
-- Tracks full and partial spell resists for [resisted] and [noresisted] conditionals

-- Set resist state with target GUID matching
function CleveRoids.SetResistState(resistType, targetGUID)
    CleveRoids.resistState = {
        resistType = resistType,
        targetGUID = targetGUID
    }
    CleveRoids.QueueActionUpdate()

    if CleveRoids.debug then
        local targetName = UnitName("target") or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff6600[Resist Track]|r %s resist on %s",
                string.upper(resistType), targetName)
        )
    end
end

-- Clear resist state
function CleveRoids.ClearResistState()
    if CleveRoids.resistState then
        CleveRoids.resistState = nil
        CleveRoids.QueueActionUpdate()
    end
end

-- Check resist state (used by conditionals)
-- Returns true if resist matches the type AND current target matches the GUID
function CleveRoids.CheckResistState(resistType)
    local state = CleveRoids.resistState
    if not state then return false end

    -- Must have current target that matches the GUID from resist event
    local currentTargetGUID = CleveRoids.GetGUID("target")
    if not currentTargetGUID or currentTargetGUID ~= state.targetGUID then
        return false
    end

    -- If no specific type requested, any resist matches
    if not resistType or resistType == "" then
        return true
    end

    -- Check specific resist type
    return state.resistType == string.lower(resistType)
end

-- COMBAT LOG DISPATCHER
-- One COMBAT_LOG_EVENT_UNFILTERED handler feeds immunity tracking, reactive
-- procs, resist state, spell-school learning, CC/bleed landing and death
-- cleanup. The event names units by GUID and carries the spell ID, school and
-- miss type, so nothing here reads the localized chat text.
local combatLogFrame = CreateFrame("Frame", "CleveRoidsCombatLogFrame")
combatLogFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
combatLogFrame:SetScript("OnEvent", function()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName, _, _,
          a1, a2, a3, a4, a5, a6, a7 = CombatLogGetCurrentEventInfo()
    local playerGUID = CleveRoids.GetGUID("player")
    local byPlayerOnOther = sourceGUID == playerGUID and destGUID and destGUID ~= playerGUID

    if subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" then
        -- spellId, spellName, spellSchool, missType
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, a4, nil)
        if sourceGUID == playerGUID then
            ProcessSpellMissSelf(a1, destGUID, destName, a4)
            CancelAuraExpectation(a1, destGUID)
        end
    elseif subevent == "DAMAGE_SHIELD_MISSED" or subevent == "SPELL_PERIODIC_MISSED" then
        -- spellId, spellName, spellSchool, missType. A target immune to the
        -- damage of a periodic tick or a damage shield (SMSG_SPELLORDAMAGE_IMMUNE)
        if sourceGUID == playerGUID and a4 == "IMMUNE" then
            ProcessSpellMissSelf(a1, destGUID, destName, a4)
        end
    elseif subevent == "SWING_MISSED" then
        -- missType
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, a1, nil)
    elseif subevent == "SWING_DAMAGE" then
        -- amount, overkill, school, resisted, blocked
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, nil, a5)
    elseif subevent == "SPELL_CAST_SUCCESS" then
        -- spellId: an instant spell went off at destGUID
        if byPlayerOnOther then
            ExpectAura(a1, destGUID, destName)
        end
    elseif subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "RANGE_DAMAGE" then
        -- spellId, spellName, spellSchool, amount, overkill, school, resisted
        LearnSpellSchool(a1, a3, subevent == "SPELL_PERIODIC_DAMAGE")
        if a7 and sourceGUID == playerGUID then
            CleveRoids.SetResistState("partial", destGUID)
        end
        if byPlayerOnOther and subevent ~= "SPELL_PERIODIC_DAMAGE" then
            ExpectAura(a1, destGUID, destName)
        end
    elseif subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_APPLIED_DOSE" then
        -- spellId, spellName, spellSchool, auraType
        if a4 == "DEBUFF" then
            if byPlayerOnOther then
                PlayerAuraApplied(a1, destGUID, destName)
            end
            if subevent == "SPELL_AURA_APPLIED" then
                HandleAffliction(destName, a2)
            end
        end
    elseif subevent == "UNIT_DIED" then
        HandleUnitDied(destGUID)
    end
end)
