require "prefabutil"

-- 棋子网格占用表（scripts/wang_piecegrid.lua）：整图分区，每格至多 1 枚
local Grid = require "wang_piecegrid"
local PieceLimit = require "wang_piece_limit"
local Audio = require "wang_audio"
local Skill3MapMarkers = require "wang_skill3_mapmarkers"

-- ════════════════════════════════════════════════════════
-- 望的棋子（黑子）
-- piece：物品态 / 最终部署态；piece_projectile：独立投掷飞行实体
--   物品态   — 可入背包(堆叠 120) / 装备手上右键投掷(TOSS)
--   部署态   — 地面建筑(structure)，可被锤子 / boss 摧毁；自动检测附近敌人并被动引爆
--              无实体碰撞（可走穿，间距由网格管）；进入连星态后停止陷阱检测
-- 投掷落地：生成 chester_transform_fx + wanda_attack_pocketwatch_old_fx
--           遮盖黑子出现，直接播放未激活动画(WeiJiHuo)
-- 网格约束：目标格已有棋子实体 → 不投掷；投掷起飞时目标格立即生成隐藏的最终棋子实体
-- 占格：棋子先确定位置，再通过 net_bool 声明占格；主客机各自维护同一份本地快捷网格
-- 引爆：主动(1技能) / 被动(被摧毁 / 部署态接近探测命中) 三种触发，参考火药爆炸 / 蜜蜂地雷
-- 动画来源: animSource/piece/piece.scml
--   idle     — 物品态（普通物品丢地上的表现）
--   XuanZuan — 投掷飞行旋转
--   ChuXian  — 出现（拈子剑单次落子与二技能批量部署都播）
--   WeiJiHuo — 部署态待机
--   JiHuo    — 预留动画（当前无独立激活态）
-- ════════════════════════════════════════════════════════

-- 物理效果数值（一般不改动，直接放预制体；可调整数值放 modmain）
local THROW_SPEED = 15    -- 投掷水平速度
local THROW_GRAVITY = -35 -- 投掷重力（抛物线）
local THROW_AOE = 1       -- 落地伤害范围

-- 爆炸数值（modmain 可调）
local EXPLODE_RANGE = TUNING.WANG.PIECE_EXPLODE_RANGE or 4 -- 爆炸半径

-- 部署态陷阱数值
-- 引爆半径 = 伤害半径 = EXPLODE_RANGE（单一数据源，二者自动同步）
-- 注意：后续某状态（如天下劫）下该值可能翻倍，检测与伤害共用，改这一处即可
local PROX_CHECK_INTERVAL = 1 -- 部署态检测周期（秒）

-- 陷阱目标筛选（参考蜜蜂地雷 mine 组件）
-- 触发：怪物 / 动物 / 敌对角色；"player" 加入禁止表 → 玩家（含望自己）不会触发陷阱
local PROX_ONEOF_TAGS = { "monster", "character", "animal" }
local PROX_MUST_TAGS = { "_combat" }
local PROX_NO_TAGS = { "notraptrigger", "flying", "ghost", "playerghost", "spawnprotection", "player" }

RegisterInventoryItemAtlas("images/inventoryimages/piece.xml", "piece.tex")

local assets = {
  Asset("ANIM", "anim/piece.zip"),
  Asset("ANIM", "anim/swap_piece.zip"),
  Asset("ATLAS", "images/inventoryimages/piece.xml"),
  Asset("ATLAS", "images/map_icons/piece.xml"),
}

local prefabs = {
  "wang_skill3_map_marker",
  "wang_piece_explode_smoke_fx",
  "wang_piece_explode_shadow_fx",
  "cavehole_flick",
}

-- ────────────────────────────────────────────────────────
-- 爆炸相关（参考游戏源码 explosive 组件 + 凯尔希二技能子弹）
-- ────────────────────────────────────────────────────────

local function SpawnFxAt(prefab, x, y, z, scale)
  local fx = SpawnPrefab(prefab)
  if fx ~= nil then
    fx.Transform:SetPosition(x, y, z)
    if scale ~= nil then
      fx.Transform:SetScale(scale, scale, scale)
    end
  end
end

-- 爆炸命中敌人时，敌人身上播放的两个特效
local function SpawnHitEnemyFx(ent)
  local x, y, z = ent.Transform:GetWorldPosition()
  SpawnFxAt("wanda_attack_shadowweapon_old_fx", x, y, z)
  SpawnFxAt("fx_dock_pop", x, y, z)
