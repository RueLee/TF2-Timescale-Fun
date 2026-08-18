#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <tf2>

#undef REQUIRE_PLUGIN
#include <updater>

#define PLUGIN_VERSION	"0.5.1"
#define UPDATE_URL		"https://github.com/RueLee/TF2-Timescale-Fun/blob/main/updater.txt"

#define GAME_TICK_TIME			1.0 / GetGameTickCount()

ConVar g_hTimeScale;
ConVar g_hRandomMin;
ConVar g_hRandomMax;
ConVar g_hLinear;
ConVar g_hLinearMax;
ConVar g_hLinearCapturedValue;
ConVar g_hTeamGloryAvgPosMin;
ConVar g_hTeamGloryAvgPosMax;
ConVar g_hTeamGloryScale;

Handle g_hHudTimer[MAXPLAYERS + 1];
Handle g_hMethodRoundTimer;

enum TimescaleMode {
	RANDOM,
	LINEAR,
	WAVELENGTH,
	TEAMGLORY,
}

enum TimescaleMethod {
	PLAYERDEATH,
	TIMER,
}

bool g_bWaitingForPlayers;
bool g_bIsModeRandom;
bool g_bHasRoundStarted;

int g_iSelectedModeIdx;

float g_fWavelengthAmplitude;
float g_fWavelengthDenom;
float g_fWavelengthInterval;
float g_fWavelengthStep;
const float PI = 3.14159;

enum struct ModeInfo {
	TimescaleMode iMode;
	TimescaleMethod iMethod;
	char sName[64];
	char sDescriptionPhrase[64];
}
ModeInfo g_hActiveMode;

