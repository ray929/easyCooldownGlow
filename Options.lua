-- Options.lua
-- Easy Cooldown Glow — 设置界面
--
-- 单一设置页，集成进暴雪自带的插件设置（ESC → 选项 → 插件 → 本插件）。
--   · 无 slash 命令；战斗中禁止修改（控件禁用 + 顶部红色提示）。
--   · 顶部全局「启用」开关 + 当前专精提示。
--   · 每行 = CDM「主冷却」分组里一个已启用的技能：设置其冷却完成后的发光档位
--     （持续 / 1-5 秒 / 无），按当前专精保存。
--   · 修改即时落盘（canvas layout 的 OnCommit 为空实现）。
--
-- 布局约定：所有控件的坐标都是【相对 row 的绝对坐标】，不互相链式锚定，
-- 保证行与行、控件与控件严格对齐且不重叠（对齐 easyButtonAuraByCDM 的既定做法）。

local CG = EasyCooldownGlow
local L = CG.L

-- 面板宽度：设置 canvas 可视宽度有限，过宽会把右侧控件裁掉
local PANEL_W = 520
local ROW_W   = PANEL_W - 16
local ROW_H   = 40

-- 行内第二行控件的横坐标（相对 row 左侧）与宽度
local X_DUR, W_DUR = 150, 110

local panel
local rows = {}          -- 行池（复用）
local refreshing = false -- RefreshPanel 递归守卫

-- 插件名（用于设置分类标题）
local function GetAddonTitle()
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if fn then
        local ok, title = pcall(fn, CG.ADDON_NAME, "Title")
        if ok and title and title ~= "" then return title end
    end
    return "Easy Cooldown Glow"
end
local ADDON_TITLE = GetAddonTitle()

-- =========================================================
-- 小工具
-- =========================================================
-- 保留模板原有的 OnEnter / OnLeave（高亮等），只在其后追加 tooltip
local function AddTip(widget, text)
    local prevEnter = widget:GetScript("OnEnter")
    local prevLeave = widget:GetScript("OnLeave")
    widget:SetScript("OnEnter", function(self, ...)
        if prevEnter then prevEnter(self, ...) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function(self, ...)
        if prevLeave then prevLeave(self, ...) end
        GameTooltip:Hide()
    end)
end

-- 战斗中禁用全部可编辑控件 + 显示红色提示
local function UpdateCombatState()
    local locked = InCombatLockdown() and true or false
    if panel and panel.combatWarning then
        panel.combatWarning:SetShown(locked)
    end
    for _, row in ipairs(rows) do
        row.durDd:SetEnabled(not locked)
    end
    if panel and panel.enableCheck then
        panel.enableCheck:SetEnabled(not locked)
    end
end

-- 下拉按钮的显示文字（不同版本方法名可能有差异，优先 SetText）
local function SetDdText(dd, text)
    if dd.SetText then
        dd:SetText(text)
    elseif dd.SetDefaultText then
        dd:SetDefaultText(text)
    end
end

-- 给发光档位下拉按钮装配菜单；dd._spellID 由 UpdateRow 写入
local function SetupDurMenu(dd)
    dd:SetupMenu(function(_, rootDescription)
        for _, v in ipairs(CG.DUR_VALUES) do
            rootDescription:CreateRadio(CG.DurationLabel(v), function()
                return (CG.GetDuration(dd._spellID) or 0) == v
            end, function()
                if InCombatLockdown() or not dd._spellID then return end
                CG.SetDuration(dd._spellID, v)
                SetDdText(dd, CG.DurationLabel(v))
            end)
        end
    end)
end

-- =========================================================
-- 行控件
-- =========================================================
local function CreateRow(index)
    local row = CreateFrame("Frame", nil, panel.rows)
    row:SetSize(ROW_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)

    -- 图标做成可悬停按钮：鼠标移上显示技能提示
    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("TOPLEFT", 6, -4)
    row.icon.tex = row.icon:CreateTexture(nil, "ARTWORK")
    row.icon.tex:SetAllPoints()
    row.icon:SetScript("OnEnter", function(self)
        local id = self.spellID
        if not id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(id)
        else
            GameTooltip:SetText(CG.GetSpellDisplayName(id))
        end
        GameTooltip:Show()
    end)
    row.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.status:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.status:SetJustifyH("LEFT")

    -- 发光档位下拉菜单（底边与行内其他控件对齐）
    row.durDd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    row.durDd:SetSize(W_DUR, 24)
    row.durDd:SetPoint("BOTTOMLEFT", X_DUR, 4)
    SetupDurMenu(row.durDd)
    AddTip(row.durDd, L("COL_DURATION"))

    return row
end

local function UpdateRow(row, spellID, barSet)
    row.name:SetText(CG.GetSpellDisplayName(spellID))
    row.icon.spellID = spellID
    row.icon.tex:SetTexture(CG.GetSpellIcon(spellID))

    if barSet and not barSet[spellID] then
        row.status:SetText(L("STATUS_NOT_ON_BAR"))
        row.status:SetTextColor(1, 0.4, 0.4)
    else
        row.status:SetText("")
    end

    row.durDd._spellID = spellID
    SetDdText(row.durDd, CG.DurationLabel(CG.GetDuration(spellID)))
end