end

-- 主动爆炸对周围可作业物施加固定基础工作量，不含已部署棋子，避免连锁引爆。
-- 基础等价于多用镐斧连续作业 5 次，并乘棋子部署时保存的攻击倍率 _damageMultiplier；
-- 走 WorkedBy_Internal 保留 workmultiplier / worked / onwork 等标准流程，且不受施法者当前手持工具影响。
local DESTROY_TAGS = { "CHOP_workable", "MINE_workable", "HAMMER_workable", "DIG_workable" }
local EXPLOSION_WORK_AMOUNT = 5 * TUNING.MULTITOOL_AXE_PICKAXE_EFFICIENCY
local function DestroySurroundingBuildings(inst, source, range)
  local x, y, z = inst.Transform:GetWorldPosition()
  local ents = TheSim:FindEntities(x, y, z, range, nil,
    { "insect", "INLIMBO", "wang_piece_deployed" }, DESTROY_TAGS)
  for _, ent in ipairs(ents) do
    if ent.components.workable ~= nil and ent.components.workable:CanBeWorked() then
      SpawnPrefab("collapse_small").Transform:SetPosition(ent.Transform:GetWorldPosition())
      ent.components.workable:WorkedBy_Internal(source or inst, EXPLOSION_WORK_AMOUNT * inst._damageMultiplier)
    end
  end
end

-- 范围伤害（参考火药爆炸 explosive 组件：范围内所有可攻击目标）
--   source  伤害来源（主动=施法者记击杀；被动=棋子自身不记名）
--   suggest 被动时吸引仇恨的对象（摧毁者）
local function AoEExplode(inst, source, damage, range, active, suggest)
  if active then
    DestroySurroundingBuildings(inst, source, range)
  end

  local x, y, z = inst.Transform:GetWorldPosition()
  local ents = TheSim:FindEntities(x, y, z, range, nil, { "INLIMBO", "notarget" })
  for _, ent in ipairs(ents) do
    if ent ~= inst and not ent:IsInLimbo() and ent:IsValid()
        and not (ent.components.health ~= nil and ent.components.health:IsDead())
        and ent.components.combat ~= nil and ent.components.combat:CanBeAttacked() then
      ent.components.combat:GetAttacked(source, damage)
      SpawnHitEnemyFx(ent)
      if suggest ~= nil and suggest ~= source and suggest:IsValid() then
        ent.components.combat:SuggestTarget(suggest)
      end
    end
  end
end

-- wang_fx 中复用原版素材；引爆时按范围倍率缩放，投掷落地保持原大小。
local function SpawnExplodeFx(inst, active, scale)
  local x, y, z = inst.Transform:GetWorldPosition()
  if active then
    SpawnFxAt("wang_piece_explode_smoke_fx", x, y, z, scale)
  end
  SpawnFxAt("wang_piece_explode_shadow_fx", x, y, z, scale)
end

local function GetExplodeDamage(inst, multiplier)
  local x, _, z = inst.Transform:GetWorldPosition()
  local gx, gz = Grid:WorldToCell(x, z)
  local neighbors = Grid:CountNeighbors(gx, gz, inst._neighborMode)
  return (inst._baseDamage + inst._eliteBonusDamage) * inst._damageMultiplier
      * (1 + TUNING.WANG.PIECE_NEIGHBOR_DAMAGE_BONUS * neighbors) * (multiplier or 1)
end

-- ────────────────────────────────────────────────────────
-- 部署态被动引爆：周期检测引爆半径内目标，命中即直接爆炸（陷阱）
-- 参考蜜蜂地雷 mine 组件（DoPeriodicTask + FindEntity）
-- 触发：怪物/动物/敌对角色（玩家不触发）；爆炸本身对所有可攻击目标造成伤害，不摧毁建造物
-- ────────────────────────────────────────────────────────
local function PassiveDetonateCheck(inst)
  local target = FindEntity(inst, EXPLODE_RANGE * inst._explodeRangeMultiplier, function(dude)
    return not (dude.components.health ~= nil and dude.components.health:IsDead())
      and dude.components.combat ~= nil and dude.components.combat:CanBeAttacked(inst)
  end, PROX_MUST_TAGS, PROX_NO_TAGS, PROX_ONEOF_TAGS)
  if target ~= nil then
    inst:PassiveExplode(nil, 1) -- 接近陷阱引爆：范围伤害、不摧毁建造物、击杀记在布子者身上
  end
