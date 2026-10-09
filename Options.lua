-- Options.lua
-- Easy Cooldown Glow — 设置界面
--
-- 界面分两块（对齐 easyButtonAuraByCDM 的既定模式，用户 2026-10-08 指定）：
--   1. 暴雪插件设置里的【占位页】：只有一句提示 + 一个按钮，点按钮打开自有配置窗口。
--   2. 【自有配置窗口】：承载全局开关 + 逐技能发光档位；用 /ecg 或占位页按钮打开；
--      窗口顶部同样有一句提示。
--
-- 战斗行为（用户指定）：战斗中配置窗口直接隐藏，战斗结束若此前是打开状态则自动恢复；
-- 战斗中不响应 /ecg 与占位页按钮（窗口无法被打开）。
--
-- 布局约定：所有控件的坐标都是【相对 row 的绝对坐标】，不互相链式锚定，
-- 保证行与行、控件与控件严格对齐且不重叠。
--
-- 列表区为【固定高度 + 滚动条】：可见 VISIBLE_ROWS 行，行数超出即出现暴雪原生滚动条
-- （支持鼠标滚轮），窗口高度不随行数增长。

local CG = EasyCooldownGlow
local L = CG.L

-- 配置窗口宽度（对齐 easyButtonAuraByCDM 的 680）
local PANEL_W = 680
local ROW_W   = PANEL_W - 44
local ROW_H   = 40

-- 列表区固定高度（可见行数），行数超过即出现滚动条，窗口高度不再随行数增长
local VISIBLE_ROWS = 10
local LIST_H = VISIBLE_ROWS * ROW_H

-- 行内第二行控件的横坐标（相对 row 左侧）与宽度
local X_DUR, W_DUR = 150, 110

-- 暴雪设置分类名 / 配置窗口标题：不本地化，固定用插件名（用户指定）
local ADDON_TITLE = "Easy Cooldown Glow"

-- 暴雪设置里的占位页宽度：与配置窗口宽度无关，用较小值避免超出暴雪设置画布
local STUB_W = 520

local configFrame
local rows = {}          -- 行池（复用）
local refreshing = false -- RefreshPanel 递归守卫

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
    local row = CreateFrame("Frame", nil, configFrame.rows)
    row:SetSize(ROW_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)

    -- 图标做成可悬停按钮：鼠标移上显示技能提示。
    -- ⚠️ 垂直对齐：与 durDd（BOTTOMLEFT, y=4, 高 24 → 中心线 y=16）同一中心，
    --    图标高 20 → 底边 y=6；名字锚在图标 RIGHT（垂直居中跟随），状态文字锚在名字 RIGHT。
    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("BOTTOMLEFT", 6, 6)
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

