<div align="center">

![logo](media/logo.png) 

</div>
  

MiniECS is a minimalist ECS (Entity Component System) module for the Nim programming language. It is designed to strike a perfect balance between performance and ease of use, making it ideal for your daily projects.

## **Features**

* **Pure Nim:** No complex macros or DSLs to learn. Your basic Nim knowledge is more than enough to use or even extend the module. (However, you're free to implement your own meta-programming patterns on top of it).  
* **Balanced Abstraction:** It organizes entities and components while providing efficient query iterators. It aims for a "just enough" abstraction to keep you flexible.
* **Single File:** It consists of a single .nim file; just drop it into your project and you're ready to go.  

## **How to Use?**

Simply copy the `miniecs.nim` file into your project. Each version includes a version number at the top of the file. If the version in the repository is newer, you can simply replace your file.

Below is an elegant example of how to use MiniECS:

``` Nim
import miniecs
import std/[random, math]

# --- Components ---
type
  Position = object
    x, y: float32
  Velocity = object
    vx, vy: float32
  Health = object
    current, max: int
  Damage = object
    value: int
    
  PlayerTag = object
  MonsterTag = object

# Initialize World
let ecs = newMiniECS()

# --- Create Player ---
var player = ecs.newEntity()
player.addComponent(Position(x: 100, y: 150))
player.addComponent(Velocity(vx: 0, vy: 0))
player.addComponent(Health(current: 100, max: 100))
player.addComponent(PlayerTag())

# --- Create Monsters ---
let monsterCount = 1000
for i in 0..<monsterCount:
  var monster = ecs.newEntity()
  monster.addComponent(Position(x: rand(800.0).float32, y: rand(600.0).float32))
  monster.addComponent(Velocity(vx: rand(-5.0..5.0).float32, vy: rand(-5.0..5.0).float32))
  monster.addComponent(Health(current: 100, max: 100))
  monster.addComponent(Damage(value: 10))
  monster.addComponent(MonsterTag())

proc update() =
  # 1. Update Player (Direct access using addr to avoid copying)
  # getComponent returns a reference, addr ensures we work on the source memory
  var pPos = addr player.getComponent(Position)
  var pVel = addr player.getComponent(Velocity)
  
  pPos.x += pVel.vx
  pPos.y += pVel.vy


  # 2. AI System: Monsters chase the player
  # allWith provides pointers (ptr) so changes are applied directly to memory
  for id, pos, vel, _ in ecs.allWith(Position, Velocity, MonsterTag):
    let diffX = pPos.x - pos.x
    let diffY = pPos.y - pos.y
    let dist = sqrt(diffX*diffX + diffY*diffY)
    
    if dist > 1.0: # Avoid division by zero
      let normalX = diffX / dist
      let normalY = diffY / dist
      
      # Update monster velocity to move towards player
      vel.vx = normalX * 2.0
      vel.vy = normalY * 2.0
      
      # Apply movement (In-place update)
      pos.x += vel.vx
      pos.y += vel.vy

# Game loop simulation
for frame in 0..<100:
  update()

```

## **Motivation**

ECS libraries are inherently complex. General-purpose ECS frameworks often grow more convoluted as features and abstractions are added. MiniECS aims to be different: it's not even a "library" in the traditional sense, but a module you drop into your project. It’s easy to read, easy to understand, and stays away from confusing DSLs.

## **Performance**

Performance is highly subjective and depends on specific use cases. As the developer, here are the criteria that satisfied my expectations for this project:

* **A Viable Alternative to OOP:** Many ECS libraries suffer from dramatic performance hits when dealing with small numbers of entities compared to OOP. MiniECS maintains acceptable performance (or matches OOP) even in scenarios with as few as 100 entities and 2 components, while scaling beautifully as entity counts grow.  
* **Core ECS Benefits:** This module delivers the dramatic performance advantages promised by Data-Oriented Design (DOD). It uses a **Sparse-Set** approach (similar to *EnTT*), making component addition/removal extremely fast. While this approach might introduce minor data access gaps compared to *Archetype* systems, the simplicity-to-performance ratio is highly optimized.

*Note: If your project requires extreme, microsecond-critical performance, I recommend designing a custom Data-Oriented structure tailored specifically to that project's needs. For most use cases, however, MiniECS will be more than sufficient.*

## API
The entire API is basically the cheatsheet below. 

<details>
<summary> Cheatsheet </summary>

```Nim
import miniecs

# --- 1. SETUP ---
# Initialize the ECS World instance
let ecs = newMiniECS()

# Define your data-only components (PODs preferred)
type
  Position = object
    x, y: float32
  Velocity = object
    vx, vy: float32
  PlayerTag = object # Empty tag component

# --- 2. ENTITY MANAGEMENT ---

# Create a new entity (Returns an Entity handle)
var ent = ecs.newEntity()

# Get an existing entity by ID (Safety: asserts alive and in-bounds)
var sameEnt = ecs.getEntity(ent.id)

# Get the count of currently active (alive) entities
let activeCount = ecs.getEntityCount()

# Destroy entity (Cleans up all components and enables recycling)
ent.destroy()                 # Handle-based
# destroy(ent.id,ecs)        # ID-based (Fastest for batches)

# --- 3. COMPONENT MANAGEMENT ---

# Add/Update Component
ent.addComponent(Position(x: 10, y: 10))        # Handle-based
# addComponent(ent.id, Velocity(vx: 1, vy: 1), ecs) # ID-based

# Remove Component
ent.removeComponent(Position)                   # Handle-based
# removeComponent(ent.id, Position, ecs)    # ID-based

# Check Component Existence
if ent.hasComponent(Position): discard          # Handle-based
# if hasComponent(ent.id, Position, ecs): discard # ID-based

# --- 4. COMPONENT ACCESS & MANIPULATION ---

# Direct Field Manipulation (One-liner)
# Since getComponent returns 'var T', you can modify fields directly
ent.getComponent(Position).x += 5.0             # Handle-based
# getComponent(ent.id, Position, ecs).y = 0.0 # ID-based

# Using 'addr' for manual optimization (Avoids hidden copies in some Nim versions)
var pos = addr ent.getComponent(Position)
pos.y = 20.0

# --- 5. HIGH-PERFORMANCE QUERIES (ITERATORS) ---

# MiniECS supports querying up to 6 components simultaneously.
# Iterators return (EntityID, ptr T1, ptr T2, ...)
# Pointers (ptr) allow direct memory manipulation without copying.

# Single Component Query
for id, pos in ecs.allWith(Position):
  pos.x += 1.0

# Multiple Component Query (Fastest: Iterates over the smallest pool)
for id, pos, vel in ecs.allWith(Position, Velocity):
  pos.x += vel.vx
  pos.y += vel.vy

# --- 6. UTILITIES ---

# Wipe everything (Entities, Pools, Bitmasks)
ecs.clearAll()
```
</details>


## **Contributing**

* Bug reports are welcome.  
* Feel free to share your ideas and feedback.  
* Pull Requests are appreciated, but acceptance is not guaranteed. Please open an issue first so we can discuss the proposal.

## **Other Projects by Me**

* [kirpi](https://github.com/erayzesen/kirpi): A minimalist framework for 2D games and creative coding. Shares the same KISS philosophy.  
* [textalot](https://github.com/erayzesen/textalot): A high-performance Terminal I/O module written in pure Nim for building Unix terminal applications.