end

local function StartProximityTrap(inst)
  if inst._proxTask == nil and not inst:IsAsleep() then
    -- 首次检测延后一整个周期：连星会在 0.5 秒内完成外围落子并转连接态，可在第一次扫描前关闭任务。
    inst._proxTask = inst:DoPeriodicTask(PROX_CHECK_INTERVAL, PassiveDetonateCheck, PROX_CHECK_INTERVAL)
  end
end

local function StopProximityTrap(inst)
  if inst._proxTask ~= nil then
    inst._proxTask:Cancel()
    inst._proxTask = nil
  end
end

local function OnEntitySleep(inst)
  -- DoPeriodicTask 挂在全局 scheduler 上，不会随实体休眠自动暂停。
  -- 睡眠区域没有活跃目标，停止部署态接近扫描，避免每枚棋子每秒继续 FindEntity。
  StopProximityTrap(inst)
end

local function OnEntityWake(inst)
  -- 仅普通部署态需要陷阱扫描；连接态在 EnterLinkState 后永久关闭该任务。
  if inst._isdeployed and not inst._islinked then
    StartProximityTrap(inst)
  end
end

-- 读档恢复时随机待机帧，避免一批存档棋子完全同步
local function RandomizeAnimFrame(inst)
  local numFrames = inst.AnimState:GetCurrentAnimationNumFrames()
  if numFrames > 0 then
    inst.AnimState:SetFrame(math.random(numFrames) - 1)
  end
end

local function DisableEntityCollisions(inst)
  if inst.Physics ~= nil then
    inst.Physics:SetCollisionMask(COLLISION.GROUND)
    inst.Physics:Stop()
  end
end

-- 脚底动画纯客户端生成：非网络实体，不参与存档，也不在专服创建。
-- 只在棋子真正进入部署态后触发；隐藏占格棋子虽然实体已生成，但不会提前创建 FX。
local function CreateGroundFx(parent)
  local fx = CreateEntity()

  fx.entity:AddTransform()
  fx.entity:AddAnimState()

  fx:AddTag("FX")
  fx:AddTag("NOCLICK")
  fx.persists = false

  fx.AnimState:SetBank("piece")
  fx.AnimState:SetBuild("piece")
  fx.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
  fx.AnimState:SetLayer(LAYER_BACKGROUND)
  fx.AnimState:SetSortOrder(3)
  fx.AnimState:PlayAnimation("JiHuo_DiMian-0", false)
  fx.AnimState:SetFrame(5)
  fx.AnimState:PushAnimation("JiHuo_DiMian-1", true)

  parent:AddChild(fx)
  fx.Transform:SetPosition(0, 0, 0)
  return fx
end

local function TryCreateGroundFx(inst)
  inst._groundFxTask = nil
  if not inst._showGroundFx:value()
      or (inst._groundFx ~= nil and inst._groundFx:IsValid()) then
    return
  end
  if not inst.entity:IsVisible() then
    inst._groundFxTask = inst:DoTaskInTime(0, TryCreateGroundFx)
    return
  end
  inst._groundFx = CreateGroundFx(inst)
end

local function OnGroundFxDirty(inst)
  if inst._showGroundFx:value()
      and inst._groundFxTask == nil
      and not (inst._groundFx ~= nil and inst._groundFx:IsValid()) then
    inst._groundFxTask = inst:DoTaskInTime(0, TryCreateGroundFx)
  end
end

local function EnableGroundFx(inst)
  if not inst._showGroundFx:value() then
    inst._showGroundFx:set(true)
  end
end

-- ────────────────────────────────────────────────────────
-- 部署态：投掷落地 / 技能放置后转地面建筑
-- 无实体碰撞（棋子出生即不参与实体碰撞，部署时无需再移除碰撞体）
-- 网格注册统一走这里：投掷/拈子剑/连星/读档恢复 → 自动重建占用表
-- ────────────────────────────────────────────────────────
local function ApplyCellOccupiedState(inst)
  if inst._wang_cell_occupied:value() then
    local x, _, z = inst.Transform:GetWorldPosition()
    local gx, gz = Grid:WorldToCell(x, z)
    return Grid:Register(inst, gx, gz)
  end
  Grid:Unregister(inst, false)
  return true
end

local function OnCellOccupiedDirty(inst)
  -- 服务端在修改 net_bool 时同步更新自己的缓存；远程客户端由 dirty 事件走同一登记逻辑。
  if not TheWorld.ismastersim then
    ApplyCellOccupiedState(inst)
  end
