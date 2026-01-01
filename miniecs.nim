#   MIT License - Copyright (c) 2026 Eray Zesen
#   Repository: https://github.com/erayzesen/miniecs
#   License information: https://github.com/erayzesen/miniecs/blob/master/LICENSE

#   Version: 1.0.0

import tables, std/[sequtils,macros], typetraits

type
    ## Entity represents a handle to a game object.
    ## It stores its own ID, a bitmask of attached components,
    ## and a reference to its parent ECS world.
    Entity* = object
        id: int
        components*: int = 0
        alive: bool = true
        owner: MiniECS

    ## Base class for component pools to allow heterogenous storage in a single sequence.
    ## Uses a function pointer (entityRemover) for type erasure during entity destruction.
    IComponentPool = ref object of RootObj
        bitCode*: int
        entityRemover: proc(p: IComponentPool, id: int) {.nimcall.}

    ## A generic Sparse Set implementation for high-performance component storage.
    ## 'data' is the dense array for cache-friendly iteration.
    ## 'entityToIndex' maps Entity ID -> index in 'data' (Sparse).
    ## 'indexToEntity' maps index in 'data' -> Entity ID (Dense).
    ComponentPool[T] = ref object of IComponentPool
        data*: seq[T]
        entityToIndex*: seq[int]
        indexToEntity*: seq[int]

    ## The main ECS World container.
    ## Manages entities, component pools, and component registration via bitmasks.
    MiniECS* = ref object
        entities*: seq[Entity] 
        freeEntities: seq[Entity] 
        componentPools: seq[IComponentPool] 
        nextComponentBitCode: int = 1
        poolTable: Table[string, int]

# --- Internal Helper Procedures ---

## Logic for removing an entity from a specific pool using the Swap-and-Pop technique.
## This ensures the 'data' array remains contiguous for performance.
proc removeEntityInternal[T](p: IComponentPool, id: int) {.nimcall.} =
    let pool = cast[ComponentPool[T]](p)
    let indexToRemove = pool.entityToIndex[id]
    if indexToRemove == -1: return

    let lastIndex = pool.data.len - 1
    if indexToRemove != lastIndex:
        let lastEntityID = pool.indexToEntity[lastIndex]
        # Move the last element into the slot of the removed element
        pool.data[indexToRemove] = pool.data[lastIndex]
        pool.indexToEntity[indexToRemove] = lastEntityID
        # Update the sparse mapping for the moved entity
        pool.entityToIndex[lastEntityID] = indexToRemove

    # Remove the last element from dense arrays
    discard pool.data.pop()
    discard pool.indexToEntity.pop()
    # Reset sparse mapping for the removed entity
    pool.entityToIndex[id] = -1

## Retrieves or creates a specialized ComponentPool for type T.
## Automatically assigns a unique bitCode for each component type.
proc getComponentPool*[T](ecs: MiniECS, component: typedesc[T]): ComponentPool[T] =
    let key = T.name
    
    if not ecs.poolTable.hasKey(key):
        # Register new component type
        let newPool = ComponentPool[T](
            data: @[],
            entityToIndex: newSeqWith(ecs.entities.len, -1),
            indexToEntity: @[],
            entityRemover: removeEntityInternal[T]
        )
        newPool.bitCode = ecs.nextComponentBitCode
        ecs.componentPools.add(newPool)
        
        # Advance bitmask (1, 2, 4, 8...)
        ecs.nextComponentBitCode = ecs.nextComponentBitCode shl 1
        ecs.poolTable[key] = ecs.componentPools.len - 1
        
    let index = ecs.poolTable[key]
    return cast[ComponentPool[T]](ecs.componentPools[index])

#region Public API

## Factory for creating a new MiniECS world instance.
proc newMiniECS*(): MiniECS =
    result = MiniECS()
    result.nextComponentBitCode = 1

## Creates or recycles an entity handle.
proc newEntity*(ecs: MiniECS): Entity =
  if ecs.freeEntities.len > 0:
    # Recycle from the pool of destroyed entities
    let oldEntity = ecs.freeEntities.pop()
    ecs.entities[oldEntity.id].alive = true
    ecs.entities[oldEntity.id].components = 0
    ecs.entities[oldEntity.id].owner = ecs
    return ecs.entities[oldEntity.id]
  else:
    # Create a brand new entity
    var id = ecs.entities.len
    ecs.entities.add(Entity(id: id, components: 0, alive: true, owner: ecs))
    return ecs.entities[id]

