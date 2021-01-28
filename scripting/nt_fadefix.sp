#pragma semicolon 1

#include <sourcemod>

#include <neotokyo>

#define PLUGIN_VERSION "0.1"

public Plugin myinfo = {
	name = "NT Competitive Fade Fix",
	description = "Block any unintended un-fade user messages. Hide new round vision to block \"ghosting\" for opposing team's loadouts.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-fadefix"
};

#define FFADE_IN          0x0001 // Just here so we don't pass 0 into the function
#define FFADE_OUT         0x0002 // Fade out (not in)
#define FFADE_MODULATE    0x0004 // Modulate (don't blend)
#define FFADE_STAYOUT     0x0008 // ignores the duration, stays faded out until new ScreenFade message received
#define FFADE_PURGE       0x0010 // Purges all other fades, replacing them with this one

#define FADE_FLAGS_ADD_FADE (FFADE_OUT | FFADE_STAYOUT)
#define FADE_FLAGS_CLEAR_FADE (FFADE_PURGE | FFADE_IN)

// Fade user message structure:
//   short - Fade duration, in ms.
//   short - Fade hold time, in ms.
//   short - Fade flags.
//   byte  - RGBA red.
//   byte  - RGBA green.
//   byte  - RGBA blue.
//   byte  - RGBA alpha.

#define DEATH_FADE_DURATION_MS 3840

#define NEO_MAX_PLAYERS 32

// Use "meta game" to get a list of user message indices for a specific game.
enum UserMsg {
	USERMSG_FADE = 11
};

static bool _unfade_once_allowed[NEO_MAX_PLAYERS + 1];
static bool _in_death_fade[NEO_MAX_PLAYERS + 1];

ConVar g_hCvar_FadeEnabled = null;

public void OnPluginStart()
{
	CreateConVar("sm_nt_fadefix_version", PLUGIN_VERSION, "NT Competitive Fade Fix plugin version.", FCVAR_DONTRECORD);

	g_hCvar_FadeEnabled = FindConVar("mp_forcecamera");
	if (g_hCvar_FadeEnabled == null) {
		SetFailState("Failed to find cvar for g_hCvar_FadeEnabled");
	}

	if (!HookEventEx("game_round_start", Event_RoundStart, EventHookMode_PostNoCopy)) {
		SetFailState("Failed to hook event game_round_start");
	}
	if (!HookEventEx("player_spawn", Event_PlayerSpawn, EventHookMode_Post)) {
		SetFailState("Failed to hook event player_spawn");
	}
	if (!HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post)) {
		SetFailState("Failed to hook event player_death");
	}
	if (!HookEventEx("player_team", Event_PlayerTeam, EventHookMode_Post)) {
		SetFailState("Failed to hook event player_team");
	}

	HookUserMessage(USERMSG_FADE, MsgHook_Fade, true);

	CreateTimer(1.0, Timer_ReFade);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (IsFadeEnforced()) {
		FadeAllDeadPlayers();
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0 || IsFakeClient(client) || GetClientTeam(client) <= TEAM_SPECTATOR) {
		return;
	}

	_unfade_once_allowed[client] = true;

	Handle userMsg = StartMessageOne("Fade", client);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, FADE_FLAGS_CLEAR_FADE);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	EndMessage();
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim_userid = event.GetInt("userid");
	int victim = GetClientOfUserId(victim_userid);
	if (victim == 0 || IsFakeClient(victim)) {
		return;
	}

	_in_death_fade[victim] = true;
	CreateTimer(DEATH_FADE_DURATION_MS * 0.001, Timer_DeathFadeFinished, victim_userid);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!IsFadeEnforced()) {
		return;
	}

	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (client == 0 || IsFakeClient(client)) {
		return;
	}

	int new_team = event.GetInt("team");
	if (new_team <= TEAM_SPECTATOR) {
		return;
	}

	// Need to wait for the team change to have gone through to ensure the fade will work here.
	CreateTimer(0.1, Timer_FadePlayer, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_FadePlayer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && !IsPlayerAlive(client) && GetClientTeam(client) > TEAM_SPECTATOR) {
		Handle userMsg = StartMessageOne("Fade", client);
		BfWriteShort(userMsg, 0);
		BfWriteShort(userMsg, 0);
		BfWriteShort(userMsg, FADE_FLAGS_ADD_FADE);
		BfWriteByte(userMsg, 0);
		BfWriteByte(userMsg, 0);
		BfWriteByte(userMsg, 0);
		BfWriteByte(userMsg, 255);
		EndMessage();
	}
	return Plugin_Stop;
}

