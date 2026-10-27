local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}
_G.CleveRoids = CleveRoids

-- Global flag for other addons to detect SRCM regardless of folder name
-- (pfUI macrotweak checks IsAddOnLoaded("SuperCleveRoidMacros") which fails
-- if the folder was renamed, e.g. "SuperCleveRoidMacros-main" from GitHub)
_G.SRCM_LOADED = true

CleveRoids.ready = false

CleveRoids.Hooks             = CleveRoids.Hooks      or {}
CleveRoids.Hooks.GameTooltip = {}

CleveRoids.Extensions          = CleveRoids.Extensions or {}
CleveRoids.actionEventHandlers = {}
CleveRoids.mouseOverResolvers  = {}

CleveRoids.mouseoverUnit = CleveRoids.mouseoverUnit or nil
CleveRoids.mouseOverUnit = nil

-- Every macro slot the client can hold: 18 account-wide (1-18) followed by 18
-- character-specific (19-36). This is the index space GetMacroInfo and
-- C_Macro.SetMacroDisplay address, and it is fixed -- GetNumMacros() returns how
-- many of each tab are *used*, which cannot be summed into a range, because the
-- character block starts at 19 no matter how few account macros exist. Blizzard's
-- own MAX_MACROS is no help either: it lives in the load-on-demand Blizzard_MacroUI
-- and is nil until the player opens the macro window.
CleveRoids.MAX_MACRO_SLOTS = 36

-- Environment flags
CleveRoids.hasSuperwow = SetAutoloot and true or false
CleveRoids.hasTurtle   = (type(_G.TURTLE_WOW_VERSION) ~= "nil")
CleveRoids.supported   = CleveRoids.hasTurtle

-- ClassicAPI macro display (C_Macro.SetMacroDisplay): hand ClassicAPI the resolved
-- action per macro instead of replacing the action-bar globals in Lua, so the icon,
-- tooltip, cooldown sweep, range and usable state all come from the client -- including
-- the drag cursor and the macro window grid, which Lua cannot reach.
--
-- ClassicAPI stands down from macro display entirely when it sees this addon loaded;
-- ClassicAPIMacroDisplay is what tells it we drive it instead, and ReleaseDisplays
-- clears it to hand every macro back. A fork that leaves the flag unset keeps the old
-- behavior -- both must never drive the same buttons. It doubles as the internal
-- "may we call C_Macro.SetMacroDisplay" guard, so the two can never disagree.
--
-- Feature-detect rather than version-check: SetMacroDisplay ships in ClassicAPI
-- v1.15.0, below this addon's minimum, so a nil here means the client mod is
-- missing outright -- the case Core.lua's requirement check warns about but
-- keeps running.
CleveRoids.ClassicAPIMacroDisplay =
    (type(C_Macro) == "table" and C_Macro.SetMacroDisplay ~= nil) and true or false

CleveRoids.ParsedMsg = {}
CleveRoids.ExpandedGroups = {}
CleveRoids.Items     = {}
CleveRoids.Spells    = {}
CleveRoids.PetSpells = {}
CleveRoids.Talents   = {}
CleveRoids.Cooldowns = {}
CleveRoids.Macros    = {}
CleveRoids.Actions   = {}
CleveRoids.Sequences = {}

CleveRoids.lastUpdate = 0
CleveRoids.lastGetItem = nil
CleveRoids.currentSequence = nil

CleveRoids.bookTypes = {BOOKTYPE_SPELL, BOOKTYPE_PET}
CleveRoids.unknownTexture = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Combo point tracking (initialized early for /cast hook)
CleveRoids.lastComboPoints = 0
-- The player's casts as they leave the client (UNIT_SPELLCAST_SENT), so a spell
-- the player cast can be told from a proc, with a finisher's combo points
-- captured before the server spends them.
-- Format: [spellId] = { timestamp = GetTime(), comboPoints = n or nil }
CleveRoids.sentCasts = {}
CleveRoids.lastComboPointsTime = 0

-- Resist tracking state
-- Structure: { resistType = "full"|"partial", targetGUID = guid }
CleveRoids.resistState = nil

-- KEY_DOWN/KEY_UP state table (populated when Nampower v2.41+ hasKeyEvents)
CleveRoids._keyState = {}

-- Auto-attack state, driven by PLAYER_ENTER_COMBAT / PLAYER_LEAVE_COMBAT and the
-- autorepeat events
CleveRoids.CurrentSpell = {
    -- is the Attack ability enabled
    autoAttack = false,
    -- is the Auto Shot ability enabled
    autoShot = false,
    -- is the Shoot ability (wands) enabled
    wand = false,
}