## Returns an Entity with ID
proc getEntity*(ecs:MiniECS, id:int): var Entity = 
  assert id >= 0 and id < ecs.entities.len, "Entity ID out of bounds"
  assert ecs.entities[id].alive, "Attempted to access a dead entity with ID: " & $id
  return ecs.entities[id]

## Returns Entity Count
proc getEntityCount*(ecs:MiniECS) : int =
  result=ecs.entities.len-ecs.freeEntities.len
  

## Checks if an entity has a specific component via its bitmask.
proc hasComponent(entity: var Entity, componentBitCode: int): bool =
    result = (entity.components and componentBitCode) != 0

## Generic wrapper for checking component existence.
#via id 
proc hasComponent*[T](entityID: int, component: typedesc[T],ecs:MiniECS): bool =
    result = (ecs.entities[entityID].components and ecs.getComponentPool(component).bitCode) != 0
proc hasComponent*[T](entity: var Entity, component: typedesc[T]): bool =
    result = (entity.components and entity.owner.getComponentPool(component).bitCode) != 0

## Adds a component to an entity. If it already exists, updates the value.
#via id
proc addComponent*[T](entityID: int, component: T, ecs:MiniECS) =
  var componentPool = ecs.getComponentPool(T)

  # Resize sparse array if world grew since pool creation
  if componentPool.entityToIndex.len <= entityID:
    let oldLen = componentPool.entityToIndex.len
    componentPool.entityToIndex.setLen(ecs.entities.len)
    for i in oldLen ..< componentPool.entityToIndex.len: componentPool.entityToIndex[i] = -1

  if hasComponent(ecs.entities[entityID], componentPool.bitCode):
    # Update existing data
    let index = componentPool.entityToIndex[entityID]
    componentPool.data[index] = component
  else:
    # Add new entry to dense data
    componentPool.data.add(component)
    componentPool.entityToIndex[entityID] = componentPool.data.len - 1
    componentPool.indexToEntity.add(entityID)
    
    # Update bitmasks on both the world-stored entity and the local handle
    let bitCode = ecs.entities[entityID].components or componentPool.bitCode
    ecs.entities[entityID].components = bitCode

proc addComponent*[T](entity: var Entity, component: T) =
  addComponent(entity.id,component,entity.owner)
  entity.components = entity.owner.entities[entity.id].components

## Removes a specific component from an entity and updates global bitmasks.
#via id
proc removeComponent*[T](entityID: int, _: typedesc[T],ecs:MiniECS) =
    var componentPool = ecs.getComponentPool(T)
    let componentBitcode = componentPool.bitCode

    if not hasComponent(entityID, T,ecs): return 

    let indexToRemove = componentPool.entityToIndex[entityID]
    let lastIndex = componentPool.data.len - 1

    # Perform Swap-and-Pop
    if indexToRemove != lastIndex:
        let lastEntityID = componentPool.indexToEntity[lastIndex]
        componentPool.data[indexToRemove] = componentPool.data[lastIndex]
        componentPool.indexToEntity[indexToRemove] = componentPool.indexToEntity[lastIndex]
        componentPool.entityToIndex[lastEntityID] = indexToRemove
    
    discard componentPool.data.pop()
    discard componentPool.indexToEntity.pop()
    componentPool.entityToIndex[entityID] = -1
    
    # Update bitmasks
    let bitcode = ecs.entities[entityID].components and (not componentBitcode)
    ecs.entities[entityID].components = bitcode
    

proc removeComponent*[T](entity: var Entity, _: typedesc[T]) =
    removeComponent(entity.id,T,entity.owner)
    entity.components = entity.owner.entities[entity.id].components

## Returns a mutable reference (var T) to the entity's component.
## CAUTION: In Nim 2.0, assigning this to a 'var' variable will copy the data
## unless using 'addr' or direct access.
proc getComponent*[T](entity: var Entity, _: typedesc[T]): var T =
  let pool = entity.owner.getComponentPool(T)
  let index = pool.entityToIndex[entity.id]
  return pool.data[index]
#via id
proc getComponent*[T](entityID: int, _: typedesc[T], ecs:MiniECS): var T =
  let pool = ecs.getComponentPool[T]()
  let index = pool.entityToIndex[entityID]
  return pool.data[index]

