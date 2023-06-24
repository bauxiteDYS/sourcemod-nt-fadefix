# sourcemod-nt-fadefix

This plugin blocks any user messages used to remove the fade-to-black effect for competitive play where the fade should not be removed.
It also periodically re-draws the fade to ensure it's still being applied.

The plugin will also enable the fade-to-black on new round, so that players can't spectate their opponents' team composition and loadouts
before spawning in themselves.

## Compile requirements
* SourceMod 1.7 or newer.
* [Neotokyo include](https://github.com/softashell/sourcemod-nt-include) v1.0 or newer.

## Server requirements
* Recommended nt_competitive version: 0.5.0 or newer
  * Old versions of the nt_competitive use their own built-in (inferior) fade system, which may interfere with this plugin

## Usage
Set the cvar value `mp_forcecamera 1` to enable this plugin. The [nt_competitive plugin](https://github.com/Rainyan/sourcemod-nt-competitive) sets this cvar value automatically when going live.