-- =========================================================
-- 面板刷新
-- =========================================================
-- 行集合 = CDM 主冷却已启用技能 ∪ 已有时长配置（后者保证技能移出 CDM 前仍可管理），按名称排序
local function BuildRowList()
    local seen, list = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    for id in pairs(CG.GetTrackedSpellIDs()) do add(id) end
    local specID = CG.GetCurrentSpecID()
    local db = easyCooldownGlowDB
    local specs = db and db.specs
    local durs = specs and specs[specID] and specs[specID].durations
    if durs then
        for id in pairs(durs) do add(id) end
    end
    table.sort(list, function(a, b)
        return CG.GetSpellDisplayName(a) < CG.GetSpellDisplayName(b)
    end)
    return list
end

function CG.RefreshPanel()
    if not panel or refreshing then return end
    refreshing = true

    -- 当前专精名
    local specName = L("SPEC_UNKNOWN")
    local idx = GetSpecialization()
    if idx and idx > 0 then
        local ok, name = pcall(GetSpecializationInfo, idx)
        if ok and name then specName = name end
    end
    panel.specText:SetText(L("SPEC_LABEL") .. ": " .. specName)

    local list = BuildRowList()
    local barSet = CG.GetBarSpellIDs()

    for i = 1, #list do
        local spellID = list[i]
        local row = rows[i]
        if not row then
            row = CreateRow(i)
            rows[i] = row
        end
        row.spellID = spellID
        row:Show()
        UpdateRow(row, spellID, barSet)
    end
    for i = #list + 1, #rows do
        rows[i].spellID = nil
        rows[i].icon.spellID = nil
        rows[i]:Hide()
    end

    local count = math.max(#list, 1)
    panel.noSpells:SetShown(#list == 0)
    panel.rows:SetSize(ROW_W, count * ROW_H)

    -- 面板高度 = 头部（面板顶 → 行区域顶） + 行区域 + 底部留白。
    -- 头部高度取运行时实际几何（描述行数会随语言变化，不能用常量）；几何不可用时用兜底值。
    local pTop, rTop = panel:GetTop(), panel.rows:GetTop()
    local headerH = (pTop and rTop and pTop > rTop) and (pTop - rTop) or 110
    panel:SetSize(PANEL_W, headerH + count * ROW_H + 16)

    UpdateCombatState()
    refreshing = false
end

-- =========================================================
-- 面板构建 + 注册进暴雪设置
-- =========================================================
local function BuildPanel()
    panel = CreateFrame("Frame")
    panel:SetSize(PANEL_W, 200)

    -- canvas layout 要求的三函数：修改即时生效，故均为空 / 仅刷新
    panel.OnCommit  = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() if CG.RefreshPanel then CG.RefreshPanel() end end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 16, -12)
    panel.title:SetText(ADDON_TITLE)

    panel.specText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.specText:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)

    panel.combatWarning = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.combatWarning:SetPoint("LEFT", panel.specText, "RIGHT", 20, 0)
    panel.combatWarning:SetTextColor(1, 0.3, 0.3)
    panel.combatWarning:SetText(L("COMBAT_LOCKED"))
    panel.combatWarning:Hide()

    -- 全局启用开关（与专精提示同一行右侧）
    panel.enableCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.enableCheck:SetSize(24, 24)
    panel.enableCheck:SetPoint("TOPRIGHT", -24, -8)
    panel.enableLabel = panel.enableCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.enableLabel:SetPoint("LEFT", panel.enableCheck, "RIGHT", 2, 0)
    panel.enableLabel:SetText(L("ENABLE"))
    panel.enableCheck:SetScript("OnClick", function(self)
        if InCombatLockdown() then
            self:SetChecked(not self:GetChecked())
            return
        end
        CG.SetEnabled(self:GetChecked() and true or false)
    end)

    panel.desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.desc:SetPoint("TOPLEFT", panel.specText, "BOTTOMLEFT", 0, -8)
    panel.desc:SetWidth(PANEL_W - 32)
    panel.desc:SetJustifyH("LEFT")
    panel.desc:SetText(L("PAGE_DESC"))

    panel.noSpells = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.noSpells:SetPoint("TOPLEFT", panel.desc, "BOTTOMLEFT", 0, -14)
    panel.noSpells:SetWidth(PANEL_W - 32)
    panel.noSpells:SetJustifyH("LEFT")
    panel.noSpells:SetText(L("NO_SPELLS"))
    panel.noSpells:Hide()

    panel.rows = CreateFrame("Frame", nil, panel)
    panel.rows:SetPoint("TOPLEFT", panel.desc, "BOTTOMLEFT", 8, -14)
    panel.rows:SetSize(ROW_W, ROW_H)

    -- 设置页显隐：打开时重扫 CDM 主冷却列表并刷新面板
    panel:SetScript("OnShow", function()
        CG.EnsureDB()
        if panel.enableCheck then
            panel.enableCheck:SetChecked(CG.IsEnabled())
        end
        CG.Rescan()
        CG.RefreshPanel()
    end)
end

local function RegisterSettings()
    if panel then return end
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    BuildPanel()
    local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON_TITLE)
    Settings.RegisterAddOnCategory(category)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event)
    self:UnregisterEvent(event)
    RegisterSettings()
    if CG.RefreshPanel then CG.RefreshPanel() end
end)
