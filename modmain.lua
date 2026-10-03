-- ════════════════════════════════════════════════════════
-- 入口：全局访问 + 前置依赖检查
-- ════════════════════════════════════════════════════════
GLOBAL.setmetatable(env, {
  __index = function(t, k)
    return GLOBAL.rawget(GLOBAL, k)
  end
})
assert(ARK_ITEM_PACKAGE_LOADED, "请安装前置模组: ark_item_package\n please install the required mod: ark_item_package\n[https://steamcommunity.com/sharedfiles/filedetails/?id=3677284770]")

-- ════════════════════════════════════════════════════════
-- 语言（台词直接写入 PO，随语言翻译）
-- ════════════════════════════════════════════════════════
RegisterPOFile(GetModConfigData("language"), {
  zh = "languages/wang_chinese_s.po",
  en = "languages/wang_english.po",
})

-- ════════════════════════════════════════════════════════
-- 角色注册
-- ════════════════════════════════════════════════════════
PrefabFiles = {'wang', 'wang_none', 'piece', 'nianzi_sword', 'piece_link_field', 'wang_fx', 'piece_box', 'wang_skill3_map_marker'}

Assets = {
  Asset("SOUNDPACKAGE", "sound/wang.fev"),
  Asset("SOUND", "sound/wang.fsb"),
  Asset("ATLAS", "images/recipe_mastery_bg.xml"),
}

AddMinimapAtlas('images/map_icons/wang.xml')
AddMinimapAtlas('images/map_icons/nianzi_sword.xml')
AddMinimapAtlas('images/map_icons/piece_box.xml')
AddMinimapAtlas('images/map_icons/piece.xml')
AddModCharacter("wang", "MALE")

ArkLogger:DeclareLogger('INFO', 'wang')

-- ════════════════════════════════════════════════════════
-- 拈子剑配方（望专属）：角色 + mods 分类
-- ════════════════════════════════════════════════════════
AddCharacterRecipe("nianzi_sword", {
  Ingredient("goldnugget", 10),
  Ingredient("livinglog", 10),
  Ingredient("nightmarefuel", 10),
}, TECH.NONE, {
  builder_tag = "wang",
  atlas = "images/inventoryimages/nianzi_sword.xml",
  image = "nianzi_sword.tex",
  description = "NIANZI_SWORD",
}, {
  "MODS",
})

-- ════════════════════════════════════════════════════════
-- 常量配置
-- ════════════════════════════════════════════════════════
TUNING.WANG = {}

-- 配音语言独立于界面文本；自动模式跟随游戏语言，其他语言默认日语。
local voice_cfg = GetModConfigData("voice_language")
local auto_voice_map = {
  zh = "zh",
  ja = "jp",
}
local voice_lang = voice_cfg == "auto"
    and (auto_voice_map[LOC.GetLocaleCode(LOC.GetLanguage())] or "jp")
    or voice_cfg
if voice_lang ~= "zh" and voice_lang ~= "jp" and voice_lang ~= "hunan" then
  voice_lang = "jp"
end
TUNING.WANG.VOICE_LANG = voice_lang
TUNING.WANG.VOICE_CD = 2
TUNING.WANG.VOICE_TALK_PATH = "wang/voice_" .. voice_lang .. "/talk_LP"
RegisterVoice("wang", "languages/wang_voice", {
  voice_lang = voice_lang,
})

-- 基础属性（望的生命上限会随成长逐渐降低，最低为 1）
TUNING.WANG_HEALTH = 181
TUNING.WANG_HUNGER = 150
TUNING.WANG_SANITY = 361

-- 基础属性修正
TUNING.WANG.SPEED_MULTIPLIER = 0.8     -- 移动速度
TUNING.WANG.DAMAGE_MULTIPLIER = 0.8    -- 武器攻击倍率
TUNING.WANG.WORK_EFFICIENCY = 0.8      -- 工作效率
TUNING.WANG.HUNGER_DRAIN_RATE = 0.8    -- 饥饿下降速率（较慢）
TUNING.WANG.EAT_EFFECT_MULTIPLIER = 0.5 -- 进食饥饿恢复（0.5倍）

