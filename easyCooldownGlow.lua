-- easyCooldownGlow.lua
-- Easy Cooldown Glow
--
-- 读取暴雪冷却管理器（CDM）【主冷却 / Essential】分组里「已启用」的技能，
-- 当某技能冷却完成（就绪可用）后，用 LibCustomGlow 的 Proc Glow 给对应动作条按钮发光提醒，
-- 并可配置发光时长：无（不发光）/ 就绪后亮 N 秒自动熄灭 / 持续常亮（直到技能被打出去）。
--
-- 来源：上游 ActionbarEnhanced/CooldownGlow.lua 拆分（2026-10-08）。
-- 与上游的关键差异：
--   · 全静默：无任何 print / 弹窗；开关变化不提示（工作区约定）。
--   · 库文件内嵌在本插件 Libs/ 下（LibStub + LibCustomGlow-1.0），不依赖其他插件携带。
--   · 发光时长档位新增「无」：某技能可配置为完全不发光（durations[sid] = -1）。
--   · 存档为独立 easyCooldownGlowDB（## SavedVariablesPerCharacter，按当前专精保存时长表）。
--   · 设置界面：暴雪设置里只留占位页（提示 + 按钮），配置在独立窗口
--     （/ecg 或占位页按钮打开）；战斗中窗口直接隐藏，战斗结束自动恢复。
--   · 绝不隐藏 / 移动 CDM 原有显示：CDM 只被【只读】使用（扫 EssentialCooldownViewer 的
--     active item 得到用户实际启用的主冷却技能集合）。
--
-- 12.x secret 值红线：
--   · 是否在冷却只用 C_Spell.GetSpellCooldown 返回的 isActive / isOnGCD 两个 NeverSecret
--     布尔判定，绝不比较 startTime / duration（secret number，算术/比较会 hard-error）。
--   · 对外部帧 / 外部数据的访问一律 pcall 包裹兜底。

EasyCooldownGlow = EasyCooldownGlow or {}
local CG = EasyCooldownGlow
CG.ADDON_NAME = ...

-- LibCustomGlow-1.0（LibStub 已在 .toc 中先行加载）
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

-- =========================================================
-- 本地化（自维护纯 Lua 表，仅 enUS（默认/回退）+ zhCN + zhTW 三语）
-- =========================================================
local LOCALES = {
    enUS = {
        SPEC_LABEL        = "Current Specialization",
        SPEC_UNKNOWN      = "Unknown",
        PAGE_DESC         = "Spells enabled in Blizzard's Cooldown Manager (Essential cooldowns) glow on the action bar when their cooldown finishes. Pick how long each spell stays lit.",
        NO_SPELLS         = "No spells found. Enable cooldowns in Blizzard's Cooldown Manager (Essential cooldowns) first, then reopen this page.",
        ENABLE            = "Enable",
        COL_DURATION      = "Glow",
        DUR_PERSISTENT    = "Persistent",
        DUR_SEC           = "%d sec",
        DUR_NONE          = "None",
        STATUS_NOT_ON_BAR = "not on action bars",
        OPEN_OPTIONS      = "Open Options",
        STUB_HINT         = "Click the button below, or type /ecg, to open the configuration window.",
    },
    zhCN = {
        SPEC_LABEL        = "当前专精",
        SPEC_UNKNOWN      = "未知",
        PAGE_DESC         = "暴雪冷却管理器「主冷却」分组中已启用的技能，冷却完成后在动作条按钮上发光提醒。可逐个技能设置发光时长。",
        NO_SPELLS         = "未找到可配置的技能。请先在暴雪冷却管理器的「主冷却」里启用技能，然后重新打开本页面。",
        ENABLE            = "启用",
        COL_DURATION      = "发光",
        DUR_PERSISTENT    = "持续",
        DUR_SEC           = "%d 秒",
        DUR_NONE          = "无",
        STATUS_NOT_ON_BAR = "不在动作条上",
        OPEN_OPTIONS      = "打开配置",
        STUB_HINT         = "点击按钮，或者输入 /ecg 打开配置窗口。",
    },
    zhTW = {
        SPEC_LABEL        = "目前專精",
        SPEC_UNKNOWN      = "未知",
        PAGE_DESC         = "暴雪冷卻管理器「主冷卻」分組中已啟用的技能，冷卻完成後在快捷列按鈕上發光提醒。可逐個技能設定發光時長。",
        NO_SPELLS         = "找不到可設定的技能。請先在暴雪冷卻管理器的「主冷卻」中啟用技能，然後重新開啟本頁面。",
        ENABLE            = "啟用",
        COL_DURATION      = "發光",
        DUR_PERSISTENT    = "持續",
        DUR_SEC           = "%d 秒",
        DUR_NONE          = "無",
        STATUS_NOT_ON_BAR = "不在快捷列上",
        OPEN_OPTIONS      = "開啟設定",
        STUB_HINT         = "點擊按鈕，或者輸入 /ecg 開啟設定視窗。",
    },
}

