local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}

local Extension = CleveRoids.RegisterExtension("Compatibility_pfUI")
Extension.Debug = false
-- pfUI-loaded and player-login handlers are wired via ClassicAPI's EventUtil at
-- the bottom of the file (ContinueOnAddOnLoaded fires immediately if pfUI already
-- loaded, so no separate "we missed pfUI's ADDON_LOADED" fallback is needed).

-- Track pfUI state
Extension.pfUILoaded = false
Extension.macrotweakLoaded = false
Extension.slashCommandsOverridden = false

function Extension.RunMacro(name)
    CleveRoids.ExecuteMacroByName(name)
end

function Extension.DLOG(msg)
    if Extension.Debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cffcccc33[R]: |cffffff55" .. ( msg ))
    end
end

-- Check if pfUI's macrotweak module is loaded
function Extension.IsPfUIMacrotweakLoaded()
    if not pfUI then return false end

    -- pfUI loads modules and stores them in pfUI.modules
    if pfUI.modules and pfUI.modules.macrotweak then
        return true
    end

    -- Also check if the slash commands exist with pfUI's pattern
    if SlashCmdList.PFUSE or SlashCmdList.PFEQUIP then
        return true
    end

    return false
end

-- Override pfUI's /use and /equip with CleveRoids versions
function Extension.OverridePfUISlashCommands()
    if Extension.slashCommandsOverridden then return end

    -- Save pfUI's original handlers as fallbacks
    if SlashCmdList.PFUSE then
        CleveRoids.Hooks.PFUI_USE = SlashCmdList.PFUSE
    end
    if SlashCmdList.PFEQUIP then
        CleveRoids.Hooks.PFUI_EQUIP = SlashCmdList.PFEQUIP
    end

    -- Override with CleveRoids' conditional-aware handlers
    SlashCmdList.USE = CleveRoids.DoUse
    SlashCmdList.EQUIP = CleveRoids.DoUse
    SlashCmdList.PFUSE = CleveRoids.DoUse
    SlashCmdList.PFEQUIP = CleveRoids.DoUse
    SlashCmdList.SMEQUIP = CleveRoids.DoUse

    Extension.slashCommandsOverridden = true

    Extension.DLOG("Overrode /use and /equip commands for conditional support")
end

-- Check and handle SendChatMessage hook compatibility
function Extension.HandleSendChatMessageHook()
    -- Check if SendChatMessage has already been hooked by something else
    local currentHook = _G.SendChatMessage
    local originalSendChat = CleveRoids.Hooks.SendChatMessage

    if not originalSendChat then return end

    -- If pfUI already hooked SendChatMessage, we need to chain properly
    if currentHook and currentHook ~= originalSendChat then
        -- pfUI's hook is in place, let it handle #showtooltip filtering
        -- Our hook is redundant, so we can skip it
        Extension.DLOG("pfUI's SendChatMessage hook detected, using pfUI's filtering")
    end
end

-- Register action event handler for pfUI button updates
function Extension.RegisterPfUIActionEventHandler()
    if not pfUI or Extension.actionHandlerRegistered then
        return
    end

    -- Register a handler that will be called whenever CleveRoids updates macro states
    if CleveRoids.RegisterActionEventHandler then
        Extension.DLOG("Registering pfUI action event handler")
        -- Declared without `...` on purpose: in 1.12's Lua 5.0 a vararg function
        -- allocates an `arg` table on every call, and this handler never read it.
        -- That mattered because UpdateAllManagedCooldowns fans
        -- ACTIONBAR_UPDATE_COOLDOWN out across every managed slot -- up to 120 calls
        -- -- on each SPELL_UPDATE_COOLDOWN, which fires on every GCD and cooldown
        -- tick. Those calls all allocated a table and then did nothing, because the
        -- whole body only ever applied to ACTIONBAR_SLOT_CHANGED. Hence the early
        -- return before any work.
        CleveRoids.RegisterActionEventHandler(function(slot, event)
            if event ~= "ACTIONBAR_SLOT_CHANGED" then return end

            local button = pfUI.bars and pfUI.bars.buttons and pfUI.bars.buttons[slot]

            if Extension.Debug then
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cff00ff00[pfUI CD]|r slot=%s event=%s button=%s cd=%s",
                    tostring(slot), tostring(event),
                    button and "yes" or "no",
                    (button and button.cd) and "yes" or "no"
                ))
            end

            -- Full button update so the icon, cooldown and tooltip refresh.
            -- pfUI's ButtonMacroScan defers to us for managed macros (leaves
            -- spellslot nil), so ButtonFullUpdate reads the stock action-bar
            -- functions -- which now resolve through the value we publish with
            -- C_Macro.SetMacroDisplay, rather than the Lua overrides this addon
            -- used to install.

            -- Mark the slot for update in pfUI's cache (processed next OnUpdate)
            if pfUI.bars and pfUI.bars.update then
                pfUI.bars.update[slot] = true
            end

            -- Also directly call ButtonFullUpdate if the button exists
            if button and pfUI.bars.ButtonFullUpdate then
                pfUI.bars.ButtonFullUpdate(button)
            end
        end)

        Extension.actionHandlerRegistered = true
        Extension.DLOG("Registered action event handler for pfUI button updates")
    end
