# TransistorEnemy

A self-contained, drop-in AI enemy for **Godot 4** (built and tested with 4.7).
The enemy is a MOSFET transistor model that detects a player, chases it (using a
navigation mesh when the level has one), keeps its distance, fires energy bolts
on a cooldown, and can be damaged and killed.

Everything it needs is inside this folder: model, scene, scripts, projectile and
a runnable demo scene. There are no references to the project it came from.

```
TransistorEnemy/
├── transistor_enemy.tscn        # the enemy scene - instantiate this
├── transistor_enemy.gd          # AI, navigation, shooting, health/death
├── projectile/
│   ├── energy_projectile.tscn   # bolt fired by the enemy
│   └── energy_projectile.gd
├── models/
│   ├── transistors.glb          # the transistor mesh (materials embedded)
│   ├── ATTRIBUTION.txt          # required model credit (CC-BY-3.0)
│   └── LICENSE.txt
└── test/
    ├── enemy_test.tscn          # standalone demo: ground, navmesh, dummy player, camera
    ├── enemy_test_navmesh.tres  # baked navigation mesh for the demo
    ├── dummy_player.tscn/.gd    # test-only stand-in player
```

---

## Install

1. Copy the whole `TransistorEnemy/` folder into your project root, next to your
   `project.godot`. Keep the folder name `TransistorEnemy`, because the scenes
   reference files by path (`res://TransistorEnemy/...`).
2. Open the project once so Godot imports `models/transistors.glb`. No plugin,
   autoload or project setting is required.

## Quick start

Drag `TransistorEnemy/transistor_enemy.tscn` into your level, or instantiate it
from code:

```gdscript
var enemy := preload("res://TransistorEnemy/transistor_enemy.tscn").instantiate()
add_child(enemy)
enemy.global_position = spawn_point.global_position
```

Drop it on the floor: the enemy has gravity and settles onto whatever is below it.

### The enemy needs a player

It finds its target in one of two ways (no collision layers to wire up):

- **Group (default):** any node added to the group `player` is a valid target.
  Add this to your player script:

  ```gdscript
  func _ready() -> void:
      add_to_group("player")
  ```

- **Fixed path:** set `player_path` on the enemy (e.g. `NodePath("../Player")`).
  This overrides the group lookup — useful for a single hand-placed enemy.

The target must be a `Node3D`.

### The player must accept damage

Bolts call `take_damage(amount: float)` on the first thing they hit. A minimal
player receiver:

```gdscript
var health := 100.0

func take_damage(amount: float) -> void:
    health -= amount
    if health <= 0.0:
        queue_free()
```

Nothing happens if the method is missing — the bolt still disappears on impact.

---

## Enemy behaviour

| State | What happens |
| --- | --- |
| `IDLE` | Stands at its spawn point (enemies without a guard area). |
| `WANDER` | Off duty: strolls between random spots inside its guard circle. |
| `CHASE` | A player entered `detection_radius`; closes in to `stop_distance` without ever leaving its guard circle. |
| `ATTACK` | Holds position, fires every `attack_cooldown` seconds. |
| `RETURNING` | The player left `lose_target_radius`; walks back into its guard circle. |
| `DEAD` | Health reached 0; stops acting and despawns after `death_despawn_delay`. |

`detection_radius` (start chasing) and `lose_target_radius` (give up) are
deliberately different, so a player hovering at the edge does not make the
enemy flicker between states. Keep `lose_target_radius` the larger one.

### Exported settings

**Guard**

| Property | Default | Meaning |
| --- | --- | --- |
| `guard_radius` | 0.0 | Area it protects (m). `0` = no post, chase anywhere in detection range. |
| `guard_point_path` | empty | Node used as the guard post. Defaults to the spawn point. |
| `leash_radius` | 0.0 | How far its body may travel from the post while fighting (m). `0` = the guard circle itself. |

**Wander**

| Property | Default | Meaning |
| --- | --- | --- |
| `wander_speed` | 1.1 | Speed while strolling around its post between fights. |
| `wander_pause` | 1.6 | Seconds it stands still between wander legs. |

**Detection**

| Property | Default | Meaning |
| --- | --- | --- |
| `detection_radius` | 18.0 | Distance at which the player is noticed (m). |
| `lose_target_radius` | 26.0 | Distance at which the chase is abandoned (m). |
| `player_group` | `player` | Group searched for the player. |
| `player_path` | empty | Fixed target path; overrides the group. |
| `scan_interval` | 0.2 | Seconds between group scans. |

**Movement**

| Property | Default | Meaning |
| --- | --- | --- |
| `chase_speed` | 7.0 | Chase speed (m/s). |
| `return_speed` | 4.5 | Speed while walking home (m/s). |
| `acceleration` | 14.0 | How quickly it reaches full speed. |
| `stop_distance` | 6.0 | Preferred gap kept from the player (m). |
| `turn_speed` | 6.0 | Turn rate (radians/s). |
| `gravity_scale` | 1.0 | Multiplier on the project's default gravity. |
| `use_navigation` | true | Follow a navmesh path when one exists. |
| `navigation_agent_path` | `NavigationAgent3D` | Child used for path following. |

**Combat**

| Property | Default | Meaning |
| --- | --- | --- |
| `attack_range` | 12.0 | Maximum shooting distance (m). |
| `attack_cooldown` | 1.5 | Seconds between shots. |
| `projectile_scene` | energy bolt | Scene fired; must be a `Node3D` (assigned in the scene). |
| `projectile_speed` | 26.0 | Bolt speed (m/s). |
| `projectile_damage` | 15.0 | Damage per bolt. |
| `aim_height` | 0.9 | Aim point above the player's origin (m). |
| `aim_inaccuracy` | 1.5 | Random spread per shot, degrees. `0` = pinpoint. |
| `muzzle_path` | `Muzzle` | Child node bolts spawn from and aim along. |