local activeLocale = LOCALES[GetLocale()] or LOCALES.enUS

local function L(key)
    local v = activeLocale[key]
    if v == nil then v = LOCALES.enUS[key] end
    return v
end
CG.L = L

-- =========================================================
-- 样式常量（发光颜色 / 缩放；画面风格集中在此）
-- =========================================================
local GLOW_COLOR = { 0.3, 1.0, 0.4, 1 }   -- 就绪发光：绿色
local GLOW_SCALE = 0.8                    -- ProcGlow 缩放（对齐上游 CooldownGlow.lua）
local GLOW_KEY   = "BAR"                  -- LCG key：Start / Stop 必须一致，否则发光帧残留

-- =========================================================
-- Secret Value 安全工具（12.x 红线）
-- =========================================================
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end
CG.IsSecret = IsSecret

-- 法术显示名 / 图标（pcall 兜底，解析失败回退 ID / 问号图标）
function CG.GetSpellDisplayName(sid)
    if sid and C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, sid)
        if ok and name then return name end
    end
    return sid and tostring(sid) or ""
end

function CG.GetSpellIcon(sid)
    if sid and C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, sid)
        if ok and icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- =========================================================
-- 前向声明：定义在文件后部，但前面的 SetDuration / SetDuration 调用方需要提前引用。
-- Lua 中「声明点之前」的同名引用会被编译为【全局】（不存在 → nil 报错）；
-- 故先在此声明 local，后部定义时直接赋值给同一个 local。
-- =========================================================
local ScheduleEvaluate
local SetExpiry

-- =========================================================
-- 存档（easyCooldownGlowDB，角色级；时长表按专精保存）
--   durations[sid] = nil / 0 → 持续常亮（默认）
--                    -1      → 无（不发光）
--                    1..5    → 就绪后亮 N 秒自动熄灭
-- =========================================================
function CG.EnsureDB()
    easyCooldownGlowDB = easyCooldownGlowDB or {}
    if easyCooldownGlowDB.enabled == nil then
        easyCooldownGlowDB.enabled = true
    end
end

function CG.IsEnabled()
    return easyCooldownGlowDB and easyCooldownGlowDB.enabled ~= false
end

function CG.SetEnabled(v)
    CG.EnsureDB()
    easyCooldownGlowDB.enabled = v and true or false
    if v then
        CG.Start()
    else
        CG.StopAll()
    end
end

-- 当前专精 ID（无专精返回 0）
local function GetCurrentSpecID()
    local idx = GetSpecialization()
    if idx and idx > 0 then
        return GetSpecializationInfo(idx) or 0
    end
    return 0
end
CG.GetCurrentSpecID = GetCurrentSpecID

local function GetDurations(specID)
    CG.EnsureDB()
    local db = easyCooldownGlowDB
    db.specs = db.specs or {}
    local spec = db.specs[specID] or {}
    db.specs[specID] = spec
    spec.durations = spec.durations or {}
    return spec.durations
end

