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

lib.objects = lib.objects or {}
lib.guidToName = lib.guidToName or {}

-- PFUI v7.4.3+ NAMPOWER-BASED DEBUFF TRACKING INTEGRATION
-- When pfUI v7.4.3+ with Nampower v2.26+ is available, we leverage pfUI's
-- comprehensive debuff tracking tables instead of duplicating the event handlers.
-- This provides accurate caster GUID tracking, rank checking, combo point
-- duration calculation, and miss/dodge/parry/resist/immune detection.

-- Enhanced tables (populated by pfUI or standalone Nampower handlers)
lib.ownDebuffs = lib.ownDebuffs or {}       -- [targetGUID][spellName] = {startTime, duration, texture, rank, spellId}
lib.ownSlots = lib.ownSlots or {}           -- [targetGUID][slot] = spellName (LEGACY - empty when pfUI 7.6+ is active)
lib.allSlots = lib.allSlots or {}           -- [targetGUID][slot] = {spellName, casterGuid, isOurs} (LEGACY - empty when pfUI 7.6+ is active)
lib.slotOwnership = lib.slotOwnership or {} -- [targetGUID][auraSlot] = {casterGuid, spellName, spellId, isOurs} (pfUI 7.6+ GetUnitField edition)
lib.allAuraCasts = lib.allAuraCasts or {}   -- [targetGUID][spellName][casterGuid] = {startTime, duration, rank}
lib.pendingCasts = lib.pendingCasts or {}   -- [targetGUID][spellName] = {casterGuid, rank, time, comboPoints}
lib.recentMisses = lib.recentMisses or {}   -- [targetGUID][spellName] = {time, spellId, targetName, reason} for miss/dodge/parry detection
lib.recentDeaths = lib.recentDeaths or {}   -- [targetGUID] = GetTime() timestamp of UNIT_DIED (prevents false immunity on dead targets)
local DR_RESET_WINDOW = 20
lib.recentCCHits = lib.recentCCHits or {}   -- [targetGUID][drType] = {count, lastHitTime} for NPC DR safeguard
lib.iconCache = lib.iconCache or {}          -- [spellId] = texture (shared with pfUI 7.6 or standalone)

-- Buff tracking tables (parallel to debuff tables, standalone Nampower mode only)
-- Buff tables are NOT linked to pfUI — pfUI has no public buff tracking tables.
-- They remain empty when hasPfUIEnhanced=true since all buff event handlers are gated by it.

-- Flag indicating whether enhanced pfUI tracking is available
lib.hasPfUIEnhanced = false
lib.hasStandaloneNampower = false

-- Check if pfUI v7.4.3+ with enhanced libdebuff is available
function lib:HasEnhancedPfUILibdebuff()
  -- Check pfUI exists
  if not pfUI then return false end

  -- Check version from TOC (stored in pfUI.version after ADDON_LOADED)
  -- Minimum required: 7.4.3
  local v = pfUI.version
  if not v or not v.major then return false end

  -- Version comparison: 7.4.3+
  if v.major > 7 then
    -- Continue to Nampower check
  elseif v.major < 7 then
    return false
  else
    -- major == 7
    if v.minor > 4 then
      -- Continue to Nampower check
    elseif v.minor < 4 then
      return false
    else
      -- minor == 4
      if (v.fix or 0) < 3 then
        return false
      end
    end
  end

  -- Verify Nampower version based on pfUI version:
  -- - pfUI 7.6+ (GetUnitField edition): requires Nampower v2.37.0+
  -- - pfUI 7.4.3 to 7.5.x (legacy): requires Nampower v2.26+
  if not GetNampowerVersion then return false end
  local npMajor, npMinor, npPatch = GetNampowerVersion()
  npPatch = npPatch or 0

  -- Check if this is pfUI 7.6+ (GetUnitField edition) by looking for the new table
  local isPfUI76 = pfUI.libdebuff_slot_ownership ~= nil

  if isPfUI76 then
    -- pfUI 7.6+ requires Nampower v2.37.0+
    if npMajor < 2 then return false end
    if npMajor == 2 and npMinor < 37 then return false end
  else
    -- Legacy pfUI 7.4.3-7.5.x requires Nampower v2.26+
    if npMajor < 2 or (npMajor == 2 and npMinor < 26) then return false end
  end

  -- Finally verify the exposed tables exist
  -- NOTE: libdebuff_own_slots and libdebuff_all_slots are LEGACY stubs (empty) in pfUI 7.6+
  -- The new GetUnitField-based libdebuff uses libdebuff_slot_ownership instead
  if not pfUI.libdebuff_own then return false end
  if not pfUI.libdebuff_pending then return false end
  -- Check for either legacy tables (pre-7.6) or new slotOwnership table (7.6+)
  if not pfUI.libdebuff_all_slots and not pfUI.libdebuff_slot_ownership then return false end

  return true
end


-- Icon caching helper: DBC lookup via GetSpellRecField
function lib:GetCachedIcon(spellId)
  if not spellId then return nil end
  if lib.iconCache[spellId] then return lib.iconCache[spellId] end

  local texture = C_Spell.GetSpellTexture(spellId) or "Interface\\Icons\\INV_Misc_QuestionMark"

  lib.iconCache[spellId] = texture
  return texture
end

-- Initialize pfUI integration (call after ADDON_LOADED for pfUI)
function lib:InitPfUIIntegration()
  if lib:HasEnhancedPfUILibdebuff() then
    -- Link to pfUI's tables directly
    lib.ownDebuffs = pfUI.libdebuff_own or lib.ownDebuffs
    lib.allAuraCasts = pfUI.libdebuff_all_auras or lib.allAuraCasts
    lib.pendingCasts = pfUI.libdebuff_pending or lib.pendingCasts

    -- LEGACY slot tables (empty in pfUI 7.6+ GetUnitField edition, but kept for backwards compat)
    lib.ownSlots = pfUI.libdebuff_own_slots or lib.ownSlots
    lib.allSlots = pfUI.libdebuff_all_slots or lib.allSlots

    -- NEW: GetUnitField-based slot ownership (pfUI 7.6+)
    -- This replaces the legacy ownSlots/allSlots with stable aura slot tracking
    if pfUI.libdebuff_slot_ownership then
      lib.slotOwnership = pfUI.libdebuff_slot_ownership
    end

    lib.hasPfUIEnhanced = true
    lib.hasStandaloneNampower = false

    -- Delegate event unregistration and hook registration to pfUI compatibility layer.
    -- All pfUI hook logic lives in Compatibility/pfUI.lua for easier debugging.
    if CleveRoids.Compatibility_pfUI and CleveRoids.Compatibility_pfUI.SetupPfUIEventHooks then
      CleveRoids.Compatibility_pfUI.SetupPfUIEventHooks(lib)
    else
      -- Fallback: call lib method directly (pfUI extension not yet loaded)
      lib:RegisterPfUIHooks()
    end

    if CleveRoids.debug then
      local v = pfUI.version
      DEFAULT_CHAT_FRAME:AddMessage(
        string.format("|cff33ff99[libdebuff]|r pfUI v%d.%d.%d enhanced tracking enabled",
          v.major, v.minor, v.fix or 0)
      )
    end

    return true
  end

  -- Check for standalone Nampower v2.26+ (when pfUI is not available or outdated)
  -- Standalone mode uses SPELL_GO and AURA_CAST events which are available in v2.26+
  if GetNampowerVersion then
    local npMajor, npMinor, npPatch = GetNampowerVersion()
    npPatch = npPatch or 0
    local hasMinVersion = npMajor > 2 or (npMajor == 2 and npMinor >= 26)
    if hasMinVersion then
      lib.hasStandaloneNampower = true
      lib.hasPfUIEnhanced = false

      if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cff33ff99[libdebuff]|r Standalone Nampower v%d.%d.%d tracking enabled",
            npMajor, npMinor, npPatch)
        )
      end

      return true
    end
  end

  return false
end

-- Register pfUI libdebuff hooks (thin wrapper — delegates to Compatibility/pfUI.lua).
-- Hook logic has been moved to Extension.SetupPfUIEventHooks() for easier debugging.
-- This wrapper exists for backwards compatibility if called directly.
function lib:RegisterPfUIHooks()
  if CleveRoids.Compatibility_pfUI and CleveRoids.Compatibility_pfUI.SetupPfUIEventHooks then
    CleveRoids.Compatibility_pfUI.SetupPfUIEventHooks(lib)
  end
end

-- Unique debuffs: Same spell overwrites itself when cast by different player
-- Only one instance can exist on a target (regardless of caster)
lib.uniqueDebuffs = lib.uniqueDebuffs or {
  ["Hunter's Mark"] = true,
  ["Scorpid Sting"] = true,
  ["Curse of Weakness"] = true,
  ["Curse of Recklessness"] = true,
  ["Curse of the Elements"] = true,
  ["Curse of Shadow"] = true,
  ["Curse of Tongues"] = true,
  ["Curse of Idiocy"] = true,
  ["Curse of Agony"] = true,
  ["Curse of Doom"] = true,
  ["Curse of Exhaustion"] = true,
  ["Judgement of Light"] = true,
  ["Judgement of Wisdom"] = true,
  ["Judgement of Justice"] = true,
  ["Judgement of the Crusader"] = true,
  ["Shadow Vulnerability"] = true,
  ["Shadow Weaving"] = true,
  ["Stormstrike"] = true,
  ["Sunder Armor"] = true,
  ["Expose Armor"] = true,
  ["Nightfall"] = true,
  ["Improved Scorch"] = true,
  ["Winter's Chill"] = true,
}

-- Debuff pairs that can overwrite each other (e.g., Faerie Fire variants)
lib.debuffOverwritePairs = lib.debuffOverwritePairs or {
  -- Faerie Fire variants
  ["Faerie Fire"] = "Faerie Fire (Feral)",
  ["Faerie Fire (Feral)"] = "Faerie Fire",

  -- Demo variants
  ["Demoralizing Shout"] = "Demoralizing Roar",
  ["Demoralizing Roar"] = "Demoralizing Shout",
}

-- Combo point abilities: Duration depends on combo points used
lib.combopointAbilities = lib.combopointAbilities or {
  ["Rip"] = true,
  ["Rupture"] = true,
  ["Kidney Shot"] = true,
  ["Slice and Dice"] = true,
  ["Expose Armor"] = true,
}

-- Check if a spell recently failed (miss/dodge/parry/resist/immune/evade)
-- @param spellName: The spell to check
-- @param targetGuid: (optional) If provided, check only for this target; otherwise check all targets
function lib:DidSpellFail(spellName, targetGuid)
  if not spellName then return false end
  local now = GetTime()

  if targetGuid then
    -- Check specific target
    if lib.recentMisses[targetGuid] and lib.recentMisses[targetGuid][spellName] then
      local data = lib.recentMisses[targetGuid][spellName]
      if data and data.time and (now - data.time) < 1 then
        return true
      end
    end
  else
    -- Check all targets (backwards compatibility)
    for _, spells in pairs(lib.recentMisses) do
      if spells[spellName] then
        local data = spells[spellName]
        if data and data.time and (now - data.time) < 1 then
          return true
        end
      end
    end
  end
  return false
end

-- Periodic cleanup of stale tracking tables
-- Call this periodically (e.g., every 30 seconds) to prevent memory leaks
local lastCleanupTime = 0
function lib:CleanupStaleTrackingData()
  local now = GetTime()

  -- Only run every 30 seconds
  if (now - lastCleanupTime) < 30 then
    return
  end
  lastCleanupTime = now

  local staleTime = 10  -- Entries older than 10 seconds are cleaned up

  -- Clean recentMisses
  if lib.recentMisses then
    for guid, spells in pairs(lib.recentMisses) do
      for spellName, data in pairs(spells) do
        if (now - data.time) > staleTime then
          spells[spellName] = nil
        end
      end
      if not next(spells) then
        lib.recentMisses[guid] = nil
      end
    end
  end

  -- Clean recentDeaths (dead target immunity guard)
  if lib.recentDeaths then
    for guid, deathTime in pairs(lib.recentDeaths) do
      if (now - deathTime) > staleTime then
        lib.recentDeaths[guid] = nil
      end
    end
  end

  -- Clean pendingCasts (including combo point data from SPELL_GO)
  if lib.pendingCasts then
    for guid, spells in pairs(lib.pendingCasts) do
      for spellName, data in pairs(spells) do
        local capturedAt = data.capturedAt or data.time or 0
        if (now - capturedAt) > staleTime then
          spells[spellName] = nil
        end
      end
      if not next(spells) then
        lib.pendingCasts[guid] = nil
      end
    end
  end

end

-- Check if a pending cast exists for a spell on a target
function lib:HasPendingCast(targetGuid, spellName)
  if not targetGuid or not spellName then return false end
  targetGuid = CleveRoids.NormalizeGUID(targetGuid)

  if lib.pendingCasts[targetGuid] and lib.pendingCasts[targetGuid][spellName] then
    local data = lib.pendingCasts[targetGuid][spellName]
    -- Pending casts expire after 1 second
    if data.time and (GetTime() - data.time) < 1 then
      return true
    end
  end

  return false
end

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

-- Combined table for backwards compatibility (will be deprecated)
lib.durations = lib.durations or {}
for k, v in pairs(lib.personalDebuffs) do
  lib.durations[k] = v
end
for k, v in pairs(lib.sharedDebuffs) do
  lib.durations[k] = v
end

-- MUTUALLY EXCLUSIVE DEBUFFS: Only one per caster can exist on a target
-- When a new curse is applied, remove any other curses from the same caster
lib.curseSpellIDs = lib.curseSpellIDs or {
  -- Curse of Agony
  [980] = true, [1014] = true, [6217] = true, [11711] = true, [11712] = true, [11713] = true,
  -- Curse of Doom
  [603] = true,
  -- Curse of Recklessness
  [704] = true, [7658] = true, [7659] = true, [11717] = true,
  -- Curse of Shadow
  [17862] = true, [17937] = true,
  -- Curse of Elements
  [1490] = true, [11721] = true, [11722] = true,
  -- Curse of Tongues
  [1714] = true, [11719] = true,
  -- Curse of Weakness
  [702] = true, [1108] = true, [6205] = true, [7646] = true, [11707] = true, [11708] = true,
  -- Curse of Exhaustion
  [18223] = true,
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

-- Track rank refreshes for pfUI integration
lib.rankRefreshOverrides = lib.rankRefreshOverrides or {}

-- Helper function to check if we should apply a debuff based on rank comparison
-- Returns: true (apply), false (skip), or {refresh=spellID, duration=X} (refresh higher rank)
-- Also removes lower/equal rank versions when applying a higher rank
function lib:ShouldApplyDebuffRank(targetGUID, newSpellID)
  if not targetGUID or not newSpellID then return true end

  -- Get base name and rank of new spell
  local newBaseName = lib:GetSpellBaseName(newSpellID)
  local newRank = lib:GetSpellRank(newSpellID)

  if not newBaseName then return true end

  -- Track highest existing rank and spell IDs to remove
  local highestExistingRank = 0
  local highestExistingSpellID = nil
  local highestExistingDuration = nil
  local spellIDsToRemove = {}

  -- Check all active debuffs on target for same base name
  if lib.objects[targetGUID] then
    for existingSpellID, rec in pairs(lib.objects[targetGUID]) do
      if rec and rec.start and rec.duration and existingSpellID ~= newSpellID then
        -- Check if debuff is still active
        local remaining = rec.duration + rec.start - GetTime()
        if remaining > 0 then
          -- Check if same spell (same base name)
          local existingBaseName = lib:GetSpellBaseName(existingSpellID)
          if existingBaseName == newBaseName then
            -- Same spell - track for potential removal
            local existingRank = lib:GetSpellRank(existingSpellID)

            if existingRank > highestExistingRank then
              highestExistingRank = existingRank
              highestExistingSpellID = existingSpellID
              highestExistingDuration = rec.duration
            end

            -- Mark all same-name spells for potential removal
            table.insert(spellIDsToRemove, existingSpellID)
          end
        end
      end
    end
  end

  -- If a higher rank exists, preserve its remaining time instead of blocking
  if newRank > 0 and highestExistingRank > 0 and newRank < highestExistingRank then
    -- Calculate remaining time on the higher rank
    local rec = lib.objects[targetGUID][highestExistingSpellID]
    local timeRemaining = rec.duration + rec.start - GetTime()

    -- Store refresh override for pfUI integration
    lib.rankRefreshOverrides[newBaseName] = {
      timestamp = GetTime(),
      targetGUID = targetGUID,
      lowerRankCast = newRank,
      higherRankActive = highestExistingRank,
      refreshSpellID = highestExistingSpellID,
      preservedTimeRemaining = timeRemaining
    }

    CleveRoids.DebugChanged("rank_preserve_" .. newBaseName .. "_" .. tostring(targetGUID),
      string.format("|cff00aaff[Rank Preserve]|r Cast %s Rank %d, preserving Rank %d timer (%.1fs remaining)",
        newBaseName, newRank, highestExistingRank, timeRemaining))

    -- Return special value indicating we should preserve the higher rank's timer
    return {
      preserve = highestExistingSpellID,
      timeRemaining = timeRemaining,
      targetGUID = targetGUID
    }
  end

  -- Remove all other ranks (lower or equal) before applying new rank
  if table.getn(spellIDsToRemove) > 0 then
    -- Get target name for pfUI cleanup
    local targetName = lib.guidToName[targetGUID]

    for _, removeID in ipairs(spellIDsToRemove) do
      if lib.objects[targetGUID][removeID] then
        local removeRank = lib:GetSpellRank(removeID)
        lib.objects[targetGUID][removeID] = nil

        if CleveRoids.debug then
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ff00[Rank Check]|r Removed %s (Rank %d) before applying Rank %d",
              newBaseName, removeRank, newRank)
          )
        end
      end
    end

    -- Also clean up pfUI's tracking to prevent it from showing old ranks
    if pfUI and pfUI.api and pfUI.api.libdebuff and targetName then
      local pflib = pfUI.api.libdebuff

      if pflib.objects and pflib.objects[targetName] then
        for level, effects in pairs(pflib.objects[targetName]) do
          if type(effects) == "table" and effects[newBaseName] then
            -- Remove the old rank entry from pfUI
            effects[newBaseName] = nil

            if CleveRoids.debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cff00ff00[Rank Check]|r Removed %s from pfUI tracking before applying new rank",
                  newBaseName)
              )
            end
            break
          end
        end
      end
    end
  end

  -- Apply the new rank
  return true