**Health**

| Property | Default | Meaning |
| --- | --- | --- |
| `max_health` | 100.0 | Starting health. |
| `death_despawn_delay` | 2.0 | Seconds the corpse stays; negative keeps it forever. |

### Guarding an area

Give the enemy a territory instead of letting it roam: add a `Node3D` where it
should stand watch, set `guard_radius`, and point `guard_point_path` at it.

```gdscript
enemy.guard_radius = 5.0
enemy.guard_point_path = ^"../VaultMarker"
```

With `guard_radius > 0` the enemy:

- attacks any player who comes within `detection_radius` of it, wherever they
  are relative to the circle;
- never leaves its circle: at the rim (`leash_radius`, the circle itself by
  default) it holds position and keeps shooting from there;
- returns to the circle and wanders around inside it whenever the player
  leaves `lose_target_radius`.

The demo `test/enemy_test.tscn` does not guard, but the main-map example below
does. `get_guard_position()` and `is_inside_guard_area(point)` are public for
level logic such as spawning waves or showing a warning.

### Signals

```gdscript
player_detected(player: Node3D)
player_lost
projectile_fired(projectile: Node3D, direction: Vector3)
state_changed(previous: State, current: State)
health_changed(current: float, maximum: float)
damaged(amount: float)
died
```

Example — a health bar and a death effect:

```gdscript
enemy.health_changed.connect(func(current, maximum): bar.value = current / maximum * 100.0)
enemy.died.connect(func(): spawn_pickup(enemy.global_position))
```

### Health and death

Anything can hurt the enemy by calling `take_damage(amount)`; `heal(amount)` and
`is_alive()` are also available. On death the enemy sets `state` to
`TransistorEnemy.State.DEAD`, disables its collision, emits `died`, and frees
itself after `death_despawn_delay`.

```gdscript
enemy.take_damage(25.0)
```

---

## Navigation

If the scene has a `NavigationRegion3D` with a baked navigation mesh, the enemy
routes around obstacles automatically through its child `NavigationAgent3D`.
That is the recommended setup:

1. Our demo does this already — see `test/enemy_test.tscn`.
2. In your level, build a `NavigationRegion3D`, bake its mesh in the editor,
   and place the enemy inside that region.
3. Keep `use_navigation` on. Keep the `NavigationAgent3D` child; move it to
   change the agent's pathing radius, height or avoidance.

If there is **no** navigation mesh, the enemy detects that and walks straight at
its target instead — so it still works in quick test scenes without a navmesh.

Note that the enemy does not use `NavigationAgent3D` avoidance by default; two
enemies can overlap while chasing the same player. Enable
`NavigationAgent3D.avoidance_enabled` on the child if you need separation.

## Customising the projectile

`projectile/energy_projectile.tscn` is a small emissive sphere. It has no
collision body: each physics frame it ray-sweeps from its previous position to
the next, so it cannot tunnel through walls, then calls `take_damage()` on what
it hit. You can swap in your own scene as long as the root is a `Node3D` and it
either:

- exposes `launch(direction, shooter, speed, damage)` (preferred), or
- already moves itself (the enemy only rotates it towards the target).

The bolt hits physics layer 1 by default (`collision_mask` on the projectile).
If your level geometry uses a different layer, change the mask there or on
`energy_projectile.tscn`.

The enemy lives on physics layer 2 and collides with layer 1. Bolts therefore
do not damage other enemies by default; extend the bolt's mask if you want
friendly fire.

---

## Test scene

Open `test/enemy_test.tscn` and press **F6** (Play Scene). Or from a terminal:

```bash
godot --path /path/to/project res://TransistorEnemy/test/enemy_test.tscn
```

The scene contains a 30 × 30 m ground, three obstacles, a baked navigation mesh,
a wandering dummy player (green capsule, implements `take_damage`, resets its
health instead of dying), the enemy at (-6, 0, -6), and a fixed camera. The
enemy should walk around the boxes, stop at 4 m, and shoot; hits are printed to
the console. Nothing in the test scene references the surrounding project.

You can also drop the enemy scene into the test scene yourself to re-bake the
navmesh if you change the geometry: select `NavigationRegion3D` →
**Bake NavigationMesh**. The region owns the ground and obstacles as children,
which is how the bake finds its geometry.

---

## Notes and limitations

- No animation or attack wind-up: the model is static and bolts appear instantly.
- Guarding is a radial area, not a shape: it cannot protect a corridor corner.
- The enemy chases the nearest node in the player group only; it does not
  remember where the player was last seen.
- No line-of-sight check — it will chase and shoot through thin walls as long
  as the distance is within range. Add a physics ray check on the muzzle if you
  need cover to matter.
- Enemy-to-enemy separation needs `NavigationAgent3D` avoidance enabled (see
  above).
- Health, traversal and death are code-only; there are no death effects or
  loot.

## Credits

Model: **mosfet-P55NF06L** by [hasecilu](https://github.com/hasecilu), from the
FreeCAD Parts Library, licensed [CC-BY-3.0](https://creativecommons.org/licenses/by/3.0/).
See `models/ATTRIBUTION.txt` and `models/LICENSE.txt`. Keep these files (and
this credit) when redistributing the module.