-- 读取某技能当前的发光档位（-1 / 0 / 1..5；无记录 = 0 持续）
function CG.GetDuration(sid)
    if not easyCooldownGlowDB then return 0 end
    local specID = GetCurrentSpecID()
    local specs = easyCooldownGlowDB.specs
    local durs = specs and specs[specID] and specs[specID].durations
    return (durs and durs[sid]) or 0
end

function CG.SetDuration(sid, n)
    CG.EnsureDB()
    local durs = GetDurations(GetCurrentSpecID())
    if not n or n == 0 then
        durs[sid] = nil
    else
        durs[sid] = n
    end
    -- 配置变更即时生效：重设到期状态并强制重评估
    if n and n > 0 then
        SetExpiry(sid, n)
    else
        SetExpiry(sid, 0)   -- 持续 / 无：清到期与兜底 timer
    end
    ScheduleEvaluate()
end

-- 档位显示（供设置界面）：下拉选项顺序 = 持续 → 1..5 秒 → 无
CG.DUR_VALUES = { 0, 1, 2, 3, 4, 5, -1 }

function CG.DurationLabel(v)
    v = v or 0
    if v == -1 then return L("DUR_NONE") end
    if v > 0 then return string.format(L("DUR_SEC"), v) end
    return L("DUR_PERSISTENT")
end

-- =========================================================
-- 读取 CDM「已启用」的主冷却技能集合
--   ⚠️ 正确来源是 EssentialCooldownViewer 的 active item frame：
--   只有用户在 CDM 主冷却分组里真正启用显示的技能才在 itemFramePool 的 active 列表里。
--   ❌ 绝不可回退 GetCooldownViewerCategorySet(Essential)——那会返回该分类下【所有已学】
--      技能（含用户故意未监控的），导致「CDM 监控为空时所有技能都发光」。
--   冷启动（重载后 viewer 尚未登记 active item）时列表为空，由登录后延迟重评估
--   （C_Timer.After 1s / 3s）与后续冷却事件补齐。
-- =========================================================
-- 从单个 cooldownID 解析出用于匹配的 spellID：优先 linkedSpellIDs[1]，
-- 其次 overrideSpellID，最后 spellID（覆盖天赋/形态变体导致的 spellID 不一致）。
local function ResolveSpellID(info)
    if not info then return nil end
    if info.linkedSpellIDs and info.linkedSpellIDs[1] then
        return info.linkedSpellIDs[1]
    end
    return info.overrideSpellID or info.spellID
end

-- 扫 EssentialCooldownViewer 当前实际显示的 item frame（= 用户在 CDM 启用的主冷却技能）
local function GetTrackedFromViewer()
    local set = {}
    local viewer = _G.EssentialCooldownViewer
    if not viewer or not viewer.itemFramePool or not viewer.itemFramePool.EnumerateActive then
        return set
    end
    for frame in viewer.itemFramePool:EnumerateActive() do
        local cid = frame and frame.cooldownID
        if cid then
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cid)
            if ok and info then
                local sid = ResolveSpellID(info)
                if sid and sid > 0 then set[sid] = true end
                -- 补充所有关联 spellID，避免个别变体漏匹配
                if info.linkedSpellIDs then
                    for _, lsid in ipairs(info.linkedSpellIDs) do
                        if lsid and lsid > 0 then set[lsid] = true end
                    end
                end
            end
        end
    end
    return set
end

-- ⚡ 性能：tracked 集合缓存仅由 0.5s ticker（ComputeTracked）刷新，
--   Evaluate / 设置面板直接复用缓存，避免每次冷却事件全量扫描 viewer。
CG._trackedCache = CG._trackedCache or {}

