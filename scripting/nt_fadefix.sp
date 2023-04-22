#pragma semicolon 1

#include <sourcemod>

#include <neotokyo>

#define PLUGIN_VERSION "0.3.7"

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

#define DEATH_FADE_DURATION_SEC 3.840

// Magic value for detecting when we haven't read the data from the related BitBuffer yet
#define BF_UNINITIALIZED 0xDEADBEEF

// UserMsg enumerations.
// Anonymous because otherwise SM complains when using these to access array
// indices, or when comparing named enums against integers.
enum {
	UM_FADE = 0,
	UM_RESETHUD,
	UM_VGUIMENU,

	UM_ENUM_COUNT
};

UserMsg _usermsgs[UM_ENUM_COUNT] = { INVALID_MESSAGE_ID, ... };
char _usermsg_name[UM_ENUM_COUNT][8 + 1] = {
	"Fade",
	"ResetHUD",
	"VGUIMenu",
};

static bool _unfade_allowed[NEO_MAXPLAYERS + 1];
static bool _in_death_fade[NEO_MAXPLAYERS + 1];
static bool _override_usermsg_hook = false;

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
		HookUserMessage(_usermsgs[i], OnUserMsg, true);
	}

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
	_override_usermsg_hook = false;
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
	CreateTimer(DEATH_FADE_DURATION_SEC, Timer_DeathFadeFinished, victim_userid);
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

