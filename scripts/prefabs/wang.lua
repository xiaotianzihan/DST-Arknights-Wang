local MakePlayerCharacter = require "prefabs/player_common"

local assets = {
  Asset("ANIM", "anim/wang.zip"),
  Asset("ATLAS", "images/map_icons/wang.xml"),
  Asset('ATLAS', 'bigportraits/wang.xml'),
  Asset('ATLAS', 'images/saveslot_portraits/wang.xml'),
  Asset('ATLAS', 'images/selectscreen_portraits/wang.xml'),
  Asset('ATLAS', 'images/selectscreen_portraits/wang_silho.xml'),
  Asset('ATLAS', 'images/avatars/avatar_wang.xml'),
  Asset('ATLAS', 'images/avatars/avatar_ghost_wang.xml'),
  Asset('ATLAS', 'images/avatars/self_inspect_wang.xml'),
  Asset("ATLAS", "images/names_wang.xml"),
  Asset("ATLAS", "images/names_gold_wang.xml"),
}

local prefabs = {
  "forcefieldfx",
}

local start_inv = {}
for k, v in pairs(TUNING.GAMEMODE_STARTING_ITEMS) do
  start_inv[string.lower(k)] = v.WANG
end

prefabs = FlattenTree({ prefabs, start_inv }, true)

-- ════════════════════════════════════════════════════════
-- 技能：出生时安装
-- ════════════════════════════════════════════════════════
local DEFAULT_SKILL_IDS = { "wang_skill1", "wang_skill2", "wang_skill3" }

local function InstallDefaultSkills(inst)
  for _, skill_id in ipairs(DEFAULT_SKILL_IDS) do
    if inst.components.ark_skill:GetSkill(skill_id) == nil then
      inst.components.ark_skill:AddSkill(skill_id)
    end
  end
end

local function OnNewSpawn(inst)
  InstallDefaultSkills(inst)
  -- 天赋：铸子出生即有；应劫预装后由精英阶段自动解锁。
  if inst.components.ark_talent:GetTalent("wang_talent_zhuzi") == nil then
    inst.components.ark_talent:AddTalent("wang_talent_zhuzi")
  end
  if inst.components.ark_talent:GetTalent("wang_talent_yingjie") == nil then
    inst.components.ark_talent:AddTalent("wang_talent_yingjie")
  end
end

-- ════════════════════════════════════════════════════════
-- 特性：工作效率 0.8（所有工作动作）
-- ════════════════════════════════════════════════════════
local function WangWorkMultiplierFn(inst, action, target, tool, numworks, recoil)
  return numworks * TUNING.WANG.WORK_EFFICIENCY
end

-- ════════════════════════════════════════════════════════
-- 特性：无法独自搬运（平时禁重物，骑牛可搬）
-- ════════════════════════════════════════════════════════
local function OnMounted(inst)
  inst.components.inventory.noheavylifting = false
end

local function OnDismounted(inst)
  inst.components.inventory.noheavylifting = true
  -- 下牛时若仍扛着重物则放下（不能独自搬运）
  if inst.components.inventory:IsHeavyLifting() then
    local item = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
    if item ~= nil then
      inst.components.inventory:DropItem(item, true, true)
    end
  end
end

-- ════════════════════════════════════════════════════════
-- 经验来源
-- ════════════════════════════════════════════════════════
-- 使用技能（解锁/掌握经验由 recipe_mastered 事件发放）
local function OnSkillActivated(inst, data)
  inst.components.ark_elite:AddExp(TUNING.WANG.EXP_PER_SKILL_USE)
end