ArrayList g_hTimescaleInfo;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max) {
	char Game[32];
	GetGameFolderName(Game, sizeof(Game));
	if(!StrEqual(Game, "tf")) {
		Format(error, err_max, "This plugin only works for Team Fortress 2");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public Plugin:myinfo = {
	name = "[TF2] Timescale Fun",
	author = "RueLee",
	description = "It's TF2 but the game gets faster/slower in certain modes",
	version = PLUGIN_VERSION,
	url = "https://github.com/RueLee/TF2-Timescale-Fun"
}

public OnPluginStart() {
	CreateConVar("sm_tsfun_version", PLUGIN_VERSION, "Plugin Version -- DO NOT MODIFY!", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hTimeScale = FindConVar("host_timescale");
	g_hRandomMin = CreateConVar("sm_tsfun_random_min", "0.5", "Lowest random timescale range");
	g_hRandomMax = CreateConVar("sm_tsfun_random_max", "2", "Highest random timescale range");
	g_hLinear = CreateConVar("sm_tsfun_linear_addrate", "0.05", "Rate of timescale to increase");
	g_hLinearMax = CreateConVar("sm_tsfun_linear_max", "2.5", "Maximum number timescale can reach for linear mode");
	g_hLinearCapturedValue = CreateConVar("sm_tsfun_linear_captured_scale", "1.5", "Scale down the current timescale value when team captured");
	g_hTeamGloryAvgPosMin = CreateConVar("sm_tsfun_teamglory_min", "0.3", "Lowest team glory timescale range");
	g_hTeamGloryAvgPosMax = CreateConVar("sm_tsfun_teamglory_max", "3", "Highest team glory timescale range");
	g_hTeamGloryScale = CreateConVar("sm_tsfun_teamglory_scale", "1000", "Shrink scale from the average two distances");
	
	// Declaring default variables inside OnPluginStart.
	g_fWavelengthAmplitude = 0.5;
	g_fWavelengthDenom = 14.0;
	g_fWavelengthInterval = PI / g_fWavelengthDenom;
	g_fWavelengthStep = 0.0;

	g_bIsModeRandom = true;

	g_iSelectedModeIdx = 0;

	g_hTimescaleInfo = new ArrayList(sizeof(ModeInfo));
	RegTsMode(RANDOM, PLAYERDEATH, "Random", "Random Mode Description");
	RegTsMode(LINEAR, PLAYERDEATH, "Linear", "Linear Mode Description");
	RegTsMode(WAVELENGTH, PLAYERDEATH, "Wavelength", "Wavelength Mode Description");
	RegTsMode(TEAMGLORY, TIMER, "Team Glory", "Team Glory Mode Description");

	// for (int i = 0; i < g_hTimescaleInfo.Length; i++) {
	// 	ModeInfo hModeInfo;
	// 	g_hTimescaleInfo.GetArray(i, hModeInfo, sizeof(hModeInfo));
	// 	PrintToServer("%s", hModeInfo.sName);
	// }
	
	RegAdminCmd("sm_timescalereset", CmdResetTimeScale, ADMFLAG_GENERIC, "Resets host_timescale to the default value");
	RegAdminCmd("sm_tsreset", CmdResetTimeScale, ADMFLAG_GENERIC, "");
	RegAdminCmd("sm_timescaleset", CmdSetScale, ADMFLAG_GENERIC, "Sets host_timescale to a desired value");
	RegAdminCmd("sm_tsset", CmdSetScale, ADMFLAG_GENERIC, "");
	RegAdminCmd("sm_wavelengthamplitude", CmdSinAmplitude, ADMFLAG_GENERIC, "Determines the amplitude for wavelength. Acceptable range: 0.25-2");
	RegAdminCmd("sm_setwavelengthinterval", CmdSetSinInterval, ADMFLAG_GENERIC, "Sets a specific number to the denominator. Ex: 20 will turn to PI/20.");
	
	RegAdminCmd("sm_timescalefunmenu", CmdTimescaleMenu, ADMFLAG_GENERIC, "Displays all timescale modes menu");
	RegAdminCmd("sm_tsfunmenu", CmdTimescaleMenu, ADMFLAG_GENERIC, "");
	
	HookEvent("teamplay_round_start", Event_RoundStart);
	HookEvent("teamplay_round_active", Event_RoundActive);
	HookEvent("teamplay_round_win", Event_RoundWin);
	HookEvent("teamplay_restart_round", Event_RoundWin);		// Same as winning the round ¯\_(ツ)_/¯
	HookEvent("teamplay_point_captured", Event_TeamCaptured);
	HookEvent("ctf_flag_captured", Event_TeamCaptured);

	LoadTranslations("common.phrases");
	LoadTranslations("timescale_fun.phrases");
	
	if (LibraryExists("updater")) {
		Updater_AddPlugin(UPDATE_URL);
	}

	for (int i = 1; i < MaxClients; i++) {
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		g_hHudTimer[i] = CreateTimer(GAME_TICK_TIME, Timer_HudTimescaleDisplay, i, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void RegTsMode(TimescaleMode iMode, TimescaleMethod iMethod, const char[] sName, const char[] sDescriptionPhrase) {
	ModeInfo hModeInfo;
	hModeInfo.iMode = iMode;
	hModeInfo.iMethod = iMethod;
	strcopy(hModeInfo.sName, sizeof(ModeInfo::sName), sName);
	strcopy(hModeInfo.sDescriptionPhrase, sizeof(ModeInfo::sDescriptionPhrase), sDescriptionPhrase);
	g_hTimescaleInfo.PushArray(hModeInfo, sizeof(hModeInfo));
}

public OnPluginEnd() {
	ResetConVar(g_hTimeScale);

	delete g_hTimescaleInfo;
}

public void OnLibraryAdded(const char[] sName) {
	if (StrEqual(sName, "updater")) {
		Updater_AddPlugin(UPDATE_URL);
	}
}

public OnMapEnd() {
	ResetConVar(g_hTimeScale);
}

public void TF2_OnWaitingForPlayersStart() {
	g_bWaitingForPlayers = true;

	ResetConVar(g_hTimeScale);
	g_fWavelengthStep = 0.0;

	if (g_bHasRoundStarted) {
		switch (g_hActiveMode.iMethod) {
			case PLAYERDEATH:
				UnhookEvent("player_death", Event_PlayerDeath);
			case TIMER:
				CloseHandle(g_hMethodRoundTimer);
		}
	}
}

public void TF2_OnWaitingForPlayersEnd() {
	g_bWaitingForPlayers = false;
}

public void OnClientPutInServer(int client) {
	if (IsFakeClient(client)) {
		return;
	}
	g_hHudTimer[client] = CreateTimer(GAME_TICK_TIME, Timer_HudTimescaleDisplay, client, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client) {
	if (IsFakeClient(client)) {
		return;
	}
	CloseHandle(g_hHudTimer[client]);
}

public Action Event_RoundStart(Event hEvent, const char[] sName, bool bDontBroadcast) {
	if (g_bWaitingForPlayers) {
		return Plugin_Handled;
	}
	ResetConVar(g_hTimeScale);	// In case something goes wrong with host_timescale.
	g_bHasRoundStarted = true;

	int iInfo = g_hTimescaleInfo.GetArray(g_bIsModeRandom ? GetRandomInt(0, g_hTimescaleInfo.Length - 1) : g_iSelectedModeIdx, g_hActiveMode);
	if (!iInfo) {
		return Plugin_Handled;
	}

	CPrintToChatAll("[SM] %t: {lightblue}%s", "Round Start", g_hActiveMode.sName);
	CPrintToChatAll("[SM] %t", g_hActiveMode.sDescriptionPhrase);
	return Plugin_Continue;
}

public Action Event_RoundActive(Event hEvent, const char[] sName, bool bDontBroadcast) {
	if (g_bWaitingForPlayers) {
		return Plugin_Handled;
	}

	switch (g_hActiveMode.iMethod) {
		case PLAYERDEATH:
			HookEvent("player_death", Event_PlayerDeath);
		case TIMER:
			g_hMethodRoundTimer = CreateTimer(GAME_TICK_TIME, Timer_MethodRoundStart, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Continue;
}

public Action Event_PlayerDeath(Event hEvent, const char[] sName, bool bDontBroadcast) {
	switch (g_hActiveMode.iMode) {
		case RANDOM: {
			g_hTimeScale.FloatValue = GetRandomFloat(g_hRandomMin.FloatValue, g_hRandomMax.FloatValue);
		}
		case LINEAR: {
			float fAddedResult = g_hTimeScale.FloatValue + g_hLinear.FloatValue;
			g_hTimeScale.FloatValue = (fAddedResult >= g_hLinearMax.FloatValue) ? g_hLinearMax.FloatValue : fAddedResult;
		}
		case WAVELENGTH: {
			g_hTimeScale.FloatValue = ((g_fWavelengthAmplitude * Sine(g_fWavelengthStep)) + (g_fWavelengthAmplitude + 0.5));
			g_fWavelengthStep += g_fWavelengthInterval;
		}
	}
	return Plugin_Continue;
}

public Action Event_RoundWin(Event hEvent, const char[] sName, bool bDontBroadcast) {
	if (g_bWaitingForPlayers) {
		return Plugin_Handled;
	}

	switch (g_hActiveMode.iMethod) {
		case PLAYERDEATH:
			UnhookEvent("player_death", Event_PlayerDeath);
		case TIMER:
			CloseHandle(g_hMethodRoundTimer);
	}

	ResetConVar(g_hTimeScale);
	g_bHasRoundStarted = false;
	g_fWavelengthStep = 0.0;
	PrintToChatAll("[SM] %t", "Round Finish");

	return Plugin_Continue;
}

public Action Event_TeamCaptured(Event hEvent, const char[] sName, bool bDontBroadcast) {
	switch (g_hActiveMode.iMode) {
		case LINEAR:
			g_hTimeScale.FloatValue /= g_hLinearCapturedValue.FloatValue;
	}
	return Plugin_Continue;
}

public Action CmdResetTimeScale(int client, int args) {
	ResetConVar(g_hTimeScale);
	PrintToChatAll("[SM] %t", "Reset", client);
	return Plugin_Handled;
}

public Action CmdSetScale(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_timescaleset <float>");
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	float scaleValue = StringToFloat(arg1);
	
	g_hTimeScale.FloatValue = scaleValue;
	PrintToChatAll("[SM] %t", "Set Value", scaleValue);
	return Plugin_Handled;
}

public Action CmdSinAmplitude(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_wavelengthamplitude <value (0.25-2)> | Current Value: %.3f", g_fWavelengthAmplitude);
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	float fAmplitude = StringToFloat(arg1);
	
	if (fAmplitude < 0.25 || fAmplitude > 2) {
		ReplyToCommand(client, "[SM] %t", "Amplitude Out of Range");
		return Plugin_Handled;
	}
	
	g_fWavelengthAmplitude = fAmplitude;
	return Plugin_Handled;
}

public Action CmdSetSinInterval(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_setwavelengthinterval <float> | Current Value: PI/%.3f", g_fWavelengthDenom);
		return Plugin_Handled;
	}
	
	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));
	
	float fWavelengthInterval = StringToFloat(arg);
	g_fWavelengthInterval = PI / fWavelengthInterval;
	g_fWavelengthStep = PI / fWavelengthInterval;
	g_fWavelengthDenom = fWavelengthInterval;
	CPrintToChat(client, "[SM] %t", "Wavelength Interval Set", g_fWavelengthDenom);
	return Plugin_Handled;
}

public int TimescaleMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_Select) {
		char sInfo[32];

		menu.GetItem(param2, sInfo, sizeof(sInfo));
		g_bIsModeRandom = (param2 == 0) ? true : false;
		g_iSelectedModeIdx = param2 - 1;
		CPrintToChat(param1, "[SM] %t", "Mode Selected", sInfo);
	}
	else if (action == MenuAction_End) {
		delete menu;
	}
	
	// Eliminate warning compile message
	return 0;
}

public Action CmdTimescaleMenu(int client, int args) {
	Menu hMenu = new Menu(TimescaleMenuHandler);

	hMenu.SetTitle("%t", "Menu", g_hActiveMode.sName, g_bIsModeRandom ? "True" : "False");

	char sInfoItem[32];
	FormatEx(sInfoItem, sizeof(sInfoItem), "%T", "Menu Pick Random", client);
	hMenu.AddItem(sInfoItem, "Pick Random");

	ModeInfo hModeInfo;
	for (int i = 0; i < g_hTimescaleInfo.Length; i++) {
		g_hTimescaleInfo.GetArray(i, hModeInfo, sizeof(hModeInfo));
		hMenu.AddItem(hModeInfo.sName, hModeInfo.sName);
	}

	int iSecondTimeDisplay = 15;
	hMenu.Display(client, iSecondTimeDisplay);

	return Plugin_Handled;
}

public Action Timer_HudTimescaleDisplay(Handle timer, int client) {
	if (!IsClientConnected(client) || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	int iRed = 255;
	int iGreen = 255;
	int iBlue = 255;
	int iAlpha = 255;
	SetHudTextParams(-1.0, 0.82, 0.1, iRed, iGreen, iBlue, iAlpha);
	ShowHudText(client, -1, "host_timescale: %.3f", g_hTimeScale.FloatValue);
	return Plugin_Continue;
}

public Action Timer_MethodRoundStart(Handle timer) {
	if (g_hActiveMode.iMethod != TIMER) {
		return Plugin_Handled;
	}

	if (g_hActiveMode.iMode == TEAMGLORY) {
		float fBluPlayerPos[3], fRedPlayerPos[3];
		float fTotalBluPos[3], fTotalRedPos[3];
		TFTeam iTeam;

		for (int i = 1; i < MaxClients; i++) {
			if (!IsClientConnected(i) || !IsClientInGame(i)) {
				continue;
			}

			iTeam = view_as<TFTeam>(GetClientTeam(i));
			if (iTeam == TFTeam_Blue) {
				GetClientAbsOrigin(i, fBluPlayerPos);
				fTotalBluPos[0] += fBluPlayerPos[0];
				fTotalBluPos[1] += fBluPlayerPos[1];
				fTotalBluPos[2] += fBluPlayerPos[2];
			}
			else if (iTeam == TFTeam_Red) {
				GetClientAbsOrigin(i, fRedPlayerPos);
				fTotalRedPos[0] += fRedPlayerPos[0];
				fTotalRedPos[1] += fRedPlayerPos[1];
				fTotalRedPos[2] += fRedPlayerPos[2];
			}
		}

		int iBluTeamCount, iRedTeamCount;
		iBluTeamCount = GetTeamClientCount(TFTeam_Blue);
		iRedTeamCount = GetTeamClientCount(TFTeam_Red);

		float fAvgBluPosResult[3];
		if (iBluTeamCount > 0) {
			fAvgBluPosResult[0] = fTotalBluPos[0] / iBluTeamCount;
			fAvgBluPosResult[1] = fTotalBluPos[1] / iBluTeamCount;
			fAvgBluPosResult[2] = fTotalBluPos[2] / iBluTeamCount;
		}

		float fAvgRedPosResult[3];
		if (iRedTeamCount > 0) {
			fAvgRedPosResult[0] = fTotalRedPos[0] / iRedTeamCount;
			fAvgRedPosResult[1] = fTotalRedPos[1] / iRedTeamCount;
			fAvgRedPosResult[2] = fTotalRedPos[2] / iRedTeamCount;
		}
		// CPrintToChatAll("Average BLU Pos: %.3f %.3f %.3f", fAvgBluPosResult[0], fAvgBluPosResult[1], fAvgBluPosResult[2]);
		// CPrintToChatAll("Average RED Pos: %.3f %.3f %.3f", fAvgRedPosResult[0], fAvgRedPosResult[1], fAvgRedPosResult[2]);

		float fDistance = SquareRoot(
			Pow(fAvgRedPosResult[0] - fAvgBluPosResult[0], 2.0) + Pow(fAvgRedPosResult[1] - fAvgBluPosResult[1], 2.0) + Pow(fAvgRedPosResult[2] - fAvgBluPosResult[2], 2.0)
		);

		float fTimeScale = fDistance / g_hTeamGloryScale.FloatValue;
		if (fTimeScale > g_hTeamGloryAvgPosMax.FloatValue) {
			fTimeScale = g_hTeamGloryAvgPosMax.FloatValue;
		}
		else if (fTimeScale < g_hTeamGloryAvgPosMin.FloatValue) {
			fTimeScale = g_hTeamGloryAvgPosMin.FloatValue;
		}
		g_hTimeScale.FloatValue = fTimeScale;
	}
	return Plugin_Continue;
}