end

lib.learnCastTimers = lib.learnCastTimers or {}

CleveRoids_LearnedDurations = CleveRoids_LearnedDurations or {}

function lib:GetDuration(spellID, casterGUID, comboPoints)
  -- Check combo-specific learned durations first if this is a combo spell
  if comboPoints and CleveRoids_ComboDurations and CleveRoids_ComboDurations[spellID] then
    local comboDuration = CleveRoids_ComboDurations[spellID][comboPoints]
    if comboDuration and comboDuration > 0 then
      if CleveRoids.debug then
        local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cffccccff[DEBUG GetDuration]|r %s (ID:%d) CP:%d -> %ds (from learned combo)",
            spellName, spellID, comboPoints, comboDuration)
        )
      end
      return comboDuration
    end
  end

  -- Check caster-specific learned durations
  if casterGUID and CleveRoids_LearnedDurations and CleveRoids_LearnedDurations[spellID] then
    local learned = CleveRoids_LearnedDurations[spellID][casterGUID]
    if learned and learned > 0 then
      if CleveRoids.debug then
        local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cffccccff[DEBUG GetDuration]|r %s (ID:%d) -> %ds (from learned caster)",
            spellName, spellID, learned)
        )
      end
      return learned
    end
  end

  -- Fall back to static database
  local staticDur = self.durations[spellID] or 0
  if CleveRoids.debug and staticDur > 0 then
    local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
    DEFAULT_CHAT_FRAME:AddMessage(
      string.format("|cffccccff[DEBUG GetDuration]|r %s (ID:%d) -> %ds (from static DB)",
        spellName, spellID, staticDur)
    )
  end
  return staticDur
end

function lib:AddEffect(guid, unitName, spellID, duration, stacks, caster)
  if not guid or not spellID then return end

  -- Normalize GUID to string for consistent table key lookups
  guid = CleveRoids.NormalizeGUID(guid)
  if not guid then return end

  duration = duration or lib:GetDuration(spellID, caster)
  if duration <= 0 then return end

  lib.objects[guid] = lib.objects[guid] or {}
  lib.guidToName[guid] = unitName

  -- CURSE REPLACEMENT: Only one curse per caster can exist on a target
  -- When casting a new curse, remove all other curses from tracking for this target
  if lib.curseSpellIDs[spellID] then
    for trackedID, rec in pairs(lib.objects[guid]) do
      if lib.curseSpellIDs[trackedID] and trackedID ~= spellID then
        if CleveRoids.debug then
          local oldName = C_Spell.GetSpellName(trackedID) or "Unknown"
          local newName = C_Spell.GetSpellName(spellID) or "Unknown"
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff8800[Curse Replace]|r %s replaced by %s on %s",
              oldName, newName, unitName or "target"))
        end
        lib.objects[guid][trackedID] = nil
      end
    end
  end

  local rec = lib.objects[guid][spellID] or {}
  rec.spellID = spellID
  rec.start = GetTime()
  rec.duration = duration
  rec.stacks = stacks or 0
  rec.caster = caster

  lib.objects[guid][spellID] = rec

  -- OWN DEBUFFS TRACKING: Mirror pfUI's ownDebuffs structure for player casts
  -- When pfUI enhanced is active, pfUI handles ownDebuffs writes from its own
  -- SPELL_GO/AURA_CAST/DEBUFF_ADDED handlers. Without pfUI, we populate it here
  -- so lib.ownDebuffs has consistent data for downrank checks and debuff queries.
  if caster == "player" and not lib.hasPfUIEnhanced then
    local spellName = C_Spell.GetSpellName(spellID)
    if spellName then
      local spellRankStr = C_Spell.GetSpellSubtext(spellID)
      local rankNum = spellRankStr and tonumber((string.gsub(spellRankStr, "Rank ", ""))) or 0

      lib.ownDebuffs[guid] = lib.ownDebuffs[guid] or {}

      -- Downrank protection: don't overwrite a higher rank that's still active
      local existing = lib.ownDebuffs[guid][spellName]
      local blocked = false
      if existing and existing.rank and existing.spellId and existing.spellId ~= spellID then
        if rankNum > 0 and existing.rank > rankNum then
          local existingTimeleft = (existing.startTime + existing.duration) - GetTime()
          if existingTimeleft > 0 then
            blocked = true
          end
        end
      end

      if not blocked then
        local texture = lib:GetCachedIcon(spellID)
        lib.ownDebuffs[guid][spellName] = {
          startTime = GetTime(),
          duration = duration,
          texture = texture,
          rank = rankNum,
          spellId = spellID,
          stacks = stacks or 1,
        }
      end
    end
  end

  if CleveRoids.debug then
    local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
    CleveRoids.DebugChanged("addeffect_" .. spellID .. "_" .. tostring(guid),
      string.format("|cff00ffff[AddEffect]|r %s (ID:%d) %ds on %s, caster:%s",
        spellName, spellID, duration, unitName or "Unknown", caster or "nil"))
  end
end

-- timeleft is -1 when the aura's timing is unknown -- ClassicAPI reports
-- expirationTime 0 for an aura whose cast it never saw (one that predates login,
-- or a max-stack refresh whose cache entry has elapsed). -1 is what the manual
-- store returned for an untracked aura, so callers testing `timeleft > 0` are
-- unaffected; it means "no timer", not "expired".
local function RemainingFrom(expirationTime)
  if expirationTime and expirationTime > 0 then
    return expirationTime - GetTime()
  end
  return -1
end

-- Query debuff data by index, in libdebuff's return shape:
--   name, rank, texture, stacks, dispelType, duration, timeleft, caster
-- The index space is C_UnitAuras' dense HARMFUL range, walked to the first nil
-- at any index -- no 16-debuff / 32-buff split and no overflow rule, because
-- isHarmful is the aura's real polarity and a debuff parked in a buff slot
-- still reads harmful. The positional form allocates nothing per slot.
function lib:UnitDebuff(unit, id, filterCaster)
  local name, icon, count, dispelType, duration, expirationTime, source =
    C_UnitAuras.UnitDebuff(unit, id)
  if not name then return nil end
  if filterCaster and source ~= filterCaster then return nil end
  return name, nil, icon, count, dispelType, duration, RemainingFrom(expirationTime), source
end

-- Query buff data by index (helpful range).
function lib:UnitBuff(unit, id, filterCaster)
  local name, icon, count, dispelType, duration, expirationTime, source =
    C_UnitAuras.UnitBuff(unit, id)
  if not name then return nil end
  if filterCaster and source ~= filterCaster then return nil end
  return name, nil, icon, count, dispelType, duration, RemainingFrom(expirationTime), source
end

-- Find a player-cast debuff by spell ID. The PLAYER filter matches on
-- ClassicAPI's cached caster GUID, so an aura whose cast was never observed is
-- excluded -- the same answer the store's `caster == "player"` test gave, since
-- an unobserved cast was never recorded there either. One lookup, not a scan,
-- so the AuraData table it returns costs a single allocation.
function lib:FindPlayerDebuff(unit, spellID)
  local aura = C_UnitAuras.GetUnitAuraBySpellID(unit, spellID, "HARMFUL|PLAYER")
  if not aura then return nil end
  return aura.name, nil, aura.icon, aura.applications, aura.dispelName,
         aura.duration, RemainingFrom(aura.expirationTime), aura.sourceUnit
end

-- Find a player-cast buff by spell ID.
function lib:FindPlayerBuff(unit, spellID)
  local aura = C_UnitAuras.GetUnitAuraBySpellID(unit, spellID, "HELPFUL|PLAYER")
  if not aura then return nil end
  return aura.name, nil, aura.icon, aura.applications, aura.dispelName,
         aura.duration, RemainingFrom(aura.expirationTime), aura.sourceUnit
end

local function SeedUnit(unit)
  local guid = CleveRoids.GetGUID(unit)
  if not guid then return end
  local unitName = UnitName(unit)

  for i=1, 16 do
    local tex, stacks, dtype, spellID = UnitDebuff(unit, i)
    if not tex then break end

    if spellID then
      -- CURSIVE ARCHITECTURE: Skip personal debuffs - they should only be tracked via UNIT_CASTEVENT
      -- Only track shared debuffs in SeedUnit (e.g., Sunder Armor, Thunder Clap)
      if lib:IsPersonalDebuff(spellID) then
        -- Skip this debuff - it should only come from UNIT_CASTEVENT
      else
        local duration = lib:GetDuration(spellID)
        if duration > 0 then
          -- SHARED DEBUFFS: Check if already tracked and handle refresh detection
          -- Player's casts are tracked via UNIT_CASTEVENT, but OTHER players' casts
          -- only trigger UNIT_AURA events. Detect refreshes via stack count changes.
          local existing = lib.objects[guid] and lib.objects[guid][spellID]

          if existing and existing.start and existing.duration then
            -- Already tracked - check if debuff was refreshed (by player or others)
            if existing.stacks ~= stacks then
              local oldStacks = existing.stacks or 0
              existing.stacks = stacks

              -- If stacks INCREASED, debuff was refreshed - reset timer to full duration
              -- This catches refreshes from other players (we can't detect via UNIT_CASTEVENT)
              if (stacks or 0) > oldStacks then
                existing.start = GetTime()
                existing.duration = duration

                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffaaff00[DEBUG SeedUnit Debuff]|r %s (ID:%d) stack increased %d->%d, timer RESET to %ds (refresh detected)",
                      spellName, spellID, oldStacks, stacks or 0, duration)
                  )
                end
              else
                -- Stacks decreased (shouldn't happen normally) - just update stacks, preserve timer
                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffaaff00[DEBUG SeedUnit Debuff]|r %s (ID:%d) updated stacks to %d (timer preserved)",
                      spellName, spellID, stacks or 0)
                  )
                end
              end
            end
            -- NOTE: When stacks stay the same (e.g., already at 5/5 Sunder), we can't detect
            -- refreshes from other players. This is a fundamental limitation without server-side
            -- duration data. The timer continues from the last known refresh.
          else
            -- First time seeing this debuff - add with full duration
            -- Check for combo spell duration
            if CleveRoids.IsComboScalingSpellID and CleveRoids.IsComboScalingSpellID(spellID) and
               CleveRoids_ComboDurations and CleveRoids_ComboDurations[spellID] then
              -- Use the longest learned duration (assume 5 CP)
              for cp = 5, 1, -1 do
                if CleveRoids_ComboDurations[spellID][cp] then
                  duration = CleveRoids_ComboDurations[spellID][cp]
                  if CleveRoids.debug then
                    local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                    DEFAULT_CHAT_FRAME:AddMessage(
                      string.format("|cffaaff00[DEBUG SeedUnit Debuff]|r %s (ID:%d) using learned %dCP duration:%ds",
                        spellName, spellID, cp, duration)
                    )
                  end
                  break
                end
              end
            end
            lib:AddEffect(guid, unitName, spellID, duration, stacks, nil)
          end
        end
      end
    end
  end

  for i=1, 32 do
    local tex, stacks, spellID = UnitBuff(unit, i)
    if not tex then break end

    if spellID then
      -- CURSIVE ARCHITECTURE: Skip personal debuffs in overflow buff slots
      -- Only track shared debuffs in SeedUnit
      if lib:IsPersonalDebuff(spellID) then
        -- Skip this debuff - it should only come from UNIT_CASTEVENT
      else
        local duration = lib:GetDuration(spellID)
        if duration > 0 then
          -- SHARED DEBUFFS (overflow): Check if already tracked and handle refresh detection
          -- Same logic as regular debuff slots - detect refreshes via stack count changes.
          local existing = lib.objects[guid] and lib.objects[guid][spellID]

          if existing and existing.start and existing.duration then
            -- Already tracked - check if debuff was refreshed (by player or others)
            if existing.stacks ~= stacks then
              local oldStacks = existing.stacks or 0
              existing.stacks = stacks

              -- If stacks INCREASED, debuff was refreshed - reset timer to full duration
              if (stacks or 0) > oldStacks then
                existing.start = GetTime()
                existing.duration = duration

                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffaaff00[DEBUG SeedUnit Buff]|r %s (ID:%d) stack increased %d->%d, timer RESET to %ds (refresh detected)",
                      spellName, spellID, oldStacks, stacks or 0, duration)
                  )
                end
              else
                -- Stacks decreased (shouldn't happen normally) - just update stacks, preserve timer
                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffaaff00[DEBUG SeedUnit Buff]|r %s (ID:%d) updated stacks to %d (timer preserved)",
                      spellName, spellID, stacks or 0)
                  )
                end
              end
            end
          else
            -- First time seeing this debuff - add with full duration
            -- Check for combo spell duration
            if CleveRoids.IsComboScalingSpellID and CleveRoids.IsComboScalingSpellID(spellID) and
               CleveRoids_ComboDurations and CleveRoids_ComboDurations[spellID] then
              -- Use the longest learned duration (assume 5 CP)
              for cp = 5, 1, -1 do
                if CleveRoids_ComboDurations[spellID][cp] then
                  duration = CleveRoids_ComboDurations[spellID][cp]
                  if CleveRoids.debug then
                    local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
                    DEFAULT_CHAT_FRAME:AddMessage(
                      string.format("|cffaaff00[DEBUG SeedUnit Buff]|r %s (ID:%d) using learned %dCP duration:%ds",
                        spellName, spellID, cp, duration)
                    )
                  end
                  break
                end
              end
            end
            lib:AddEffect(guid, unitName, spellID, duration, stacks, nil)
          end
        end
      end
    end
  end
end