end

local function OnGridEntityRemove(inst)
  -- 删除实体时客户端也要清本地缓存；邻子残留只有服务端伤害计算需要。
  Grid:Unregister(inst, TheWorld.ismastersim and inst._isdeployed == true)
end

local function DeclareCellOccupied(inst)
  local x, _, z = inst.Transform:GetWorldPosition()
  local gx, gz = Grid:WorldToCell(x, z)
  local current = Grid:GetPiece(gx, gz)
  if current ~= nil and current ~= inst then
    return false
  end
  if not inst._wang_cell_occupied:value() then
    inst._wang_cell_occupied:set(true)
  end
  return ApplyCellOccupiedState(inst)
end

-- 占格后棋子已经不再是普通可堆叠物品。直接卸载 stackable 会同步移除 _stackable 标签，
-- 从组件与标签两层避开第三方地面自动堆叠；锤回收时会生成新的普通 piece，无需恢复组件。
local function DisableStacking(inst)
  if inst.components.stackable ~= nil then
    inst:RemoveComponent("stackable")
  end
end

-- 延迟落子 / 投掷使用：调用前必须先确定 Transform；随后只声明“我占当前格”。
local function ReserveDeployCell(inst)
  if inst._isdeployed or not DeclareCellOccupied(inst) then
    return false
  end
  DisableStacking(inst)
  inst.persists = false
  inst.components.inventoryitem.canbepickedup = false
  inst.components.workable:SetWorkable(false)
  inst:Hide()
  return true
end

local function SetDeployedState(inst, options)
  if inst._isdeployed then
    return true
  end
  if not DeclareCellOccupied(inst) then
    return false
  end
  DisableStacking(inst)
  options = options or {}

  inst._isdeployed = true
  inst.persists = true
  inst:Show()
  inst:AddTag("structure")
  inst:AddTag("wang_piece_deployed") -- 已部署标记：供 1 技能引爆检索
  DisableEntityCollisions(inst)
  inst.components.inventoryitem.canbepickedup = false
  inst.components.workable:SetWorkable(true)
  if not options.silent then
    Audio.PlayPiecePlace(inst)
  end
  if options.playappear then
    inst.AnimState:PlayAnimation("ChuXian", false)
    inst.AnimState:PushAnimation("WeiJiHuo", true)
  else
    inst.AnimState:PlayAnimation("WeiJiHuo", true)
    if options.randomize then
      RandomizeAnimFrame(inst)
    end
  end
  EnableGroundFx(inst)

  Skill3MapMarkers:Register(inst)

  -- 普通部署态即为陷阱态；连星会在 EnterLinkState 中关闭检测。
  StartProximityTrap(inst)
  PieceLimit:Register(inst)
  return true
end

-- ────────────────────────────────────────────────────────
-- 投掷落地（complexprojectile onhit）：
-- 飞行物在实际命中点造成伤害；目标格的隐藏最终棋子转部署态并显形。
-- 若预部署实体异常失效，则飞行棋子落地为可拾取物品，不制造无实体占位。
-- ────────────────────────────────────────────────────────
local function OnTossHit(inst, attacker)
  local x, y, z = inst.Transform:GetWorldPosition()
  Audio.PlaySfx(inst, "piece_projectile_hit", 0.55)

  local ents = TheSim:FindEntities(x, y, z, THROW_AOE, nil, { "INLIMBO", "playerghost" })
  for _, ent in ipairs(ents) do
    if ent ~= nil and ent:IsValid() and ent.components.combat ~= nil
        and attacker ~= nil and attacker:IsValid() then
      ent.components.combat:GetAttacked(attacker, TUNING.WANG.PIECE_THROW_DAMAGE)
    end
  end

  -- 目标格的隐藏棋子在起飞时已经声明占格；命中后只负责显形并转部署态。
  local reserved = inst._wang_toss_target_piece
  inst._wang_toss_target_piece = nil
  if reserved ~= nil and reserved:IsValid() and reserved:DeployPiece() then
    SpawnExplodeFx(reserved, true)
    inst:Remove()
    return
  end

  -- 极端异常（预部署实体被外部移除）时不凭空占格；返还一枚普通黑子到实际落点。
  if reserved ~= nil and reserved:IsValid() then
    reserved:Remove()
  end
  local piece = SpawnPrefab("piece")
  if piece ~= nil then
    piece.Transform:SetPosition(x, 0, z)
  end
  inst:Remove()
