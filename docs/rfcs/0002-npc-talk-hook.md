# RFC 0002: NPC talk hook

## Motivation

Tool and accessibility mods can observe `world.interacted`, but that event
fires after talk dispatch and cannot replace the dialogue.  A conversational
NPC mod needs one safe interception point without patching every map's text
pointer table or replacing progression scripts.

## Decision extended

This extends the additive hook/runtime-bus design described by the mod API v2
milestones and follows the parity obligations in `CONTRIBUTING-mods.md`.

## API delta

The overworld calls `world.npc.talk(next, game, ctx)` before NPC dispatch when
at least one wrapper exists.  `next(game, ctx)` returns `false`.  A wrapper
returns `true` only when it owns the interaction; otherwise it returns the
downstream result.

`ctx` contains `overworld`, `npc`, `npcId`, `mapId`, `mapLabel`, `textId`,
`kind`, `vanillaText`, and `finish`.  `kind` is one of `dialogue`, `script`,
`item`, `pokemon`, `trainer`, `mart`, `nurse`, `pc`, or `cable_club`.
Wrappers that return true must eventually call `ctx.finish()` to release the
NPC.  `vanillaText` is populated only for harmless dialogue.

The call site is guarded with `Runtime.wantsHook`, so an unmodded game builds
no context and executes the existing dispatch unchanged.

Separately, `Game:textinput` forwards LÖVE UTF-8 text events only to a top
state that implements `onTextInput`; this is a no-op for every existing state.

## Compatibility

Existing mods require no changes.  Hook and text-input forwarding are both
additive.  An empty hook bus returns the vanilla result exactly once, and the
guard skips all new classification work when no mod subscribes.
