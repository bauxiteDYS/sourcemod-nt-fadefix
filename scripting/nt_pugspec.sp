#include <sourcemod>
#include <neotokyo>

public Plugin myinfo = {
	name = "NT PUG Spec",
	description = "Allows semi-fair spectating for dead players in semi-comp games",
	author = "bauxite, modified version of Rain's fadefix plugin",
	version = "0.1.0",
	url = ""
};

#define FFADE_IN		0x0001 // Just here so we don't pass 0 into the function
#define FFADE_OUT		0x0002 // Fade out (not in)
#define FFADE_STAYOUT	0x0008 // ignores the duration, stays faded out until new ScreenFade message received
#define FFADE_PURGE		0x0010 // Purges all other fades, replacing them with this one

#define FADE_FLAGS_ADD_FADE (FFADE_OUT | FFADE_STAYOUT)
#define FADE_FLAGS_CLEAR_FADE (FFADE_PURGE | FFADE_IN)

#define DEATH_FADE_DURATION_SEC 7.5
#define DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC 10.0

enum {
	UM_FADE = 0,
	UM_VGUIMENU,

	UM_ENUM_COUNT
};

char _usermsg_name[UM_ENUM_COUNT][] = {
	"Fade",
	"VGUIMenu",
};

UserMsg _usermsgs[UM_ENUM_COUNT] = { INVALID_MESSAGE_ID, ... };

static bool _in_death_fade[NEO_MAXPLAYERS + 1];

ConVar g_hCvar_FadeEnabled = null;

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
	
	g_hCvar_FadeEnabled = FindConVar("mp_forcecamera");
	
	if (g_hCvar_FadeEnabled == null)
	{
		SetFailState("Failed to find cvar mp_forcecamera");
	}
	
	g_hCvar_FadeEnabled.AddChangeHook(CvarChanged_ForceCamera);
	
	if (!HookEventEx("game_round_start", Event_RoundStart, EventHookMode_Pre))
	{
		SetFailState("Failed to hook event game_round_start");
	}
	if (!HookEventEx("player_spawn", Event_PlayerSpawn, EventHookMode_Post))
	{
		SetFailState("Failed to hook event player_spawn");
	}
	if (!HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post))
	{
		SetFailState("Failed to hook event player_death");
	}
	if (!HookEventEx("player_team", Event_PlayerTeam, EventHookMode_Post))
	{
		SetFailState("Failed to hook event player_team");
	}
	
	AddCommandListener(OnSpecMode, "spec_mode");
	AddCommandListener(OnSpecPlayer, "spec_player");
	
	CreateTimer(1.0, Timer_UnFade, _, TIMER_REPEAT);
}

public Action OnSpecMode(int client, const char[] command, int argc)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return Plugin_Continue;
	}
	
	if(IsClientInGame(client) && GetClientTeam(client) > TEAM_SPECTATOR && !IsPlayerAlive(client))
	{
		char specArg[1 + 1];
		GetCmdArg(1, specArg, sizeof(specArg));
		int mode = StringToInt(specArg);
	
		if(mode == 4)
		{
			return Plugin_Continue;
		}
	
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public Action OnSpecPlayer(int client, const char[] command, int argc)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return Plugin_Continue;
	}
	
	if(IsClientInGame(client) && GetClientTeam(client) > TEAM_SPECTATOR && !IsPlayerAlive(client))
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public void CvarChanged_ForceCamera(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(newValue) == 0)
	{
		int clients[NEO_MAXPLAYERS];
		int n_clients;
		
		for (int client = 1; client <= MaxClients; ++client)
		{
			if (!IsClientInGame(client) || IsFakeClient(client))
			{
				continue;
			}
			
			clients[n_clients++] = client;
		}
		
		SendFadeMessage(clients, n_clients, FADE_FLAGS_CLEAR_FADE);
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return;
	}
	
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client) || IsFakeClient(client)) // || event.GetInt("team") > TEAM_SPECTATOR
		{
			continue;
		}
			
		_in_death_fade[client] = true;
		CreateTimer(0.1, Timer_FadePlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return;
	}
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	
	_in_death_fade[client] = false;

	SendFadeMessageOne(client, FADE_FLAGS_CLEAR_FADE);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return;
	}
	
	int victim_userid = event.GetInt("userid");
	int victim = GetClientOfUserId(victim_userid);
	
	if (victim == 0 || !IsClientInGame(victim) || IsFakeClient(victim))
	{
		return;
	}
	
	_in_death_fade[victim] = true;
	
	CreateTimer(DEATH_FADE_DURATION_SEC -1, Timer_FadePlayer, victim_userid);
	CreateTimer(DEATH_FADE_DURATION_SEC, Timer_FadePlayer, victim_userid);
	CreateTimer(DEATH_FADE_DURATION_SEC +1, Timer_FadePlayer, victim_userid);
	CreateTimer(DEATH_TRANSITION_SEQUENCE_COMPLETE_SEC, Timer_DeathFadeFinished, victim_userid, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hCvar_FadeEnabled.BoolValue)
	{
		return;
	}

	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	
	_in_death_fade[client] = false;
	
	if(!IsPlayerAlive(client) && event.GetInt("team") > TEAM_SPECTATOR)
	{
		RequestFrame(SetObserverMode, client);
	}
}