end

-- ────────────────────────────────────────────────────────
-- 装备手上显示
-- ────────────────────────────────────────────────────────
local function OnEquip(inst, owner)
  owner.AnimState:OverrideSymbol("swap_object", "swap_piece", "swap_object")
  owner.AnimState:Show("ARM_carry")
  owner.AnimState:Hide("ARM_normal")
end

local function OnUnequip(inst, owner)
  owner.AnimState:ClearOverrideSymbol("swap_object")
  owner.AnimState:Hide("ARM_carry")
  owner.AnimState:Show("ARM_normal")
end

-- ────────────────────────────────────────────────────────
-- 部署态被锤击 → 回收成普通黑子。
-- 锤击只作为一次性交互触发，不走生命/伤害结算；棋子本体移除后生成普通物品态黑子。
-- boss / 自然灾害等其它摧毁路径仍可通过外部调用 PassiveExplode 触发被动引爆。
-- ────────────────────────────────────────────────────────
local function PieceShouldRecoil(_, _, tool, numworks)
  -- 拈子剑保留对普通建筑 0 HAMMER 效率；仅回收棋子时把本次工作量视为 1。
  if tool ~= nil and tool.prefab == "nianzi_sword" and (numworks or 0) <= 0 then
    return false, 1
  end
end

local function OnHammered(inst, worker)
  if not inst._isdeployed then
    inst:Remove()
    return
  end

  local x, y, z = inst.Transform:GetWorldPosition()
  SpawnFxAt("cavehole_flick", x, y, z)

  -- 先移除部署实体，让 onremove 统一清理占格、连线、陷阱任务与部署数量统计。
  inst:Remove()

  local piece = SpawnPrefab("piece")
  if piece ~= nil then
    piece.Transform:SetPosition(x, y, z)
  end
end

local function ReticuleTargetFn()
  return TheInput:GetWorldPosition()
end

local function CanTossInWorld(_, _, pos)
  -- 兼容不同版本的原版动作采集器：旧版这里只传 doer，新版会把 point 一并传入。
  pos = pos or (TheInput ~= nil and TheInput:GetWorldPosition() or nil)
  if pos == nil then
    return true
  end
  local gx, gz = Grid:WorldToCell(pos.x, pos.z)
  return not Grid:IsOccupied(gx, gz)
end

-- 原版 Stackable:Put 会先走 CanStackWith，并支持 prefab 自定义 stackable_CanStackWithFn。
-- 已占格即表示处于隐藏预部署或正式部署态：两者都不能再被任何常规堆叠逻辑合并。
-- 普通物品态 _wang_cell_occupied=false，仍保持原有背包/地面堆叠行为。
local function CanStackPieceWith(inst, item)
  return not inst._wang_cell_occupied:value() and not item._wang_cell_occupied:value()
end

local function CopyDeploySnapshot(source, target)
  target._baseDamage = source._baseDamage
  target._eliteBonusDamage = source._eliteBonusDamage
  target._damageMultiplier = source._damageMultiplier
  target._explodeRangeMultiplier = source._explodeRangeMultiplier
  target._neighborMode = source._neighborMode
  target._deployer = source._deployer
  target._deployerUserid = source._deployerUserid
end

local function OnTossLaunch(inst, attacker, targetPos)
  inst.AnimState:PlayAnimation("XuanZuan", true)
  Audio.PlaySfx(inst, "piece_projectile_start", 0.5)

  -- 飞行物自身会移动，不能代表目标格占用；目标格提前生成隐藏的最终棋子实体。
  local sx, sz = Grid:SnapWorldPos(targetPos.x, targetPos.z)
  local reserved = SpawnPrefab("piece")
  if reserved ~= nil then
    CopyDeploySnapshot(inst, reserved)
    reserved.Transform:SetPosition(sx, 0, sz)
    if reserved:ReserveDeployCell() then
      inst._wang_toss_target_piece = reserved
    else
      reserved:Remove()
    end
  end
end

local function OnProjectileRemove(inst)
  local reserved = inst._wang_toss_target_piece
  inst._wang_toss_target_piece = nil
  if reserved ~= nil and reserved:IsValid() and not reserved._isdeployed then
    reserved:Remove()
  end
end

local function OnRemove(inst)
  StopProximityTrap(inst)
  Skill3MapMarkers:Unregister(inst)
  PieceLimit:Unregister(inst)
