#pragma semicolon 1

#include <sourcemod>

#include <neotokyo>

#define PLUGIN_VERSION "0.4.2"

public Plugin myinfo = {
	name = "NT Competitive Fade Fix",
	description = "Block any unintended un-fade user messages. Hide new round \
vision to block \"ghosting\" for opposing team's loadouts.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-fadefix"
};

#define FFADE_IN		0x0001 // Just here so we don't pass 0 into the function
#define FFADE_OUT		0x0002 // Fade out (not in)
#define FFADE_MODULATE	0x0004 // Modulate (don't blend)
#define FFADE_STAYOUT	0x0008 // ignores the duration, stays faded out until new ScreenFade message received
#define FFADE_PURGE		0x0010 // Purges all other fades, replacing them with this one

#define FADE_FLAGS_ADD_FADE (FFADE_OUT | FFADE_STAYOUT)
#define FADE_FLAGS_CLEAR_FADE (FFADE_PURGE | FFADE_IN)

#define DEATH_FADE_DURATION_SEC 7.5
#define DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC 10.0

// Magic value for detecting when we haven't read the data from the related BitBuffer yet
#define BF_UNINITIALIZED 0xDEADBEEF

#define MAX_FILTERED_VGUI_PANEL_SIZE 7+1 // strlen("loadout") + 1

// UserMsg enumerations.
// Anonymous because otherwise SM complains when using these to access array
// indices, or when comparing named enums against integers.
enum {
	UM_FADE = 0,
	UM_VGUIMENU,

	UM_ENUM_COUNT
};

UserMsg _usermsgs[UM_ENUM_COUNT] = { INVALID_MESSAGE_ID, ... };
char _usermsg_name[UM_ENUM_COUNT][8 + 1] = {
	"Fade",
	"VGUIMenu",
};

static bool _unfade_allowed[NEO_MAXPLAYERS + 1];
static bool _in_death_fade[NEO_MAXPLAYERS + 1];
static bool _override_usermsg_hook[NEO_MAXPLAYERS + 1];

ConVar g_hCvar_FadeEnabled = null;

Handle g_hTimer_ReFade = INVALID_HANDLE;