local function ComputeTracked()
    local set = GetTrackedFromViewer()
    CG._trackedCache = set
    local ids = {}
    for sid in pairs(set) do
        ids[#ids + 1] = sid
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function GetTrackedSpellIDs()
    if not next(CG._trackedCache) then
        return GetTrackedFromViewer()   -- 缓存为空时回退一次实时扫描（冷启动兼容）
    end
    return CG._trackedCache
end
CG.GetTrackedSpellIDs = GetTrackedSpellIDs

-- 供设置面板触发的即时重扫（面板打开时保持 CDM 列表最新）
function CG.Rescan()
    ComputeTracked()
end

-- =========================================================
-- 冷却判定（12.x secret 安全）
-- =========================================================
local GetSpellCD = (C_Spell and C_Spell.GetSpellCooldown) or nil

-- 判定按钮是否处于「真实冷却」中（非纯 GCD）。
-- 用 isActive（NeverSecret 布尔：含 GCD 与真实冷却为 true，就绪为 false）排除纯 GCD：
--   isActive=true 且 isOnGCD=false → 真实冷却中（技能打出去了）→ 熄灭高亮；
--   isActive=true 且 isOnGCD=true  → 仅 GCD（施放其他技能触发）→ 保持高亮，
--   避免「用任意技能都让高亮闪灭 1~2 秒」。
-- ⚠️ startTime/duration 是 secret number，绝不能算术/比较/tostring；只用这两个布尔。
local function IsOnCooldown(btn, sid)
    if not sid then return false end
    if not GetSpellCD then
        -- 极旧客户端兜底（无 C_Spell.GetSpellCooldown）：依赖冷却帧可见性
        if btn and btn.cooldown and btn.cooldown:IsShown() then return true end
        if btn and btn.chargeCooldown and btn.chargeCooldown:IsShown() then return true end
        return false
    end
    local ok, cd = pcall(GetSpellCD, sid)
    if ok and type(cd) == "table" then
        if cd.isActive and not cd.isOnGCD then return true end
        return false
    end
    -- pcall 失败（如法术不存在）→ 按未冷却处理，保持高亮，避免误灭
    return false
end

-- =========================================================
-- 动作条按钮扫描（玩家主动作条 + 多动作条；不扫 Stance/Pet）
-- =========================================================
local ACTION_BAR_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
}
CG.ACTION_BAR_PREFIXES = ACTION_BAR_PREFIXES

-- 取按钮当前指向的 spellID。
-- 直接 spell 类型：返回 id。
-- 宏类型：解析宏内第一个法术（玩家常把带条件的技能放进宏，必须解析才能匹配 CDM 追踪列表）。
-- flyout / item / 其他类型：返回 nil（无法稳定落到单一按钮发光）。
-- ⚠️ 性能：按钮级 spellID 缓存（weak key，false 哨兵 = 无技能）。
--   Evaluate 在每次冷却事件遍历全部按钮，逐按钮 GetActionInfo + 宏解析开销可观；
--   槽位内容只在动作条/天赋事件时变化，届时整体失效（SID_INVALIDATE_EVENTS），热路径零解析。
local _sidCache = setmetatable({}, { __mode = "k" })

local function ComputeButtonSpellID(btn)
    if not btn.action then return nil end
    local ok, at, id = pcall(GetActionInfo, btn.action)
    if not ok or not at or not id then return nil end
    if at == "spell" then
        return (id > 0) and id or nil
    elseif at == "macro" then
        if not (id and id > 0) then return nil end
        -- 1) 按宏书索引解析宏内法术
        local sid
        if C_Macro and C_Macro.GetMacroSpell then
            local _, spellID = C_Macro.GetMacroSpell(id)
            sid = spellID
        elseif GetMacroSpell then
            local _, spellID = GetMacroSpell(id)
            sid = spellID
        end
        -- 2) 现代客户端单 /cast 宏：GetActionInfo 直接把 spellID 作为 id 返回，
        --    GetMacroSpell(id) 解析失败。此时若 id 本身是真实法术则直接采用。
        if not (sid and sid > 0) then
            local okN, nm = pcall(CG.GetSpellDisplayName, id)
            if okN and nm and nm ~= tostring(id) then sid = id end
        end
        return (sid and sid > 0) and sid or nil
    end
    return nil
end

local function GetButtonSpellID(btn)
    local cached = _sidCache[btn]
    if cached ~= nil then return cached or nil end
    local sid = ComputeButtonSpellID(btn)
    _sidCache[btn] = sid or false
    return sid