end

local function OnSave(inst, data)
  data.baseDamage = inst._baseDamage
  data.eliteBonusDamage = inst._eliteBonusDamage
  data.damageMultiplier = inst._damageMultiplier
  data.explodeRangeMultiplier = inst._explodeRangeMultiplier
  data.neighborMode = inst._neighborMode
  data.deployer_userid = inst._deployerUserid
  data.deployed_age = inst._deployTime ~= nil and (GetTime() - inst._deployTime) or nil
  data.deployment_order = inst._deployOrder
  data.isdeployed = inst._isdeployed
  data.islinked = inst._islinked
end

local function OnLoad(inst, data)
  if data == nil then
    return
  end

  inst._baseDamage = data.baseDamage or TUNING.WANG.PIECE_BASE_DAMAGE
  inst._eliteBonusDamage = data.eliteBonusDamage or 0
  inst._damageMultiplier = data.damageMultiplier or 1
  inst._explodeRangeMultiplier = data.explodeRangeMultiplier or 1
  inst._neighborMode = data.neighborMode or "cross"
  inst._deployerUserid = data.deployer_userid
  inst._deployTime = data.deployed_age ~= nil and (GetTime() - data.deployed_age) or nil
  inst._deployOrder = data.deployment_order

  if data.isdeployed then
    SetDeployedState(inst, { silent = true, randomize = true })
  end
  if data.islinked then
    inst:EnterLinkState()
  end
end

