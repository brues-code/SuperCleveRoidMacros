--[[
	Author  : Dennis Werner Garske (DWG) / brian / Mewtiny
	License : MIT License
]]
local _G = _G or getfenv(0)
local CleveRoids = _G.CleveRoids or {}
CleveRoids.Locale = GetLocale()
CleveRoids.Localized = {}

if CleveRoids.Locale == "enUS" or CleveRoids.Locale == "enGB" then
    CleveRoids.Localized.Attack    = "Attack"
    CleveRoids.Localized.AutoShot  = "Auto Shot"
    CleveRoids.Localized.Shoot     = "Shoot"

    -- target creature and run:
    -- /script local ct, uc = UnitCreatureType("target"),UnitClassification("target"); DEFAULT_CHAT_FRAME:AddMessage("\n\nUnitCreatureType: ["..ct.."]\nUnitClassificationType: ["..uc.."]\n\n");
    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "Beast",
        ["Critter"]       = "Critter",
        ["Demon"]         = "Demon",
        ["Dragonkin"]     = "Dragonkin",
        ["Elemental"]     = "Elemental",
        ["Giant"]         = "Giant",
        ["Humanoid"]      = "Humanoid",
        ["Mechanical"]    = "Mechanical",
        ["Not specified"] = "Not Specified",
        ["Totem"]         = "Totem",
        ["Undead"]        = "Undead",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "Shadowform",
        ["Stealth"]         = "Stealth",
        ["Prowl"]           = "Prowl",
        ["Shadowmeld"]      = "Shadowmeld",
    }
elseif CleveRoids.Locale == "deDE" then
    CleveRoids.Localized.Attack    = "Angriff"
    CleveRoids.Localized.AutoShot  = "Automatischer Schuss"
    CleveRoids.Localized.Shoot     = "Schießen"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "Wildtier",
        ["Critter"]       = "Kleintier",
        ["Demon"]         = "Dämon",
        ["Dragonkin"]     = "Drachkin",
        ["Elemental"]     = "Elementar",
        ["Giant"]         = "Riese",
        ["Humanoid"]      = "Humanoid",
        ["Mechanical"]    = "Mechanisch",
        ["Not Specified"] = "Nicht spezifiziert",
        ["Totem"]         = "Totem",
        ["Undead"]        = "Untoter",
    }


    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "Schattengestalt",
        ["Stealth"]         = "Verstohlenheit",
        ["Prowl"]           = "Schleichen",
        ["Shadowmeld"]      = "Schattenmimik",
    }
elseif CleveRoids.Locale == "frFR" then
    CleveRoids.Localized.Attack    = "Attack"
    CleveRoids.Localized.AutoShot  = "Auto Shot"
    CleveRoids.Localized.Shoot     = "Shoot"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "Bête",
        ["Critter"]       = "Bestiole",
        ["Demon"]         = "Démon",
        ["Dragonkin"]     = "Draconien",
        ["Elemental"]     = "Elémentaire",
        ["Giant"]         = "Géant",
        ["Humanoid"]      = "Humanoïde",
        ["Mechanical"]    = "Machine",
        ["Not Specified"] = "Non spécifié",
        ["Totem"]         = "Totem",
        ["Undead"]        = "Mort-vivant",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "Forme d'Ombre",
        ["Stealth"]         = "Camouflage",
        ["Prowl"]           = "Rôder",
        ["Shadowmeld"]      = "Camouflage dans l'ombre",
    }
elseif CleveRoids.Locale == "koKR" then
    CleveRoids.Localized.Attack    = "Attack"
    CleveRoids.Localized.AutoShot  = "Auto Shot"
    CleveRoids.Localized.Shoot     = "Shoot"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "야수",
        ["Critter"]       = "동물",
        ["Demon"]         = "악마",
        ["Dragonkin"]     = "용족",
        ["Elemental"]     = "정령",
        ["Giant"]         = "거인",
        ["Humanoid"]      = "인간형",
        ["Mechanical"]    = "기계",
        ["Not Specified"] = "기타",
        ["Totem"]         = "토템",
        ["Undead"]        = "언데드",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "어둠의 형상",
        ["Stealth"]         = "은신",
        ["Prowl"]           = "숨기",
        ["Shadowmeld"]      = "그림자 숨기",
    }