void FadeAllDeadPlayers()
{
	int fade_clients[NEO_MAX_PLAYERS];
	int num_fade_clients;
	for (int client = 1; client <= MaxClients; ++client) {
		if (!IsClientInGame(client) || IsFakeClient(client) ||
			GetClientTeam(client) <= TEAM_SPECTATOR ||
			IsPlayerAlive(client) || _in_death_fade[client])
		{
			continue;
		}
		fade_clients[num_fade_clients++] = client;
	}

	if (num_fade_clients == 0) {
		return;
	}

	Handle userMsg = StartMessage("Fade", fade_clients, num_fade_clients);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, FADE_FLAGS_ADD_FADE);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 255);
	EndMessage();
}

public Action Timer_ReFade(Handle timer)
{
	if (IsFadeEnforced()) {
		FadeAllDeadPlayers();
	}
	return Plugin_Continue;
}

public Action Timer_DeathFadeFinished(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0) {
		_in_death_fade[client] = false;
	}
	return Plugin_Stop;
}

public Action MsgHook_Fade(UserMsg msg_id, BfRead msg, const int[] players,
	int playersNum, bool reliable, bool init)
{
	int duration = msg.ReadShort();
	int holdtime = msg.ReadShort();
	int fade_flags = msg.ReadShort();

	// This is not a type of fade that could lead to the screen un-fading.
	if ((fade_flags & (FADE_FLAGS_ADD_FADE)) && (!(fade_flags & FADE_FLAGS_CLEAR_FADE))) {
		return Plugin_Continue;
	}

	// Players who are allowed one unfiltered fade message (just spawned, etc.)
	int fade_exceptions[NEO_MAX_PLAYERS];
	int num_fade_exceptions;

	for (int i = 0; i < playersNum; ++i) {
		if (_unfade_once_allowed[players[i]]) {
			_unfade_once_allowed[players[i]] = false;
			fade_exceptions[num_fade_exceptions++] = players[i];
		}
	}

	if (!IsFadeEnforced()) {
		return Plugin_Continue;
	}

	// Need a new modifiable array to filter out recipients for this fade message.
	int[] allowed_players = new int[playersNum];
	int allowed_num_players = playersNum;

	// Filter out any players inside playable teams from this unfade message.
	for (int i = 0; i < playersNum; ++i) {
		if (!IsClientInGame(players[i]) || IsFakeClient(players[i]) ||
			GetClientTeam(players[i]) <= TEAM_SPECTATOR)
		{
			continue;
		}

		bool skip_from_filter;
		for (int j = 0; j < num_fade_exceptions; ++j) {
			if (players[i] == fade_exceptions[j]) {
				skip_from_filter = true;
				break;
			}
		}

		if (!skip_from_filter) {
			RemovePlayerFromArray(allowed_players, allowed_num_players, i);
		}
	}

	// Did we actually filter out any players?
	if (allowed_num_players != playersNum) {
		// Don't bother re-fading if there's 0 players remaining.
		if (allowed_num_players != 0) {
			int color_r = msg.ReadByte();
			int color_g = msg.ReadByte();
			int color_b = msg.ReadByte();
			int color_a = msg.ReadByte();

			// Mimicking the message of this callback, except for the new recipient list.
			Handle userMsg = StartMessage("Fade", allowed_players, allowed_num_players);
			BfWriteShort(userMsg, duration);
			BfWriteShort(userMsg, holdtime);
			BfWriteShort(userMsg, fade_flags);
			BfWriteByte(userMsg, color_r);
			BfWriteByte(userMsg, color_g);
			BfWriteByte(userMsg, color_b);
			BfWriteByte(userMsg, color_a);
			EndMessage();
		}
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

bool IsFadeEnforced()
{
	return g_hCvar_FadeEnabled.BoolValue;
}

void RemovePlayerFromArray(int[] array, int& num_elements, const int player)
{
    for (int i = 0; i < num_elements; ++i) {
        if (array[i] == player) {
            for (int j = i + 1; j < num_elements; ++j) {
                array[j - 1] = array[j]; // move each superseding element back
            }
            // clear the trailing copy of the final moved element
            array[--num_elements] = 0;
            return;
        }
    }
}