-- ────────────────────────────────────────────────────────
-- 主函数
-- ────────────────────────────────────────────────────────
local function fn()
  local inst = CreateEntity()

  inst.entity:AddTransform()
  inst.entity:AddAnimState()
  inst.entity:AddSoundEmitter()
  inst.entity:AddNetwork()

  MakeInventoryPhysics(inst)
  DisableEntityCollisions(inst)

  -- 物品态：普通物品的表现（背包/地上显示 idle）
  inst.AnimState:SetBank("piece")
  inst.AnimState:SetBuild("piece")
  inst.AnimState:PlayAnimation("idle", true)

  MakeInventoryFloatable(inst)

  -- 投掷物标签保留在 pristine state；真正飞行组件位于 piece_projectile。
  inst:AddTag("projectile")

  -- 瞄准圈（装备时由 playercontroller 创建，客户端组件）
  inst:AddComponent("reticule")
  inst.components.reticule.targetfn = ReticuleTargetFn

  -- 投掷落点网格门禁：动作采集器只查询本机 Grid.cells。
  -- 服务端权威拦截在 modmain/wang_piecegrid.lua（包 ACTIONS.TOSS.fn）。
  inst.CanTossInWorld = CanTossInWorld

  -- 占格是棋子自身的联网状态。位置必须先确定，再把此位设为 true；客户端 dirty 后按当前 Transform 登记本地网格。
  inst._wang_cell_occupied = net_bool(inst.GUID, "piece._wang_cell_occupied", "piece_cell_occupied_dirty")
  inst.stackable_CanStackWithFn = CanStackPieceWith
  inst:ListenForEvent("piece_cell_occupied_dirty", OnCellOccupiedDirty)
  inst:ListenForEvent("onremove", OnGridEntityRemove)

  -- 部署是一次性状态，用父棋子的 1 bit net_bool 通知各客户端创建本地脚底 FX。
  -- FX 自身完全不联网；专服只同步这个已有实体上的状态位。
  inst._showGroundFx = net_bool(inst.GUID, "piece._showGroundFx", "piece_groundfxdirty")
  if not TheNet:IsDedicated() then
    inst:ListenForEvent("piece_groundfxdirty", OnGroundFxDirty)
  end

  inst.entity:SetPristine()

  if not TheWorld.ismastersim then
    -- 初次收到实体时补一次当前网络状态，避免只依赖 dirty 边沿。
    inst:DoTaskInTime(0, ApplyCellOccupiedState)
    return inst
  end

  inst._isdeployed = false
  inst._islinked = false -- 连接态（连星）标志
  inst._proxTask = nil   -- 仅普通部署态运行；连星/物品等其它状态均关闭

  -- AddComponent("complexprojectile") 原本会自动注册这组组件动作；现在物品与飞行 prefab 分离，
  -- 因此只注册原版动作采集，让客户端仍能生成 TOSS，真正 Launch 由 wang_piecegrid.lua 处理。
  inst:RegisterComponentActions("complexprojectile")

  -- 服务端移除时清理玩法状态；网格释放由上方主客机共用的 onremove 监听统一处理。
  inst:ListenForEvent("onremove", OnRemove)

  inst:AddComponent("inspectable")

  inst:AddComponent("inventoryitem")

  -- 可堆叠（系统最大堆叠数）。部署/预部署态通过原版 CanStackWith 扩展点拒绝参与堆叠，
  -- 兼容会直接调用 stackable:Put 的第三方自动堆叠逻辑。
  inst:AddComponent("stackable")
  inst.components.stackable.maxsize = TUNING.STACK_SIZE_PELLET

  -- 装备手上（equipstack：从堆叠分出单个装备，投掷即消耗一个）
  inst:AddComponent("equippable")
  inst.components.equippable.equipslot = EQUIPSLOTS.HANDS
  inst.components.equippable.equipstack = true
  inst.components.equippable:SetOnEquip(OnEquip)
  inst.components.equippable:SetOnUnequip(OnUnequip)

  -- 真正的抛物线组件放在独立 piece_projectile 上；piece 只保留 pristine action tag 供客户端采集 TOSS。

  -- 部署态可被锤击回收；workable 只提供一次性 HAMMER 交互，不承担伤害结算。
  inst:AddComponent("workable")
  inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
  inst.components.workable:SetWorkLeft(1)
  inst.components.workable:SetOnFinishCallback(OnHammered)
  inst.components.workable:SetShouldRecoilFn(PieceShouldRecoil)
  inst.components.workable:SetWorkable(false)

  -- 连接态（连星）：复用原版 electricconnector，连接/断开/读档重连全内置
  -- max_links=4（每棋子最多连 4 个）；field_prefab 为连接光束（仅视觉，电击后续接入）
  -- 组件惰性：只有 EnterLinkState 后 ConnectTo 才真正建连，平时无副作用
  inst:AddComponent("electricconnector")
  inst.components.electricconnector.max_links = TUNING.WANG.PIECE_MAX_LINKS or 4
  inst.components.electricconnector.field_prefab = "piece_link_field"
  -- 组件构造会打 electric_connector 标签，导致原版麻刺节点(Fence)自动搜索时找到棋子，
  -- 而棋子无状态机(sg) → CanLinkTo 里 IsLinking() 崩溃。移除标签：棋子只按技能直连，不参与自动搜索
  inst:RemoveTag("electric_connector")
  -- 取消该组件的菜单动作注册：连接(连星)完全由技能 ConnectTo 管理，不向玩家暴露原版
  -- 手动操作（左键"打开连接"=STARTELECTRICLINK / 右键"断开连接"=ENDELECTRICLINK）
  inst:UnregisterComponentActions("electricconnector")

  -- 部署/连接状态存档；普通部署态读档后自动恢复陷阱，连星态随后关闭；electricconnector 自行重连
  inst.OnSave = OnSave
  inst.OnLoad = OnLoad

  -- 周期任务按实体休眠生命周期启停；原版大量 prefab 也用此模式避免休眠区继续跑 scheduler 任务。
  inst.OnEntitySleep = OnEntitySleep
  inst.OnEntityWake = OnEntityWake

  -- ────────────────────────────────────────────────────────
  -- 引爆方法（挂在棋子实例上，仅部署态有效）
  -- ────────────────────────────────────────────────────────

  -- 外部生成后直接设置属性；属性与部署/连接状态分别存档。
  inst._baseDamage = TUNING.WANG.PIECE_BASE_DAMAGE
  inst._eliteBonusDamage = 0
  inst._damageMultiplier = 1
  inst._explodeRangeMultiplier = 1
  inst._neighborMode = "cross"

  -- 主动引爆（1技能取势调用）：范围伤害 + 摧毁周围建造物 + 双特效
  -- multiplier: 引爆时的额外倍率，与部署倍率及邻子加成相乘。
  inst.ActiveExplode = function(_, source, multiplier, sfx_volume)
    if not inst._isdeployed then return end
    local damage = GetExplodeDamage(inst, multiplier)
    local range = EXPLODE_RANGE * inst._explodeRangeMultiplier
    AoEExplode(inst, source, damage, range, true)
    SpawnExplodeFx(inst, true, inst._explodeRangeMultiplier)
    Audio.PlaySfx(inst, "skill1_active_explode", sfx_volume or 0.6)
    inst:Remove()
  end

  -- 被动引爆（boss / 自然灾害等外部摧毁路径触发）：范围伤害，仅单特效，不摧毁建造物
  -- multiplier: 倍率，默认 1（被动引爆无技能加成）
  -- source: 摧毁者（可为 nil），仍按原样只用于 SuggestTarget 拉仇恨
  --
  -- 伤害来源记在布下这枚棋子的玩家（_attacker）身上，而不是棋子自己：
  -- 引擎 combat.lua 的击杀事件是 attacker:PushEvent("killed", ...)，
  -- 传 inst（棋子）会让事件落在棋子上，而棋子紧接着就被 Remove —— 这段击杀经验直接丢弃。
  -- 交给玩家后，接近陷阱自动引爆与投掷落地造成的击杀同样计入望的经验。
  -- 注意 _attacker 只由部署路径写入、不存档（存档只有 userid）：
  -- 读档后重新加载的棋子拿不到主人，此时退回棋子自身，即原来的行为。
  local function ResolveExplodeAttacker(inst)
    local attacker = inst._attacker
    if attacker ~= nil and attacker:IsValid() and not attacker:HasTag("playerghost") then
      return attacker
    end
    return inst
  end

  inst.PassiveExplode = function(_, source, multiplier)
    if not inst._isdeployed then return end
    local damage = GetExplodeDamage(inst, multiplier)
    local range = EXPLODE_RANGE * inst._explodeRangeMultiplier
    -- 第 6 参 suggest 保持原样传 source：不改变仇恨行为，只把击杀归属交给布子者
    AoEExplode(inst, ResolveExplodeAttacker(inst), damage, range, false, source)
    SpawnExplodeFx(inst, false, inst._explodeRangeMultiplier)
    Audio.PlaySfx(inst, "piece_passive_explode", 0.65)
    inst:Remove()
  end

  -- 连接态（连星）：关闭普通部署态的接近陷阱，只保留连接行为。
  -- 连接本身由 electricconnector 管理（ConnectTo 建连 / 读档 LoadPostPass 重连）
  -- 可重复调用（幂等）：已是连接态则直接返回
  inst.EnterLinkState = function(_)
    if not inst._isdeployed or inst._islinked then
      return
    end
    inst._islinked = true
    StopProximityTrap(inst)
  end

  -- 属性和 Transform 由外部先设好；预部署只声明当前格占用，完成动作后 DeployPiece 显形。
  inst.ReserveDeployCell = ReserveDeployCell
  inst.DeployPiece = SetDeployedState

  return inst
