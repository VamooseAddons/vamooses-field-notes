-- VFN.L
--
-- Localization stub. All user-facing strings should flow through L() so the
-- string-resolution boundary lives in one place. Real translations come later;
-- today L() returns the fallback (English source string).
--
-- Usage:
--   text = VFN.L("vfn.field_notes.title", "Field Notes")
--
-- Keys are dotted, namespaced. Lookup walks VFN.L.translations[currentLocale]
-- then VFN.L.translations.enUS. Returns the fallback when no translation
-- exists.

VFN = VFN or {}
VFN.L = VFN.L or {
    locale = "enUS",
    translations = { enUS = {} },
}

local L = VFN.L

function L:Get(key, fallback)
    if type(key) ~= "string" or key == "" then return fallback end
    local table_for_locale = self.translations and self.translations[self.locale]
    local v = table_for_locale and table_for_locale[key] or nil
    if v then return v end
    if self.locale ~= "enUS" then
        local enUS = self.translations and self.translations.enUS
        v = enUS and enUS[key] or nil
        if v then return v end
    end
    return fallback
end

function L:Set(locale, key, value)
    self.translations[locale] = self.translations[locale] or {}
    self.translations[locale][key] = value
end

function L:SetLocale(locale)
    if type(locale) == "string" and locale ~= "" then self.locale = locale end
end

-- Module-level convenience: VFN.L(key, fallback) acts as a callable shortcut
-- for VFN.L:Get(key, fallback).
setmetatable(L, {
    __call = function(self, key, fallback)
        return self:Get(key, fallback)
    end,
})
