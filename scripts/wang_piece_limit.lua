local PieceLimit = {
  piecesByOwner = {},
  nextOrder = 0,
}

local function IsOlder(a, b)
  if a._deployTime ~= b._deployTime then
    return a._deployTime < b._deployTime
  end
  return a._deployOrder < b._deployOrder
end

local function GetOwnerPieces(self, deployer)
  local userid = type(deployer) == "string" and deployer or deployer ~= nil and deployer.userid or nil
  return userid ~= nil and self.piecesByOwner[userid] or nil
end

local function RemovePiece(piece)
  if piece == nil or not piece:IsValid() then
    return false
  end
  if not piece:IsAsleep() then
    SpawnPrefab("cavehole_flick").Transform:SetPosition(piece.Transform:GetWorldPosition())
  end
  piece:Remove()
  return true
end

function PieceLimit:GetLimit(deployer)
  local elite = deployer.components.ark_elite
  if elite == nil then
    return TUNING.WANG.PIECE_DEFAULT_LIMIT
  end

  local baseHealth = TUNING.WANG_HEALTH
  local eliteHealth = baseHealth + elite:GetHealthBonus()
  return math.clamp(baseHealth - eliteHealth, 1, baseHealth - 1)
end

function PieceLimit:Register(piece)
  local deployer = piece._deployer
  -- 保留一份布子者引用：被动引爆（接近陷阱 / 投掷落地）要把击杀记回玩家身上，
  -- 而 AoEExplode 的伤害来源必须是实体，_deployerUserid 是字符串用不了。
  -- 只留到本次部署，不写进存档（存档只有 userid），读档后的棋子拿不到主人属预期。
  piece._attacker = deployer
  piece._deployer = nil
  piece._deployTime = piece._deployTime or GetTime()
  if piece._deployOrder == nil then
    self.nextOrder = self.nextOrder + 1
    piece._deployOrder = self.nextOrder
  else
    self.nextOrder = math.max(self.nextOrder, piece._deployOrder)
  end
  local userid = piece._deployerUserid
  if userid == nil then
    return
  end
  local pieces = self.piecesByOwner[userid]
  if pieces == nil then
    pieces = {}
    self.piecesByOwner[userid] = pieces
  end
  table.insert(pieces, piece)

  -- Loading only rebuilds the index; the next deployment checks the owner's current limit.
  if deployer ~= nil then
    local limit = self:GetLimit(deployer)
    if #pieces > limit then
      table.sort(pieces, IsOlder)
      while #pieces > limit do
        if not RemovePiece(pieces[1]) then
          table.remove(pieces, 1)
        end
      end
    end
  end
end

function PieceLimit:GetCount(deployer)
  local pieces = GetOwnerPieces(self, deployer)
  return pieces ~= nil and #pieces or 0
end

function PieceLimit:ConsumeOne(deployer)
  local pieces = GetOwnerPieces(self, deployer)
  if pieces == nil or #pieces == 0 then
    return false
  end

  table.sort(pieces, IsOlder)
  while #pieces > 0 and not pieces[1]:IsValid() do
    table.remove(pieces, 1)
  end
  return #pieces > 0 and RemovePiece(pieces[1]) or false
end

function PieceLimit:Unregister(piece)
  local userid = piece._deployerUserid
  local pieces = self.piecesByOwner[userid]
  if pieces == nil then
    return
  end

  for index, owned in ipairs(pieces) do
    if owned == piece then
      table.remove(pieces, index)
      break
    end
  end
  if #pieces == 0 then
    self.piecesByOwner[userid] = nil
  end
end

return PieceLimit