end

-- 槽位内容可能变化的时机 → 失效缓存（事件帧均已注册）
local SID_INVALIDATE_EVENTS = {
    ACTIONBAR_SLOT_CHANGED      = true,
    ACTIONBAR_PAGE_CHANGED      = true,
    UPDATE_BONUS_ACTIONBAR      = true,
    UPDATE_VEHICLE_ACTIONBAR    = true,
    UPDATE_POSSESS_BAR          = true,
    SPELLS_CHANGED              = true,
    PLAYER_TALENT_UPDATE        = true,
    ACTIVE_TALENT_GROUP_CHANGED = true,
}

-- 供设置面板查询：当前动作条上实际存在的 spellID 集合（「不在动作条上」状态用）
function CG.GetBarSpellIDs()
    local set = {}
    for _, prefix in ipairs(ACTION_BAR_PREFIXES) do
        for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
            local btn = _G[prefix .. i]
            if btn and btn.action then
                local sid = GetButtonSpellID(btn)
                if sid then set[sid] = true end
            end
        end
    end
    return set
end

-- =========================================================
-- 发光状态
-- =========================================================
CG._glowing = CG._glowing or {}   -- [button] = spellID
CG._expiry  = CG._expiry or {}    -- [sid] = 到期时间戳（限时高亮用）；nil = 常亮
CG._wasCd   = CG._wasCd or {}     -- [sid] = 上一次评估是否处于冷却（上升沿检测用）
CG._timers  = CG._timers or {}    -- [sid] = 兜底 C_Timer 句柄（到点强制重评估熄灭）

-- （ScheduleEvaluate 与 SetExpiry 均为文件顶部前向声明的 local，在文件后部赋值定义。）

local function ProcGlowStart(btn)
    if not LCG then return end
    -- ⚠️ 防叠层：LCG 每次 ProcGlow_Start 都新建发光帧，不复用/顶替上一张。
    --   重复 Start 前必须先 Stop（key 一致），否则发光帧逐层叠加越来越厚。
    if btn then
        pcall(LCG.ProcGlow_Stop, btn, GLOW_KEY)
    end
    LCG.ProcGlow_Start(btn, { key = GLOW_KEY, startAnim = true, color = GLOW_COLOR, scale = GLOW_SCALE })
end

local function ProcGlowStop(btn)
    if not LCG then return end
    -- ⚠️ key 必须与 ProcGlowStart 一致，否则查不到发光帧 → 永久残留
    pcall(LCG.ProcGlow_Stop, btn, GLOW_KEY)
end

-- 停止单个按钮发光并清理状态
local function StopGlow(btn)
    ProcGlowStop(btn)
    CG._glowing[btn] = nil
end

-- 设置某技能的限时到期时间；dur<=0 表示常亮（无到期）。
-- 同时安排「到点兜底」timer：限时到点时即便没有冷却事件触发，也强制重评估熄灭。
-- （SetExpiry 为文件顶部前向声明的 local，此处赋值定义。）
function SetExpiry(sid, dur)
    if dur and dur > 0 then
        CG._expiry[sid] = GetTime() + dur
        if CG._timers[sid] then
            pcall(CG._timers[sid].Cancel, CG._timers[sid])
            CG._timers[sid] = nil
        end
        CG._timers[sid] = C_Timer.After(dur, function()
            CG._timers[sid] = nil
            ScheduleEvaluate()
        end)
    else
        CG._expiry[sid] = nil
        -- 改回常亮 / 无时，取消该技能的兜底 timer，避免它到点仍触发重评估
        if CG._timers[sid] then
            pcall(CG._timers[sid].Cancel, CG._timers[sid])
            CG._timers[sid] = nil
        end
    end
end