public void OnPluginStart()
{
	for (int i = 0; i < UM_ENUM_COUNT; ++i)
	{
		_usermsgs[i] = GetUserMessageId(_usermsg_name[i]);
		if (_usermsgs[i] == INVALID_MESSAGE_ID)
		{
			SetFailState("Could not find usermsg \"%s\"", _usermsg_name[i]);
		}
	}
	HookUserMessage(_usermsgs[UM_FADE], OnUserMsg_Fade, true);
	HookUserMessage(_usermsgs[UM_VGUIMENU], OnUserMsg_VguiMenu, true);

	CreateConVar("sm_nt_fadefix_version", PLUGIN_VERSION,
		"NT Competitive Fade Fix plugin version.", FCVAR_DONTRECORD);

	g_hCvar_FadeEnabled = FindConVar("mp_forcecamera");
	if (g_hCvar_FadeEnabled == null) {
		SetFailState("Failed to find cvar for g_hCvar_FadeEnabled");
	}

	if (!HookEventEx("game_round_start", Event_RoundStart, EventHookMode_Pre)) {
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

	g_hTimer_ReFade = CreateTimer(1.0, Timer_ReFade, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
	_unfade_allowed[client] = false;
	_in_death_fade[client] = false;
	_override_usermsg_hook[client] = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hTimer_ReFade != INVALID_HANDLE)
	{
		KillTimer(g_hTimer_ReFade);
		g_hTimer_ReFade = CreateTimer(1.0, Timer_ReFade, _, TIMER_REPEAT);
	}

	if (g_hCvar_FadeEnabled.BoolValue) {
		FadeAllDeadPlayers(false);
	}
}

public void OnMapEnd()
{
	if (g_hTimer_ReFade != INVALID_HANDLE)
	{
		KillTimer(g_hTimer_ReFade);
		g_hTimer_ReFade = INVALID_HANDLE;
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0 || IsFakeClient(client) ||
		GetClientTeam(client) <= TEAM_SPECTATOR)
	{
		return;
	}

	_unfade_allowed[client] = true;

	int clients[1];
	clients[0] = client;
	SendFadeMessage(clients, 1, FADE_FLAGS_CLEAR_FADE);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim_userid = event.GetInt("userid");
	int victim = GetClientOfUserId(victim_userid);
	if (victim == 0 || IsFakeClient(victim)) {
		return;
	}

	_in_death_fade[victim] = true;
	// Allow the player to see their surroundings during the death fade time.
	// Also give it some overhead because this timer isn't super accurate.
	CreateTimer(DEATH_FADE_DURATION_SEC + 0.2, Timer_DeathFadeFinished, victim_userid);

	// At this time, there's a visible hitch where some kind of player state change occurs,
	// and you can actually glimpse past the fade screen during it, so we specifically
	// apply the fade at that exact moment to prevent it from occurring.
	// Apply thrice within the expected timer inaccuracy range for higher likelihood of
	// catching the correct timing & minimize unintended vision.
	CreateTimer(DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC - 0.2, Timer_FadePlayer, victim_userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC, Timer_FadePlayer, victim_userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC + 0.2, Timer_FadePlayer, victim_userid, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hCvar_FadeEnabled.BoolValue) {
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

	_unfade_allowed[client] = false;
	_in_death_fade[client] = false;

	// Need to wait for the team change to have gone through to ensure the
	// fade will work here.
	CreateTimer(0.1, Timer_FadePlayer, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_FadePlayer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	// Checking for team again in case the player got rapidly moved to
	// spectator right after joining a playing team.
	if (client != 0 && !IsPlayerAlive(client) &&
		GetClientTeam(client) > TEAM_SPECTATOR)
	{
		int clients[1];
		clients[0] = client;
		SendFadeMessage(clients, 1, FADE_FLAGS_ADD_FADE);
	}
	return Plugin_Stop;
}

void FadeAllDeadPlayers(bool ignore_clients_in_death_fade)
{
	int fade_clients[NEO_MAXPLAYERS];
	int num_fade_clients;
	for (int client = 1; client <= MaxClients; ++client) {
		if (!IsClientInGame(client) || IsFakeClient(client) ||
			GetClientTeam(client) <= TEAM_SPECTATOR ||
			IsPlayerAlive(client))
		{
			continue;
		}
		if (ignore_clients_in_death_fade && _in_death_fade[client]) {
			continue;
		}
		fade_clients[num_fade_clients++] = client;
	}

	if (num_fade_clients == 0) {
		return;
	}

	SendFadeMessage(fade_clients, num_fade_clients, FADE_FLAGS_ADD_FADE);
}

public Action Timer_ReFade(Handle timer)
{
	if (g_hCvar_FadeEnabled.BoolValue) {
		FadeAllDeadPlayers(true);
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

// Poll for this client's one-time permission to skip the UserMsgHook
// restrictions. This is necessary because we can re-fire a modified
// UserMsg from within the UserMsg hook, and otherwise would then
// re-capture & process that same message again because it'd get
// caught in the hook after being fired.
//
// Assumes a valid client index as input.
// Modifies the global _override_usermsg_hook state of that client index.
// Returns a boolean of whether this client is allowed to skip the hook checks.
bool OneTimeUserMsgOverride(int client)
{
	bool allowed = _override_usermsg_hook[client];
	_override_usermsg_hook[client] = false;
	return allowed;
}

// UserMsg hook for the "Fade" message.
// NOTE!! You *cannot* use any code that fires a UserMessage inside
// this hook, such as the PrintToChat... functions.
public Action OnUserMsg_Fade(UserMsg msg_id, BfRead msg, const int[] players,
	int playersNum, bool reliable, bool init)
{
	if (!g_hCvar_FadeEnabled.BoolValue || playersNum <= 0)
	{
		return Plugin_Continue;
	}

	int duration = msg.ReadShort();
	int holdtime = msg.ReadShort();
	int fade_flags = msg.ReadShort();

	int[] allowed_players = new int[playersNum];
	int num_allowed_players = 0;
	for (int i = 0; i < playersNum; ++i)
	{
		if (OneTimeUserMsgOverride(players[i]))
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}

		if (IsPlayerAlive(players[i]))
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}

		if (fade_flags & FADE_FLAGS_ADD_FADE)
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}
		else if (fade_flags & FADE_FLAGS_CLEAR_FADE)
		{
			if (_unfade_allowed[players[i]])
			{
				_unfade_allowed[players[i]] = false;
				allowed_players[num_allowed_players++] = players[i];
				continue;
			}
		}
	}

	if (num_allowed_players == 0)
	{
		return Plugin_Handled;
	}

	if (num_allowed_players == playersNum)
	{
		return Plugin_Continue;
	}

	// Have to recreate the UserMessage because we can't modify the hook's
	// const clients array here.
	DataPack dp;
	// Using a data timer to delegate this because we can't fire the UserMsg
	// from inside this UserMsg hook.
	CreateDataTimer(0.0, Timer_SendModifiedUserMsg, dp,
		TIMER_FLAG_NO_MAPCHANGE);

	dp.WriteCell(num_allowed_players);
	for (int i = 0; i < num_allowed_players; ++i)
	{
		dp.WriteCell(GetClientUserId(allowed_players[i]));
	}

	dp.WriteCell(msg_id);

	dp.WriteCell(duration);
	dp.WriteCell(holdtime);
	dp.WriteCell(fade_flags);
	dp.WriteCell(msg.ReadByte()); // r,g,b,a as 4 bytes
	dp.WriteCell(msg.ReadByte());
	dp.WriteCell(msg.ReadByte());
	dp.WriteCell(msg.ReadByte());

	return Plugin_Handled;
}

// UserMsg hook for the "VGUIMenu" message.
// NOTE!! You *cannot* use any code that fires a UserMessage inside
// this hook, such as the PrintToChat... functions.
public Action OnUserMsg_VguiMenu(UserMsg msg_id, BfRead msg, const int[] players,
	int playersNum, bool reliable, bool init)
{
	if (!g_hCvar_FadeEnabled.BoolValue || playersNum <= 0)
	{
		return Plugin_Continue;
	}

	char panel_name[MAX_FILTERED_VGUI_PANEL_SIZE];
	msg.ReadString(panel_name, sizeof(panel_name));

	int show = msg.ReadByte();
	// Actually a boolean, so any nonzero evaluates as true.
	// We don't cast to bool because it needs to be passed on as-is
	// to guarantee we don't modify the UserMsg when doing passthrough.
	// If this is not a "show" message, it means we want to hide a panel,
	// and this should always be allowed, because the hide messages may
	// be received out-of-order by the client, which could otherwise end
	// up with them having spectator panel etc. incorrectly not cleared
	// during the (re)spawn sequence.
	if (show == 0)
	{
		return Plugin_Continue;
	}

	int[] allowed_players = new int[playersNum];
	int num_allowed_players = 0;
	for (int i = 0; i < playersNum; ++i)
	{
		if (OneTimeUserMsgOverride(players[i]))
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}

		if (_unfade_allowed[players[i]])
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}

		/* The player VGUIMenu flow actually fires a ton of usermessages,
		   many of them redundant. Since it seems there's a rare bug with
		   the UserMsg timing going out-of-order, we're specifically blocking
		   any unrelated messages for clients in the spawn flow.

			Event & usermsg flow for (
				Event_RoundStart, Event_PlayerSpawn,
				UserMsg_VGUIMenu, UserMsg_ResetHUD
			):

			Event_RoundStart // <-- new round starts
				VGUIMenu -> specgui: hide
				VGUIMenu -> scores: show
				VGUIMenu -> specgui: show
				VGUIMenu -> specmenu: show
				VGUIMenu -> class: show	   // <-- Class selection
				-------------------------
				VGUIMenu -> loadout: hide
				VGUIMenu -> specgui: hide
				VGUIMenu -> specmenu: show
				VGUIMenu -> specgui: show
				VGUIMenu -> overview: show
				VGUIMenu -> scores: show
				VGUIMenu -> specgui: show
				VGUIMenu -> specmenu: show
				VGUIMenu -> loadout: show	// <-- Loadout selection
				-------------------------
				VGUIMenu -> loadout_dev: show
				VGUIMenu -> class: show
				-------------------------
			Event_PlayerSpawn // <-- player spawns in the world
				ResetHUD					// <-- Closes all HUD menus
		*/

		// Block showing any panel other than "class" and "loadout".
		if (StrEqual(panel_name, "class") || StrEqual(panel_name, "loadout"))
		{
			allowed_players[num_allowed_players++] = players[i];
			continue;
		}
	}

	if (num_allowed_players == 0)
	{
		return Plugin_Handled;
	}

	if (num_allowed_players == playersNum)
	{
		return Plugin_Continue;
	}

	// Have to recreate the UserMessage because we can't modify the hook's
	// const clients array here.
	DataPack dp;
	// Using a data timer to delegate this because we can't fire the UserMsg
	// from inside this UserMsg hook.
	CreateDataTimer(0.0, Timer_SendModifiedUserMsg, dp,
		TIMER_FLAG_NO_MAPCHANGE);

	dp.WriteCell(num_allowed_players);
	for (int i = 0; i < num_allowed_players; ++i)
	{
		dp.WriteCell(GetClientUserId(allowed_players[i]));
	}

	dp.WriteCell(msg_id);

	dp.WriteString(panel_name);
	dp.WriteCell(show);
	int subcount = msg.ReadByte();
	dp.WriteCell(subcount);
	if (subcount > 0)
	{
		do {
			msg.ReadString(panel_name, sizeof(panel_name));
			dp.WriteString(panel_name);
			dp.WriteCell(msg.ReadByte());
			subcount = msg.ReadByte();
			dp.WriteCell(subcount);
		} while (subcount > 0);
	}

	return Plugin_Handled;
}