elseif CleveRoids.Locale == "zhCN" then
    CleveRoids.Localized.Attack    = "攻击"
    CleveRoids.Localized.AutoShot  = "自动射击"
    CleveRoids.Localized.Shoot     = "射击"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "野兽",
        ["Critter"]       = "小动物",
        ["Demon"]         = "恶魔",
        ["Dragonkin"]     = "龙类",
        ["Elemental"]     = "元素生物",
        ["Giant"]         = "巨人",
        ["Humanoid"]      = "人型生物",
        ["Mechanical"]    = "机械",
        ["Not Specified"] = "未指定",
        ["Totem"]         = "图腾",
        ["Undead"]        = "亡灵",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "暗影形态",
        ["Stealth"]         = "潜行",
        ["Prowl"]           = "潜行",
        ["Shadowmeld"]      = "影遁",
    }
elseif CleveRoids.Locale == "zhTW" then
    CleveRoids.Localized.Attack    = "攻擊"
    CleveRoids.Localized.AutoShot  = "自動射擊"
    CleveRoids.Localized.Shoot     = "射擊"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "野獸",
        ["Critter"]       = "小動物",
        ["Demon"]         = "惡魔",
        ["Dragonkin"]     = "龍類",
        ["Elemental"]     = "元素生物",
        ["Giant"]         = "巨人",
        ["Humanoid"]      = "人型生物",
        ["Mechanical"]    = "機械",
        ["Not Specified"] = "不明",
        ["Totem"]         = "圖騰",
        ["Undead"]        = "不死族",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "暗影形態",
        ["Stealth"]         = "隱形",
        ["Prowl"]           = "徘徊",
        ["Shadowmeld"]      = "影遁",
    }
elseif CleveRoids.Locale == "ruRU" then
    CleveRoids.Localized.Attack    = "Attack"
    CleveRoids.Localized.AutoShot  = "Auto Shot"
    CleveRoids.Localized.Shoot     = "Shoot"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "Животное",
        ["Critter"]       = "Существо",
        ["Demon"]         = "Демон",
        ["Dragonkin"]     = "Дракон",
        ["Elemental"]     = "Элементаль",
        ["Giant"]         = "Великан",
        ["Humanoid"]      = "Гуманоид",
        ["Mechanical"]    = "Механизм",
        ["Not Specified"] = "Не указано",
        ["Totem"]         = "Тотем",
        ["Undead"]        = "Нежить",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "Облик Тени",
        ["Stealth"]         = "Незаметность",
        ["Prowl"]           = "Крадущийся зверь",
        ["Shadowmeld"]      = "Слияние с тенью",
    }
elseif CleveRoids.Locale == "esES" then
    CleveRoids.Localized.Attack    = "Attack"
    CleveRoids.Localized.AutoShot  = "Auto Shot"
    CleveRoids.Localized.Shoot     = "Shoot"

    CleveRoids.Localized.CreatureTypes = {
        ["Beast"]         = "Bestia",
        ["Critter"]       = "Alma",
        ["Demon"]         = "Demonio",
        ["Dragonkin"]     = "Dragon",
        ["Elemental"]     = "Elemental",
        ["Giant"]         = "Gigante",
        ["Humanoid"]      = "Humanoide",
        ["Mechanical"]    = "Mecánico",
        ["Not Specified"] = "No especificado",
        ["Totem"]         = "Tótem",
        ["Undead"]        = "No-muerto",
    }

    CleveRoids.Localized.Spells = {
        ["Shadowform"]      = "Forma de las Sombras",
        ["Stealth"]         = "Sigilo",
        ["Prowl"]           = "Acechar",
        ["Shadowmeld"]      = "Fusión con las sombras",
    }
end

_G["CleveRoids"] = CleveRoids