end

-- Main compatibility check and setup
function Extension.SetupCompatibility()
    Extension.pfUILoaded = (pfUI ~= nil)
    Extension.macrotweakLoaded = Extension.IsPfUIMacrotweakLoaded()

    if Extension.pfUILoaded then
        Extension.DLOG("pfUI detected")

        -- Register action event handler for button updates
        Extension.RegisterPfUIActionEventHandler()

        if Extension.macrotweakLoaded then
            Extension.DLOG("pfUI macrotweak module detected")

            -- Override slash commands to ensure CleveRoids' conditional support works
            Extension.OverridePfUISlashCommands()

            -- Handle SendChatMessage hook
            Extension.HandleSendChatMessageHook()
        end
    end
end

-- ============================================================================
-- API Functions for pfUI Integration
-- These functions allow pfUI's actionbar module to query CleveRoids for
-- the active spell data, enabling proper cooldown/tooltip/icon display.
-- ============================================================================

-- Get the spell slot and book type for a given action slot
-- Returns: spellSlot, bookType (or nil, nil if not a CleveRoids-managed macro)
-- This is used by pfUI's ButtonMacroScan to get spell data for macros
function CleveRoids.GetActionSpellSlot(actionSlot)
    if not actionSlot then return nil, nil end

    local actions = CleveRoids.GetAction(actionSlot)
    if not actions then return nil, nil end

    -- Check if we have an active action with spell data
    if actions.active and actions.active.spell then
        local spell = actions.active.spell
        if spell.spellSlot and spell.bookType then
            return spell.spellSlot, spell.bookType
        end
    end

    -- Fallback: check tooltip action
    if actions.tooltip then
        local action = actions.tooltip
        if action.spell and action.spell.spellSlot and action.spell.bookType then
            return action.spell.spellSlot, action.spell.bookType
        end
    end

    return nil, nil
end

-- Get the spell slot and book type for a given macro name
-- Returns: spellSlot, bookType (or nil, nil if not found)
function CleveRoids.GetMacroSpellSlot(macroName)
    if not macroName then return nil, nil end

    local macro = CleveRoids.Macros[macroName]
    if not macro or not macro.actions then return nil, nil end

    local actions = macro.actions

    -- Check if we have an active action with spell data
    if actions.active and actions.active.spell then
        local spell = actions.active.spell
        if spell.spellSlot and spell.bookType then
            return spell.spellSlot, spell.bookType
        end
    end

    -- Fallback: check tooltip action
    if actions.tooltip then
        local action = actions.tooltip
        if action.spell and action.spell.spellSlot and action.spell.bookType then
            return action.spell.spellSlot, action.spell.bookType
        end
    end

    return nil, nil
end

-- Check if CleveRoids is managing a given action slot
-- Returns: true if CleveRoids has parsed this macro, false otherwise
function CleveRoids.IsManagedAction(actionSlot)
    if not actionSlot then return false end
    local actions = CleveRoids.GetAction(actionSlot)
    return actions ~= nil and (actions.tooltip ~= nil or actions.list ~= nil)
end

-- Check if CleveRoids is managing a given macro by name
-- Returns: true if CleveRoids has parsed this macro, false otherwise
function CleveRoids.IsManagedMacro(macroName)
    if not macroName then return false end
    return CleveRoids.Macros[macroName] ~= nil
end

-- Get the active spell name for a given action slot (for debugging/display)
-- Returns: spellName (or nil if not found)
function CleveRoids.GetActionActiveSpellName(actionSlot)
    if not actionSlot then return nil end

    local actions = CleveRoids.GetAction(actionSlot)
    if not actions then return nil end

    if actions.active and actions.active.action then
        return actions.active.action
    end

    if actions.tooltip and actions.tooltip.action then
        return actions.tooltip.action
    end

    return nil
end

-- ============================================================================
-- pfUI Event Hook Management
-- Centralizes all pfUI libdebuff event unregistration and hook registration.
-- Called from lib:InitPfUIIntegration() in Utility.lua.
-- ============================================================================