// Data timer callback for creating modified UserMessages.
// This is required because we can't fire a new UserMsg directly from inside
// the UserMsg hook itself.
public Action Timer_SendModifiedUserMsg(Handle timer, DataPack data)
{
	data.Reset();

	UserMsg msg_id = data.ReadCell();

	int num_clients = data.ReadCell();
	if (num_clients <= 0)
	{
		return Plugin_Stop;
	}

	int[] clients = new int[num_clients];
	int failed_clients = 0;
	for (int i = 0; i < num_clients; ++i)
	{
		int client = GetClientOfUserId(data.ReadCell());
		if (client == 0)
		{
			++failed_clients;
			continue;
		}
		_override_usermsg_hook[client] = true;
		clients[i] = client;
	}
	num_clients -= failed_clients;
	if (num_clients <= 0)
	{
		return Plugin_Stop;
	}

	BfWrite userMsg = view_as<BfWrite>(StartMessageEx(msg_id, clients, num_clients, USERMSG_RELIABLE));

	if (msg_id == _usermsgs[UM_FADE])
	{
		userMsg.WriteShort(data.ReadCell()); // Fade duration, in ms.
		userMsg.WriteShort(data.ReadCell()); // Fade hold time, in ms.
		userMsg.WriteShort(data.ReadCell()); // Fade flags.
		userMsg.WriteByte(data.ReadCell()); // RGBA red.
		userMsg.WriteByte(data.ReadCell()); // RGBA green.
		userMsg.WriteByte(data.ReadCell()); // RGBA blue.
		userMsg.WriteByte(data.ReadCell()); // RGBA alpha.
	}
	else if (msg_id == _usermsgs[UM_VGUIMENU])
	{
		char buffer[MAX_FILTERED_VGUI_PANEL_SIZE];
		int subcount = 0;
		do {
			data.ReadString(buffer, sizeof(buffer));
			userMsg.WriteString(buffer); // name
			userMsg.WriteByte(data.ReadCell()); // show
			subcount = data.ReadCell();
			userMsg.WriteByte(subcount);
		} while (subcount > 0);
	}
	else
	{
		char msg_name[64];
		if (!GetUserMessageName(msg_id, msg_name, sizeof(msg_name)))
		{
			SetFailState("Invalid UserMessage id: %d", msg_id);
		}
		else
		{
			SetFailState("Unsupported/unimplemented UserMsg: %s", msg_name);
		}
	}

	EndMessage();

	// This is a datatimer, so we don't need to free the DataPack memory here
	return Plugin_Stop;
}

// Simpler & faster version of the custom UserMsg function, for cases where we
// can just send it without relying on a DataPack.
#if SOURCEMOD_V_MAJOR <= 1 && SOURCEMOD_V_MINOR <= 8
// Need this signature for SM 1.8 and 1.7
void SendFadeMessage(int[] clients, int num_clients, int fade_flags)
#else
void SendFadeMessage(const int[] clients, int num_clients, int fade_flags)
#endif
{
	BfWrite userMsg = view_as<BfWrite>(StartMessageEx(_usermsgs[UM_FADE], clients, num_clients,
		USERMSG_RELIABLE));
	userMsg.WriteShort(0); // Fade duration, in ms.
	userMsg.WriteShort(0); // Fade hold time, in ms.
	userMsg.WriteShort(fade_flags); // Fade flags.
	userMsg.WriteByte(0); // RGBA red.
	userMsg.WriteByte(0); // RGBA green.
	userMsg.WriteByte(0); // RGBA blue.
	userMsg.WriteByte(255); // RGBA alpha.

	for (int i = 0; i < num_clients; ++i)
	{
		_override_usermsg_hook[clients[i]] = true;
	}

	EndMessage();
}