-- 黑子（可调整数值；物理数值在 piece.lua 内）
TUNING.WANG.PIECE_THROW_DAMAGE = 5    -- 落地对附近生物伤害
TUNING.WANG.PIECE_BASE_DAMAGE = 10    -- 爆炸基础伤害（主动 / 被动引爆）
TUNING.WANG.PIECE_EXPLODE_RANGE = 4   -- 爆炸半径
TUNING.WANG.PIECE_DEFAULT_LIMIT = 20 -- 无精英组件的玩家部署上限
TUNING.WANG.PIECE_ELITE_DAMAGE_PER_LEVEL = 0.2 -- 部署时每累计精英等级增加的基础伤害
TUNING.WANG.PIECE_NEIGHBOR_DAMAGE_BONUS = 0.25 -- 每个有效邻格的伤害加成
TUNING.WANG.PIECE_NEIGHBOR_LINGER = 2         -- 棋子消失后邻格加成保留时间（秒）

-- 连星（二技能）：棋子连接
TUNING.WANG.PIECE_MAX_LINKS = 4       -- 每个棋子最多连接数

-- 棋子网格（全地图分区，每格至多 1 枚占格棋子；隐藏预部署与正式部署统一约束）
TUNING.WANG.PIECE_GRID_SIZE = 2            -- 网格边长（地皮）：部署占用分区
TUNING.WANG.PIECE_GRID_SNAP = false        -- 部署自动吸附格中心（默认关：落点即落点，格内自由偏移）

-- 天下劫（三技能）：地图上的部署棋子按 20 单位固定世界网格聚合为长期选点。
-- 固定网格保证增减棋子/读档时聚合坐标不会随成员平均位置漂移。
TUNING.WANG.SKILL3_MAP_CLUSTER_SIZE = 20

-- 经验来源（框架默认击杀经验已在 prefabs/wang.lua 开启）
TUNING.WANG.EXP_PER_RECIPE_UNLOCK = 10 -- 解锁配方
TUNING.WANG.EXP_PER_SKILL_USE = 10     -- 使用技能
-- 击杀经验：框架按「怪物最大血量 ×5」发放（ark_elite.lua 先发 floor(maxhealth)，AddExp 内部再 ×5）
-- 之前是关闭的，望只靠「掌握配方 + 放技能」升级；但放技能被铸子产量锁死
--（精英1 每 15 秒、精英2 每 10 秒一枚黑子），击杀经验是唯一能随战斗力成长放大的来源。

-- 各精英阶段升级经验的缩放系数（只影响望，不改前置包的 EXP_CONFIG）
-- 索引 = 精英阶段（1=精英0 / 2=精英1 / 3=精英2）
-- 依据（六星上限 50/80/90，按前置包经验表实算）：
--   精英0  24,400 经验 = 488 次动作，本来就健康          → 保持原样
--   精英1 337,000 经验 = 6,740 次动作，是精英0 的 13.8 倍
--   精英2 750,000 经验 = 15,000 次动作，是精英0 的 30.7 倍
--   后两档合计占总需求的 97.8%，且曲线尾部极陡（最后 20% 的等级吃掉 52% 经验）
TUNING.WANG.LEVEL_EXP_SCALE = {
  [1] = 1.00, -- 精英0：24,400 经验（不动）
  [2] = 0.40, -- 精英1：337,000 → 134,769
  [3] = 0.25, -- 精英2：750,000 → 187,454
}

-- 读书理智消耗控制（倍率：首次阅读新书翻倍 → 随已读次数降至 0.5 倍）
TUNING.WANG.READ_SANITY_MULT_FIRST = 2   -- 首次阅读理智消耗倍率
TUNING.WANG.READ_SANITY_MULT_MIN = 0.5   -- 最低降至正常值 0.5 倍
TUNING.WANG.READ_SANITY_MULT_STEP = 0.1  -- 每次阅读后降低 0.1