-- Personal debuff pending tracking system
-- Stores personal debuffs to be added after 0.5s delay (to verify they weren't dodged/parried/blocked)
-- Format: { [index] = { timestamp = GetTime(), targetGUID = guid, targetName = name, spellID = id, duration = X, comboPoints = CP } }
lib.pendingPersonalDebuffs = lib.pendingPersonalDebuffs or {}

-- CC (Crowd Control) pending tracking system
-- Stores CC spells to verify they landed (for immunity detection)
-- Format: { [index] = { timestamp = GetTime(), targetGUID = guid, targetName = name, spellID = id, ccType = "stun", immunityType = "stun", drType = "stun_control" } }
lib.pendingCCDebuffs = lib.pendingCCDebuffs or {}

-- Shared debuff pending tracking system
-- Stores shared debuffs to verify they landed (for immunity detection by spell school)
-- Format: { [index] = { timestamp = GetTime(), targetGUID = guid, targetName = name, spellID = id, school = "arcane", duration = X, stacks = N } }
lib.pendingSharedDebuffs = lib.pendingSharedDebuffs or {}

-- Spells with HIDDEN CC debuffs - these apply CC effects but don't show visible debuffs
-- Pounce stun is hidden - the target is stunned but no debuff icon appears
-- These spells use extended verification (0.4s instead of 0.2s) to allow time for:
--   1. "afflicted by" combat log messages to arrive and confirm success
--   2. Mechanic-based ValidateUnitCC check (if the stun is internally tracked)
-- If neither confirms the CC landed, immunity is recorded
lib.hiddenCCSpells = {
  [9005] = true,   -- Pounce (Rank 1)
  [9823] = true,   -- Pounce (Rank 2)
  [9827] = true,   -- Pounce (Rank 3)
}

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

-- Frame for delayed personal debuff tracking and judgement scanning

-- PERFORMANCE: Upvalues for frequently called functions
local _GetTime = GetTime
local _UnitExists = UnitExists
local _UnitDebuff = UnitDebuff
local _IsUnitDead = CleveRoids.IsUnitDead
local _UnitName = UnitName
local _GetSpellRecField = GetSpellRecField
local _string_find = string.find
local _string_format = string.format
local _string_sub = string.sub
local _tostring = tostring
local _next = next
local _pairs = pairs
local _getn = table.getn  -- Lua 5.0 compatible table length
local _table_insert = table.insert  -- Lua 5.0 compatible

-- PERFORMANCE: Static buffers for removal tracking - reused every frame
-- Using mark-and-sweep pattern instead of table.remove() for O(1) removal
local _pendingPersonalBuffer = {}
local _pendingCCBuffer = {}
local _pendingSharedBuffer = {}

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

-- PERFORMANCE: Throttling - run at 20Hz max instead of every frame (60+Hz)
-- Minimum delay is 0.2s, so 20Hz (50ms) gives us 4 checks per minimum delay
local _lastDelayedTrackingUpdate = 0
local _DELAYED_TRACKING_INTERVAL = 0.05  -- 50ms = 20Hz

local delayedTrackingFrame = CreateFrame("Frame", "CleveRoidsDelayedTrackingFrame", UIParent)
delayedTrackingFrame:SetScript("OnUpdate", function()
  -- PERFORMANCE: Throttle updates - most pending items have 0.2-0.5s delays anyway
  local currentTime = _GetTime()
  if (currentTime - _lastDelayedTrackingUpdate) < _DELAYED_TRACKING_INTERVAL then
    return
  end
  _lastDelayedTrackingUpdate = currentTime

  -- Process deferred guidToName cleanups
  if lib._guidNameCleanupQueue then
    local i = 1
    while i <= table.getn(lib._guidNameCleanupQueue) do
      local entry = lib._guidNameCleanupQueue[i]
      if entry and currentTime >= entry.expiry then
        -- Only remove if no active tracking data references this GUID
        if not (lib.ownDebuffs[entry.guid] or lib.pendingCasts[entry.guid]) then
          lib.guidToName[entry.guid] = nil
        end
        table.remove(lib._guidNameCleanupQueue, i)
      else
        i = i + 1
      end
    end
  end

  -- PERFORMANCE: Early exit if all queues are empty
  -- NOTE: Use next() instead of [1] to handle array holes from table.remove()
  -- Array holes can occur when combat log handlers remove entries mid-iteration
  local hasPersonal = lib.pendingPersonalDebuffs and _next(lib.pendingPersonalDebuffs)
  local hasCC = lib.pendingCCDebuffs and _next(lib.pendingCCDebuffs)
  local hasShared = lib.pendingSharedDebuffs and _next(lib.pendingSharedDebuffs)
  local hasOverrides = lib.rankRefreshOverrides and _next(lib.rankRefreshOverrides)

  -- DEBUG: Track pending queue state (keyed — only prints on change)
  if CleveRoids.debug then
    local sharedCount = lib.pendingSharedDebuffs and _getn(lib.pendingSharedDebuffs) or 0
    local personalCount = lib.pendingPersonalDebuffs and _getn(lib.pendingPersonalDebuffs) or 0
    if sharedCount > 0 then
      CleveRoids.DebugChanged("pending_shared",
        _string_format("|cffaaaaaa[Pending Queue]|r shared:%d personal:%d",
          sharedCount, personalCount))
    elseif CleveRoids._lastDebugState["pending_shared"] then
      CleveRoids._lastDebugState["pending_shared"] = nil
    end
    if personalCount > 0 then
      CleveRoids.DebugChanged("pending_personal",
        _string_format("|cffaaaaaa[Personal Queue]|r count:%d",
          personalCount))
    elseif CleveRoids._lastDebugState["pending_personal"] then
      CleveRoids._lastDebugState["pending_personal"] = nil
    end
  end

  if not (hasPersonal or hasCC or hasShared or hasOverrides) then
    return
  end

  -- Cache frequently accessed values
  local hasSuperwow = CleveRoids.hasSuperwow
  local hasExtendedTokens = CleveRoids.NampowerAPI and CleveRoids.NampowerAPI.features
      and CleveRoids.NampowerAPI.features.hasExtendedUnitTokens
  local debug = CleveRoids.debug

  -- Resolve a GUID to a queryable unit token
  -- SuperWoW: returns GUID directly (SuperWoW extends WoW APIs to accept GUIDs)
  -- Nampower v2.41+ extended tokens: GUID works as unit token if unit is in range
  -- Fallback: returns "target" if GUID matches current target, nil otherwise
  local function ResolveGUIDUnit(guid)
    if not guid then return nil end
    if hasSuperwow then return guid end
    if hasExtendedTokens and _UnitExists(guid) then return guid end
    local ctGUID = CleveRoids.GetGUID("target")
    if ctGUID and ctGUID == guid then
      return "target"
    end
    return nil
  end

  -- Process pending personal debuffs
  if hasPersonal then
    -- Count entries properly using pairs (handles array holes)
    local pendingCount = 0
    for _ in _pairs(lib.pendingPersonalDebuffs) do
      pendingCount = pendingCount + 1
    end

    if debug and pendingCount > 0 then
      CleveRoids.DebugChanged("pending_debug",
        _string_format("|cffaaaaaa[Pending Debug]|r %d personal debuffs waiting", pendingCount))
    end

    -- Use pairs() to iterate and rebuild without holes
    -- This handles array holes created by table.remove() in combat log handlers
    local newPendingList = {}

    for _, pending in _pairs(lib.pendingPersonalDebuffs) do
      -- Process each entry (pairs handles holes correctly)
      if pending then
      local elapsed = currentTime - pending.timestamp

      -- Add debuff after 0.2 second delay (enough time for server sync)
      if elapsed >= 0.2 then
        -- DEBUFF IMMUNITY VERIFICATION: Check if debuff actually appeared
        -- This happens AFTER the delay, giving the server time to sync the debuff
        local isBleedSpell = CleveRoids.BleedSpellIDs and CleveRoids.BleedSpellIDs[pending.spellID]
        local debuffVerified = true

        -- SPELL_GO confirmed miss → debuff definitely didn't land (any spell type)
        -- Immunity is recorded by SPELL_MISSED → ProcessSpellMissSelf → RecordImmunity
        if pending.spellGoMissed then
          debuffVerified = false
          if debug then
            local spellNameDbg = C_Spell.GetSpellName(pending.spellID) or "Unknown"
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cffff6600[Personal Miss]|r %s (ID:%d) missed on %s - SPELL_GO confirmed miss",
                spellNameDbg, pending.spellID, pending.targetName or "Unknown")
            )
          end
        end

        -- DEBUG: Log verification attempt for bleed spells
        if debug and isBleedSpell and not pending.spellGoMissed then
          local spellNameDbg = C_Spell.GetSpellName(pending.spellID) or "Unknown"
          DEFAULT_CHAT_FRAME:AddMessage(
            _string_format("|cff00aaff[Bleed Verify Start]|r %s (ID:%d) on %s - hasSuperwow:%s, targetGUID:%s",
              spellNameDbg, pending.spellID, pending.targetName or "Unknown",
              hasSuperwow and "yes" or "NO", pending.targetGUID and "exists" or "NIL")
          )
        end

        local verifyUnit = isBleedSpell and not pending.spellGoMissed
          and pending.targetGUID and ResolveGUIDUnit(pending.targetGUID) or nil
        if isBleedSpell and verifyUnit then
          -- Check if mob is in bleed whitelist (skip verification for known bleeders)
          local isWhitelisted = CleveRoids.MobsThatBleed and CleveRoids.MobsThatBleed[pending.targetGUID]

          if not isWhitelisted then
            -- Check if target is dead - requires special handling
            if _IsUnitDead(verifyUnit) then
              -- Target died - check if we saw "afflicted by" message before death
              if pending.verifiedByAffliction then
                -- We confirmed bleed landed via combat log before target died
                if debug then
                  local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Bleed"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    _string_format("|cff00ff00[Bleed Verified]|r %s on %s confirmed via 'afflicted by' (target now dead)",
                      spellNameDebug, pending.targetName or "Unknown")
                  )
                end
              else
                -- Target died WITHOUT "afflicted by" message
                -- BUT: Don't record immunity for one-shot kills!
                -- If target died within 0.5s of cast, the bleed didn't have time to apply
                -- even on a valid target. We can't determine immunity from instant kills.
                local timeSinceCast = currentTime - pending.timestamp
                local ONE_SHOT_THRESHOLD = 0.5  -- seconds

                if timeSinceCast < ONE_SHOT_THRESHOLD then
                  -- One-shot kill - can't determine immunity, skip recording
                  -- Set debuffVerified=false so we don't add to tracking or remove existing immunity
                  debuffVerified = false
                  if debug then
                    local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Bleed"
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[Bleed Skip]|r %s on %s - target died too quickly (%.2fs), can't determine immunity",
                        spellNameDebug, pending.targetName or "Unknown", timeSinceCast)
                    )
                  end
                  -- Note: We set debuffVerified = false but DON'T record immunity
                  -- This is intentional - one-shots are inconclusive
                else
                  -- Target died without "afflicted by" — inconclusive, don't record immunity.
                  -- "afflicted by" combat log messages can be delayed/throttled, so absence
                  -- is not proof of immunity. SPELL_MISSED handles true immunity detection.
                  debuffVerified = false
                  if debug then
                    local spellNameForImmunity = C_Spell.GetSpellName(pending.spellID) or "Bleed"
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[Bleed Inconclusive]|r %s on %s - target died without 'afflicted by' (%.2fs), not recording immunity",
                        spellNameForImmunity, pending.targetName or "Unknown", timeSinceCast)
                    )
                  end
                end
              end
            elseif not UnitExists(verifyUnit) then
              -- Target despawned or GUID is invalid - can't verify, skip without recording immunity
              -- This is similar to one-shot kills: inconclusive result, don't record immunity
              debuffVerified = false
              if debug then
                local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Bleed"
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cffaaaaaa[Bleed Skip]|r %s on %s - target no longer exists (despawned), can't determine immunity",
                    spellNameDebug, pending.targetName or "Unknown")
                )
              end
              -- Note: We set debuffVerified = false but DON'T record immunity
              -- This is intentional - despawned targets are inconclusive
            else
              -- Target is alive - check debuffs for bleed spell
              debuffVerified = false
              local totalDebuffs = 0

              for slot = 1, 48 do
                local _, _, _, debuffSpellID = _UnitDebuff(verifyUnit, slot)
                if not debuffSpellID then
                  if slot <= 16 then break end  -- Regular debuffs are dense, overflow continues on nil
                else
                  totalDebuffs = totalDebuffs + 1
                  if debuffSpellID == pending.spellID then
                    debuffVerified = true
                    -- Don't break - continue counting total debuffs for immunity vs cap detection
                  end
                end
              end

              -- If bleed is missing and target has few debuffs, it's likely immunity (not debuff cap)
              if not debuffVerified then
                local DEBUFF_CAP_THRESHOLD = 47  -- Max is 48 (16 visible + 32 overflow)
                -- Guard: don't record immunity for player targets (PvP resists, trinkets, etc.)
                local isPlayer = UnitIsPlayer(verifyUnit)
                -- Guard: don't record if target has temporary immunity buff
                local immunityBuff = not isPlayer and HasImmunityGrantingBuff(verifyUnit)
                if isPlayer then
                  if debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[Bleed Skip]|r Player target %s - not recording immunity",
                        pending.targetName or "Unknown")
                    )
                  end
                elseif immunityBuff then
                  if debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[Bleed Skip]|r %s has %s - not recording immunity",
                        pending.targetName or "Unknown", immunityBuff)
                    )
                  end
                elseif totalDebuffs < DEBUFF_CAP_THRESHOLD then
                  -- Few debuffs = likely bleed immunity, not debuff cap
                  if pending.targetName and pending.targetName ~= "" then
                    -- Record as BLEED immunity directly (bypass split damage override in RecordImmunity)
                    -- RecordImmunity would record Rake/Pounce as "physical" (initial school),
                    -- but we specifically detected the BLEED debuff didn't land
                    local spellNameForImmunity = C_Spell.GetSpellName(pending.spellID) or "Bleed"

                    if not CleveRoids_ImmunityData["bleed"] then
                      CleveRoids_ImmunityData["bleed"] = {}
                    end
                    CleveRoids_ImmunityData["bleed"][pending.targetName] = true

                    CleveRoids.DebugChanged("bleed_immune_" .. _tostring(pending.targetName),
                      _string_format("|cffff6600[Bleed Immunity]|r %s is immune to bleed (%s) - only %d debuffs on target",
                        pending.targetName, spellNameForImmunity, totalDebuffs))
                  end
                else
                  CleveRoids.DebugChanged("bleed_cap_" .. _tostring(pending.targetName) .. "_" .. pending.spellID,
                    _string_format("|cffff6600[Debuff Cap]|r %s not found on %s - likely pushed off (%d debuffs on target)",
                      C_Spell.GetSpellName(pending.spellID) or "Bleed", pending.targetName or "Unknown", totalDebuffs))
                end
              end
            end
          end
        end

        -- NON-BLEED VERIFICATION: Verify non-bleed personal debuffs actually applied
        -- Always verify even when spellGoHit=true: SPELL_GO "hit" means initial damage landed,
        -- not that the DoT was applied (e.g., lower rank Moonfire deals initial damage but DoT
        -- is blocked by "a more powerful spell is already active")
        if not isBleedSpell and debuffVerified and not pending.spellGoMissed then
          -- Fast path: use pfUI's downrank-protected ownDebuffs table when available
          -- pfUI blocks lower-rank overwrites, so if ownDebuffs still has a higher rank
          -- with time remaining, the lower rank DoT didn't apply
          local downrankBlocked = false
          if lib.ownDebuffs and pending.targetGUID then
            local spellName = C_Spell.GetSpellName(pending.spellID)
            if spellName then
              local existing = lib.ownDebuffs[pending.targetGUID] and lib.ownDebuffs[pending.targetGUID][spellName]
              if existing and existing.rank and existing.spellId and existing.spellId ~= pending.spellID then
                local pendingRankStr = C_Spell.GetSpellSubtext(pending.spellID)
                local pendingRank = pendingRankStr and tonumber((string.gsub(pendingRankStr, "Rank ", ""))) or 0
                if pendingRank > 0 and existing.rank > pendingRank then
                  local existingTimeleft = (existing.startTime + existing.duration) - GetTime()
                  if existingTimeleft > 0 then
                    downrankBlocked = true
                    debuffVerified = false
                    CleveRoids.DebugChanged("downrank_" .. pending.spellID .. "_" .. _tostring(pending.targetGUID),
                      _string_format("|cffff6600[Downrank Blocked]|r %s Rank %d blocked by Rank %d (%.1fs left)",
                        spellName, pendingRank, existing.rank, existingTimeleft))
                  end
                end
              end
            end
          end

          -- Non-pfUI fallback: check lib.objects for a higher rank of the same spell
          if not downrankBlocked and lib.objects and pending.targetGUID and lib.objects[pending.targetGUID] then
            local pendingBaseName = lib.GetSpellBaseName and lib:GetSpellBaseName(pending.spellID)
            local pendingRank = lib.GetSpellRank and lib:GetSpellRank(pending.spellID)
            if pendingBaseName and pendingRank > 0 then
              for existingSID, rec in pairs(lib.objects[pending.targetGUID]) do
                if existingSID ~= pending.spellID and rec and rec.caster == "player"
                  and rec.start and rec.duration then
                  local remaining = rec.duration + rec.start - GetTime()
                  if remaining > 0 then
                    local existingBaseName = lib:GetSpellBaseName(existingSID)
                    if existingBaseName == pendingBaseName then
                      local existingRank = lib:GetSpellRank(existingSID)
                      if existingRank > pendingRank then
                        downrankBlocked = true
                        debuffVerified = false
                        CleveRoids.DebugChanged("downrank_obj_" .. pending.spellID .. "_" .. _tostring(pending.targetGUID),
                          _string_format("|cffff6600[Downrank Blocked]|r %s Rank %d blocked by Rank %d in lib.objects (%.1fs left)",
                            pendingBaseName, pendingRank, existingRank, remaining))
                        break
                      end
                    end
                  end
                end
              end
            end
          end

          local nonBleedVerifyUnit = not downrankBlocked
            and pending.targetGUID and ResolveGUIDUnit(pending.targetGUID) or nil
          if nonBleedVerifyUnit then
            if _IsUnitDead(nonBleedVerifyUnit) then
              -- Target died - can't verify, assume landed
              if debug then
                local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Debuff"
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cffaaaaaa[NonBleed Skip]|r %s on %s - target dead, assuming landed",
                    spellNameDebug, pending.targetName or "Unknown")
                )
              end
            elseif not UnitExists(nonBleedVerifyUnit) then
              -- Target despawned - inconclusive, don't add to tracking
              debuffVerified = false
              if debug then
                local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Debuff"
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cffaaaaaa[NonBleed Skip]|r %s on %s - target despawned, can't verify",
                    spellNameDebug, pending.targetName or "Unknown")
                )
              end
            else
              -- Target is alive - check if debuff exists
              local nonBleedFound = false
              local totalDebuffs = 0

              for slot = 1, 48 do
                local _, _, _, debuffSpellID = _UnitDebuff(nonBleedVerifyUnit, slot)
                if not debuffSpellID then
                  if slot <= 16 then break end  -- Regular debuffs are dense, overflow continues on nil
                else
                  totalDebuffs = totalDebuffs + 1
                  if debuffSpellID == pending.spellID then
                    nonBleedFound = true
                    -- Don't break - continue counting for immunity vs cap detection
                  end
                end
              end

              if not nonBleedFound then
                debuffVerified = false
                local DEBUFF_CAP_THRESHOLD = 47
                local isPlayer = UnitIsPlayer(nonBleedVerifyUnit)
                local immunityBuff = not isPlayer and HasImmunityGrantingBuff(nonBleedVerifyUnit)
                if isPlayer then
                  if debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[NonBleed Skip]|r Player target %s - not recording immunity",
                        pending.targetName or "Unknown")
                    )
                  end
                elseif immunityBuff then
                  if debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[NonBleed Skip]|r %s has %s - not recording immunity",
                        pending.targetName or "Unknown", immunityBuff)
                    )
                  end
                elseif totalDebuffs < DEBUFF_CAP_THRESHOLD then
                  -- Few debuffs = likely school immunity, not debuff cap
                  -- Use RecordImmunity for proper DBC school lookup (with bleed override)
                  if pending.targetName and pending.targetName ~= "" then
                    CleveRoids.RecordImmunity(pending.targetName, nil, nil, pending.spellID)
                    CleveRoids.DebugChanged("nonbleed_immune_" .. _tostring(pending.targetName) .. "_" .. pending.spellID,
                      _string_format("|cffff6600[NonBleed Immunity]|r %s is immune to %s - only %d debuffs on target",
                        pending.targetName, C_Spell.GetSpellName(pending.spellID) or "Debuff", totalDebuffs))
                  end
                else
                  CleveRoids.DebugChanged("nonbleed_cap_" .. _tostring(pending.targetName) .. "_" .. pending.spellID,
                    _string_format("|cffff6600[NonBleed Debuff Cap]|r %s not found on %s - likely pushed off (%d debuffs)",
                      C_Spell.GetSpellName(pending.spellID) or "Debuff", pending.targetName or "Unknown", totalDebuffs))
                end
              end
            end
          end
          -- If no verifyUnit (can't resolve GUID), debuffVerified stays true (can't verify)
        end

        -- Only apply the debuff to tracking if it was verified (or not a bleed/was whitelisted)
        if debuffVerified then
          -- Debug: Show what we're about to add to tracking
          if debug then
            local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Unknown"
            local guidStr = _string_sub(_tostring(pending.targetGUID or "nil"), 1, 20)
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff88ff88[Pending Process]|r Adding %s (ID:%d, %ds) GUID:%s",
                spellNameDebug, pending.spellID, pending.duration or 0, guidStr)
            )
          end

          lib:AddEffect(pending.targetGUID, pending.targetName, pending.spellID, pending.duration, 0, "player")

          -- Remove any existing bleed immunity record for this NPC ONLY if a bleed spell landed
          -- Previously this unconditionally removed bleed immunity for ANY personal debuff
          if isBleedSpell and pending.targetName and pending.targetName ~= "" then
            CleveRoids.RemoveSpellImmunity(pending.targetName, "bleed")
          end

          if debug then
            local spellName = C_Spell.GetSpellName(pending.spellID) or "Unknown"
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff00ff00[Delayed Track]|r Applied %s (ID:%d) to tracking on %s",
                spellName, pending.spellID, pending.targetName or "Unknown")
            )
          end
        end
        -- Item processed, don't add to new list
      else
        -- Item not ready, keep it in the new list
        _table_insert(newPendingList, pending)
      end
      end -- if pending
    end

    -- Replace old list with compacted new list (no holes)
    lib.pendingPersonalDebuffs = newPendingList
  end

  -- Process pending CC debuffs for immunity detection
  if hasCC then
    -- Use pairs() to iterate and rebuild without holes (same fix as personal debuffs)
    local newPendingList = {}

    for _, pending in _pairs(lib.pendingCCDebuffs) do
      -- Process each entry (pairs handles holes correctly)
      if pending then
      local elapsed = currentTime - pending.timestamp

      -- Check after delay: 0.4s for hidden CC (no visible debuff), 0.2s for normal CC
      -- Hidden CC (e.g., Pounce stun) needs longer delay to wait for "afflicted by" messages
      local verifyDelay = pending.isHiddenCC and 0.4 or 0.2

      -- Drop stale entries (>2s) without recording immunity - inconclusive due to severe lag
      if elapsed > 2.0 then
        if debug then
          DEFAULT_CHAT_FRAME:AddMessage(
            _string_format("|cffff6600[CC Stale]|r Dropping stale CC entry for %s on %s (%.1fs old)",
              pending.ccType or "CC", pending.targetName or "Unknown", elapsed)
          )
        end
        -- Don't add to newPendingList - silently discard
      elseif elapsed >= verifyDelay then
        local ccVerified = false
        local totalDebuffs = 0

        -- Check if already verified via "afflicted by" combat log message
        -- This happens for hidden CC spells like Pounce when the message arrives first
        if pending.verifiedByAffliction then
          ccVerified = true
        end

        -- SPELL_GO early-exit: Use definitive hit/miss data when available
        -- This is faster and more reliable than debuff scanning, and handles debuff cap correctly
        if not ccVerified and pending.spellGoHit then
          ccVerified = true
          if debug then
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff00ff00[CC Verified via SPELL_GO]|r %s landed on %s - skipping debuff scan",
                pending.ccType or "CC", pending.targetName or "Unknown")
            )
          end
        end

        -- CC IMMUNITY VERIFICATION: Check if CC effect actually landed
        -- Uses hybrid approach: direct spell ID match OR mechanic-based validation
        -- (CC debuff IDs often differ from cast IDs, e.g., Pounce cast ≠ Pounce Stun debuff)
        -- Guard: skip debuff scanning if SPELL_GO already determined outcome
        local ccVerifyUnit = not ccVerified and not pending.spellGoHit and not pending.spellGoMissed
          and pending.targetGUID and ResolveGUIDUnit(pending.targetGUID) or nil
        if ccVerifyUnit then
          -- Skip verification if target is dead (debuffs are removed on death)
          if _IsUnitDead(ccVerifyUnit) then
            ccVerified = true  -- Assume CC landed, can't verify on dead target
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffff6600[CC Verify Skip]|r Target %s is dead - skipping immunity check for %s",
                  pending.targetName or "Unknown", pending.ccType or "CC")
              )
            end
          else
            -- Method 1: Direct spell ID matching (scan debuffs for exact spell ID)
            if pending.spellID then
              for slot = 1, 48 do
                local texture, _, _, debuffSpellID = _UnitDebuff(ccVerifyUnit, slot)
                if not texture then
                  if slot <= 16 then break end  -- Regular debuffs are dense, overflow continues on nil
                else
                  totalDebuffs = totalDebuffs + 1
                  -- Debug: Show each debuff found during CC verification
                  if debug then
                    local debuffName = C_Spell.GetSpellName(debuffSpellID) or "Unknown"
                    local mechanic = CleveRoids.GetSpellMechanic and CleveRoids.GetSpellMechanic(debuffSpellID) or 0
                    DEFAULT_CHAT_FRAME:AddMessage(
                      _string_format("|cffaaaaaa[CC Scan]|r Slot %d: %s (ID:%d, Mech:%d) - Looking for %s (ID:%d)",
                        slot, debuffName, debuffSpellID or 0, mechanic, pending.spellName or "CC", pending.spellID or 0)
                    )
                  end
                  if debuffSpellID == pending.spellID then
                    ccVerified = true
                    -- Don't break - continue counting total debuffs for immunity vs cap detection
                  end
                end
              end
            end

            -- Method 2: Mechanic-based validation (fallback if spell ID not found)
            -- CC debuff IDs often differ from cast IDs (e.g., Pounce stun uses different ID)
            -- Check if target has ANY debuff of the correct CC type (stun, fear, etc.)
            if not ccVerified and pending.ccType and CleveRoids.ValidateUnitCC then
              if debug then
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cffaaaa00[CC Verify]|r Direct ID match failed, trying mechanic check for %s...",
                    pending.ccType)
                )
              end
              ccVerified = CleveRoids.ValidateUnitCC(ccVerifyUnit, pending.ccType)
              if debug then
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cff00aaff[CC Verify]|r Mechanic check result: %s",
                    ccVerified and "FOUND" or "NOT FOUND")
                )
              end
            end
          end
        end

        if not ccVerified and pending.spellGoMissed and debug then
          DEFAULT_CHAT_FRAME:AddMessage(
            _string_format("|cffff6600[CC Missed via SPELL_GO]|r %s missed on %s - checking immunity",
              pending.ccType or "CC", pending.targetName or "Unknown")
          )
        end

        -- If CC didn't land, check if it's immunity or debuff cap
        if not ccVerified and ccVerifyUnit and not _IsUnitDead(ccVerifyUnit) then
          -- Guard: don't record immunity for player targets (PvP trinkets, resists, etc.)
          if UnitIsPlayer(ccVerifyUnit) then
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffaaaaaa[CC Skip]|r Player target %s - not recording %s immunity",
                  pending.targetName or "Unknown", pending.ccType or "CC")
              )
            end
          -- Guard: don't record if target has temporary immunity buff
          elseif HasImmunityGrantingBuff(ccVerifyUnit) then
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffaaaaaa[CC Skip]|r %s has immunity buff - not recording %s immunity",
                  pending.targetName or "Unknown", pending.ccType or "CC")
              )
            end
          else
          -- totalDebuffs already counted above, reuse it
          if totalDebuffs == 0 then
            -- Count wasn't done (dead target check skipped counting), do it now
            for slot = 1, 48 do
              local texture, _, _, debuffSpellID = _UnitDebuff(ccVerifyUnit, slot)
              if not texture then
                if slot <= 16 then break end
              else
                totalDebuffs = totalDebuffs + 1
              end
            end
          end

          -- Try to get target name if we don't have it (might have been a focus/mouseover cast)
          local resolvedTargetName = pending.targetName
          if (not resolvedTargetName or resolvedTargetName == "") and pending.targetGUID then
            -- Try to get from GUID cache
            resolvedTargetName = lib.guidToName[pending.targetGUID]
            -- Try to resolve from current target
            if not resolvedTargetName then
              local currentTargetGUID = CleveRoids.GetGUID("target")
              if currentTargetGUID and currentTargetGUID == pending.targetGUID then
                resolvedTargetName = _UnitName("target")
                lib.guidToName[pending.targetGUID] = resolvedTargetName
              end
            end
            -- Try to resolve using SuperWoW or Nampower extended tokens GUID-based query
            if not resolvedTargetName and (hasSuperwow or hasExtendedTokens) then
              if _UnitExists(pending.targetGUID) then
                local name = _UnitName(pending.targetGUID)
                if name and name ~= "Unknown" then
                  resolvedTargetName = name
                  lib.guidToName[pending.targetGUID] = resolvedTargetName
                end
              end
            end
          end

          local DEBUFF_CAP_THRESHOLD = 47  -- Max is 48 (16 visible + 32 overflow)

          -- SPLIT CC SPELLS: Skip immunity recording for spells with physical damage + resistable CC
          -- (e.g., Master Strike) - physical damage lands but CC can be resisted independently
          -- spellGoHit: SPELL_GO confirmed hit, so CC was resisted independently (not true immunity)
          local isSplitCCSpell = SPLIT_CC_SPELLS[pending.spellID] or pending.spellGoHit
          if isSplitCCSpell then
            if debug then
              local spellNameDebug = pending.spellName or (C_Spell.GetSpellName(pending.spellID) or "Unknown")
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cff00aaff[Split CC Skip]|r %s CC resisted on %s - skipping CC immunity recording",
                  spellNameDebug, resolvedTargetName or "Unknown")
              )
            end
            -- Skip immunity recording - damage landed, only CC was resisted
          elseif totalDebuffs < DEBUFF_CAP_THRESHOLD then
            -- Check DR before recording as permanent CC immunity
            local isDR = false
            if pending.targetGUID and pending.drType then
              local drEntry = lib.recentCCHits[pending.targetGUID] and lib.recentCCHits[pending.targetGUID][pending.drType]
              if drEntry and (GetTime() - drEntry.lastHitTime) < DR_RESET_WINDOW and drEntry.count >= 3 then
                isDR = true
              end
            end
            if isDR then
              if debug then
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cff00aaff[CC DR Skip]|r %s on %s - likely %s DR immunity (3+ recent hits), not recording permanent immunity",
                    pending.spellName or "Unknown", resolvedTargetName or "Unknown", pending.drType or "Unknown")
                )
              end
            elseif resolvedTargetName and resolvedTargetName ~= "" and (pending.immunityType or pending.ccType) then
              local learnedImmunityType = pending.immunityType or pending.ccType
              CleveRoids.RecordCCImmunity(resolvedTargetName, learnedImmunityType, nil, pending.spellName)

              if debug then
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cff00ff00[CC Immunity]|r %s is immune to %s (%s) - verified: debuff missing, only %d debuffs on target",
                    resolvedTargetName, learnedImmunityType, pending.spellName or "Unknown", totalDebuffs)
                )
              end
            elseif debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffff6600[CC Immunity Skip]|r Could not resolve target name for GUID %s - cannot record %s immunity",
                  pending.targetGUID or "nil", pending.ccType or "Unknown")
              )
            end
          else
            -- Many debuffs = likely pushed off
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffff6600[CC Debuff Cap]|r %s not found on %s - likely pushed off (%d debuffs)",
                  pending.ccType, resolvedTargetName or "Unknown", totalDebuffs)
              )
            end
          end
          end -- end of player/immunity-buff guard else block
        else
          -- CC landed successfully - remove any existing immunity record for this NPC/CC type
          local resolvedTargetName = pending.targetName
          if (not resolvedTargetName or resolvedTargetName == "") and pending.targetGUID then
            resolvedTargetName = lib.guidToName[pending.targetGUID]
          end
          local learnedImmunityType = pending.immunityType or pending.ccType
          if resolvedTargetName and learnedImmunityType then
            CleveRoids.RemoveCCImmunity(resolvedTargetName, learnedImmunityType)
          end
          -- Track only NPC-applicable DR groups for the permanent-immunity safeguard.
          if pending.targetGUID and pending.drType then
            lib.recentCCHits[pending.targetGUID] = lib.recentCCHits[pending.targetGUID] or {}
            local now = GetTime()
            local entry = lib.recentCCHits[pending.targetGUID][pending.drType]
            local count = 1
            if entry and (now - entry.lastHitTime) < DR_RESET_WINDOW then
              count = (entry.count or 0) + 1
            end
            lib.recentCCHits[pending.targetGUID][pending.drType] = {
              count = count,
              lastHitTime = now,
            }
          end
          if debug then
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff00ff00[CC Verified]|r %s landed on %s",
                pending.ccType, resolvedTargetName or "Unknown")
            )
          end
        end
        -- Item processed, don't add to new list
      else
        -- Item not ready, keep it in the new list
        _table_insert(newPendingList, pending)
      end
      end -- if pending
    end

    -- Replace old list with compacted new list (no holes)
    lib.pendingCCDebuffs = newPendingList
  end

  -- Process pending shared debuffs for immunity detection
  if hasShared then
    -- Use pairs() to iterate and rebuild without holes (same fix as personal/CC debuffs)
    local newPendingList = {}

    -- Count for debug output
    local pendingCount = 0
    for _ in _pairs(lib.pendingSharedDebuffs) do
      pendingCount = pendingCount + 1
    end

    if debug then
      DEFAULT_CHAT_FRAME:AddMessage(
        _string_format("|cff00aaff[Shared Process]|r Processing %d pending shared debuffs", pendingCount)
      )
    end

    for _, pending in _pairs(lib.pendingSharedDebuffs) do
      -- Guard against nil entries (can occur if combat log events remove items during iteration)
      if pending then
      local elapsed = currentTime - pending.timestamp

      if debug then
        local spellName = pending.spellID and C_Spell.GetSpellName(pending.spellID) or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(
          _string_format("|cff00aaff[Shared Check]|r %s elapsed:%.2fs (need 0.2s)", spellName, elapsed)
        )
      end

      -- Drop stale entries (>2s) without recording immunity - inconclusive due to severe lag
      if elapsed > 2.0 then
        if debug then
          local spellNameDebug = pending.spellID and C_Spell.GetSpellName(pending.spellID) or "Unknown"
          DEFAULT_CHAT_FRAME:AddMessage(
            _string_format("|cffff6600[Shared Stale]|r Dropping stale shared entry for %s on %s (%.1fs old)",
              spellNameDebug, pending.targetName or "Unknown", elapsed)
          )
        end
        -- Don't add to newPendingList - silently discard
      elseif elapsed >= 0.2 then
        local debuffVerified = false
        local totalDebuffs = 0

        -- SPELL_GO early-exit: Use definitive hit/miss data when available
        if pending.spellGoHit then
          debuffVerified = true
          if debug then
            local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Shared Debuff"
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff00ff00[Shared Verified via SPELL_GO]|r %s landed on %s - skipping debuff scan",
                spellNameDebug, pending.targetName or "Unknown")
            )
          end
        end

        -- SPELL_GO confirmed miss - debuff definitely didn't land
        if pending.spellGoMissed then
          -- Leave debuffVerified=false → falls through to immunity recording
          if debug then
            local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Shared Debuff"
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cffff6600[Shared Miss]|r %s missed on %s - SPELL_GO confirmed miss",
                spellNameDebug, pending.targetName or "Unknown")
            )
          end
        end

        -- Skip verification if target is dead (debuffs are removed on death)
        -- Guard: skip debuff scanning if SPELL_GO already determined outcome
        local sharedVerifyUnit = not debuffVerified and not pending.spellGoHit and not pending.spellGoMissed
          and pending.targetGUID and ResolveGUIDUnit(pending.targetGUID) or nil
        if sharedVerifyUnit then
          if _IsUnitDead(sharedVerifyUnit) then
            -- Target died - can't verify immunity, assume debuff landed
            debuffVerified = true
            if debug then
              local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Shared Debuff"
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffff6600[Shared Verify Skip]|r Target %s is dead - skipping immunity check for %s",
                  pending.targetName or "Unknown", spellNameDebug)
              )
            end
          else
            -- Target is alive - check if debuff exists
            for slot = 1, 48 do
              local _, _, _, debuffSpellID = _UnitDebuff(sharedVerifyUnit, slot)
              if not debuffSpellID then
                if slot <= 16 then break end  -- Regular debuffs are dense, overflow continues on nil
              else
                totalDebuffs = totalDebuffs + 1
                if debuffSpellID == pending.spellID then
                  debuffVerified = true
                  -- Don't break - continue counting total debuffs for immunity vs cap detection
                end
              end
            end
          end
        elseif not pending.spellGoMissed then
          -- No SuperWoW or no GUID - assume debuff landed (can't verify)
          debuffVerified = true
        end

        -- Process result
        if debuffVerified then
          -- Debuff landed - add to tracking
          if debug then
            local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Unknown"
            DEFAULT_CHAT_FRAME:AddMessage(
              _string_format("|cff88ff88[Shared Verified]|r %s (ID:%d) verified on %s",
                spellNameDebug, pending.spellID, pending.targetName or "Unknown")
            )
          end

          lib:AddEffect(pending.targetGUID, pending.targetName, pending.spellID, pending.duration, pending.stacks or 0, "player")

          -- Remove any existing immunity record for this NPC for this spell's school
          if pending.school and pending.targetName and pending.targetName ~= "" then
            CleveRoids.RemoveSpellImmunity(pending.targetName, pending.school)
          end
        else
          -- Debuff didn't land - check if it's immunity or debuff cap
          local DEBUFF_CAP_THRESHOLD = 47  -- Max is 48 (16 visible + 32 overflow)

          -- Guard: don't record immunity for player targets
          local sharedQueryUnit = pending.targetGUID and ResolveGUIDUnit(pending.targetGUID) or nil
          local isPlayer = sharedQueryUnit and UnitIsPlayer(sharedQueryUnit)
          local sharedImmunityBuff = sharedQueryUnit and not isPlayer and HasImmunityGrantingBuff(sharedQueryUnit)

          -- SPLIT CC SPELLS: Skip immunity recording for spells with physical damage + resistable CC
          -- (e.g., Master Strike) - the physical damage lands but CC can be resisted independently
          -- spellGoHit: SPELL_GO confirmed hit, so debuff was resisted independently (not true immunity)
          local isSplitCCSpell = SPLIT_CC_SPELLS[pending.spellID] or SPLIT_CC_SPELLS[pending.castSpellID] or pending.spellGoHit
          if isPlayer then
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffaaaaaa[Shared Skip]|r Player target %s - not recording immunity",
                  pending.targetName or "Unknown")
              )
            end
          elseif sharedImmunityBuff then
            if debug then
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffaaaaaa[Shared Skip]|r %s has immunity buff - not recording immunity",
                  pending.targetName or "Unknown")
              )
            end
          elseif isSplitCCSpell then
            if debug then
              local spellNameDebug = C_Spell.GetSpellName(pending.castSpellID or pending.spellID) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cff00aaff[Split CC Skip]|r %s CC resisted on %s - skipping immunity recording (physical damage landed)",
                  spellNameDebug, pending.targetName or "Unknown")
              )
            end
            -- Skip immunity recording - damage landed, only CC was resisted
          elseif totalDebuffs < DEBUFF_CAP_THRESHOLD then
            -- Few debuffs = likely immunity — use DBC school if available (more reliable than name-based)
            local recordSchool = pending.school
            if pending.spellID and _GetSpellRecField then
              local dbcSchool = _GetSpellRecField(pending.spellID, "school")
              -- Inline school mapping (SCHOOL_NAMES local is defined later in file, not visible here)
              local dbcSchoolName = dbcSchool == 0 and "physical" or dbcSchool == 1 and "holy"
                or dbcSchool == 2 and "fire" or dbcSchool == 3 and "nature"
                or dbcSchool == 4 and "frost" or dbcSchool == 5 and "shadow"
                or dbcSchool == 6 and "arcane" or nil
              if dbcSchoolName then
                recordSchool = dbcSchoolName
              end
            end
            if pending.targetName and pending.targetName ~= "" and recordSchool then
              -- Record immunity for this spell's school
              if not CleveRoids_ImmunityData[recordSchool] then
                CleveRoids_ImmunityData[recordSchool] = {}
              end
              CleveRoids_ImmunityData[recordSchool][pending.targetName] = true

              if debug then
                local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(
                  _string_format("|cffff6600[Shared Immunity]|r %s is immune to %s (%s) - only %d debuffs on target",
                    pending.targetName, recordSchool, spellNameDebug, totalDebuffs)
                )
              end
            end
          else
            -- Many debuffs = likely pushed off at debuff cap
            if debug then
              local spellNameDebug = C_Spell.GetSpellName(pending.spellID) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffff6600[Shared Debuff Cap]|r %s not found on %s - likely pushed off (%d debuffs)",
                  spellNameDebug, pending.targetName or "Unknown", totalDebuffs)
              )
            end
          end
        end
        -- Item processed, don't add to new list
      else
        -- Item not ready, keep it in the new list
        _table_insert(newPendingList, pending)
      end
      end -- if pending
    end

    -- Replace old list with compacted new list (no holes)
    lib.pendingSharedDebuffs = newPendingList
  end

  -- Clean up old rank refresh overrides (older than 2 seconds)
  if hasOverrides then
    for spellName, override in pairs(lib.rankRefreshOverrides) do
      if currentTime - override.timestamp > 2.0 then
        lib.rankRefreshOverrides[spellName] = nil
      end
    end
  end

  -- CleanupStaleTrackingData moved to UnitXP timer (30s interval) when available,
  -- falls back to inline call here when UnitXP is not present
  if not CleveRoids.hasUnitXP then
    lib:CleanupStaleTrackingData()
  end
