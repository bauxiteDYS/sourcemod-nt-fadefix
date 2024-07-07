# sourcemod-nt-fadefix

This plugin blocks any user messages used to remove the fade-to-black effect for competitive play where the fade should not be removed.
It also periodically re-draws the fade to ensure it's still being applied.

The plugin will also enable the fade-to-black on new round, so that players can't spectate their opponents' team composition and loadouts
before spawning in themselves.

## Compile requirements
* SourceMod 1.7 or newer.
* [Neotokyo include](https://github.com/softashell/sourcemod-nt-include) v1.0 or newer.

## Server requirements
#### If using nt_competitive plugin
* Recommended nt_competitive plugin version: 0.5.0 or newer
  * Older versions of the nt_competitive plugin use their own built-in (inferior) fade system, which may interfere with this plugin

## Usage
Set the cvar value `mp_forcecamera 1` and `sm_competitive_fade_enabled 1` (default) to enable this plugin. The [nt_competitive plugin](https://github.com/Rainyan/sourcemod-nt-competitive) sets the cvar `mp_forcecamera 1` automatically when going live, so you don't need to do anything if using these plugins in tandem.  

Set the cvar value `mp_forcecamera 1` and `sm_competitive_fade_enabled 0` to enable players to spectate their teammates only in 3rd person, and not be able to use freecam etc. Useful for semi-competitive gameplay like PUGs so players aren't forced to stare at a black screen.
