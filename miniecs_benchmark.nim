import miniecs # Assuming your file is named mini_ecs.nim
import std/[monotimes, times, random, sequtils]

# --- Components ---

type
  # OOP version for comparison
  BulletObj = ref object
    x, y, vx, vy: float

  # ECS version (Value types)
  Position = object
    x, y: float
  Velocity = object
    vx, vy: float

# --- OOP Benchmark Logic ---

proc setupOOP(n: int): seq[BulletObj] =
  result = newSeqOfCap[BulletObj](n)
  for i in 0..<n:
    result.add(BulletObj(x: 100.0, y: 100.0, vx: 10.0, vy: 5.0))
  # Randomizing memory access to simulate real-world fragmentation
  result.shuffle()

proc updateOOP(bullets: var seq[BulletObj]) =
  for b in bullets:
    b.x += b.vx
    b.y += b.vy

# --- ECS Benchmark Logic ---
proc setupECS(ecs: MiniECS, n: int) =
  ecs.clearAll()
  for i in 0..<n:
    var e = ecs.newEntity()
    e.addComponent(Position(x: 100.0, y: 100.0))
    e.addComponent(Velocity(vx: 10.0, vy: 5.0))

proc updateECS(ecs: MiniECS) =
  
  
  # Standard update using sparse-set logic
  # We iterate over the smallest pool (pPool in this case)
  for ent,p,v in ecs.allWith(Position,Velocity) :
    p.x += v.vx
    p.y += v.vy

proc updateECS_Pro(ecs: MiniECS) =
  # 1. Access pools
  let pPool = ecs.getComponentPool(Position)
  let vPool = ecs.getComponentPool(Velocity)
  
  if pPool.data.len == 0: return

  # 2. Pin pointers to the start of sequences (Prevents repeated field access in loop)
  # Using UncheckedArray for maximum raw pointer performance
  let pDataPtr = cast[ptr UncheckedArray[Position]](addr pPool.data[0])
  let vDataPtr = cast[ptr UncheckedArray[Velocity]](addr vPool.data[0])
  let i2ePtr = cast[ptr UncheckedArray[int]](addr pPool.indexToEntity[0])
  let vE2iPtr = cast[ptr UncheckedArray[int]](addr vPool.entityToIndex[0])
  let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
  
  let count = pPool.data.len
  let otherBit = vPool.bitCode

  # 3. Disable all runtime checks and force inlining
  {.push inline, checks: off.}
  for i in 0 ..< count:
    let entityID = i2ePtr[i]
    
    # Fast bitmask check via pinned entities pointer
    if (entitiesPtr[entityID].components and otherBit) != 0:
      let vIndex = vE2iPtr[entityID]
      
      # Direct memory access without bounds checking
      pDataPtr[i].x += vDataPtr[vIndex].vx
      pDataPtr[i].y += vDataPtr[vIndex].vy
  {.pop.}

proc update_Direct_Data_Oriented(ecs: MiniECS) =
  # Optimized update: Direct linear scan of contiguous data
  # Safe only if we know both pools are perfectly aligned (added in same order)
  let pPool = ecs.getComponentPool(Position)
  let vPool = ecs.getComponentPool(Velocity)
  
  for i in 0 ..< pPool.data.len:
    pPool.data[i].x += vPool.data[i].vx
    pPool.data[i].y += vPool.data[i].vy

# --- Runner ---

proc runTest(n: int) =
  echo "--- Benchmark Running (N = ", n, ") ---"
  randomize()
  let world = newMiniECS()

  # 1. OOP Test
  echo "Setting up OOP..."
  var bullets = setupOOP(n)
  let startOOP = getMonoTime()
  updateOOP(bullets)
  let endOOP = getMonoTime()
  echo "OOP Update: ", (endOOP - startOOP)

  # 2. Standard ECS Test
  echo "Setting up ECS..."
  setupECS(world, n)
  var startECS = getMonoTime()
  updateECS(world)
  var endECS = getMonoTime()
  echo "Standard ECS Update: ", (endECS - startECS)

  # 3. Direct Data ECS Test
  echo "Starting BoundCheck-off Optimised ECS..."
  startECS = getMonoTime()
  updateECS_Pro(world)
  endECS = getMonoTime()
  echo "BoundCheck-off Optimised ECS Update: ", (endECS - startECS)

  # 4. Direct Data ECS Test
  echo "Starting Direct Data Oriented ECS..."
  startECS = getMonoTime()
  update_Direct_Data_Oriented(world)
  endECS = getMonoTime()
  echo "Direct Data Oriented Update: ", (endECS - startECS)
  echo "--------------------------------------\n"


# Run with 1 Million entities
runTest(1_000_000)