-- 配方掌握（recipe_mastery 组件）
-- 普通制造掌握成功率 [精英阶级][难度档]：普通一/魔法一/普通二/魔法二/远古/暗影月亮/其他mod
TUNING.WANG.MASTER_CHANCE = {
  { 0.75, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25 }, -- 无精英化
  { 1.00, 0.75, 0.50, 0.25, 0.25, 0.25, 0.25 }, -- 精一
  { 1.00, 1.00, 0.75, 0.50, 0.25, 0.25, 0.25 }, -- 精二
}
TUNING.WANG.AMULET_MASTERY_BONUS = 0.5             -- 建筑护符：掌握成功率加算 50%（各阶级一致）
TUNING.WANG.SANITY_DRAIN_PER_UNMASTERED = -0.2      -- 每个未掌握配方每秒掉理智（占位）
TUNING.WANG.SANITY_RECOVERY_PER_MASTERED = 0.05     -- 每个已掌握配方每秒回理智（占位）
TUNING.WANG.TEACH_DURATION = 10                       -- 传授持续时间（秒）
TUNING.WANG.TEACH_SANITY_TOTAL = 30                   -- 完整传授累计损失理智
-- 升级自动掌握：按难度档权重分配（科一/魔一/科二/魔二/远古/暗影月亮/其他）
TUNING.WANG.AUTO_MASTER_WEIGHTS = {
  { 75, 25, 0, 0, 0, 0, 0 },   -- 无精英化
  { 45, 33, 20, 2, 0, 0, 0 },  -- 精一
  { 9, 15, 30, 30, 16, 0, 0 }, -- 精二
}
TUNING.WANG.AUTO_MASTER_AMULET_WEIGHTS = { 0, 0, 0, 25, 25, 25, 25 } -- 佩戴建筑护符时完全覆盖精英化分布

-- ════════════════════════════════════════════════════════
-- 配方掌握共享接口（组件与外部共用）
-- ════════════════════════════════════════════════════════
-- 状态枚举
GLOBAL.RECIPE_MASTERY_STATE = {
  UNMASTERED = 0,
  MASTERING = 1,
  MASTERED = 2,
}

-- 可掌握的有效配方判定
function GLOBAL.IsLearnableRecipe(recipe)
  if recipe == nil then return false end
  if recipe.builder_tag ~= nil and recipe.builder_tag ~= "wang" then return false end
  if recipe.manufactured or recipe.nounlock then return false end
  local level = recipe.level
  if level.ANCIENT > 0 or level.CELESTIAL > 0 or level.CARTOGRAPHY > 0 or level.SCULPTING > 0 then return false end
  return true
end

-- ════════════════════════════════════════════════════════
-- 子模块
-- ════════════════════════════════════════════════════════
modimport("modmain/wang_elite")
modimport("modmain/wang_skill")
modimport("modmain/wang_talent")
modimport("modmain/nianzi_sword")
modimport("modmain/wang_piecegrid") -- TOSS 服务端拦截（依赖 scripts/wang_piecegrid 与上方 TUNING.WANG）

-- ════════════════════════════════════════════════════════
-- recipe_mastery 组件注册（可复制，全玩家挂载；传授目标也需组件）
-- ════════════════════════════════════════════════════════
AddReplicableComponent("recipe_mastery")
AddPlayerPostInit(function(inst)
  if TheWorld.ismastersim and not inst.components.recipe_mastery then
    inst:AddComponent("recipe_mastery")
  end
end)
modimport("modmain/recipe_mastery")
modimport("modmain/recipe_mastery_bg")

-- ════════════════════════════════════════════════════════
-- 棋盒主人组件（宠物式存在）：棋盒 follow 态存档数据由主人管理
-- ════════════════════════════════════════════════════════
AddReplicableComponent("wang_chess_box_owner")
AddPlayerPostInit(function(inst)
  if TheWorld.ismastersim and not inst.components.wang_chess_box_owner then
    inst:AddComponent("wang_chess_box_owner")
  end
end)