public Action OnUserMsg(UserMsg msg_id, BfRead msg, const int[] players,
	int playersNum, bool reliable, bool init)
{
	if (!g_hCvar_FadeEnabled.BoolValue || playersNum <= 0)
	{
		return Plugin_Continue;
	}

	if (msg_id != _usermsgs[UM_FADE] &&
		msg_id != _usermsgs[UM_VGUIMENU] &&
		msg_id != _usermsgs[UM_RESETHUD])
	{
		LogError("Unexpected usermsg: %d", msg_id);
		return Plugin_Continue;
	}

	if (_override_usermsg_hook)
	{
		_override_usermsg_hook = false;
		return Plugin_Continue;
	}

	DataPack dp = new DataPack();
	if (msg_id == _usermsgs[UM_FADE])
	{
		dp.WriteCell(msg.ReadShort()); // duration
		dp.WriteCell(msg.ReadShort()); // holdtime
		dp.WriteCell(msg.ReadShort()); // fade flags
		dp.WriteCell(msg.ReadByte()); // color R
		dp.WriteCell(msg.ReadByte()); // color G
		dp.WriteCell(msg.ReadByte()); // color B
		dp.WriteCell(msg.ReadByte()); // color A
	}
	else if (msg_id == _usermsgs[UM_VGUIMENU])
	{
		char buffer[64];
		int subcount = 0;
		do {
			msg.ReadString(buffer, sizeof(buffer));
			dp.WriteString(buffer); // show
			dp.WriteCell(msg.ReadByte()); // show
			subcount = msg.ReadByte(); // count
			dp.WriteCell(subcount);
		} while (subcount > 0);
	}
	else if (msg_id == _usermsgs[UM_RESETHUD])
	{
		// do nothing
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

	dp.Reset();

	int fade_flags = BF_UNINITIALIZED;
	char vguimenu_buffer[sizeof(_usermsg_name[])];
	int vguimenu_show = BF_UNINITIALIZED;

	int[] filtered_players = new int[playersNum];
	int num_filtered_players = 0;
	for (int i = 0; i < playersNum; ++i)
	{
		if (!IsClientInGame(players[i]) ||
			GetClientTeam(players[i]) <= TEAM_SPECTATOR)
		{
			filtered_players[num_filtered_players++] = players[i];
			continue;
		}

		if (msg_id == _usermsgs[UM_FADE])
		{
			if (IsPlayerAlive(players[i]))
			{
				filtered_players[num_filtered_players++] = players[i];
				continue;
			}

			if (fade_flags == BF_UNINITIALIZED)
			{
				dp.ReadCell(); // duration
				dp.ReadCell(); // holdtime
				fade_flags = dp.ReadCell();
				if (fade_flags == BF_UNINITIALIZED)
				{
					SetFailState("Failed to read from bf");
				}
			}

			if (fade_flags & FADE_FLAGS_CLEAR_FADE)
			{
				if (_unfade_allowed[players[i]])
				{
					_unfade_allowed[players[i]] = false;
					filtered_players[num_filtered_players++] = players[i];
					continue;
				}
			}
			else if (fade_flags & FADE_FLAGS_ADD_FADE)
			{
				filtered_players[num_filtered_players++] = players[i];
				continue;
			}
		}
		else if (msg_id == _usermsgs[UM_VGUIMENU])
		{
			if (_unfade_allowed[players[i]])
			{
				filtered_players[num_filtered_players++] = players[i];
				continue;
			}

			if (vguimenu_show == BF_UNINITIALIZED)
			{
				dp.ReadString(vguimenu_buffer, sizeof(vguimenu_buffer));
				vguimenu_show = dp.ReadCell();
				if (vguimenu_buffer[0] == '\0')
				{
					SetFailState("Failed to read from bf (%s)", vguimenu_buffer);
				}
				if (vguimenu_show == BF_UNINITIALIZED)
				{
					SetFailState("Failed to read from bf");
				}
			}

			bool show = (vguimenu_show != 0);
			// If this is a VGUIMenu hide message (not "show"),
			// always allow it to go through.
			// This prevents a race condition with out-of-order
			// network messages leading to the spectator menu
			// never clearing for a player who just spawned into
			// a player team.
			if (!show)
			{
				filtered_players[num_filtered_players++] = players[i];
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
			// Block any panel other than "class" and "loadout".
			if (StrEqual(vguimenu_buffer, "class") || StrEqual(vguimenu_buffer, "loadout"))
			{
				filtered_players[num_filtered_players++] = players[i];
				continue;
			}
		}
	}

	if (playersNum != num_filtered_players)
	{
		// Have to recreate the UserMessage because we can't modify the clients array in this hook
		DataPack dp_final;
		// Using a data timer to delegate this because we can't fire the UserMsg from inside this UserMsg hook
		CreateDataTimer(0.0, Timer_SendModifiedUserMsg, dp_final, TIMER_FLAG_NO_MAPCHANGE);

		dp_final.WriteCell(msg_id);

		dp_final.WriteCell(num_filtered_players);
		for (int i = 0; i < num_filtered_players; ++i)
		{
			dp_final.WriteCell(GetClientUserId(filtered_players[i]));
		}

		dp.Reset();
		if (msg_id == _usermsgs[UM_FADE])
		{
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
			dp_final.WriteCell(dp.ReadCell());
		}
		else if (msg_id == _usermsgs[UM_VGUIMENU])
		{
			char buffer[64];
			int subcount = 0;
			do {
				dp.ReadString(buffer, sizeof(buffer));
				dp_final.WriteString(buffer);
				dp_final.WriteCell(dp.ReadCell());
				subcount = dp.ReadCell();
				dp_final.WriteCell(subcount);
			} while (subcount > 0);
		}
	}

	delete dp;
	return (playersNum == num_filtered_players) ? Plugin_Continue : Plugin_Handled;
}

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
		clients[i] = client;
	}
	num_clients -= failed_clients;
	if (num_clients <= 0)
	{
		return Plugin_Stop;
	}

	Handle userMsg = StartMessageEx(msg_id, clients, num_clients, USERMSG_RELIABLE);

	if (msg_id == _usermsgs[UM_FADE])
	{
		BfWriteShort(userMsg, data.ReadCell()); // Fade duration, in ms.
		BfWriteShort(userMsg, data.ReadCell()); // Fade hold time, in ms.
		BfWriteShort(userMsg, data.ReadCell()); // Fade flags.
		BfWriteByte(userMsg, data.ReadCell()); // RGBA red.
		BfWriteByte(userMsg, data.ReadCell()); // RGBA green.
		BfWriteByte(userMsg, data.ReadCell()); // RGBA blue.
		BfWriteByte(userMsg, data.ReadCell()); // RGBA alpha.
	}
	else if (msg_id == _usermsgs[UM_VGUIMENU])
	{
		char buffer[64];
		int subcount = 0;
		do {
			data.ReadString(buffer, sizeof(buffer));
			BfWriteString(userMsg, buffer); // name
			BfWriteByte(userMsg, data.ReadCell()); // show
			subcount = data.ReadCell();
			BfWriteByte(userMsg, subcount);
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

	_override_usermsg_hook = true;
	EndMessage();

	// This is a datatimer, so we don't need to free the DataPack memory here
	return Plugin_Stop;
}

void SendFadeMessage(const int[] clients, int num_clients, int fade_flags)
{
	Handle userMsg = StartMessageEx(_usermsgs[UM_FADE], clients, num_clients,
		USERMSG_RELIABLE);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, 0);
	BfWriteShort(userMsg, fade_flags);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 0);
	BfWriteByte(userMsg, 255);

	_override_usermsg_hook = true;
	EndMessage();
}