## Destroys an entity, removing all its components and making it available for recycling.
#via id
proc destroy*(entityID:int,ecs:MiniECS) =
    
    if not ecs.entities[entityID].alive: return

    # Clean up all component pools using type-erased remover functions
    if ecs.entities[entityID].components != 0: 
        for i in 0 ..< ecs.componentPools.len:
            let bitCode = ecs.componentPools[i].bitCode
            # Only call remover if the entity actually has this component
            if (ecs.entities[entityID].components and bitCode) != 0:
                ecs.componentPools[i].entityRemover(ecs.componentPools[i], entityID)

    # Mark as dead and store for recycling
    ecs.entities[entityID].alive = false
    ecs.entities[entityID].components = 0
    ecs.freeEntities.add(ecs.entities[entityID])
    
## Destroys an entity, removing all its components and making it available for recycling.
proc destroy*(entity: var Entity) =
    let id = entity.id
    if not entity.owner.entities[id].alive: return

    destroy(id,entity.owner)
    entity.alive = false
    entity.components = 0

## Wipes the entire ECS state.
proc clearAll*(ecs: MiniECS) =
  ecs.componentPools = @[]
  ecs.entities = @[]
  ecs.freeEntities = @[]
  ecs.nextComponentBitCode = 1

#endregion

#region Queries

# 1 Component Query
iterator allWith*[T1](ecs: MiniECS, t1: typedesc[T1]): tuple[entID: int, c1: ptr T1] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let count = pool1.data.len
  if count > 0:
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0])
    let i2e = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])
    
    {.push checks: off.}
    for i in 0 ..< count:
      yield (i2e[i], addr p1Data[i])
    {.pop.}

# 2 Components Query
iterator allWith*[T1, T2](ecs: MiniECS, t1: typedesc[T1], t2: typedesc[T2]): tuple[entID: int, c1: ptr T1, c2: ptr T2] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let pool2 = ecs.getComponentPool(t2)
  
  if pool1.data.len > 0 and pool2.data.len > 0:
    let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0])
    let p1E2I = cast[ptr UncheckedArray[int32]](addr pool1.entityToIndex[0])
    let p2Data = cast[ptr UncheckedArray[T2]](addr pool2.data[0])
    let p2E2I = cast[ptr UncheckedArray[int32]](addr pool2.entityToIndex[0])
    
    # Always iterate over the smaller pool for speed
    if pool1.data.len <= pool2.data.len:
      let count = pool1.data.len
      let otherBit = pool2.bitCode
      let sI2E = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])
      {.push checks: off.}
      for i in 0 ..< count:
        let entID = sI2E[i]
        if (entitiesPtr[entID].components and otherBit) != 0:
          yield (entID, addr p1Data[i], addr p2Data[p2E2I[entID]])
      {.pop.}
    else:
      let count = pool2.data.len
      let otherBit = pool1.bitCode
      let sI2E = cast[ptr UncheckedArray[int]](addr pool2.indexToEntity[0])
      {.push checks: off.}
      for i in 0 ..< count:
        let entID = sI2E[i]
        if (entitiesPtr[entID].components and otherBit) != 0:
          yield (entID, addr p1Data[p1E2I[entID]], addr p2Data[i])
      {.pop.}

# 3 Components Query
iterator allWith*[T1, T2, T3](ecs: MiniECS, t1: typedesc[T1], t2: typedesc[T2], t3: typedesc[T3]): tuple[entID: int, c1: ptr T1, c2: ptr T2, c3: ptr T3] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let pool2 = ecs.getComponentPool(t2)
  let pool3 = ecs.getComponentPool(t3)
  
  if pool1.data.len > 0 and pool2.data.len > 0 and pool3.data.len > 0:
    let combinedMask = pool1.bitCode or pool2.bitCode or pool3.bitCode
    let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
    
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0])
    let p1E2I = cast[ptr UncheckedArray[int32]](addr pool1.entityToIndex[0])
    let p2Data = cast[ptr UncheckedArray[T2]](addr pool2.data[0])
    let p2E2I = cast[ptr UncheckedArray[int32]](addr pool2.entityToIndex[0])
    let p3Data = cast[ptr UncheckedArray[T3]](addr pool3.data[0])
    let p3E2I = cast[ptr UncheckedArray[int32]](addr pool3.entityToIndex[0])
    let sI2E = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])

    {.push checks: off.}
    for i in 0 ..< pool1.data.len:
      let entID = sI2E[i]
      if (entitiesPtr[entID].components and combinedMask) == combinedMask:
        yield (entID, addr p1Data[i], addr p2Data[p2E2I[entID]], addr p3Data[p3E2I[entID]])
    {.pop.}