-- ════════════════════════════════════════════════════════
-- 升级经验缩放（精英1 / 精英2）
-- ════════════════════════════════════════════════════════
-- 前置包把 EXP_CONFIG 写成 ark_elite_replica.lua 的文件内局部表，
-- 既没有对外暴露，也没有提供覆盖接口。为了不污染前置包（改了会连带影响
-- 其它角色的成长曲线），这里只在望自己的组件实例上挂钩子。
--
-- 挂 GetLevelUpExp 而不是直接改数值的原因：
--   ① 服务端靠它推进等级（ark_elite.lua 的 _ApplyExpPool）、满级伪升级也读它；
--   ② 客户端经验条靠它算进度与 "EXP x/y" 文本（ark_exp_bar.lua 的 _GetTotalExp）。
--   两边都调用同一个方法，钩子一处即可保证服务端结算与客户端显示一致。
-- 用 next() 先取原始值再缩放，就无需访问那个局部表，前置包更新数值也不用跟着改。
--
-- 安装标记挂在实体上，而不是模块级 local：
-- 模块级标记只对「本次加载的第一个望」有效，之后进服务器的望会因为标记已置位而漏装缩放。
local function InstallWangExpScale(inst)
  if inst._wang_exp_scale_installed then
    return
  end
  local replica = inst.replica ~= nil and inst.replica.ark_elite or nil
  if replica == nil then
    return
  end
  inst._wang_exp_scale_installed = true
  ArkHookFunction(replica, "GetLevelUpExp", function(next, level)
    local base = next(level)
    local scale = TUNING.WANG.LEVEL_EXP_SCALE
    -- replica.state 由 NetState 提供；取不到就退回原值，不要因为读数失败卡住升级
    local elite = replica.state ~= nil and replica.state.elite or 1
    local mult = scale and scale[elite] or 1
    if mult == 1 then
      return base
    end
    -- 至少留 1 点：缩放后若出现 0 经验，_ApplyExpPool 的升级判定会陷入死循环
    return math.max(1, math.floor(base * mult))
  end)
end

-- 兜底：正常路径在 master_postinit 里装；万一那时 replica 还没注册
--（AddComponent 内部注册 replica 的时机随引擎版本变化），在组件 PostInit 再装一次。
-- InstallWangExpScale 自带幂等标记，两条路径都命中也不会重复缩放。
AddComponentPostInit("ark_elite", function(self)
  local inst = self.inst
  if inst == nil or inst.prefab ~= "wang" then
    return
  end
  InstallWangExpScale(inst)
end)

-- ════════════════════════════════════════════════════════
-- 特性：阅读书籍（理智消耗随已读次数降低）
-- ════════════════════════════════════════════════════════
local function GetReadSanityMultiplier(inst, book)
  local reads = inst.wang_book_reads[book.prefab] or 0
  local mult = TUNING.WANG.READ_SANITY_MULT_FIRST - reads * TUNING.WANG.READ_SANITY_MULT_STEP
  return math.max(TUNING.WANG.READ_SANITY_MULT_MIN, mult)
end

-- 挂 reader.Read：读前按该书设倍率，读完恢复原倍率（备份旧值，兼容其他模组）
-- 不做 pcall 兜底：异常直接上抛，让问题暴露
local function HookWangRead(next, self, book, ...)
  local inst = self.inst
  local old_mult = self:GetSanityPenaltyMultiplier()
  if book ~= nil then
    self:SetSanityPenaltyMultiplier(GetReadSanityMultiplier(inst, book))
  end
  local success, reason = next(self, book, ...)
  self:SetSanityPenaltyMultiplier(old_mult)
  if success and book ~= nil then
    inst.wang_book_reads[book.prefab] = (inst.wang_book_reads[book.prefab] or 0) + 1
  end
  return success, reason
end

-- ════════════════════════════════════════════════════════
-- 配方掌握（望专属：升级自动掌握 / 掌握经验）
-- ════════════════════════════════════════════════════════
-- 按难度档权重随机选档（护符完全覆盖精英化分布）
local function WangRollRandomTier(inst)
  local mastery = inst.components.recipe_mastery
  local weights
  if mastery:IsWearingAmulet() then
    weights = TUNING.WANG.AUTO_MASTER_AMULET_WEIGHTS
  else
    weights = TUNING.WANG.AUTO_MASTER_WEIGHTS[mastery:GetElite()]
  end
  local total = 0
  for _, w in ipairs(weights) do
    total = total + w
  end
  if total <= 0 then
    return nil
  end
  local roll = math.random() * total
  local acc = 0
  for tier, w in ipairs(weights) do
    acc = acc + w
    if roll <= acc then
      return tier
    end
  end
  return nil
end