-- Available hooks (registered on pfUI global tables):
--   pfUI.libdebuff_spell_go_hooks["key"]               = fn(spellId, arg1..arg7)
--   pfUI.libdebuff_spell_go_other_hooks["key"]          = fn(spellId, casterGuid, targetGuid)
--   pfUI.libdebuff_spell_start_self_hooks["key"]        = fn(spellId, casterGuid, targetGuid, castTime)
--   pfUI.libdebuff_spell_start_other_hooks["key"]       = fn(spellId, casterGuid, targetGuid, castTime)
--   pfUI.libdebuff_spell_failed_other_hooks["key"]      = fn(casterGuid, spellId)
--   pfUI.libdebuff_spell_cast_hooks["key"]              = fn(success, spellId, castType, targetGuid)
--   pfUI.libdebuff_aura_cast_on_self_hooks["key"]       = fn(spellId, casterGuid, targetGuid)
--   pfUI.libdebuff_aura_cast_on_other_hooks["key"]      = fn(spellId, casterGuid, targetGuid)
--   pfUI.libdebuff_debuff_added_other_hooks["key"]      = fn(guid, luaSlot, spellId, stackCount)
--   pfUI.libdebuff_debuff_removed_other_hooks["key"]    = fn(guid, luaSlot, spellId, stackCount)
--   pfUI.libdebuff_unit_health_hooks["key"]             = fn(unitToken)
--   pfUI.libdebuff_unit_died_hooks["key"]               = fn(guid)
--   pfUI.libdebuff_player_target_changed_hooks["key"]   = fn()
--
-- Note: AURA_CAST hooks don't provide durationMs/auraCapStatus, so
-- AllCasterAuraTracking and overflow buff tracking remain on their own
-- event frame (CleveRoidsAutoAttackFrame in Conditionals.lua).

function Extension.SetupPfUIEventHooks(lib)
    if not pfUI or not lib then return end

    -- ----------------------------------------------------------------
    -- Part 1: Unregister Nampower events from CleveRoidsLibDebuffFrame
    -- that pfUI handles. All these handlers early-return when
    -- hasPfUIEnhanced, so unregistering avoids wasted event dispatch.
    -- ----------------------------------------------------------------
    local ev = CleveRoidsLibDebuffFrame
    if ev then
        -- Events whose handlers early-return when hasPfUIEnhanced
        ev:UnregisterEvent("SPELL_GO_SELF")
        ev:UnregisterEvent("SPELL_GO_OTHER")
        ev:UnregisterEvent("AURA_CAST_ON_SELF")
        ev:UnregisterEvent("AURA_CAST_ON_OTHER")
        ev:UnregisterEvent("DEBUFF_ADDED_OTHER")
        ev:UnregisterEvent("DEBUFF_REMOVED_OTHER")
        ev:UnregisterEvent("BUFF_REMOVED_SELF")
        ev:UnregisterEvent("BUFF_REMOVED_OTHER")

        -- Keep registered: SPELL_START_SELF (channel duration capture before early return),
        -- UNIT_DIED (AllCasterAuraTracking + OverflowBuff cleanup), UNIT_CASTEVENT (SuperWoW),
        -- PLAYER_TARGET_CHANGED, UNIT_AURA (SeedUnit)

        if CleveRoids.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r Unregistered redundant events (pfUI handles via hooks)")
        end
    end

    -- ----------------------------------------------------------------
    -- Part 2: Register pfUI libdebuff hooks for supplementary processing.
    -- Hooks fire after pfUI processes each event, avoiding duplicate
    -- event listeners.
    -- ----------------------------------------------------------------
    local HOOK_KEY = "SuperCleveRoidMacros"
    local registered = 0

    -- UNIT_DIED hook: supplementary cleanup for our private tables
    -- (AllCasterAuraTracking, OverflowBuffs) that pfUI doesn't manage.
    -- Our UNIT_DIED event handler on the libdebuff frame also does this,
    -- but the hook provides a second path in case event ordering shifts.
    if type(pfUI.libdebuff_unit_died_hooks) == "table" then
        pfUI.libdebuff_unit_died_hooks[HOOK_KEY] = function(guid)
            if not guid then return end
            guid = CleveRoids.NormalizeGUID(guid)

            -- Clean up AllCasterAuraTracking (our own table, not shared with pfUI)
            if CleveRoids.AllCasterAuraTracking and CleveRoids.AllCasterAuraTracking[guid] then
                CleveRoids.AllCasterAuraTracking[guid] = nil
            end

            -- Clean up OverflowBuffs on player death
            local playerGUID = CleveRoids.GetGUID("player")
            if playerGUID and guid == playerGUID then
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
        end
        registered = registered + 1
    end

    lib.pfUIHooksRegistered = registered > 0

    if CleveRoids.debug and registered > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff33ff99[libdebuff]|r Registered %d pfUI libdebuff hook(s)", registered)
        )
    end