# 4 Components Query
iterator allWith*[T1, T2, T3, T4](ecs: MiniECS, t1: typedesc[T1], t2: typedesc[T2], t3: typedesc[T3], t4: typedesc[T4]): tuple[entID: int, c1: ptr T1, c2: ptr T2, c3: ptr T3, c4: ptr T4] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let pool2 = ecs.getComponentPool(t2)
  let pool3 = ecs.getComponentPool(t3)
  let pool4 = ecs.getComponentPool(t4)
  
  if pool1.data.len > 0 and pool2.data.len > 0 and pool3.data.len > 0 and pool4.data.len > 0:
    let combinedMask = pool1.bitCode or pool2.bitCode or pool3.bitCode or pool4.bitCode
    let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
    
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0])
    let p1E2I = cast[ptr UncheckedArray[int32]](addr pool1.entityToIndex[0])
    let p2Data = cast[ptr UncheckedArray[T2]](addr pool2.data[0])
    let p2E2I = cast[ptr UncheckedArray[int32]](addr pool2.entityToIndex[0])
    let p3Data = cast[ptr UncheckedArray[T3]](addr pool3.data[0])
    let p3E2I = cast[ptr UncheckedArray[int32]](addr pool3.entityToIndex[0])
    let p4Data = cast[ptr UncheckedArray[T4]](addr pool4.data[0])
    let p4E2I = cast[ptr UncheckedArray[int32]](addr pool4.entityToIndex[0])
    
    let sI2E = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])

    {.push checks: off.}
    for i in 0 ..< pool1.data.len:
      let entID = sI2E[i]
      if (entitiesPtr[entID].components and combinedMask) == combinedMask:
        yield (entID, addr p1Data[i], addr p2Data[p2E2I[entID]], addr p3Data[p3E2I[entID]], addr p4Data[p4E2I[entID]])
    {.pop.}

# 5 Components Query
iterator allWith*[T1, T2, T3, T4, T5](ecs: MiniECS, t1: typedesc[T1], t2: typedesc[T2], t3: typedesc[T3], t4: typedesc[T4], t5: typedesc[T5]): tuple[entID: int, c1: ptr T1, c2: ptr T2, c3: ptr T3, c4: ptr T4, c5: ptr T5] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let pool2 = ecs.getComponentPool(t2)
  let pool3 = ecs.getComponentPool(t3)
  let pool4 = ecs.getComponentPool(t4)
  let pool5 = ecs.getComponentPool(t5)
  
  if pool1.data.len > 0 and pool2.data.len > 0 and pool3.data.len > 0 and pool4.data.len > 0 and pool5.data.len > 0:
    let combinedMask = pool1.bitCode or pool2.bitCode or pool3.bitCode or pool4.bitCode or pool5.bitCode
    let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
    
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0]); let p1E2I = cast[ptr UncheckedArray[int32]](addr pool1.entityToIndex[0])
    let p2Data = cast[ptr UncheckedArray[T2]](addr pool2.data[0]); let p2E2I = cast[ptr UncheckedArray[int32]](addr pool2.entityToIndex[0])
    let p3Data = cast[ptr UncheckedArray[T3]](addr pool3.data[0]); let p3E2I = cast[ptr UncheckedArray[int32]](addr pool3.entityToIndex[0])
    let p4Data = cast[ptr UncheckedArray[T4]](addr pool4.data[0]); let p4E2I = cast[ptr UncheckedArray[int32]](addr pool4.entityToIndex[0])
    let p5Data = cast[ptr UncheckedArray[T5]](addr pool5.data[0]); let p5E2I = cast[ptr UncheckedArray[int32]](addr pool5.entityToIndex[0])
    
    let sI2E = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])

    {.push checks: off.}
    for i in 0 ..< pool1.data.len:
      let entID = sI2E[i]
      if (entitiesPtr[entID].components and combinedMask) == combinedMask:
        yield (entID, addr p1Data[i], addr p2Data[p2E2I[entID]], addr p3Data[p3E2I[entID]], addr p4Data[p4E2I[entID]], addr p5Data[p5E2I[entID]])
    {.pop.}

