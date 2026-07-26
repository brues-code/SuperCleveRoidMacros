--[[
	Author: Dennis Werner Garske (DWG) / brian / Mewtiny
	License: MIT License
]]
local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}

local Extension = CleveRoids.RegisterExtension("sRaidFrames")

function Extension:OnEnter(frame)
    CleveRoids.SetMouseoverFrom("sraid", frame.unit)
end

function Extension.OnLeave()
    CleveRoids.ClearMouseoverFrom("sraid")
    CleveRoids.ClearMouseoverFrom("native")
end

function Extension.OnLoad()
    Extension.HookMethod(sRaidFrames, "UnitTooltip", "OnEnter")
    Extension.HookMethod(_G["GameTooltip"], "Hide", "OnLeave")
    Extension.HookMethod(_G["GameTooltip"], "FadeOut", "OnLeave")
end

EventUtil.ContinueOnAddOnLoaded("sRaidFrames", Extension.OnLoad)