end

function Extension.OnLoad()
    Extension.DLOG("Extension pfUI Loaded.")

    -- Export extension for external access
    CleveRoids.Compatibility_pfUI = Extension

    -- Initial compatibility check
    Extension.SetupCompatibility()

    -- Add slash command to toggle pfUI cooldown debug
    -- Usage: /pfuicd to toggle debug mode
    SlashCmdList["PFUICD"] = function()
        Extension.Debug = not Extension.Debug
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r Debug mode: " .. (Extension.Debug and "ON" or "OFF"))
        if Extension.Debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r Handler registered: " .. (Extension.actionHandlerRegistered and "YES" or "NO"))
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r pfUI detected: " .. (Extension.pfUILoaded and "YES" or "NO"))
            if pfUI and pfUI.bars then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r pfUI.bars exists: YES")
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r pfUI.bars.buttons: " .. (pfUI.bars.buttons and "YES" or "NO"))
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[pfUI Compat]|r pfUI.bars exists: NO")
            end
        end
    end
    SLASH_PFUICD1 = "/pfuicd"
end

-- Fires once pfUI has loaded (immediately if it loaded before us, via EventUtil).
function Extension.OnPfUILoaded()
    -- Guard: only the real pfUI framework sets this global (another addon could be
    -- named "pfUI" without being the UI framework).
    if not pfUI then return end
    Extension.pfUILoaded = true
    -- pfUI's submodules initialize after its ADDON_LOADED, so defer the setup.
    if CleveRoids.ScheduleTimer then
        CleveRoids.ScheduleTimer(function()
            Extension.SetupCompatibility()
        end, 0.5)
    end
end

function Extension.OnPlayerLogin()
    -- Ensure lib.objects is linked correctly (InitPfUIIntegration is idempotent).
    if pfUI then
        local lib = CleveRoids.libdebuff
        if lib and lib.InitPfUIIntegration then
            lib:InitPfUIIntegration()
        end
    end

    -- Register libdebuff downrank blocked hook now that pfUI is fully initialized.
    -- Done here (not in Core.lua PLAYER_LOGIN) because pfUI.libdebuff_downrank_blocked_hooks
    -- is only guaranteed to exist after InitPfUIIntegration has run.
    if pfUI and pfUI.libdebuff_downrank_blocked_hooks then
        table.insert(pfUI.libdebuff_downrank_blocked_hooks, function(spellName, castRank, activeRank, targetGuid, casterGuid)
            local playerGuid = CleveRoids.GetGUID("player")
            if casterGuid ~= playerGuid then return end
            CleveRoids.DownrankBlocked[targetGuid] = CleveRoids.DownrankBlocked[targetGuid] or {}
            CleveRoids.DownrankBlocked[targetGuid][spellName] = {
                castRank = castRank,
                activeRank = activeRank,
                time = GetTime()
            }
            CleveRoids.DebugChanged("downrank_hook_" .. spellName .. "_" .. tostring(targetGuid),
                string.format("|cffff0000[DownrankBlocked]|r %s Rank %d blocked by active Rank %d",
                    spellName, castRank, activeRank))
        end)
    end

    -- Final check after everything is loaded
    Extension.SetupCompatibility()

    -- Print startup status only if pfUI global exists and compatibility was set up
    if Extension.pfUILoaded and pfUI then
        local statusMsg = "|cff00ff00[SCRM]|r pfUI compatibility loaded"
        -- statusMsg = statusMsg .. ". Use /pfuicd for debug."
        DEFAULT_CHAT_FRAME:AddMessage(statusMsg)
        if not Extension.actionHandlerRegistered then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SCRM]|r WARNING: pfUI action handler NOT registered!")
        end
    end
end

-- Utility: Schedule a delayed function call via ClassicAPI's C_Timer.
if not CleveRoids.ScheduleTimer then
    CleveRoids.ScheduleTimer = function(func, delay)
        C_Timer.After(delay, function()
            -- Prevent SuperWoW API calls during shutdown (crash prevention)
            if CleveRoids.isShuttingDown then return end
            func()
        end)
    end
end

-- Wire handlers via ClassicAPI EventUtil (fires immediately if the event already
-- happened, so load order relative to pfUI no longer matters). Registered here,
-- after the handlers are defined, since ContinueOnAddOnLoaded may fire inline.
EventUtil.ContinueOnAddOnLoaded("pfUI", Extension.OnPfUILoaded)
EventUtil.ContinueOnPlayerLogin(Extension.OnPlayerLogin)

_G["CleveRoids"] = CleveRoids