-- 重评估：遍历动作条按钮 → 取按钮自身 spellID → CDM 主冷却白名单过滤
--   → 就绪发光：在「主冷却」分组里、且当前就绪的技能按钮发光；
--     进入真实冷却（非纯 GCD，即「技能打出去了」）立即熄灭；施放其他技能触发的纯 GCD 不影响。
--   → 发光档位（按当前专精）：
--     · 持续（0/未配置）：一直亮到施放；
--     · 限时（1..5）：就绪瞬间亮、N 秒后自动熄灭（即使仍就绪）；
--     · 无（-1）：该技能永不发光。
-- 用「按钮自身 spellID」做匹配，避免 CDM spellID 与动作条 spellID 不一致导致匹配失败。
function CG.Evaluate()
    if not CG.IsEnabled() then return end
    if not LCG then return end   -- 库未加载：静默跳过（工作区全静默约定）

    local now = GetTime()

    -- 1) CDM 主冷却白名单 + 当前专精的时长表
    local tracked = GetTrackedSpellIDs()
    local specID = GetCurrentSpecID()
    local specs = easyCooldownGlowDB and easyCooldownGlowDB.specs
    local durs = (specs and specs[specID] and specs[specID].durations) or {}

    -- 2) 遍历所有动作条按钮
    local shouldGlow = {}
    for _, prefix in ipairs(ACTION_BAR_PREFIXES) do
        for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
            local btn = _G[prefix .. i]
            if btn and btn:IsShown() and btn.action then
                local sid = GetButtonSpellID(btn)
                if sid and sid > 0 and tracked[sid] then
                    local dur = durs[sid] or 0
                    if dur == -1 then
                        -- 档位「无」：不发光，清理该技能的限时状态
                        CG._expiry[sid] = nil
                        if CG._timers[sid] then
                            pcall(CG._timers[sid].Cancel, CG._timers[sid])
                            CG._timers[sid] = nil
                        end
                        CG._wasCd[sid] = nil
                    else
                        local onCd = IsOnCooldown(btn, sid)
                        if onCd then
                            -- 进入/处于冷却（技能打出去）：立即熄灭，清到期与 timer，记录冷却态
                            CG._expiry[sid] = nil
                            if CG._timers[sid] then
                                pcall(CG._timers[sid].Cancel, CG._timers[sid])
                                CG._timers[sid] = nil
                            end
                            CG._wasCd[sid] = true
                        else
                            -- 就绪：按「时长配置」维护到期时间
                            --   · 上升沿（刚转好）/ 首见即就绪 → 设到期（开始计时）
                            --   · 当前无到期（运行时由常亮改为限时）→ 立即开始计时
                            --   · 限时已设（steady 状态 / 已到点）→ 不重置，沿用
                            if dur > 0 then
                                if CG._wasCd[sid] or CG._wasCd[sid] == nil or not CG._expiry[sid] then
                                    SetExpiry(sid, dur)
                                end
                            else
                                CG._expiry[sid] = nil
                            end
                            CG._wasCd[sid] = false
                            local exp = CG._expiry[sid]
                            if exp and now > exp then
                                shouldGlow[btn] = false    -- 限时已到：不再亮（即使仍就绪）
                            else
                                shouldGlow[btn] = true
                                if not CG._glowing[btn] then
                                    ProcGlowStart(btn)
                                    CG._glowing[btn] = sid
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3) 停止发光：按钮不再应发光（指向改变 / 不再被主冷却追踪 / 进入冷却 / 限时到点）即熄灭
    for btn in pairs(CG._glowing) do
        if not shouldGlow[btn] then
            StopGlow(btn)
        end
    end
end

-- 停止所有发光（关闭开关 / 停用时）
function CG.StopAll()
    if not LCG then return end
    for btn in pairs(CG._glowing) do
        ProcGlowStop(btn)
    end
    CG._glowing = {}
    -- 清理限时状态：取消待触发 timer，清空到期与冷却态缓存
    for sid, t in pairs(CG._timers) do
        pcall(t.Cancel, t)
        CG._timers[sid] = nil
    end
    for sid in pairs(CG._expiry) do CG._expiry[sid] = nil end
    for sid in pairs(CG._wasCd) do CG._wasCd[sid] = nil end