end

-- 独立飞行实体：参考原版 slingshotammo_*_proj / cannonball_rock 的物品与投射物分离模式。
local function projectile_fn()
  local inst = CreateEntity()

  inst.entity:AddTransform()
  inst.entity:AddAnimState()
  inst.entity:AddSoundEmitter()
  inst.entity:AddNetwork()

  MakeInventoryPhysics(inst)
  DisableEntityCollisions(inst)

  inst.AnimState:SetBank("piece")
  inst.AnimState:SetBuild("piece")
  inst.AnimState:PlayAnimation("XuanZuan", true)

  inst:AddTag("projectile")
  inst:AddTag("NOCLICK")

  inst.entity:SetPristine()

  if not TheWorld.ismastersim then
    return inst
  end

  inst.persists = false
  inst:ListenForEvent("onremove", OnProjectileRemove)

  inst:AddComponent("complexprojectile")
  inst.components.complexprojectile:SetHorizontalSpeed(THROW_SPEED)
  inst.components.complexprojectile:SetGravity(THROW_GRAVITY)
  inst.components.complexprojectile:SetLaunchOffset(Vector3(0.25, 1, 0))
  -- 地面落子不设置 targetoffset：原版 point TOSS 直接瞄准地面，轨迹会在目标点附近真正落地。
  inst.components.complexprojectile:SetOnLaunch(OnTossLaunch)
  inst.components.complexprojectile:SetOnHit(OnTossHit)

  -- 起飞前由 wang_piecegrid.lua 写入本次部署快照。
  inst._baseDamage = TUNING.WANG.PIECE_BASE_DAMAGE
  inst._eliteBonusDamage = 0
  inst._damageMultiplier = 1
  inst._explodeRangeMultiplier = 1
  inst._neighborMode = "cross"

  return inst
end

return Prefab("piece", fn, assets, prefabs),
    Prefab("piece_projectile", projectile_fn, assets, { "piece" })