end)

-- Periodic libdebuff cleanup via ClassicAPI's C_Timer (every 30s).
CleveRoids._cleanupTicker = C_Timer.NewTicker(30, function()
  if CleveRoids.isShuttingDown then return end
  local libRef = CleveRoids.libdebuff
  if libRef and libRef.CleanupStaleTrackingData then
    libRef:CleanupStaleTrackingData()
  end
end)

local ev = CreateFrame("Frame", "CleveRoidsLibDebuffFrame", UIParent)
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterUnitEvent("UNIT_AURA", "target")
ev:RegisterEvent("ADDON_LOADED")  -- For pfUI integration initialization
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")  -- Clear known enemy GUIDs on zone change

if CleveRoids.hasSuperwow then
  ev:RegisterEvent("UNIT_CASTEVENT")
end

-- Register Nampower v2.26+ events for standalone mode (when pfUI is not available or outdated)
-- These provide accurate hit/miss detection and debuff application tracking
if CleveRoids.hasNampower then
  local npMajor, npMinor = GetNampowerVersion()
  if npMajor > 2 or (npMajor == 2 and npMinor >= 26) then
    ev:RegisterEvent("SPELL_GO_SELF")
    ev:RegisterEvent("SPELL_GO_OTHER")
    ev:RegisterEvent("AURA_CAST_ON_SELF")
    ev:RegisterEvent("AURA_CAST_ON_OTHER")
    ev:RegisterEvent("DEBUFF_ADDED_OTHER")
    ev:RegisterEvent("DEBUFF_REMOVED_OTHER")

    -- BUFF_ADDED/REMOVED events require v2.30+ for auraSlot and state args
    if npMajor > 2 or (npMajor == 2 and npMinor >= 30) then
      ev:RegisterEvent("BUFF_REMOVED_SELF")
      ev:RegisterEvent("BUFF_REMOVED_OTHER")
    end

    if CleveRoids.debug then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Nampower]|r Registered UNIT_DIED for instant cleanup (v2.26+)")
    end
  end

  -- Register SPELL_START/SPELL_FAILED events for cast tracking (v2.25+)
  -- These events let us know when ANY unit starts or fails a cast-time spell
  -- pfUI 7.6 handles these itself, but we register anyway for standalone mode
  if npMajor > 2 or (npMajor == 2 and npMinor >= 25) then
    ev:RegisterEvent("SPELL_START_SELF")
    ev:RegisterEvent("SPELL_START_OTHER")
    ev:RegisterEvent("SPELL_FAILED_OTHER")

    if CleveRoids.debug then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Nampower]|r Registered SPELL_START/SPELL_FAILED for cast tracking (v2.25+)")
    end
  end