end

-- =========================================================
-- 事件驱动刷新：
-- 用 dispatchFrame 把「同一帧内」的多次冷却/动作条事件合并成一次 Evaluate
-- （每帧至多评估一次），省 CPU 且更跟手。
-- =========================================================
local dirty = false
local dispatchFrame = CreateFrame("Frame")
dispatchFrame:Hide()
dispatchFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    dirty = false
    if CG.IsEnabled() then CG.Evaluate() end
end)

ScheduleEvaluate = function()
    if dirty then return end
    dirty = true
    dispatchFrame:Show()
end

function CG.Start()
    if not LCG then return end
    ComputeTracked()        -- 启动时先刷新一次 CDM 主冷却缓存，避免首评为空
    ScheduleEvaluate()
end

function CG.EvaluateNow()
    ScheduleEvaluate()
end

-- =========================================================
-- 事件：动作条切换 / 冷却变化 / 天赋变动 → 重评估
-- =========================================================
local evFrame = CreateFrame("Frame")
CG._evFrame = evFrame
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
evFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
evFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
evFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
evFrame:RegisterEvent("UPDATE_POSSESS_BAR")
evFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
evFrame:RegisterEvent("SPELL_UPDATE_CHARGES")   -- 充能技能冷却变化
evFrame:RegisterEvent("SPELLS_CHANGED")
evFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
evFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
evFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

evFrame:SetScript("OnEvent", function(_, event)
    -- 槽位内容可能变化（换技能/翻页/姿态/载具/天赋）→ 失效 spellID 缓存
    if SID_INVALIDATE_EVENTS[event] then
        wipe(_sidCache)
    end
    if event == "PLAYER_LOGIN" then
        CG.EnsureDB()
        if CG.IsEnabled() then
            CG.Start()
            -- 登录后延迟重评估：CDM viewer 的 active item 在登录瞬间可能尚未登记（冷启动），
            -- 延后补两次让发光正常出现，避免「启用却没亮」的空白期。
            C_Timer.After(1.0, function()
                if CG.IsEnabled() then ScheduleEvaluate() end
            end)
            C_Timer.After(3.0, function()
                if CG.IsEnabled() then ScheduleEvaluate() end
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 战斗结束：配置窗口若此前因进战斗被隐藏则恢复
        if CG.OnCombatChanged then CG.OnCombatChanged(false) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- 进入战斗：隐藏配置窗口
        if CG.OnCombatChanged then CG.OnCombatChanged(true) end
    else
        -- 动作条切换 / 冷却变化 / 天赋变动：合并到下一帧统一评估（同帧多次事件只评估一次）
        ScheduleEvaluate()
    end
end)

-- =========================================================
-- 0.5s 低频 ticker（唯一的全量重扫点）
--   1) 检测用户在 CDM 主冷却分组里增删法术：这类改动不触发冷却事件，
--      事件驱动的 Evaluate 不会自跑 → 比对 tracked 集合签名，变化即重评估。
--   2) 限时到期双保险：玩家「不做任何动作」时无冷却事件，仅靠 C_Timer.After 兜底；
--      这里再检测一次到期并强制重评估，确保「就绪后亮 N 秒」必然到点熄灭（最多延迟 0.5s）。
--   ⚡ Evaluate 不再扫描 viewer，冷却事件高频时省下大量 GetCooldownViewerCooldownInfo pcall。
-- =========================================================
local lastTrackedSig = ""
C_Timer.NewTicker(0.5, function()
    local sig = ComputeTracked()
    if not CG.IsEnabled() then
        -- 开关关闭时不发光；同步签名避免下次开启瞬间误触发
        lastTrackedSig = sig
        return
    end
    local need = false
    if sig ~= lastTrackedSig then
        lastTrackedSig = sig
        need = true
    end
    if not need then
        local now = GetTime()
        for _, exp in pairs(CG._expiry) do
            if exp and now > exp then
                need = true
                break
            end
        end
    end
    if need then
        ScheduleEvaluate()
    end
end)