# 6 Components Query
iterator allWith*[T1, T2, T3, T4, T5, T6](ecs: MiniECS, t1: typedesc[T1], t2: typedesc[T2], t3: typedesc[T3], t4: typedesc[T4], t5: typedesc[T5], t6: typedesc[T6]): tuple[entID: int, c1: ptr T1, c2: ptr T2, c3: ptr T3, c4: ptr T4, c5: ptr T5, c6: ptr T6] {.inline.} =
  let pool1 = ecs.getComponentPool(t1)
  let pool2 = ecs.getComponentPool(t2)
  let pool3 = ecs.getComponentPool(t3)
  let pool4 = ecs.getComponentPool(t4)
  let pool5 = ecs.getComponentPool(t5)
  let pool6 = ecs.getComponentPool(t6)
  
  if pool1.data.len > 0 and pool2.data.len > 0 and pool3.data.len > 0 and pool4.data.len > 0 and pool5.data.len > 0 and pool6.data.len > 0:
    let combinedMask = pool1.bitCode or pool2.bitCode or pool3.bitCode or pool4.bitCode or pool5.bitCode or pool6.bitCode
    let entitiesPtr = cast[ptr UncheckedArray[Entity]](addr ecs.entities[0])
    
    let p1Data = cast[ptr UncheckedArray[T1]](addr pool1.data[0]); let p1E2I = cast[ptr UncheckedArray[int32]](addr pool1.entityToIndex[0])
    let p2Data = cast[ptr UncheckedArray[T2]](addr pool2.data[0]); let p2E2I = cast[ptr UncheckedArray[int32]](addr pool2.entityToIndex[0])
    let p3Data = cast[ptr UncheckedArray[T3]](addr pool3.data[0]); let p3E2I = cast[ptr UncheckedArray[int32]](addr pool3.entityToIndex[0])
    let p4Data = cast[ptr UncheckedArray[T4]](addr pool4.data[0]); let p4E2I = cast[ptr UncheckedArray[int32]](addr pool4.entityToIndex[0])
    let p5Data = cast[ptr UncheckedArray[T5]](addr pool5.data[0]); let p5E2I = cast[ptr UncheckedArray[int32]](addr pool5.entityToIndex[0])
    let p6Data = cast[ptr UncheckedArray[T6]](addr pool6.data[0]); let p6E2I = cast[ptr UncheckedArray[int32]](addr pool6.entityToIndex[0])
    
    let sI2E = cast[ptr UncheckedArray[int]](addr pool1.indexToEntity[0])

    {.push checks: off.}
    for i in 0 ..< pool1.data.len:
      let entID = sI2E[i]
      if (entitiesPtr[entID].components and combinedMask) == combinedMask:
        yield (entID, addr p1Data[i], addr p2Data[p2E2I[entID]], addr p3Data[p3E2I[entID]], addr p4Data[p4E2I[entID]], addr p5Data[p5E2I[entID]], addr p6Data[p6E2I[entID]])
    {.pop.}

#endregion


#region Tests 
# --- Unit Tests ---

when defined(test):
  import std/unittest
  
  suite "MiniECS Core Engine Tests":
    type 
        Position = object
            x, y: float
        Velocity = object
            x, y: float
            
    var world = newMiniECS()
    
    test "Entity Lifecycle: Creation and Component Addition":
      var ent = world.newEntity()
      ent.addComponent(Position(x: 10, y: 20))
      check(ent.components > 0)
      check(ent.hasComponent(Position))

    test "Component Management: Selective Removal":
      var ent = world.newEntity()
      ent.addComponent(Position(x: 10, y: 20))
      ent.addComponent(Velocity(x: 1, y: 2))
      ent.removeComponent(Position)
      check(not ent.hasComponent(Position) and ent.hasComponent(Velocity))

    test "World Management: Entity Destruction and Recycling":
      var ent = world.newEntity()
      ent.addComponent(Position(x: 10, y: 20))
      ent.destroy()
      # Verify that the next entity creation recycles the ID
      check(world.freeEntities.len == 1)

#endregion