local function DoRefresh()
    if not configFrame then return end

    -- 当前专精名（⚠️ GetSpecializationInfo 第 1 个返回值是 specID，名字是第 2 个）
    local specName = L("SPEC_UNKNOWN")
    local idx = GetSpecialization()
    if idx and idx > 0 then
        local ok, id, name = pcall(GetSpecializationInfo, idx)
        if ok and name and name ~= "" then
            specName = name
        elseif ok and id then
            specName = tostring(id)
        end
    end
    configFrame.specText:SetText(L("SPEC_LABEL") .. ": " .. specName)

    if configFrame.enableCheck then
        configFrame.enableCheck:SetChecked(CG.IsEnabled())
    end

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
    -- 空列表：隐藏滚动区（其自带底板会盖住提示文字），只显示提示
    local empty = (#list == 0)
    configFrame.noSpells:SetShown(empty)
    configFrame.scroll:SetShown(not empty)
    configFrame.rows:SetSize(ROW_W, count * ROW_H)
    -- 内容尺寸变化后让 ScrollFrame 重算滚动范围（超出即自动显示滚动条，否则隐藏）
    if configFrame.scroll.UpdateScrollChildRect then
        pcall(configFrame.scroll.UpdateScrollChildRect, configFrame.scroll)
    end

    -- 窗口高度 = 顶部（窗口顶 → 滚动区顶） + 固定列表高度 + 底部留白。
    -- 顶部高度取运行时实际几何（提示文字行数会随语言变化，不能用常量）；几何不可用时用兜底值。
    local pTop, rTop = configFrame:GetTop(), configFrame.scroll:GetTop()
    local headerH = (pTop and rTop and pTop > rTop) and (pTop - rTop) or 110
    configFrame:SetSize(PANEL_W, headerH + LIST_H + 20)
end

-- ⚠️ refreshing 守卫必须无条件复位：刷新中途一旦抛错，若不复位，之后所有刷新都会被守卫挡掉
--    → 面板从此不再更新（表现为「配置像是丢了」）。
function CG.RefreshPanel()
    if not configFrame or refreshing then return end
    refreshing = true
    pcall(DoRefresh)
    refreshing = false
end

-- =========================================================
-- 自有配置窗口
-- =========================================================
local function BuildConfigFrame()
    configFrame = CreateFrame("Frame", "EasyCooldownGlowConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    configFrame:SetSize(PANEL_W, 320)
    configFrame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:Hide()

    -- 标题（不本地化，固定插件名）
    local titleText = (configFrame.TitleContainer and configFrame.TitleContainer.TitleText) or configFrame.TitleText
    if titleText then titleText:SetText(ADDON_TITLE) end

    -- 标题栏下分割线（三窗统一）
    configFrame.divTitle = configFrame:CreateTexture(nil, "ARTWORK")
    configFrame.divTitle:SetColorTexture(0.7, 0.7, 0.7, 0.35)
    configFrame.divTitle:SetSize(PANEL_W - 24, 1)
    configFrame.divTitle:SetPoint("TOPLEFT", 12, -31)

    -- 顶部提示：当前专精（说明文字已按用户要求去掉）
    configFrame.specText = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    configFrame.specText:SetPoint("TOPLEFT", 16, -36)

    -- 全局启用开关（窗口右上角）
    configFrame.enableCheck = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    configFrame.enableCheck:SetSize(24, 24)
    configFrame.enableCheck:SetPoint("TOPRIGHT", -14, -36)
    configFrame.enableLabel = configFrame.enableCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- 标签锚在复选框左侧：向右伸出会越过窗口右边界（CDM / byUnit 同款约定）
    configFrame.enableLabel:SetPoint("RIGHT", configFrame.enableCheck, "LEFT", -4, 0)
    configFrame.enableLabel:SetText(L("ENABLE"))
    configFrame.enableCheck:SetScript("OnClick", function(self)
        if InCombatLockdown() then
            self:SetChecked(not self:GetChecked())
            return
        end
        CG.SetEnabled(self:GetChecked() and true or false)
    end)

    configFrame.noSpells = configFrame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    configFrame.noSpells:SetPoint("TOPLEFT", configFrame.specText, "BOTTOMLEFT", 0, -12)
    configFrame.noSpells:SetWidth(PANEL_W - 40)
    configFrame.noSpells:SetJustifyH("LEFT")
    configFrame.noSpells:SetText(L("NO_SPELLS"))
    configFrame.noSpells:Hide()

    -- 列表区：固定高度的滚动区（行数超过可见行数时出现滚动条，支持鼠标滚轮）
    configFrame.scroll = CreateFrame("ScrollFrame", "EasyCooldownGlowConfigScroll", configFrame, "UIPanelScrollFrameTemplate")
    configFrame.scroll:SetPoint("TOPLEFT", configFrame.specText, "BOTTOMLEFT", 8, -14)
    configFrame.scroll:SetSize(ROW_W, LIST_H)
    configFrame.scroll:EnableMouseWheel(true)
    configFrame.scroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = self.ScrollBar or _G["EasyCooldownGlowConfigScrollScrollBar"]
        if not bar or not bar:IsShown() then return end
        local lo, hi = bar:GetMinMaxValues()
        local v = (bar:GetValue() or 0) - delta * ROW_H
        if v < lo then v = lo elseif v > hi then v = hi end
        bar:SetValue(v)
    end)

    configFrame.rows = CreateFrame("Frame", nil, configFrame.scroll)
    configFrame.rows:SetPoint("TOPLEFT", configFrame.scroll, "TOPLEFT", 0, 0)
    configFrame.rows:SetSize(ROW_W, LIST_H)
    configFrame.scroll:SetScrollChild(configFrame.rows)

    -- ⚠️ UIPanelScrollFrameTemplate 的滚动条【默认锚在滚动区右侧外部】（右缘约在滚动区右缘
    -- 之外 13px），会越过窗口右边界（easyButtonAuraByCDM 踩过此坑）。
    -- 模板把滚动条存在 `ScrollBar` 字段（大写 S）、全局名 <帧名>.."ScrollBar"。
    -- 显式 ClearAllPoints 后把滚动条【右缘】贴到滚动区【内部右缘】（内缩 2px）。
    local bar = configFrame.scroll.ScrollBar or _G["EasyCooldownGlowConfigScrollScrollBar"]
    if bar then
        bar:ClearAllPoints()
        bar:SetPoint("TOPRIGHT", configFrame.scroll, "TOPRIGHT", -2, -14)
        bar:SetPoint("BOTTOMRIGHT", configFrame.scroll, "BOTTOMRIGHT", -2, 14)
    end

    -- 窗口显隐：打开时重扫 CDM 主冷却列表并刷新面板
    configFrame:SetScript("OnShow", function()
        CG.EnsureDB()
        CG.Rescan()
        CG.RefreshPanel()
    end)
end

-- 打开配置窗口（战斗中不允许打开）
function CG.ShowConfigFrame()
    if InCombatLockdown() then return end
    if not configFrame then BuildConfigFrame() end
    configFrame:Show()
end

-- /ecg 与占位页按钮：切换配置窗口显隐（战斗中不响应）
function CG.ToggleConfigFrame()
    if InCombatLockdown() then return end
    if not configFrame then BuildConfigFrame() end
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        configFrame:Show()
    end
end

-- 战斗状态切换（主文件 PLAYER_REGEN_DISABLED / ENABLED 调用）：
-- 战斗中直接隐藏配置窗口并记住；战斗结束若此前是打开状态则恢复。
function CG.OnCombatChanged(inCombat)
    if not configFrame then return end
    if inCombat then
        if configFrame:IsShown() then
            CG._restoreConfig = true
            configFrame:Hide()
        end
    elseif CG._restoreConfig then
        CG._restoreConfig = nil
        CG.ShowConfigFrame()
    end
end

-- =========================================================
-- 暴雪插件设置里的占位页（提示 + 按钮）
-- =========================================================
local function BuildBlizzardStub()
    local stub = CreateFrame("Frame")
    stub:SetSize(STUB_W, 200)

    -- canvas layout 要求的三函数：本页无实际设置，故均为空实现
    stub.OnCommit  = function() end
    stub.OnDefault = function() end
    stub.OnRefresh = function() end

    -- 页面顶部标题（英文插件名，Chattynator 风格）：左侧分类树有名字，页内自身也要有
    local title = stub:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", stub, "TOP", 0, -18)
    -- 金色大字（与插件图标同色系，#E8BC75 直方图采样主峰）
    title:SetFont(STANDARD_TEXT_FONT, 22, "")
    title:SetTextColor(0.910, 0.737, 0.459)
    title:SetText(ADDON_TITLE)

    local hint = stub:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOP", stub, "TOP", 0, -64)
    hint:SetWidth(STUB_W - 40)
    hint:SetJustifyH("CENTER")
    hint:SetText(L("STUB_HINT"))

    local template = "SharedButtonLargeTemplate"
    local hasTemplate = false
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, template)
        hasTemplate = ok and info ~= nil
    end
    if not hasTemplate then template = "UIPanelDynamicResizeButtonTemplate" end
    local button = CreateFrame("Button", nil, stub, template)
    button:SetText(L("OPEN_OPTIONS"))
    button.padding = 40
    if DynamicResizeButton_Resize then pcall(DynamicResizeButton_Resize, button) end
    button:SetPoint("TOP", hint, "BOTTOM", 0, -30)
    button:SetScript("OnClick", function() CG.ToggleConfigFrame() end)

    return stub
end

local function RegisterSettings()
    if CG._stubRegistered then return end
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    CG._stubRegistered = true
    local stub = BuildBlizzardStub()
    -- 分类名不本地化，固定用插件名（用户指定）
    local category = Settings.RegisterCanvasLayoutCategory(stub, ADDON_TITLE)
    Settings.RegisterAddOnCategory(category)
end

-- =========================================================
-- slash 命令：/ecg 打开自有配置窗口
-- =========================================================
SLASH_EASYCOOLDOWNGLOW1 = "/ecg"
SlashCmdList["EASYCOOLDOWNGLOW"] = function()
    CG.ToggleConfigFrame()
end

-- =========================================================
-- 启动
-- =========================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event)
    self:UnregisterEvent(event)
    RegisterSettings()
    BuildConfigFrame()
    CG.RefreshPanel()
end)