-- The player's cast in progress, from ClassicAPI's cast state, which has the
-- effective cast time (haste, talents) and tracks pushback. Returns the kind
-- ("cast" or "channeled"), the spell name and the seconds left, or nil when the
-- player is not casting.
function CleveRoids.GetPlayerCast()
    local kind = "cast"
    local name, _, _, _, endMs = C_Spell.CastingInfo()
    if not name then
        kind = "channeled"
        name, _, _, _, endMs = C_Spell.ChannelInfo()
        if not name then return nil end
    end
    local remaining = endMs / 1000 - GetTime()
    if remaining < 0 then remaining = 0 end
    return kind, name, remaining
end

-- Seconds left on the player's cast of this kind ("cast" or "channeled", or nil
-- for either), 0 when not casting one.
function CleveRoids.PlayerCastTimeLeft(kind)
    local castKind, _, remaining = CleveRoids.GetPlayerCast()
    if not castKind or (kind and castKind ~= kind) then return 0 end
    return remaining
end

-- A cast this close to its end already counts as finished, so a macro can
-- queue the next spell (Nampower's spell queue) instead of being blocked.
CleveRoids.CAST_END_GRACE = 0.1

CleveRoids.dynamicCmds = {
    ["/cast"]         = true,
    ["/castpet"]      = true,
    ["/castsequence"] = true,
    ["/use"]          = true,
    ["/feedpet"]      = true,
    ["/equip"]        = true,
    ["/equipmh"]      = true,
    ["/equipoh"]      = true,
    ["/equip11"]      = true,
    ["/equip12"]      = true,
    ["/equip13"]      = true,
    ["/equip14"]      = true,
    ["/applymain"]    = true,
    ["/applyoff"]     = true,
}

-- Equipment swap queue system
CleveRoids.equipmentQueue = {}
CleveRoids.equipmentQueueLen = 0  -- PERFORMANCE: Track length to avoid table.getn() every frame
CleveRoids.lastEquipTime = {}
CleveRoids.lastGlobalEquipTime = 0
CleveRoids.EQUIP_COOLDOWN = 1.5  -- Per-slot cooldown
CleveRoids.EQUIP_GLOBAL_COOLDOWN = 0.5  -- Global cooldown

-- PERFORMANCE: Table pool for queue entries to reduce garbage collection
CleveRoids.queueEntryPool = {}

-- PERFORMANCE: Static buffer for proc removal to avoid per-frame allocation
CleveRoids._procRemovalBuffer = {}

-- PERFORMANCE: Static buffer for action grouping to avoid per-call allocation
CleveRoids._actionsToSlotsBuffer = {}
CleveRoids._slotsBuffer = {}
CleveRoids._actionsListBuffer = {}

-- PERFORMANCE: Static buffer for arg backup in SendEventForAction
CleveRoids._originalArgsBuffer = {}

-- KEYED DEBUG: Only prints when the message for a given key changes from last print.
-- Usage: CleveRoids.DebugChanged("immunity_moonfire", formatted_msg)
-- Prevents spam when the same state is reported repeatedly (e.g., per-frame or per-eval).
CleveRoids._lastDebugState = {}
function CleveRoids.DebugChanged(key, msg)
  if not CleveRoids.debug then return end
  if CleveRoids._lastDebugState[key] == msg then return end
  CleveRoids._lastDebugState[key] = msg
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

-- Spell queue state (Nampower)
CleveRoids.queuedSpell = nil

-- Macro execution control
CleveRoids.stopMacroFlag = false

-- PERFORMANCE: Event-driven cached state (updated on events, not polled)
CleveRoids._cachedPlayerInCombat = nil   -- Updated on PLAYER_REGEN_DISABLED, PLAYER_REGEN_ENABLED

CleveRoids.ignoreKeywords = {
    action        = true,
    ignoretooltip = true,
    cancelaura    = true,
    noSpam        = true,  -- ! prefix flag: prevent toggle-off at execution time
    _operators    = true,  -- Metadata for AND/OR operator tracking
    _groups       = true,  -- Grouped conditional values for AND/OR evaluation
    multiscan     = true,  -- Processed before Keywords loop (target resolution)
    cursor        = true,  -- Modifier: place ground-target spell/item at cursor (CastAtCursor)
    stopattack    = true,  -- Post-cast modifier: stop autoattack after cast (CheapShot pattern)
}

-- Deprecated conditional names, rewritten to their current keyword in ParseMsg
-- before anything downstream (evaluation, _groups) sees them. This is the path
-- for renamed *modifiers* -- ignoreKeywords entries, which have no Keywords
-- predicate that an alias could just point at the way [stl] does for [stealth].
-- MacroErrorChecker also reads this table, so the old names stay valid syntax.
CleveRoids.conditionalAliases = {
    mouseuse = "cursor",  -- pre-ClassicAPI name, back when it clicked the AoE reticle
}

-- TODO: Localize?
CleveRoids.countedItemTypes = {
    ["Consumable"]  = true,
    ["Reagent"]     = true,
    ["Projectile"]  = true,
    ["Trade Goods"] = true,
}


-- TODO: Localize?
CleveRoids.actionSlots    = {}
CleveRoids.reactiveSlots  = {}
CleveRoids.reactiveSpells = {
    ["Revenge"]         = true,
    ["Overpower"]       = true,
    ["Riposte"]         = true,
    ["Surprise Attack"] = true,
    ["Lacerate"]        = true,
    ["Baited Shot"]     = true,
    ["Counterattack"]   = true,
    ["Arcane Surge"]    = true,
    ["Aquatic Form"]    = true,
}


-- PERFORMANCE: Static lookup for toggled buff abilities (built once, used per-frame)
CleveRoids._toggledBuffAbilities = {
    [CleveRoids.Localized.Spells["Prowl"]] = true,
    [CleveRoids.Localized.Spells["Shadowmeld"]] = true,
}

function CleveRoids.IsToggledBuffAbility(spellName)
    return CleveRoids._toggledBuffAbilities[spellName]
end

-- I need to make a 2h modifier
-- Maps easy-to-use weapon type names (e.g. Axes, Shields) to their inventory
-- slot plus the locale-independent item class/subclass IDs that identify them
-- (read via C_Item.GetItemInfoInstant). class 2 = Weapon, 4 = Armor (shields).
-- subClass is a set because the logical "Axes"/"Swords"/"Maces" types span both
-- the one-handed and two-handed weapon subclasses.
CleveRoids.WeaponTypeNames = {
    Daggers   = { slot = "MainHandSlot",      class = 2, subClass = { [15] = true } },
    Fists     = { slot = "MainHandSlot",      class = 2, subClass = { [13] = true } },
    Axes      = { slot = "MainHandSlot",      class = 2, subClass = { [0] = true, [1] = true } },
    Swords    = { slot = "MainHandSlot",      class = 2, subClass = { [7] = true, [8] = true } },
    Staves    = { slot = "MainHandSlot",      class = 2, subClass = { [10] = true } },
    Maces     = { slot = "MainHandSlot",      class = 2, subClass = { [4] = true, [5] = true } },
    Polearms  = { slot = "MainHandSlot",      class = 2, subClass = { [6] = true } },
    -- OH
    Daggers2  = { slot = "SecondaryHandSlot", class = 2, subClass = { [15] = true } },
    Fists2    = { slot = "SecondaryHandSlot", class = 2, subClass = { [13] = true } },
    Axes2     = { slot = "SecondaryHandSlot", class = 2, subClass = { [0] = true, [1] = true } },
    Swords2   = { slot = "SecondaryHandSlot", class = 2, subClass = { [7] = true, [8] = true } },
    Maces2    = { slot = "SecondaryHandSlot", class = 2, subClass = { [4] = true, [5] = true } },
    Shields   = { slot = "SecondaryHandSlot", class = 4, subClass = { [6] = true } },
    -- ranged
    Guns      = { slot = "RangedSlot",        class = 2, subClass = { [3] = true } },
    Crossbows = { slot = "RangedSlot",        class = 2, subClass = { [18] = true } },
    Bows      = { slot = "RangedSlot",        class = 2, subClass = { [2] = true } },
    Thrown    = { slot = "RangedSlot",        class = 2, subClass = { [16] = true } },
    Wands     = { slot = "RangedSlot",        class = 2, subClass = { [19] = true } },
}

-- Detect available features
CleveRoids.hasNampower = (QueueSpellByName ~= nil)
CleveRoids.hasUnitXP = pcall(UnitXP, "nop", "nop")

-- Extended Nampower feature flags (populated by NampowerAPI.lua)
CleveRoids.nampowerVersion = { major = 0, minor = 0, patch = 0 }
CleveRoids.hasExtendedNampower = false  -- True if v2.12+ with new API functions

-- Feature detection messages
local function PrintFeatures()
    local features = {}
    if CleveRoids.hasSuperwow then table.insert(features, "SuperWoW") end
    if CleveRoids.hasNampower then
        local ver = CleveRoids.nampowerVersion
        if ver.major > 0 then
            table.insert(features, string.format("Nampower v%d.%d.%d", ver.major, ver.minor, ver.patch))
        else
            table.insert(features, "Nampower")
        end
    end
    if CleveRoids.hasUnitXP then table.insert(features, "UnitXP") end
    if CleveRoids.hasTurtle then table.insert(features, "Turtle") end

    if table.getn(features) > 0 then
        CleveRoids.Print("Enhanced features: " .. table.concat(features, ", "))
    end
end

-- Immunity data version - increment this when changing immunity data format
-- This will cause all immunity data to be reset on addon update
-- v3: Fixed Master Strike false physical immunity recording (split CC spell handling)
-- v4: Fixed false immunity recording when target dies with spells in-flight (dead = IMMUNE)
-- v5: Fixed false physical immunity from unknown spell schools (now uses DBC lookup; unknown defaults to nil not "physical")
-- v6: Reset stale immunity data that may contain false positives
CleveRoids.IMMUNITY_DATA_VERSION = 6

-- Call on next frame to ensure everything is loaded
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function()
    this:UnregisterAllEvents()

    -- Check immunity data version and reset if outdated
    CleveRoidMacros = CleveRoidMacros or {}
    CleveRoids_ImmunityData = CleveRoids_ImmunityData or {}
    local savedVersion = CleveRoidMacros.immunityDataVersion or 0

    if savedVersion < CleveRoids.IMMUNITY_DATA_VERSION then
        -- Check if there was existing data to clear
        local hadData = next(CleveRoids_ImmunityData) ~= nil

        -- Version changed - reset all immunity data
        CleveRoids_ImmunityData = {}
        CleveRoidMacros.immunityDataVersion = CleveRoids.IMMUNITY_DATA_VERSION

        if hadData then
            -- Show message if we actually cleared existing data
            CleveRoids.Print("|cffff9900Immunity data reset|r - addon updated to data version " .. CleveRoids.IMMUNITY_DATA_VERSION)
        end
    end

    -- Detect pfUI macrotweak conflict (folder name mismatch)
    -- pfUI macrotweak disables itself via IsAddOnLoaded("SuperCleveRoidMacros"),
    -- but this fails when the addon folder is renamed (e.g. GitHub download adds "-main").
    -- When both are active: conflicting SendChatMessage hooks, duplicate /use and /equip
    -- handlers, and #showtooltip can leak into chat (pfUI only filters "#showtooltip "
    -- with trailing space, missing bare "#showtooltip").
    if pfUI and pfUI.module and pfUI.module["macrotweak"]
       and not IsAddOnLoaded("SuperCleveRoidMacros") then
        CleveRoids.Print("|cffff0000WARNING:|r Your addon folder name is not |cff00ff00SuperCleveRoidMacros|r.")
        CleveRoids.Print("This causes a conflict with pfUI's macrotweak module.")
        CleveRoids.Print("Please rename the folder to exactly |cff00ff00SuperCleveRoidMacros|r and /reload.")
    end

    -- Initialize NampowerAPI if available
    if CleveRoids.NampowerAPI then
        local API = CleveRoids.NampowerAPI

        -- Get version info
        local major, minor, patch = API.GetVersion()
        CleveRoids.nampowerVersion = { major = major, minor = minor, patch = patch }

        -- Check for extended API (v2.12+)
        CleveRoids.hasExtendedNampower = API.HasMinimumVersion(2, 12, 0)

        -- Sync feature flags
        if API.features then
            CleveRoids.hasGetSpellRec = API.features.hasGetSpellRec
            CleveRoids.hasGetItemStats = API.features.hasGetItemStats
            CleveRoids.hasGetUnitData = API.features.hasGetUnitData
            CleveRoids.hasGetSpellModifiers = API.features.hasGetSpellModifiers
            CleveRoids.hasEnhancedSpellFunctions = API.features.hasEnhancedSpellFunctions
            -- v2.37+: CastSpellByName supports unit token strings as 2nd param
            CleveRoids.hasCastSpellByNameUnitToken = API.features.hasCastSpellByNameUnitToken
        end

        -- Initialize the API
        API.Initialize()
    end

    PrintFeatures()
end)

_G["CleveRoids"] = CleveRoids