void SetObserverMode(int client)
{
	SetEntProp(client, Prop_Data, "m_iObserverMode", 4); // so the display doesn't mess up when mp_forcecamera is enabled
}

public Action Timer_FadePlayer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (client != 0 && IsClientInGame(client) && !IsPlayerAlive(client) && GetClientTeam(client) > TEAM_SPECTATOR)
	{
		SendFadeMessageOne(client, FADE_FLAGS_ADD_FADE);
	}
	return Plugin_Stop;
}

void UnFadeAllDeadPlayers(bool ignore_clients_in_death_fade)
{
	int fade_clients[NEO_MAXPLAYERS];
	int num_fade_clients = 0;
	
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) <= TEAM_SPECTATOR || IsPlayerAlive(client))
		{
			continue;
		}
		
		if (ignore_clients_in_death_fade && _in_death_fade[client])
		{
			continue;
		}
		
		fade_clients[num_fade_clients++] = client;
	}

	if (num_fade_clients == 0)
	{
		return;
	}

	SendFadeMessage(fade_clients, num_fade_clients, FADE_FLAGS_CLEAR_FADE);
}

public Action Timer_UnFade(Handle timer)
{
	if (g_hCvar_FadeEnabled.BoolValue)
	{
		UnFadeAllDeadPlayers(true);
	}
	
	return Plugin_Continue;
}

public Action Timer_DeathFadeFinished(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	_in_death_fade[client] = false;
	RequestFrame(SetObserverMode, client);
	return Plugin_Stop;
}

void SendFadeMessage(const int[] clients, int num_clients, int fade_flags)
{
	Handle msg = StartMessageEx(_usermsgs[UM_FADE], clients, num_clients, USERMSG_RELIABLE);
	
	InitFadeMessage(msg, fade_flags);

	EndMessage();
}

void SendFadeMessageOne(int client, int fade_flags)
{
	int clients[1];
	clients[0] = client;
	
	Handle msg = StartMessageEx(_usermsgs[UM_FADE], clients, 1, USERMSG_RELIABLE);
	
	InitFadeMessage(msg, fade_flags);

	EndMessage();
}

void InitFadeMessage(Handle message, int fade_flags)
{
	BfWrite bfw = UserMessageToBfWrite(message);
	bfw.WriteShort(0); // Fade duration, in ms.
	bfw.WriteShort(0); // Fade hold time, in ms.
	bfw.WriteShort(fade_flags); // Fade flags.
	bfw.WriteByte(0); // RGBA red.
	bfw.WriteByte(0); // RGBA green.
	bfw.WriteByte(0); // RGBA blue.
	bfw.WriteByte(255); // RGBA alpha.
}