-- 抽一个未掌握配方名：优先"掌握中"纯随机，其次按难度权重从未掌握里抽
local function WangPickRandomUnmastered(inst)
  local replica = inst.replica.recipe_mastery
  local mastering = replica:GetRecipeListByState(RECIPE_MASTERY_STATE.MASTERING)
  if #mastering > 0 then
    return mastering[math.random(#mastering)]
  end
  local tier = WangRollRandomTier(inst)
  if tier ~= nil then
    local candidates = replica:GetRecipeListByState(RECIPE_MASTERY_STATE.UNMASTERED)
    local tiered = {}
    for _, name in ipairs(candidates) do
      local recipe = GetValidRecipe(name)
      if recipe ~= nil and inst.components.recipe_mastery:GetMasteryTier(recipe) == tier then
        table.insert(tiered, name)
      end
    end
    if #tiered > 0 then
      return tiered[math.random(#tiered)]
    end
  end
  return nil
end

-- 显示物品名而非代码（与原版制作菜单一致：STRINGS.NAMES 键为大写）
local function GetRecipeDisplayName(recipe, recname)
  if recipe == nil then
    return recname
  end
  local nameKey = recipe.nameoverride or recipe.name
  return STRINGS.NAMES[string.upper(nameKey)]
    or (recipe.product ~= nil and STRINGS.NAMES[string.upper(recipe.product)])
    or nameKey
end

-- 升级自动掌握（含满级伪升级）：每次升级掌握一个，说"学到了 xxx"
local function OnWangEliteLevelUp(inst, data)
  local mastery = inst.components.recipe_mastery
  local count = (data ~= nil and data.count) or 1
  for _ = 1, count do
    local name = WangPickRandomUnmastered(inst)
    if name == nil then
      break
    end
    mastery:MasterRecipe(name)
    inst.components.talker:Say(string.format(STRINGS.CHARACTERS.WANG.ANNOUNCE.WANG_LEARNED,
      GetRecipeDisplayName(GetValidRecipe(name), name)))
  end
end

-- 掌握 → 精英经验
local function OnWangRecipeMastered(inst, data)
  if data ~= nil and data.recipe ~= nil then
    inst.components.ark_elite:AddExp(TUNING.WANG.EXP_PER_RECIPE_UNLOCK)
  end
end

-- 精二解锁传授资格；最终开关还会与 recipe_mastery 的持续负理智层共同判定。
local function OnWangApplyElite(inst, elite)
  if inst.components.recipe_mastery ~= nil then
    inst.components.recipe_mastery:SetTeachingEliteEnabled(elite >= 3)
  end
end

-- ════════════════════════════════════════════════════════
-- 存档（配方掌握状态由 recipe_mastery 组件自身存档）
-- ════════════════════════════════════════════════════════
local function OnSave(inst, data)
  data.wang_book_reads = inst.wang_book_reads
end

local function OnLoad(inst, data)
  if data and data.wang_book_reads then
    inst.wang_book_reads = data.wang_book_reads
  end
end

-- ════════════════════════════════════════════════════════
-- 客户端与服务端都会执行：tags / 表现相关
-- ════════════════════════════════════════════════════════
local function common_post_init(inst)
  inst:AddTag("wang")
  inst:AddTag("reader")        -- 可以阅读书籍
  inst:AddTag("ark_character") -- 物品包框架识别
  inst:AddTag("heavybody")     -- 免疫击飞（原版机制：SGwilson knockback 处理器判定，被击飞时原地落地）
  if TUNING.WANG ~= nil and TUNING.WANG.VOICE_TALK_PATH ~= nil then
    inst.talksoundoverride = TUNING.WANG.VOICE_TALK_PATH
  end
end

-- ════════════════════════════════════════════════════════
-- 仅服务端执行：组件 / 属性 / 玩法
-- ════════════════════════════════════════════════════════
local function master_post_init(inst)
  inst.starting_inventory = start_inv[TheNet:GetServerGameMode()] or start_inv.default

  BindVoice(inst, "wang")
  inst.MiniMapEntity:SetIcon("wang.tex")
  -- 基础属性（生命上限会随成长逐渐降低，最低为 1）
  inst.components.health:SetMaxHealth(TUNING.WANG_HEALTH)
  inst.components.hunger:SetMax(TUNING.WANG_HUNGER)
  inst.components.sanity:SetMax(TUNING.WANG_SANITY)

  -- 阅读书籍（reader 组件 + common 里的 reader tag）
  inst:AddComponent("reader")
  inst.wang_book_reads = {}
  ArkHookFunction(inst.components.reader, "Read", HookWangRead)

  -- 六星干员，精英化（精英0/1/2，等级上限 50/80/90 由框架按六星配置）
  inst:AddComponent("ark_elite")
  inst.components.ark_elite:SetRarity(6)
  inst.components.ark_elite:SetOnApplyElite(OnWangApplyElite)
  -- 生命上限随成长降低：基础 181，成长满后为 1（框架按累计等级平滑施加负奖励）
  inst.components.ark_elite:SetMaxHealthBonus(TUNING.WANG.MAX_HEALTH_BONUS)
  -- 开启框架默认击杀经验（= 怪物最大血量 ×5）。
  -- 望的经验来源因此有三条：掌握配方 / 使用技能 / 击败敌人。
  -- 击杀经验会随战斗力一起放大（精英化解锁应劫、连星、天下劫，黑子伤害与影响范围同步成长），
  -- 这是后两阶段唯一不受铸子产量限制的收入来源。
  inst.components.ark_elite:SetKillExpEnabled(true)
  -- 望专属的升级经验缩放：只压精英1 / 精英2 两档，精英0 保持原样
  InstallWangExpScale(inst)

  -- 技能（绑定精英化解锁）
  inst:AddComponent("ark_skill")
  inst.components.ark_skill:DeclareBuiltin("wang_skill1", { -- 取势：精英0 解锁
    requiredElite = 1,
    eliteLevelMap = { [1] = 1, [2] = 2, [3] = 3 },
  })
  inst.components.ark_skill:DeclareBuiltin("wang_skill2", { -- 连星：精英1 解锁
    requiredElite = 2,
    eliteLevelMap = { [2] = 1, [3] = 2 },
  })
  inst.components.ark_skill:DeclareBuiltin("wang_skill3", { -- 天下劫：精英2 解锁
    requiredElite = 3,
    eliteLevelMap = { [3] = 1 },
  })
  -- 出生时安装技能（DeclareBuiltin 只注册配置，AddSkill 才真正安装）
  inst.OnNewSpawn = OnNewSpawn

  -- 天赋：铸子（出生解锁，等级随精英化 20/15/10 秒生成黑子）
  -- 组件可能已被物品包 AddPlayerPostInit 挂载，避免重复添加
  if inst.components.ark_talent == nil then
    inst:AddComponent("ark_talent")
  end
  inst.components.ark_talent:DeclareBuiltin("wang_talent_zhuzi", {
    requiredElite = 1,                       -- 精英0 解锁（出生即有）
    eliteLevelMap = { [1] = 1, [2] = 2, [3] = 3 }, -- 精英0→1级，精英1→2级，精英2→3级
  })
  inst.components.ark_talent:DeclareBuiltin("wang_talent_yingjie", {
    requiredElite = 2,                       -- 精英1 解锁
    eliteLevelMap = { [2] = 1, [3] = 2 },   -- 精英1→1级，精英2→2级
  })

  -- 配方掌握（全玩家 PostInit 已挂组件；望额外启用自动掌握 / 精神增益）
  if inst.components.recipe_mastery == nil then
    inst:AddComponent("recipe_mastery")
  end
  inst.components.recipe_mastery:EnableAutoMastery()
  inst.components.recipe_mastery:EnableSanityBuff()
  inst.components.recipe_mastery:SetTeachingEliteEnabled(inst.components.ark_elite.elite >= 3)

  -- 事件监听（经验 / 升级自动掌握 / 掌握经验）
  inst:ListenForEvent("ark_skill_activate", OnSkillActivated)
  inst:ListenForEvent("ark_elite_levelup", OnWangEliteLevelUp)
  inst:ListenForEvent("recipe_mastered", OnWangRecipeMastered)

  -- 存档（配方掌握状态由组件自身存档）
  inst.OnSave = OnSave
  inst.OnLoad = OnLoad

  -- 基础属性修正
  inst.components.locomotor:SetExternalSpeedMultiplier(inst, "wang_speed", TUNING.WANG.SPEED_MULTIPLIER) -- 移动速度 0.8
  inst.components.combat.externaldamagemultipliers:SetModifier(inst, TUNING.WANG.DAMAGE_MULTIPLIER, "wang_damage") -- 武器攻击倍率 0.8
  inst.components.workmultiplier:SetSpecialMultiplierFn(WangWorkMultiplierFn) -- 工作效率 0.8
  inst.components.hunger.burnratemodifiers:SetModifier(inst, TUNING.WANG.HUNGER_DRAIN_RATE, "wang_hunger_rate") -- 饥饿下降较慢
  inst.components.eater.hungerabsorption = TUNING.WANG.EAT_EFFECT_MULTIPLIER -- 进食效果 0.5

  -- 特性：免疫猴子诅咒
  inst.components.cursable.IsCursable = function(self, item)
    return false
  end

  -- 特性：无法独自搬运（平时禁止重物，骑牛时放开）
  inst.components.inventory.noheavylifting = true
  inst:ListenForEvent("mounted", OnMounted)
  inst:ListenForEvent("dismounted", OnDismounted)
end

return MakePlayerCharacter("wang", prefabs, assets, common_post_init, master_post_init)