-- ════════════════════════════════════════════════════════
-- 兽形棋盒：容器 UI 配置 + 起始物品
-- ════════════════════════════════════════════════════════
-- containers 是游戏模块（非全局），需 require 后注册容器 UI 配置
-- 4 格储物 UI（2×2）。暂用原版 ui_chest_2x2，等棋盒专属容器 UI 资源补齐后替换 animbank/animbuild
local containers = require("containers")

-- 原版 specialized container 只扫描主物品栏；补充扫描头部装备栏中的云兽。
local function IncludeEquippedPieceBox(next, inventory, ...)
  local specialized = next(inventory, ...)
  if inventory.ignorespoverflow then
    return specialized
  end

  local equipped = inventory:GetEquippedItem(EQUIPSLOTS.HEAD)
  local container = equipped ~= nil and equipped.prefab == "piece_box"
    and equipped.components.container or nil
  if container ~= nil and container.priorityfn ~= nil
      and container.canbeopened
      and not (container.droponopen or container.inst:HasTag("portablecontainer")) then
    specialized = specialized or {}
    if not table.contains(specialized, container) then
      table.insert(specialized, container)
    end
  end
  return specialized
end

-- 原版会为 specialized container 自动调用 Open；仅在棋子自动入盒期间临时跳过该分支。
local function GivePieceToBoxSilently(next, inventory, item, ...)
  if item == nil or item.prefab ~= "piece" then
    return next(inventory, item, ...)
  end

  local tagged = {}
  local specialized = inventory:GetSpecializedContainers()
  if specialized ~= nil then
    for _, container in ipairs(specialized) do
      if container.inst.prefab == "piece_box"
          and container:ShouldPrioritizeContainer(item)
          and not container.inst:HasTag("portablestorage") then
        container.inst:AddTag("portablestorage")
        table.insert(tagged, container.inst)
      end
    end
  end

  local ok, result = pcall(next, inventory, item, ...)
  for _, inst in ipairs(tagged) do
    if inst:IsValid() then
      inst:RemoveTag("portablestorage")
    end
  end
  if not ok then
    error(result, 0)
  end
  return result
end

AddComponentPostInit("inventory", function(self)
  ArkHookFunction(self, "GetSpecializedContainers", IncludeEquippedPieceBox)
  ArkHookFunction(self, "GiveItem", GivePieceToBoxSilently)
end)

-- 可装备容器会同时生成右键 PICKUP 和 RUMMAGE，前者优先级更高并遮蔽“打开”。
-- 仅过滤地面云兽的右键拾取；左键拾取、物品栏装备和原版容器动作保持不变。
AddComponentAction("SCENE", "inventoryitem", function(inst, doer, actions, right)
  if right and inst.prefab == "piece_box" then
    for i = #actions, 1, -1 do
      if actions[i] == ACTIONS.PICKUP then
        table.remove(actions, i)
      end
    end
  end
end)

containers.params["piece_box"] = {
  widget = {
    slotpos = {
      Vector3(-37.5, 32 + 4, 0),
      Vector3(37.5, 32 + 4, 0),
      Vector3(-37.5, -(32 + 4), 0),
      Vector3(37.5, -(32 + 4), 0),
    },
    animbank = "ui_chest_2x2",
    animbuild = "ui_chest_2x2",
    pos = Vector3(200, 0, 0),
    side_align_tip = 120,
  },
  type = "chest",
  priorityfn = function(_, item)
    return item ~= nil and item.prefab == "piece"
  end,
}

-- 初始物品：拈子剑与兽形棋盒；云兽可拾取进背包 / 放下跟随
local StartItems = { "piece_box", "nianzi_sword" }
TUNING.GAMEMODE_STARTING_ITEMS.DEFAULT.WANG = StartItems