end

ev:SetScript("OnEvent", function()
  -- Initialize pfUI integration when pfUI loads
  if event == "ADDON_LOADED" and arg1 == "pfUI" then
    -- Defer initialization slightly to ensure pfUI.version is populated
    local initFrame = CreateFrame("Frame")
    local initTimer = 0
    initFrame:SetScript("OnUpdate", function()
      initTimer = initTimer + arg1
      if initTimer >= 0.5 then
        lib:InitPfUIIntegration()
        this:SetScript("OnUpdate", nil)
      end
    end)
    return
  end

  if event == "ZONE_CHANGED_NEW_AREA" then
    -- Wipe known enemy GUIDs — all previous units are invalid in the new zone
    if CleveRoids.knownEnemyGuids then
      for k in pairs(CleveRoids.knownEnemyGuids) do
        CleveRoids.knownEnemyGuids[k] = nil
      end
    end
    -- Wipe GUID-to-name cache — GUIDs can be reused across zones
    if lib.guidToName then
      for k in pairs(lib.guidToName) do
        lib.guidToName[k] = nil
      end
    end
    -- Wipe DR tracking — DR state is invalid in a new zone
    if lib.recentCCHits then
      for k in pairs(lib.recentCCHits) do
        lib.recentCCHits[k] = nil
      end
    end
    return

  elseif event == "PLAYER_TARGET_CHANGED" then
    -- Seed known enemy GUIDs from target changes
    if UnitExists("target") and UnitCanAttack("player", "target") and CleveRoids.knownEnemyGuids then
      local guid = CleveRoids.GetGUID("target")
      if guid then
        CleveRoids.knownEnemyGuids[guid] = true
      end
    end
    SeedUnit("target")

  elseif event == "UNIT_AURA" then
    SeedUnit("target")

  elseif event == "UNIT_CASTEVENT" then
    local casterGUID = arg1
    local targetGUID = arg2
    local eventType = arg3
    local spellID = arg4

    -- Normalize targetGUID to string for consistent table key lookups
    targetGUID = CleveRoids.NormalizeGUID(targetGUID)

    -- Capture combo points when cast STARTS (before they're consumed)
    if (eventType == "START" or eventType == "CHANNEL") and spellID then
      local playerGUID = CleveRoids.GetGUID("player")
      if casterGUID == playerGUID and targetGUID then
        -- If this is a combo scaling spell OR Ferocious Bite, capture combo points NOW (before consumption)
        local isComboSpell = CleveRoids.IsComboScalingSpellID and CleveRoids.IsComboScalingSpellID(spellID)
        local isFerociousBite = CleveRoids.FerociousBiteSpellIDs and CleveRoids.FerociousBiteSpellIDs[spellID]

        if isComboSpell or isFerociousBite then
          local currentCP = CleveRoids.GetComboPoints()
          if currentCP and currentCP > 0 then
            CleveRoids.lastComboPoints = currentCP
            if CleveRoids.debug then
              local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cffaaaaff[UNIT_CASTEVENT START]|r Captured %d CP before casting %s (ID:%d)",
                  currentCP, spellName, spellID)
              )
            end
          end
        end

      end
    end

    if eventType == "CAST" and spellID then
      local playerGUID = CleveRoids.GetGUID("player")
      if casterGUID == playerGUID and targetGUID then

        -- SHAMAN MOLTEN BLAST: Track for Flame Shock refresh detection (TWoW Custom)
        -- Credits: Avitasia / Cursive addon
        if CleveRoids.MoltenBlastSpellIDs and CleveRoids.MoltenBlastSpellIDs[spellID] then
          CleveRoids.lastMoltenBlastTime = GetTime()
          CleveRoids.lastMoltenBlastTargetGUID = targetGUID
          if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
              string.format("|cff0070dd[Molten Blast]|r Tracking cast on %s (waiting for hit confirmation)",
                lib.guidToName[targetGUID] or "Unknown")
            )
          end
        end

        -- WARLOCK CONFLAGRATE: Reduces Immolate duration by 3 seconds
        -- Credits: Avitasia / Cursive addon
        if CleveRoids.ConflagrateSpellIDs and CleveRoids.ConflagrateSpellIDs[spellID] then
          -- Find active Immolate on target and reduce its duration
          if lib.objects[targetGUID] then
            for immolateID, _ in pairs(CleveRoids.ImmolateSpellIDs or {}) do
              local rec = lib.objects[targetGUID][immolateID]
              if rec and rec.duration and rec.start then
                local remaining = rec.duration + rec.start - GetTime()
                if remaining > 0 then
                  -- Reduce duration by 3 seconds
                  rec.duration = rec.duration - 3
                  if CleveRoids.debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                      string.format("|cff9482c9[Conflagrate]|r Reduced Immolate duration by 3s (now %.1fs remaining)",
                        rec.duration + rec.start - GetTime())
                    )
                  end
                  break
                end
              end
            end
          end
        end

        -- POUNCE: Convert cast spell ID to triggered Pounce Bleed spell ID
        -- Pounce (cast) triggers a separate Pounce Bleed spell with a different ID
        -- We track the bleed, not the stun, for immunity detection
        local trackingSpellID = spellID
        if CleveRoids.PounceToBleedMapping and CleveRoids.PounceToBleedMapping[spellID] then
          trackingSpellID = CleveRoids.PounceToBleedMapping[spellID]
          if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
              string.format("|cff00aaff[Pounce→Bleed]|r Converted cast ID %d to bleed ID %d", spellID, trackingSpellID)
            )
          end
        end

        -- CC IMMUNITY TRACKING: Check if this spell is a CC spell and track for immunity verification
        -- Uses the original spellID (not trackingSpellID) to detect CC type
        local ccType = CleveRoids.GetSpellCCType and CleveRoids.GetSpellCCType(spellID)
        local immunityType = CleveRoids.GetSpellImmunityType and CleveRoids.GetSpellImmunityType(spellID)
        local drType = CleveRoids.GetSpellImmunityDRType and CleveRoids.GetSpellImmunityDRType(spellID)

        -- Debug: Show what GetSpellCCType returns for this spell
        if CleveRoids.debug then
          local spellNameDebug = C_Spell.GetSpellName(spellID) or "Unknown"
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffaaaaaa[CC Check]|r %s (ID:%d) → ccType: %s",
              spellNameDebug, spellID, ccType or "nil")
          )
        end

        if ccType then
          -- Track ALL CC spells for immunity verification, including hidden CC (e.g., Pounce stun)
          -- Hidden CC spells don't show visible debuffs, but:
          -- 1. They may still be detectable via mechanic-based ValidateUnitCC check
          -- 2. Combat log "afflicted by" messages confirm successful CC
          -- 3. If neither detection method finds the CC, we record immunity
          local isHiddenCC = lib.hiddenCCSpells and lib.hiddenCCSpells[spellID]
          -- v3.0+: Dynamically detect hidden CC via IsAuraHidden
          if not isHiddenCC and _G.IsAuraHidden then
            isHiddenCC = (_G.IsAuraHidden(spellID) == 1)
          end
          local spellName = C_Spell.GetSpellName(spellID)
          -- Get target name from cache or current target
          local ccTargetName = lib.guidToName[targetGUID]
          if not ccTargetName then
            local currentTargetGUID = CleveRoids.GetGUID("target")
            if currentTargetGUID == targetGUID then
              ccTargetName = UnitName("target")
              lib.guidToName[targetGUID] = ccTargetName
            end
          end
          table.insert(lib.pendingCCDebuffs, {
            timestamp = GetTime(),
            targetGUID = targetGUID,
            targetName = ccTargetName,
            spellID = spellID,
            spellName = spellName,
            ccType = ccType,
            immunityType = immunityType or ccType,
            drType = drType,
            isHiddenCC = isHiddenCC,  -- Flag for hidden CC spells
          })

          if CleveRoids.debug then
            local hiddenStr = isHiddenCC and " (hidden CC)" or ""
            DEFAULT_CHAT_FRAME:AddMessage(
              string.format("|cff00ff00[CC Track]|r Tracking %s (%s) on %s for immunity verification%s",
                spellName or "Unknown", ccType, ccTargetName or "Unknown", hiddenStr)
            )
          end
        end

        -- Check if this is a combo point scaling spell first
        local duration = nil
        local comboPoints = nil
        if CleveRoids.TrackComboPointCastByID then
          duration = CleveRoids.TrackComboPointCastByID(trackingSpellID, targetGUID)
          -- Get combo points used from tracking
          if CleveRoids.ComboPointTracking and CleveRoids.ComboPointTracking.byID and
             CleveRoids.ComboPointTracking.byID[trackingSpellID] then
            comboPoints = CleveRoids.ComboPointTracking.byID[trackingSpellID].combo_points
          end
        end

        -- If not a combo scaling spell, use normal duration lookup
        if not duration then
          duration = lib:GetDuration(trackingSpellID, casterGUID)

          -- Apply all duration modifiers (Nampower, talents, equipment, set bonuses)
          -- (combo spells already have modifiers applied in CalculateComboScaledDurationByID)
          if duration and CleveRoids.ApplyAllDurationModifiers then
            duration = CleveRoids.ApplyAllDurationModifiers(trackingSpellID, duration)
          end
        end

        -- DEBUG: Show what duration we calculated
        if CleveRoids.debug and duration then
          local spellName = C_Spell.GetSpellName(trackingSpellID) or "Unknown"
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cffff00ff[DEBUG CAST]|r %s (ID:%d) CP:%s duration:%ds",
              spellName, trackingSpellID, tostring(comboPoints or "nil"), duration)
          )
        end

        if duration and duration > 0 then
          local targetName = lib.guidToName[targetGUID]
          if not targetName then
            local currentTargetGUID = CleveRoids.GetGUID("target")
            if currentTargetGUID == targetGUID then
              targetName = UnitName("target")
              lib.guidToName[targetGUID] = targetName
            end
            -- Try SuperWoW GUID-based name lookup if still not resolved
            if not targetName and CleveRoids.hasSuperwow then
              targetName = UnitName(targetGUID)
              if targetName and targetName ~= "Unknown" then
                lib.guidToName[targetGUID] = targetName
              end
            end
            -- Final fallback
            if not targetName then
              targetName = "Unknown"
            end
          end

          -- For combo spells, populate name-based tracking for pfUI compatibility
          if comboPoints and comboPoints > 0 then
            local spellName = C_Spell.GetSpellName(spellID)
            if spellName and CleveRoids.ComboPointTracking then
              -- Remove rank from spell name to match pfUI's format
              local baseName = CleveRoids.StripRank(spellName)
              CleveRoids.ComboPointTracking[baseName] = {
                combo_points = comboPoints,
                duration = duration,
                cast_time = GetTime(),
                target = targetName,
                confirmed = true  -- This is from actual UNIT_CASTEVENT, always confirmed
              }
              if CleveRoids.debug then
                DEFAULT_CHAT_FRAME:AddMessage(
                  string.format("|cff00ffff[Name-based tracking]|r Set %s: %d CP, %ds duration (for pfUI)",
                    baseName, comboPoints, duration)
                )
              end

              -- Update pfUI's duration database directly (pre-7.6 only)
              -- pfUI 7.6+ handles combo durations internally via GetStoredComboPoints()
              if pfUI and pfUI.api and pfUI.api.libdebuff and pfUI.api.libdebuff.debuffs then
                pfUI.api.libdebuff.debuffs[baseName] = duration
                if CleveRoids.debug then
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffff00ff[pfUI Duration Inject]|r Set pfUI.api.libdebuff.debuffs['%s'] = %ds",
                      baseName, duration)
                  )
                end
              end
            end
          end

          -- Check if this is a personal debuff - if so, delay tracking to verify it lands
          local isPersonal = lib:IsPersonalDebuff(trackingSpellID)

          if isPersonal then
            -- Check if we should apply based on rank comparison
            local rankCheck = lib:ShouldApplyDebuffRank(targetGUID, trackingSpellID)

            if rankCheck == true then
              -- Normal application - schedule personal debuff for delayed tracking
              table.insert(lib.pendingPersonalDebuffs, {
                timestamp = GetTime(),
                targetGUID = targetGUID,
                targetName = targetName,
                spellID = trackingSpellID,  -- Use tracking spell ID (e.g., Pounce Bleed, not Pounce)
                castSpellID = spellID,      -- Original cast spell ID (for dodge/parry matching)
                duration = duration,
                comboPoints = comboPoints
              })

              if CleveRoids.debug then
                local spellName = C_Spell.GetSpellName(trackingSpellID) or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(
                  string.format("|cffaaff00[Pending Track]|r Scheduled %s (ID:%d) for tracking on %s (will apply if hit)",
                    spellName, trackingSpellID, targetName or "Unknown")
                )
              end
            elseif type(rankCheck) == "table" and rankCheck.preserve then
              -- Preserve higher rank's timer - schedule with higher rank's spell ID and remaining time
              table.insert(lib.pendingPersonalDebuffs, {
                timestamp = GetTime(),
                targetGUID = targetGUID,
                targetName = targetName,
                spellID = rankCheck.preserve,  -- Use higher rank's spell ID
                duration = rankCheck.timeRemaining,  -- Use remaining time, not full duration
                comboPoints = comboPoints,
                isRankPreserve = true  -- Flag this as a rank preserve
              })

              if CleveRoids.debug then
                local spellName = C_Spell.GetSpellName(rankCheck.preserve) or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(
                  string.format("|cffaaff00[Pending Track]|r Scheduled rank preserve for %s (ID:%d, %.1fs remaining) on %s",
                    spellName, rankCheck.preserve, rankCheck.timeRemaining, targetName or "Unknown")
                )
              end
            end
            -- If rankCheck == false, skip entirely (shouldn't happen for personal debuffs with new logic)
          else
            -- Shared debuff - schedule for delayed verification (immunity detection)
            -- For stacking debuffs (Sunder, Faerie Fire), predict new stack count
            local newStacks = 0

            -- Check current stacks on target
            local currentTargetGUID = CleveRoids.GetGUID("target")
            if currentTargetGUID == targetGUID then
              -- Scan debuff slots to find current stacks
              for i = 1, 16 do
                local _, existingStacks, _, existingSpellID = UnitDebuff("target", i)
                if existingSpellID == spellID then
                  newStacks = (existingStacks or 0) + 1
                  break
                end
              end

              -- If not found in debuff slots, check buff slots (overflow)
              if newStacks == 0 then
                for i = 1, 32 do
                  local _, existingStacks, existingSpellID = UnitBuff("target", i)
                  if existingSpellID == spellID then
                    newStacks = (existingStacks or 0) + 1
                    break
                  end
                end
              end

              -- If still not found, this is the first stack
              if newStacks == 0 then
                newStacks = 1
              end

              -- Cap at maximum stacks (5 for Sunder Armor, most debuffs)
              -- TODO: Make this configurable per spell if needed
              if newStacks > 5 then
                newStacks = 5
              end
            else
              -- Target changed or not available, default to 1 stack
              newStacks = 1
            end

            -- Determine spell school for immunity tracking
            -- GetSpellSchool is defined later in file, use CleveRoids wrapper if available
            local spellSchool = nil
            local spellNameForSchool = C_Spell.GetSpellName(spellID)
            if CleveRoids.GetSpellSchool then
              spellSchool = CleveRoids.GetSpellSchool(spellNameForSchool, spellID)
            end

            -- Check if we should apply based on rank comparison
            local rankCheck = lib:ShouldApplyDebuffRank(targetGUID, spellID)

            local trackingSpellID = spellID
            local trackingDuration = duration
            if type(rankCheck) == "table" and rankCheck.preserve then
              -- Preserve higher rank's timer
              trackingSpellID = rankCheck.preserve
              trackingDuration = rankCheck.timeRemaining
            elseif rankCheck == false then
              -- Skip entirely
              trackingSpellID = nil
            end

            if trackingSpellID then
              -- REFRESH DETECTION: If newStacks > 1, debuff already existed on target
              -- Skip pending queue for refreshes - directly reset the timer
              -- The pending queue is only for NEW applications where immunity detection matters
              local isRefresh = (newStacks > 1)

              if isRefresh then
                -- Direct timer reset for refreshes (debuff already verified to exist)
                lib:AddEffect(targetGUID, targetName, trackingSpellID, trackingDuration, newStacks, "player")

                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(trackingSpellID) or "Unknown"
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cff00ff00[Shared Refresh]|r %s (ID:%d) on %s - timer reset to %ds (stacks:%d)",
                      spellName, trackingSpellID, targetName or "Unknown", trackingDuration, newStacks)
                  )
                end
              else
                -- NEW APPLICATION: Schedule for delayed verification (immunity detection)
                table.insert(lib.pendingSharedDebuffs, {
                  timestamp = GetTime(),
                  targetGUID = targetGUID,
                  targetName = targetName,
                  spellID = trackingSpellID,
                  castSpellID = spellID,  -- Original cast spell ID (for dodge/parry matching)
                  duration = trackingDuration,
                  stacks = newStacks,
                  school = spellSchool,
                  isRankPreserve = (trackingSpellID ~= spellID)
                })

                if CleveRoids.debug then
                  local spellName = C_Spell.GetSpellName(trackingSpellID) or "Unknown"
                  local queueLen = table.getn(lib.pendingSharedDebuffs)
                  local firstItem = lib.pendingSharedDebuffs[1]
                  DEFAULT_CHAT_FRAME:AddMessage(
                    string.format("|cffaaff00[Pending Shared]|r Scheduled %s (ID:%d, school:%s) for tracking on %s [queueLen:%d, [1]:%s]",
                      spellName, trackingSpellID, spellSchool or "unknown", targetName or "Unknown",
                      queueLen, firstItem and "exists" or "NIL")
                  )
                end
              end
            end
          end

          -- NOTE: Bleed immunity detection is now handled in the delayed pending debuff
          -- processing system (see pendingPersonalDebuffs OnUpdate handler above).
          -- This prevents false positives from checking UnitDebuff() immediately after
          -- UNIT_CASTEVENT, before the server has synced the debuff to the client.

          -- ALWAYS set up learning for combo spells (even if we have calculated duration)
          if comboPoints then
            lib.learnCastTimers[targetGUID] = lib.learnCastTimers[targetGUID] or {}
            lib.learnCastTimers[targetGUID][spellID] = {
              start = GetTime(),
              caster = casterGUID,
              comboPoints = comboPoints  -- Store CP count for learning
            }
          end

        else
          lib.learnCastTimers[targetGUID] = lib.learnCastTimers[targetGUID] or {}
          lib.learnCastTimers[targetGUID][spellID] = {
            start = GetTime(),
            caster = casterGUID
          }

          lib.objects[targetGUID] = lib.objects[targetGUID] or {}
          lib.objects[targetGUID][spellID] = {
            spellID = spellID,
            start = GetTime(),
            duration = 999,  -- Placeholder
            stacks = 0,
            caster = casterGUID
          }
        end
      end

      -- SHARED DEBUFFS FROM OTHER PLAYERS: Track when other players cast shared debuffs
      -- This ensures Sunder Armor, Faerie Fire, etc. are tracked when ANY player casts them
      -- Personal debuffs are still only tracked from the player (we only care about our own)
      local playerGUID = CleveRoids.GetGUID("player")
      if casterGUID ~= playerGUID and targetGUID then
        -- Check if this is a shared debuff we should track
        if lib.sharedDebuffs[spellID] then
          local duration = lib:GetDuration(spellID)
          if duration and duration > 0 then
            -- Get target name from cache or current target
            local targetName = lib.guidToName[targetGUID]
            if not targetName then
              local currentTargetGUID = CleveRoids.GetGUID("target")
              if currentTargetGUID == targetGUID then
                targetName = UnitName("target")
                lib.guidToName[targetGUID] = targetName
              end
            end

            -- For stacking debuffs, predict new stack count
            local newStacks = 1
            local currentTargetGUID = CleveRoids.GetGUID("target")
            if currentTargetGUID == targetGUID then
              -- Scan debuff slots to find current stacks
              for i = 1, 16 do
                local _, existingStacks, _, existingSpellID = UnitDebuff("target", i)
                if existingSpellID == spellID then
                  newStacks = (existingStacks or 0) + 1
                  break
                end
              end

              -- If not found in debuff slots, check buff slots (overflow)
              if newStacks == 1 then
                for i = 1, 32 do
                  local _, existingStacks, existingSpellID = UnitBuff("target", i)
                  if existingSpellID == spellID then
                    newStacks = (existingStacks or 0) + 1
                    break
                  end
                end
              end

              -- Cap at maximum stacks
              if newStacks > 5 then
                newStacks = 5
              end
            end

            -- Directly add the effect (other players' casts don't need immunity verification)
            -- Reset timer to full duration since the debuff was just refreshed
            lib:AddEffect(targetGUID, targetName, spellID, duration, newStacks, casterGUID)

            if CleveRoids.debug then
              local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
              local casterName = lib.guidToName[casterGUID] or "Other Player"
              DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cff00aaff[Other Cast]|r %s cast %s (ID:%d) on %s - timer reset to %ds",
                  casterName, spellName, spellID, targetName or "Unknown", duration)
              )
            end
          end
        end
      end
    end

  -- NAMPOWER v2.25+ CAST TRACKING HANDLERS (Standalone or pfUI < 7.6)
  -- Populates CleveRoids.castTracking, whose target GUID SPELL_GO falls back on.
  -- When pfUI 7.6+ is active, castTracking points to pfUI.libdebuff_casts
  -- and these handlers return early (pfUI handles it).

  elseif event == "SPELL_START_SELF" or event == "SPELL_START_OTHER" then

    -- Nampower fallback for UNIT_CASTEVENT START/CHANNEL: capture combo points and Dark Harvest
    -- Only needed when SuperWoW is not available (UNIT_CASTEVENT won't fire)
    if event == "SPELL_START_SELF" and not CleveRoids.hasSuperwow then
      local spellID = arg2
      local casterGuid = arg3
      local targetGuid = arg4
      local playerGUID = CleveRoids.GetGUID("player")
      if casterGuid == playerGUID and spellID and targetGuid then
        targetGuid = CleveRoids.NormalizeGUID(targetGuid)

        -- Capture combo points before consumption (equivalent to UNIT_CASTEVENT START)
        local isComboSpell = CleveRoids.IsComboScalingSpellID and CleveRoids.IsComboScalingSpellID(spellID)
        local isFerociousBite = CleveRoids.FerociousBiteSpellIDs and CleveRoids.FerociousBiteSpellIDs[spellID]

        if isComboSpell or isFerociousBite then
          local currentCP = CleveRoids.GetComboPoints and CleveRoids.GetComboPoints()
          if currentCP and currentCP > 0 then
            CleveRoids.lastComboPoints = currentCP
            if CleveRoids.debug then
              local spellName = C_Spell.GetSpellName(spellID) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                _string_format("|cffaaaaff[SPELL_START_SELF]|r Captured %d CP before casting %s (ID:%d)",
                  currentCP, spellName, spellID)
              )
            end
          end
        end

      end
    end

    -- pfUI 7.6 manages castTracking via its own SPELL_START handler

    local spellId = arg2
    local casterGuid = arg3
    local castTime = arg6  -- cast time in milliseconds
    -- v2.38+: arg7 = channel duration (ms, channeling spells only), arg8 = spellType (0=Normal,1=Channeling,2=Autorepeating)
    local channelDuration = arg7
    local spellType = arg8

    if not casterGuid or not spellId then return end

    local spellName = C_Spell.GetSpellName(spellId)
    local icon = lib:GetCachedIcon(spellId)
    local now = GetTime()

    -- For channeling spells (v2.38+: spellType==1), use the channel duration.
    -- For normal cast-time spells, use castTime. Fall back to castTime if params unavailable.
    local durationMs
    if spellType == 1 and channelDuration and channelDuration > 0 then
      durationMs = channelDuration
    else
      durationMs = castTime or 0
    end
    local durationSec = durationMs / 1000

    CleveRoids.castTracking[casterGuid] = {
      spellID = spellId,
      spellName = spellName,
      icon = icon,
      startTime = now,
      duration = durationSec,
      endTime = durationSec > 0 and (now + durationSec) or nil,
      -- v2.40+: arg4 is now correct for friendly player targets (packed GUID bug fixed).
      -- Nil/zero target means no explicit target (e.g. self-cast buffs, AoE spells).
      targetGuid = (arg4 and arg4 ~= "0x0000000000000000") and CleveRoids.NormalizeGUID(arg4) or nil,
    }

    if CleveRoids.debug then
      local typeStr = spellType == 1 and "channel" or (spellType == 2 and "auto" or "cast")
      DEFAULT_CHAT_FRAME:AddMessage(
        string.format("|cff00ccff[SPELL_START]|r %s (ID:%d) cast by %s - %.1fs [%s]",
          spellName or "Unknown", spellId, casterGuid, durationSec, typeStr)
      )
    end

  elseif event == "SPELL_FAILED_OTHER" then
    -- pfUI 7.6 manages castTracking cleanup itself

    local casterGuid = arg1
    if casterGuid and CleveRoids.castTracking[casterGuid] then
      if CleveRoids.debug then
        local entry = CleveRoids.castTracking[casterGuid]
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cffff6600[SPELL_FAILED]|r %s cast by %s interrupted/failed",
            entry.spellName or "Unknown", casterGuid)
        )
      end
      CleveRoids.castTracking[casterGuid] = nil
    end

  -- NAMPOWER v2.26+ SPELL EVENT HANDLERS (Standalone Mode)
  -- These handlers are only used when pfUI v7.4.3+ is NOT available.
  -- When pfUI is available, we use its tables directly instead.

  elseif event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
    -- Clear the cast tracking entry FIRST, before the hasPfUIEnhanced bail below.
    -- We always own castTracking (SPELL_START populates it unconditionally), whereas
    -- hasPfUIEnhanced only gates the miss/debuff work further down. Clearing used to
    -- sit after that bail, so with pfUI's enhanced libdebuff tables present
    -- SPELL_START kept adding entries while this cleanup never ran and castTracking
    -- grew without bound.
    -- v2.40+: Save the SPELL_START targetGuid before clearing so we can fall back
    -- to it below when SPELL_GO arg4 is empty (e.g. AoE spells with no single target).
    local startTargetGuid
    if arg3 and CleveRoids.castTracking[arg3] then
      startTargetGuid = CleveRoids.castTracking[arg3].targetGuid
      CleveRoids.castTracking[arg3] = nil
    end

    -- Skip the remaining miss/debuff work if pfUI enhanced tracking is active
    if lib.hasPfUIEnhanced then return end

    local spellId = arg2
    local casterGuid = arg3
    -- v2.40+: SPELL_GO targetGuid is now correct for friendly player GUIDs.
    -- Fall back to the SPELL_START-cached targetGuid for spells with no explicit
    -- single target in SPELL_GO (AoE, self-cast with no target arg, etc.).
    local targetGuid = arg4
    if not targetGuid or targetGuid == "0x0000000000000000" then
      targetGuid = startTargetGuid
    end
    local numHit = arg6 or 0
    local numMissed = arg7 or 0

    if not spellId or not targetGuid then return end
    targetGuid = CleveRoids.NormalizeGUID(targetGuid)

    local spellName = C_Spell.GetSpellName(spellId)
    if not spellName then return end

    local playerGUID = CleveRoids.GetGUID("player")
    local isOurs = (casterGuid == playerGUID)

    -- Annotate pending CC/shared debuffs with SPELL_GO hit/miss outcome
    -- This data is consumed by the OnUpdate verification loop for early-exit paths
    if isOurs then
      -- Annotate pendingCCDebuffs
      for _, pending in ipairs(lib.pendingCCDebuffs) do
        if pending and pending.spellID == spellId and pending.targetGUID == targetGuid then
          if numHit > 0 then
            pending.spellGoHit = true
          elseif numMissed > 0 then
            pending.spellGoMissed = true
          end
          break
        end
      end
      -- Annotate pendingSharedDebuffs (match against both castSpellID and spellID)
      for _, pending in ipairs(lib.pendingSharedDebuffs) do
        if pending and pending.targetGUID == targetGuid
          and (pending.castSpellID == spellId or pending.spellID == spellId) then
          if numHit > 0 then
            pending.spellGoHit = true
          elseif numMissed > 0 then
            pending.spellGoMissed = true
          end
          break
        end
      end
      -- Annotate pendingPersonalDebuffs (from UNIT_CASTEVENT when SuperWoW present,
      -- or from SPELL_GO_SELF personal debuff bridge when SuperWoW absent)
      for _, pending in ipairs(lib.pendingPersonalDebuffs) do
        if pending and pending.targetGUID == targetGuid
          and (pending.castSpellID == spellId or pending.spellID == spellId) then
          if numHit > 0 then
            pending.spellGoHit = true
          elseif numMissed > 0 then
            pending.spellGoMissed = true
          end
          break
        end
      end
    end

    -- Spell missed - clear pending, mark as failed, track for immunity detection
    if numHit == 0 and numMissed > 0 then
      if lib.pendingCasts[targetGuid] then
        lib.pendingCasts[targetGuid][spellName] = nil
      end

      -- Get target name for immunity tracking
      local targetName = lib.guidToName[targetGuid]
      if not targetName then
        local currentTargetGUID = CleveRoids.GetGUID("target")
        if currentTargetGUID == targetGuid then
          targetName = UnitName("target")
          lib.guidToName[targetGuid] = targetName
        end
      end

      -- Mark spell as recently failed for DidSpellFail() check
      lib.recentMisses[targetGuid] = lib.recentMisses[targetGuid] or {}
      lib.recentMisses[targetGuid][spellName] = {
        time = GetTime(),
        spellId = spellId,
        targetGuid = targetGuid,
        targetName = targetName,
        casterGuid = casterGuid,
        isOurs = isOurs,
      }

      if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cffff6600[SPELL_GO MISS]|r %s missed on %s",
            spellName, targetName or "Unknown")
        )
      end

      return
    end

    -- Spell hit - do refresh logic for OWN debuffs
    if isOurs and lib.ownDebuffs[targetGuid] and lib.ownDebuffs[targetGuid][spellName] then
      local existingData = lib.ownDebuffs[targetGuid][spellName]
      if existingData.startTime and existingData.duration then
        local timeleft = (existingData.startTime + existingData.duration) - GetTime()
        if timeleft > 0 then
          -- Refresh the timer
          lib.ownDebuffs[targetGuid][spellName].startTime = GetTime()

          CleveRoids.DebugChanged("spellgo_refresh_" .. spellName .. "_" .. tostring(targetGuid),
            string.format("|cff00ff00[SPELL_GO REFRESH]|r %s refreshed on %s",
              spellName, lib.guidToName[targetGuid] or "Unknown"))
        end
      end
    end

    -- Spell hit on target - clear any pending immunity checks
    -- (The spell landed, so target is definitely not immune to it)
    if isOurs and lib.recentMisses and lib.recentMisses[targetGuid] then
      lib.recentMisses[targetGuid][spellName] = nil
    end

    -- COMBO POINT INTEGRATION: Capture combo points on SPELL_GO hit
    -- SPELL_GO fires immediately when the spell lands - this is the best time
    -- to capture combo points because they might already be consumed by the
    -- time AURA_CAST fires. Store in pendingCasts for AURA_CAST to use.
    if isOurs and lib.combopointAbilities and lib.combopointAbilities[spellName] then
      -- Capture combo points from multiple sources
      -- Priority: UNIT_SPELLCAST_SENT (client-side, pre-server) > GetComboPoints > lastComboPoints > ComboPointTracking
      local comboPoints = 0

      -- PRIMARY: Check UNIT_SPELLCAST_SENT capture (most reliable - captured before server consumed CP)
      local pending = CleveRoids.sentCasts and CleveRoids.sentCasts[spellId]
      if pending and pending.comboPoints and pending.comboPoints > 0 then
        comboPoints = pending.comboPoints
      end

      -- Fallback: Try GetComboPoints (may still be available)
      if comboPoints == 0 then
        comboPoints = CleveRoids.GetComboPoints and CleveRoids.GetComboPoints() or 0
      end

      -- Fallback: lastComboPoints (from pre-cast hooks or UNIT_CASTEVENT START)
      if comboPoints == 0 and CleveRoids.lastComboPoints and CleveRoids.lastComboPoints > 0 then
        comboPoints = CleveRoids.lastComboPoints
      end

      -- Fallback: ComboPointTracking for recent data (from /cast hook pre-population)
      if comboPoints == 0 and CleveRoids.ComboPointTracking then
        local tracking = CleveRoids.ComboPointTracking[spellName]
        if tracking and tracking.combo_points and tracking.combo_points > 0 then
          local age = GetTime() - (tracking.cast_time or 0)
          if age < 1.0 then  -- Use if less than 1 second old
            comboPoints = tracking.combo_points
          end
        end
      end

      -- Store combo points in pendingCasts for AURA_CAST to retrieve
      if comboPoints > 0 then
        lib.pendingCasts[targetGuid] = lib.pendingCasts[targetGuid] or {}
        lib.pendingCasts[targetGuid][spellName] = lib.pendingCasts[targetGuid][spellName] or {}
        lib.pendingCasts[targetGuid][spellName].comboPoints = comboPoints
        lib.pendingCasts[targetGuid][spellName].capturedAt = GetTime()
        lib.pendingCasts[targetGuid][spellName].spellId = spellId

        if CleveRoids.debug then
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ffaa[SPELL_GO COMBO]|r Captured %d CP for %s on %s",
              comboPoints, spellName, lib.guidToName[targetGuid] or "Unknown")
          )
        end
      end
    end

    -- Nampower fallback: Cast-complete features from UNIT_CASTEVENT CAST
    -- Only needed when SuperWoW is not available and spell hit the target
    if isOurs and not CleveRoids.hasSuperwow and numHit > 0 then
      -- SHAMAN MOLTEN BLAST: Track for Flame Shock refresh detection
      if CleveRoids.MoltenBlastSpellIDs and CleveRoids.MoltenBlastSpellIDs[spellId] then
        CleveRoids.lastMoltenBlastTime = GetTime()
        CleveRoids.lastMoltenBlastTargetGUID = targetGuid
      end

      -- WARLOCK CONFLAGRATE: Reduces Immolate duration by 3 seconds
      if CleveRoids.ConflagrateSpellIDs and CleveRoids.ConflagrateSpellIDs[spellId] then
        if lib.objects[targetGuid] then
          for immolateID, _ in pairs(CleveRoids.ImmolateSpellIDs or {}) do
            local rec = lib.objects[targetGuid][immolateID]
            if rec and rec.duration and rec.start then
              local remaining = rec.duration + rec.start - GetTime()
              if remaining > 0 then
                rec.duration = rec.duration - 3
                break
              end
            end
          end
        end
      end

      -- CC IMMUNITY TRACKING: Check if this spell is a CC spell
      local ccType = CleveRoids.GetSpellCCType and CleveRoids.GetSpellCCType(spellId)
      local immunityType = CleveRoids.GetSpellImmunityType and CleveRoids.GetSpellImmunityType(spellId)
      local drType = CleveRoids.GetSpellImmunityDRType and CleveRoids.GetSpellImmunityDRType(spellId)
      if ccType then
        local isHiddenCC = lib.hiddenCCSpells and lib.hiddenCCSpells[spellId]
        if not isHiddenCC and _G.IsAuraHidden then
          isHiddenCC = (_G.IsAuraHidden(spellId) == 1)
        end
        local ccTargetName = lib.guidToName[targetGuid]
        if not ccTargetName then
          local currentTargetGUID = CleveRoids.GetGUID("target")
          if currentTargetGUID == targetGuid then
            ccTargetName = UnitName("target")
            lib.guidToName[targetGuid] = ccTargetName
          end
        end
        table.insert(lib.pendingCCDebuffs, {
          timestamp = GetTime(),
          targetGUID = targetGuid,
          targetName = ccTargetName,
          spellID = spellId,
          spellName = spellName,
          ccType = ccType,
          immunityType = immunityType or ccType,
          drType = drType,
          isHiddenCC = isHiddenCC,
          spellGoHit = true,  -- We already know it hit
        })
      end

      -- PERSONAL DEBUFF TRACKING: Bridge for [debuff:X>Y] conditionals
      -- Without SuperWoW's UNIT_CASTEVENT or pfUI, personal debuffs never reach lib.objects.
      -- This replicates the relevant personal debuff logic from UNIT_CASTEVENT CAST handler.

      -- Pounce: Convert cast spell ID to triggered Pounce Bleed spell ID
      local trackingSpellID = spellId
      if CleveRoids.PounceToBleedMapping and CleveRoids.PounceToBleedMapping[spellId] then
        trackingSpellID = CleveRoids.PounceToBleedMapping[spellId]
        if CleveRoids.debug then
          DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00aaff[SPELL_GO Pounce\226\134\146Bleed]|r Converted cast ID %d to bleed ID %d", spellId, trackingSpellID)
          )
        end
      end

      -- Check if this is a combo point scaling spell
      local debuffDuration = nil
      local debuffComboPoints = nil
      if CleveRoids.TrackComboPointCastByID then
        debuffDuration = CleveRoids.TrackComboPointCastByID(trackingSpellID, targetGuid)
        if CleveRoids.ComboPointTracking and CleveRoids.ComboPointTracking.byID and
           CleveRoids.ComboPointTracking.byID[trackingSpellID] then
          debuffComboPoints = CleveRoids.ComboPointTracking.byID[trackingSpellID].combo_points
        end
      end

      -- If not combo scaling, try normal duration lookup
      if not debuffDuration then
        debuffDuration = lib:GetDuration(trackingSpellID, playerGUID)
        if debuffDuration and CleveRoids.ApplyAllDurationModifiers then
          debuffDuration = CleveRoids.ApplyAllDurationModifiers(trackingSpellID, debuffDuration)
        end
      end

      if debuffDuration and debuffDuration > 0 then
        -- Only process personal debuffs (shared debuffs use SeedUnit fallback)
        local isPersonal = lib:IsPersonalDebuff(trackingSpellID)

        if isPersonal then
          -- Resolve target name
          local targetName = lib.guidToName[targetGuid]
          if not targetName then
            local currentTargetGUID = CleveRoids.GetGUID("target")
            if currentTargetGUID == targetGuid then
              targetName = UnitName("target")
              lib.guidToName[targetGuid] = targetName
            end
            if not targetName then
              targetName = "Unknown"
            end
          end

          -- Check rank comparison
          local rankCheck = lib:ShouldApplyDebuffRank(targetGuid, trackingSpellID)

          if rankCheck == true then
            table.insert(lib.pendingPersonalDebuffs, {
              timestamp = GetTime(),
              targetGUID = targetGuid,
              targetName = targetName,
              spellID = trackingSpellID,
              castSpellID = spellId,
              duration = debuffDuration,
              comboPoints = debuffComboPoints,
              spellGoHit = true,  -- Already confirmed hit from SPELL_GO
            })

            if CleveRoids.debug then
              local trackingName = C_Spell.GetSpellName(trackingSpellID) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cffaaff00[SPELL_GO Pending]|r Scheduled %s (ID:%d) for tracking on %s (confirmed hit)",
                  trackingName, trackingSpellID, targetName)
              )
            end
          elseif type(rankCheck) == "table" and rankCheck.preserve then
            table.insert(lib.pendingPersonalDebuffs, {
              timestamp = GetTime(),
              targetGUID = targetGuid,
              targetName = targetName,
              spellID = rankCheck.preserve,
              duration = rankCheck.timeRemaining,
              comboPoints = debuffComboPoints,
              isRankPreserve = true,
              spellGoHit = true,
            })

            if CleveRoids.debug then
              local preserveName = C_Spell.GetSpellName(rankCheck.preserve) or "Unknown"
              DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cffaaff00[SPELL_GO Pending]|r Scheduled rank preserve for %s (ID:%d, %.1fs remaining) on %s",
                  preserveName, rankCheck.preserve, rankCheck.timeRemaining, targetName)
              )
            end
          end

          -- Name-based combo tracking for pfUI compatibility
          if debuffComboPoints and debuffComboPoints > 0 and CleveRoids.ComboPointTracking then
            local baseName = CleveRoids.StripRank(spellName)
            CleveRoids.ComboPointTracking[baseName] = {
              combo_points = debuffComboPoints,
              duration = debuffDuration,
              cast_time = GetTime(),
              target = targetName,
              confirmed = true
            }
            -- Update pfUI's duration database directly (pre-7.6 only)
            if pfUI and pfUI.api and pfUI.api.libdebuff and pfUI.api.libdebuff.debuffs then
              pfUI.api.libdebuff.debuffs[baseName] = debuffDuration
            end
          end

          -- Set up learning for combo spells
          if debuffComboPoints then
            lib.learnCastTimers[targetGuid] = lib.learnCastTimers[targetGuid] or {}
            lib.learnCastTimers[targetGuid][spellId] = {
              start = GetTime(),
              caster = playerGUID,
              comboPoints = debuffComboPoints
            }
          end
        end
      end
    end

  elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
    -- Skip if pfUI enhanced tracking is active
    if lib.hasPfUIEnhanced then return end

    local spellId = arg1
    local casterGuid = arg2
    local targetGuid = arg3
    local durationMs = arg8

    if not spellId or not targetGuid then return end
    targetGuid = CleveRoids.NormalizeGUID(targetGuid)

    local spellName = C_Spell.GetSpellName(spellId)
    local spellRankStr = C_Spell.GetSpellSubtext(spellId)
    local texture = lib:GetCachedIcon(spellId)
    if not spellName then return end

    -- Extract rank number
    local rankNum = 0
    if spellRankStr and spellRankStr ~= "" then
      rankNum = tonumber((string.gsub(spellRankStr, "Rank ", ""))) or 0
    end

    local duration = durationMs and (durationMs / 1000) or 0
    local now = GetTime()
    local playerGUID = CleveRoids.GetGUID("player")
    local isOurs = (playerGUID and casterGuid == playerGUID)

    -- Check if this debuff recently failed (miss/dodge/parry) on this specific target
    if isOurs and lib:DidSpellFail(spellName, targetGuid) then
      return  -- Don't track - spell failed
    end

    -- Handle combo point abilities for our casts
    if isOurs and lib.combopointAbilities[spellName] then
      -- Priority order for combo points:
      -- 1. UNIT_SPELLCAST_SENT capture (client-side, before server consumes CP)
      -- 2. pendingCasts from SPELL_GO (captured on spell landing)
      -- 3. CleveRoids.lastComboPoints (from pre-cast hooks)
      -- 4. GetComboPoints() (might be 0 if already consumed)
      local comboPoints = 0
      local comboSource = "none"

      -- PRIMARY: Check UNIT_SPELLCAST_SENT capture (most reliable - client-side pre-server)
      local castPending = CleveRoids.sentCasts and CleveRoids.sentCasts[spellId]
      if castPending and castPending.comboPoints and castPending.comboPoints > 0 then
        comboPoints = castPending.comboPoints
        comboSource = "UNIT_SPELLCAST_SENT"
      end

      -- Fallback: Check lib.pendingCasts (populated by SPELL_GO)
      if comboPoints == 0 and lib.pendingCasts[targetGuid] and lib.pendingCasts[targetGuid][spellName] then
        local pending = lib.pendingCasts[targetGuid][spellName]
        local age = GetTime() - (pending.capturedAt or 0)
        if pending.comboPoints and pending.comboPoints > 0 and age < 2.0 then
          comboPoints = pending.comboPoints
          comboSource = "SPELL_GO"
        end
      end

      -- Clean up lib.pendingCasts after reading (regardless of which source won)
      if lib.pendingCasts[targetGuid] and lib.pendingCasts[targetGuid][spellName] then
        lib.pendingCasts[targetGuid][spellName] = nil
      end

      -- Fallback to lastComboPoints
      if comboPoints == 0 and CleveRoids.lastComboPoints and CleveRoids.lastComboPoints > 0 then
        comboPoints = CleveRoids.lastComboPoints
        comboSource = "lastComboPoints"
      end

      -- Last resort: current GetComboPoints (might be 0)
      if comboPoints == 0 then
        comboPoints = CleveRoids.GetComboPoints and CleveRoids.GetComboPoints() or 0
        if comboPoints > 0 then
          comboSource = "GetComboPoints"
        end
      end

      -- Default to 1 CP if we couldn't find any data
      if comboPoints == 0 then
        comboPoints = 1
        comboSource = "default"
      end

      if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cff00aaff[AURA_CAST COMBO]|r %s using %d CP (source: %s)",
            spellName, comboPoints, comboSource)
        )
      end

      -- Use our GetDuration which handles combo points
      duration = lib:GetDuration(spellId, casterGuid, comboPoints)
    end

    -- Store in appropriate table
    if isOurs then
      lib.ownDebuffs[targetGuid] = lib.ownDebuffs[targetGuid] or {}

      -- Check existing for rank comparison
      local existing = lib.ownDebuffs[targetGuid][spellName]
      if existing and existing.startTime and existing.duration then
        local timeleft = (existing.startTime + existing.duration) - now
        if timeleft > 0 and rankNum > 0 and existing.rank and rankNum < existing.rank then
          CleveRoids.DebugChanged("auracast_rank_" .. spellName .. "_" .. tostring(targetGuid),
            string.format("|cffff6600[AURA_CAST RANK BLOCK]|r %s Rank %d cannot overwrite Rank %d",
              spellName, rankNum, existing.rank))
          return
        end
      end

      lib.ownDebuffs[targetGuid][spellName] = {
        startTime = now,
        duration = duration,
        texture = texture,
        rank = rankNum,
        spellId = spellId,
        stacks = 1,
        slot = nil,  -- Will be set by DEBUFF_ADDED
      }

      if CleveRoids.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
          string.format("|cff00ffff[AURA_CAST OURS]|r %s duration=%.1fs target=%s",
            spellName, duration, lib.guidToName[targetGuid] or "Unknown")
        )
      end
    else
      -- Other player's debuff
      lib.allAuraCasts[targetGuid] = lib.allAuraCasts[targetGuid] or {}
      lib.allAuraCasts[targetGuid][spellName] = lib.allAuraCasts[targetGuid][spellName] or {}
      lib.allAuraCasts[targetGuid][spellName][casterGuid] = {
        startTime = now,
        duration = duration,
        rank = rankNum,
      }
    end

  elseif event == "DEBUFF_ADDED_OTHER" then
    -- Skip if pfUI enhanced tracking is active
    if lib.hasPfUIEnhanced then return end

    local guid = arg1
    local slot = arg2
    local spellId = arg3
    local stacks = arg4 or 1
    local auraSlot = arg6  -- v2.30+: raw 0-based aura slot index (stable, no shifting)
    local state = arg7     -- v2.32+: 0=added, 1=removed, 2=modified (stack increase)

    if not guid or not slot or not spellId then return end
    guid = CleveRoids.NormalizeGUID(guid)

    local spellName = C_Spell.GetSpellName(spellId)
    if not spellName then return end

    local playerGUID = CleveRoids.GetGUID("player")
    local isOurs = lib.ownDebuffs[guid] and lib.ownDebuffs[guid][spellName] ~= nil

    -- v2.32+: state == 2 means stack increase - update stacks on existing entry
    if state == 2 and isOurs then
      lib.ownDebuffs[guid][spellName].stacks = stacks
      lib.ownDebuffs[guid][spellName].slot = slot
      if auraSlot then
        lib.ownDebuffs[guid][spellName].auraSlot = auraSlot
      end
      return
    end

    -- Update slot info in ownDebuffs if this is our debuff
    if isOurs then
      lib.ownDebuffs[guid][spellName].slot = slot
      if auraSlot then
        lib.ownDebuffs[guid][spellName].auraSlot = auraSlot
      end
    end

    -- Determine caster GUID
    local casterGuid = playerGUID  -- Default to player
    if lib.allAuraCasts[guid] and lib.allAuraCasts[guid][spellName] then
      for cGuid, _ in pairs(lib.allAuraCasts[guid][spellName]) do
        casterGuid = cGuid
        break
      end
    end

    -- v2.30+: Use stable auraSlot for slotOwnership (no shifting needed)
    if auraSlot then
      lib.slotOwnership[guid] = lib.slotOwnership[guid] or {}
      lib.slotOwnership[guid][auraSlot] = {
        casterGuid = casterGuid,
        spellName = spellName,
        spellId = spellId,
        isOurs = isOurs,
      }
    end

    -- Legacy: Update allSlots for slot tracking (pre-v2.30 or fallback)
    -- Skip if luaSlot is 0 (hidden aura in v3.0+)
    if slot > 0 then
      lib.allSlots[guid] = lib.allSlots[guid] or {}
      lib.allSlots[guid][slot] = {
        spellName = spellName,
        casterGuid = casterGuid,
        isOurs = isOurs,
      }
    end

  elseif event == "DEBUFF_REMOVED_OTHER" then
    -- Skip if pfUI enhanced tracking is active
    if lib.hasPfUIEnhanced then return end

    local guid = arg1
    local slot = arg2
    local spellId = arg3
    local stacks = arg4     -- v2.32+: current stack count after decrement
    local auraSlot = arg6   -- v2.30+: raw 0-based aura slot index (stable, no shifting)
    local state = arg7      -- v2.32+: 0=added, 1=removed, 2=modified (stack decrease)

    if not guid or not slot then return end
    guid = CleveRoids.NormalizeGUID(guid)

    local spellName = spellId and C_Spell.GetSpellName(spellId)

    -- v2.32+: state == 2 means stack decrease - update stacks, don't remove
    if state == 2 and stacks and stacks > 0 then
      if spellName and lib.ownDebuffs[guid] and lib.ownDebuffs[guid][spellName] then
        lib.ownDebuffs[guid][spellName].stacks = stacks
      end
      return
    end

    -- Full removal (state == 1, or nil for pre-v2.32)
    -- Remove from ownDebuffs if present
    if spellName and lib.ownDebuffs[guid] and lib.ownDebuffs[guid][spellName] then
      lib.ownDebuffs[guid][spellName] = nil
    end

    -- Remove from ownSlots
    -- Skip if luaSlot is 0 (hidden aura in v3.0+)
    if slot > 0 and lib.ownSlots[guid] and lib.ownSlots[guid][slot] then
      lib.ownSlots[guid][slot] = nil
    end

    -- v2.30+: Remove from stable slotOwnership (no shifting needed!)
    if auraSlot and lib.slotOwnership[guid] then
      lib.slotOwnership[guid][auraSlot] = nil
    end

    -- Legacy: Remove from allSlots and shift slots down (pre-v2.30 or fallback)
    -- Skip if luaSlot is 0 (hidden aura in v3.0+)
    if slot > 0 and lib.allSlots[guid] and lib.allSlots[guid][slot] then
      lib.allSlots[guid][slot] = nil

      -- Shift slots down (only needed for legacy slot tracking)
      local maxSlot = 0
      for s in pairs(lib.allSlots[guid]) do
        if s > maxSlot then maxSlot = s end
      end

      for s = slot + 1, maxSlot + 1 do
        if lib.allSlots[guid][s] then
          lib.allSlots[guid][s - 1] = lib.allSlots[guid][s]
          lib.allSlots[guid][s] = nil
        end
      end
    end

  -- NAMPOWER v2.30+ BUFF_REMOVED_SELF - Player's own buffs removed
  elseif event == "BUFF_REMOVED_SELF" then
    if lib.hasPfUIEnhanced then return end

    local spellId = arg3
    local state   = arg7
    if not spellId then return end
    if state == 2 then return end  -- Stack decrease only, not full removal

    local spellName = C_Spell.GetSpellName(spellId)

    -- Also prune from OverflowBuffs (existing system)
    if spellId and CleveRoids.OverflowBuffs and CleveRoids.OverflowBuffs[spellId] then
      CleveRoids.OverflowBuffs[spellId] = nil
    end

    -- Also prune from combat log fallback overflow table (name-based)
    if spellName and CleveRoids.OverflowBuffsByName then
      local lowerName = string.lower(spellName)
      if CleveRoids.OverflowBuffsByName[lowerName] then
        CleveRoids.OverflowBuffsByName[lowerName] = nil
      end
    end

  -- NAMPOWER v2.30+ BUFF_REMOVED_OTHER - Buffs removed from other units
  elseif event == "BUFF_REMOVED_OTHER" then
    if lib.hasPfUIEnhanced then return end

    local guid    = CleveRoids.NormalizeGUID(arg1)
    local spellId = arg3
    local state   = arg7
    if not guid or not spellId then return end
    if state == 2 then return end  -- Stack decrease only, not full removal

    local spellName = C_Spell.GetSpellName(spellId)

    -- Also clean AllCasterAuraTracking (keyed by spellName)
    if spellName and CleveRoids.AllCasterAuraTracking[guid] then
      if CleveRoids.AllCasterAuraTracking[guid][spellName] then
        CleveRoids.AllCasterAuraTracking[guid][spellName] = nil
        if not next(CleveRoids.AllCasterAuraTracking[guid]) then
          CleveRoids.AllCasterAuraTracking[guid] = nil
        end
      end
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

  -- Clean up all tracking data for this GUID immediately
  if lib.ownDebuffs[guid] then
    lib.ownDebuffs[guid] = nil
  end
  if lib.ownSlots[guid] then
    lib.ownSlots[guid] = nil
  end
  if lib.allSlots[guid] then
    lib.allSlots[guid] = nil
  end
  if lib.slotOwnership[guid] then
    lib.slotOwnership[guid] = nil
  end
  if lib.allAuraCasts[guid] then
    lib.allAuraCasts[guid] = nil
  end
  if lib.pendingCasts[guid] then
    lib.pendingCasts[guid] = nil
  end
  if lib.recentMisses and lib.recentMisses[guid] then
    lib.recentMisses[guid] = nil
  end
  if lib.recentCCHits and lib.recentCCHits[guid] then
    lib.recentCCHits[guid] = nil
  end

  -- Clean up buff tracking tables

  -- Clean up cast tracking for this unit (they can't be casting if dead)
  if CleveRoids.castTracking[guid] then
    CleveRoids.castTracking[guid] = nil
  end

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

-- Cleanup dead/invalid targets
local evCleanup = CreateFrame("Frame", "CleveRoidsLibDebuffCleanupFrame", UIParent)
evCleanup:RegisterEvent("PLAYER_TARGET_CHANGED")
evCleanup:RegisterEvent("PLAYER_DEAD")
evCleanup:RegisterEvent("PLAYER_ENTERING_WORLD")

local lastCleanup = 0
local CLEANUP_THROTTLE = 2  -- Only run cleanup every 2 seconds max

evCleanup:SetScript("OnEvent", function()
    local timestamp = GetTime()

    -- Cleanup on zone change / login / death
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_DEAD" then
        -- Keep only current target's data
        local currentGUID = CleveRoids.GetGUID("target")
        if currentGUID then
            local temp = lib.objects[currentGUID]
            lib.objects = {}
            if temp then
                lib.objects[currentGUID] = temp
            end
        else
            lib.objects = {}  -- Clear everything
        end
        lastCleanup = timestamp
        return
    end

    -- Throttle cleanup on target change
    if event == "PLAYER_TARGET_CHANGED" then
        if (timestamp - lastCleanup) < CLEANUP_THROTTLE then
            return  -- Don't cleanup too frequently
        end
        lastCleanup = timestamp

        -- Remove expired effects from all GUIDs
        for guid, effects in pairs(lib.objects) do
            local targetGUID = CleveRoids.GetGUID("target")
            local isCurrentTarget = (targetGUID == guid)

            -- Check if current target is dead
            if isCurrentTarget and CleveRoids.IsUnitDead("target") then
                lib.objects[guid] = nil
                lib.guidToName[guid] = nil  -- MEMORY: Clean up name mapping
            else
                -- Remove expired effects
                for spellID, effect in pairs(effects) do
                    if effect.start + effect.duration < timestamp then
                        effects[spellID] = nil
                    end
                end

                -- Remove GUID if no effects remain (but keep current target)
                if not next(effects) and not isCurrentTarget then
                    lib.objects[guid] = nil
                    lib.guidToName[guid] = nil  -- MEMORY: Clean up name mapping
                end
            end
        end

        -- MEMORY: Clean up orphaned guidToName entries (GUIDs not in lib.objects)
        for guid in pairs(lib.guidToName) do
            if not lib.objects[guid] then
                lib.guidToName[guid] = nil
            end
        end
    end
end)

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

-- Cancel pending verification entries when immunity is confirmed from combat log
-- This prevents redundant 0.2s verification when combat log already told us about immunity
-- Parameters:
--   targetName: Name of the target (required)
--   spellName: Name of the spell (optional - if nil, cancels ALL pending entries for target)
local function CancelPendingVerification(targetName, spellName)
    if not targetName or targetName == "" then return end

    local debug = CleveRoids.debug
    local lowerTarget = string.lower(targetName)
    local lowerSpell = spellName and string.lower(string.gsub(spellName, "%s*%(.-%)%s*$", ""))

    -- Cancel pending CC debuff entries
    if lib.pendingCCDebuffs then
        local toRemove = {}
        for i, pending in ipairs(lib.pendingCCDebuffs) do
            local matches = false
            if pending.targetName and string.lower(pending.targetName) == lowerTarget then
                if lowerSpell then
                    -- Specific spell - only cancel if spell matches
                    local pendingSpellName = pending.spellName and string.lower(string.gsub(pending.spellName, "%s*%(.-%)%s*$", ""))
                    if pendingSpellName and pendingSpellName == lowerSpell then
                        matches = true
                    end
                else
                    -- No spell specified - cancel all for this target
                    matches = true
                end
            end
            if matches then
                if debug then
                    DEFAULT_CHAT_FRAME:AddMessage(
                        string.format("|cff00aaff[Combat Log Immune]|r Cancelled pending CC verification for %s on %s - combat log confirmed immunity",
                            pending.ccType or "CC", targetName)
                    )
                end
                table.insert(toRemove, i)
            end
        end
        for i = table.getn(toRemove), 1, -1 do
            table.remove(lib.pendingCCDebuffs, toRemove[i])
        end
    end

    -- Cancel pending shared debuff entries
    if lib.pendingSharedDebuffs then
        local toRemove = {}
        for i, pending in ipairs(lib.pendingSharedDebuffs) do
            local matches = false
            if pending.targetName and string.lower(pending.targetName) == lowerTarget then
                if lowerSpell then
                    local pendingSpellName = pending.spellID and C_Spell.GetSpellName(pending.spellID)
                    pendingSpellName = pendingSpellName and string.lower(string.gsub(pendingSpellName, "%s*%(.-%)%s*$", ""))
                    if pendingSpellName and pendingSpellName == lowerSpell then
                        matches = true
                    end
                else
                    matches = true
                end
            end
            if matches then
                if debug then
                    local spellNameDebug = pending.spellID and C_Spell.GetSpellName(pending.spellID) or "Unknown"
                    DEFAULT_CHAT_FRAME:AddMessage(
                        string.format("|cff00aaff[Combat Log Immune]|r Cancelled pending shared debuff verification for %s on %s - combat log confirmed immunity",
                            spellNameDebug, targetName)
                    )
                end
                table.insert(toRemove, i)
            end
        end
        for i = table.getn(toRemove), 1, -1 do
            table.remove(lib.pendingSharedDebuffs, toRemove[i])
        end
    end

    -- Cancel pending personal debuff entries (bleeds)
    if lib.pendingPersonalDebuffs then
        local toRemove = {}
        for i, pending in ipairs(lib.pendingPersonalDebuffs) do
            local matches = false
            if pending.targetName and string.lower(pending.targetName) == lowerTarget then
                if lowerSpell then
                    local pendingSpellName = pending.spellID and C_Spell.GetSpellName(pending.spellID)
                    pendingSpellName = pendingSpellName and string.lower(string.gsub(pendingSpellName, "%s*%(.-%)%s*$", ""))
                    local castSpellName = pending.castSpellID and C_Spell.GetSpellName(pending.castSpellID)
                    castSpellName = castSpellName and string.lower(string.gsub(castSpellName, "%s*%(.-%)%s*$", ""))
                    if (pendingSpellName and pendingSpellName == lowerSpell) or
                       (castSpellName and castSpellName == lowerSpell) then
                        matches = true
                    end
                else
                    matches = true
                end
            end
            if matches then
                if debug then
                    local spellNameDebug = pending.spellID and C_Spell.GetSpellName(pending.spellID) or "Unknown"
                    DEFAULT_CHAT_FRAME:AddMessage(
                        string.format("|cff00aaff[Combat Log Immune]|r Cancelled pending personal debuff verification for %s on %s - combat log confirmed immunity",
                            spellNameDebug, targetName)
                    )
                end
                table.insert(toRemove, i)
            end
        end
        for i = table.getn(toRemove), 1, -1 do
            table.remove(lib.pendingPersonalDebuffs, toRemove[i])
        end
    end
end

-- A debuff landed on a unit (SPELL_AURA_APPLIED). For a tracked CC effect
-- (like Pounce stun) or bleed, this confirms the effect worked and removes any
-- false immunity record.
local function HandleAffliction(targetName, spellName)
    if not targetName or not spellName then return end

    -- Check if this is a tracked spell (CC or bleed)
    local affliction = lib.trackedAfflictions and lib.trackedAfflictions[spellName]
    if not affliction then
        return  -- Not a tracked spell, ignore
    end

    if affliction.type == "cc" then
        -- CC effect landed - remove any false CC immunity
        if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cff00ff00[CC Landed]|r %s afflicted by %s (%s)",
                    targetName, spellName, affliction.value)
            )
        end
        RemoveCCImmunity(targetName, affliction.value)

        -- Mark any pending CC verification for this target/spell as verified
        -- This prevents false immunity recordings when "afflicted by" message arrives
        -- before the verification delay completes (especially for hidden CC spells)
        if lib.pendingCCDebuffs then
            for _, pending in ipairs(lib.pendingCCDebuffs) do
                if pending.targetName == targetName and
                   pending.ccType == affliction.value and
                   not pending.verifiedByAffliction then
                    pending.verifiedByAffliction = true
                    if CleveRoids.debug then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            string.format("|cff00aaff[CC Verified Early]|r %s on %s confirmed via SPELL_AURA_APPLIED",
                                pending.ccType, targetName)
                        )
                    end
                    break  -- Only mark one pending entry
                end
            end
        end

    elseif affliction.type == "school" then
        -- School/bleed effect landed - remove any false school immunity
        if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("|cff00ff00[Bleed Landed]|r %s afflicted by %s (%s)",
                    targetName, spellName, affliction.value)
            )
        end
        RemoveSpellImmunity(targetName, affliction.value)

        -- Mark any pending bleed verification for this target/spell as verified
        -- This prevents false immunity recordings when target dies before verification
        -- (e.g., Rake lands, target dies at 0.1s, verification at 0.2s would miss it)
        if lib.pendingPersonalDebuffs then
            for _, pending in ipairs(lib.pendingPersonalDebuffs) do
                if pending.targetName == targetName and not pending.verifiedByAffliction then
                    -- Check if this pending entry matches the affliction spell
                    local pendingSpellName = pending.spellID and C_Spell.GetSpellName(pending.spellID)
                    if pendingSpellName then
                        -- Strip rank info for comparison
                        pendingSpellName = string.gsub(pendingSpellName, "%s*%(.-%)%s*$", "")
                        local afflictionSpellName = string.gsub(spellName, "%s*%(.-%)%s*$", "")
                        if string.lower(pendingSpellName) == string.lower(afflictionSpellName) then
                            pending.verifiedByAffliction = true
                            if CleveRoids.debug then
                                DEFAULT_CHAT_FRAME:AddMessage(
                                    string.format("|cff00aaff[Bleed Verified Early]|r %s on %s confirmed via SPELL_AURA_APPLIED",
                                        pendingSpellName, targetName)
                                )
                            end
                            break  -- Only mark one pending entry
                        end
                    end
                end
            end
        end
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

    -- Cancel any pending delayed verification immediately
    CancelPendingVerification(targetName, spellName)

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

    if subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" then
        -- spellId, spellName, spellSchool, missType
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, a4, nil)
        if sourceGUID == playerGUID then
            ProcessSpellMissSelf(a1, destGUID, destName, a4)
        end
    elseif subevent == "SWING_MISSED" then
        -- missType
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, a1, nil)
    elseif subevent == "SWING_DAMAGE" then
        -- amount, overkill, school, resisted, blocked
        ProcessAvoidance(sourceGUID, destGUID, playerGUID, nil, a5)
    elseif subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "RANGE_DAMAGE" then
        -- spellId, spellName, spellSchool, amount, overkill, school, resisted
        LearnSpellSchool(a1, a3, subevent == "SPELL_PERIODIC_DAMAGE")
        if a7 and sourceGUID == playerGUID then
            CleveRoids.SetResistState("partial", destGUID)
        end
    elseif subevent == "SPELL_AURA_APPLIED" then
        -- spellId, spellName, spellSchool, auraType
        if a4 == "DEBUFF" then
            HandleAffliction(destName, a2)
        end
    elseif subevent == "UNIT_DIED" then
        HandleUnitDied(destGUID)
    end
end)
