#include <sourcemod>
#include <regex>
#include "smacbans-block"

#undef REQUIRE_PLUGIN
#include <updater>

#undef REQUIRE_EXTENSIONS
#include <socket>
#include <cURL>

#pragma semicolon 1



#define PLUGIN_VERSION "0.1.8-dev"


// Used for the kickmessage
#define COMMUNITYURL "smacbans.com"


// Used for updater
#define UPDATERURL "http://update.smacbans.com/block/smacbans-block.txt"


// Api
#define APIURL "api.smacbans.com"
#define APIPORT 80
#define USERAGENT "SmacBans_Blockx"


// Debug message switch
#define DEBUG true


// Internal testing doesn't need updatersupport
#define UPDATER false



// Dependencies
#define SOCKET_AVAILABLE()		(GetFeatureStatus(FeatureType_Native, "SocketCreate")   == FeatureStatus_Available)
#define CURL_AVAILABLE()		(GetFeatureStatus(FeatureType_Native, "curl_easy_init") == FeatureStatus_Available)
#define EXTENSIONS_MISSING_ERROR "This plugin requires either the Socket or cURL extension to work.\nOne of them must be installed and running to use this plugin."


// You can define your preferred extension here, though it is recommended to use socket
#define EXT_CURL   0
#define EXT_SOCKET 1
new g_iPreferredExtension = EXT_SOCKET;
new Handle:g_hPreferredExtension;



// IPC
new Handle:g_hOnReceiveForward;




public Plugin:myinfo = 
{
	name = "SMACBANS: Block",
	author = "SMACBANS Team",
	description = "Kicks players listed on the Smacbans global banlist",
	version = PLUGIN_VERSION,
	url = "http://smacbans.com"
}






// Logfile
new String:g_sLogFile[PLATFORM_MAX_PATH];



// Version
new Handle:g_HVersion;



// LateLoaded
new bool:g_bLateLoaded;



// WasChecked
new bool:g_bWasChecked[MAXPLAYERS+1];



// Logswitch
new Handle:g_hLogEnabled;
new bool:g_bLogEnabled;



// Public messages
new Handle:g_hPublicMessages;
new bool:g_bPublicMessages;



// Undetermined action
new Handle:g_hRecheckUndetermined;
new g_bRecheckUndetermined;



// Welcome message
new Handle:g_hWelcomeMessage;
new bool:g_bWelcomeMessage;



// Messageverbosity
new Handle:g_hMessageVerbosity;
new g_iMessageVerbosity;



// Messages from cache
new Handle:g_hCacheMessages;
new bool:g_bCacheMessages;



// Multirequeststring, we need +1 for the slash
new String:g_sMultiRequestString[(MAXPLAYERS+1) * (MAX_STEAMAUTH_LENGTH+1)];



// Fix the doublecheck issue
new bool:g_bIsBeingChecked[MAXPLAYERS+1];



// Regex
new Handle:g_hRegex;



// Port
new Handle:g_hPort;
new g_iPort;



// Hostip
new Handle:g_hHostIp;
new g_iHostIp;



// This is used to push some more infos with the Useragent-header for tracking
new String:g_sDynamicUserAgent[128];



// Pluginversionstatus
new g_iPluginVersionStatus;
#define PLUGIN_VERSION_OK   0
#define PLUGIN_VERSION_BAD  1
#define PLUGIN_VERSION_FAIL 2



// Cache
new Handle:g_hTrie;



#define CACHE_MAX_SIZE   15000
#define CACHE_EXPIRY     24
#define CACHE_UNKNOWN    0
#define CACHE_NOT_BANNED 1
#define CACHE_IS_BANNED  2





// Used for init/lateload check
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	// Because most includefiles don't set this by themselves (blame them) we set their natives as optional here
	// --------------------------------------------------------------------------------------------
	
	
	// Socket
	MarkNativeAsOptional("SocketCreate");
	MarkNativeAsOptional("SocketSetArg");
	MarkNativeAsOptional("SocketSetOption");
	MarkNativeAsOptional("SocketConnect");
	MarkNativeAsOptional("SocketDisconnect");
	MarkNativeAsOptional("SocketIsConnected");
	MarkNativeAsOptional("SocketSend");
	
	
	// cURL
	MarkNativeAsOptional("curl_OpenFile");
	MarkNativeAsOptional("curl_slist");
	MarkNativeAsOptional("curl_slist_append");
	MarkNativeAsOptional("curl_easy_init");
	MarkNativeAsOptional("curl_easy_setopt_int");
	MarkNativeAsOptional("curl_easy_setopt_int_array");
	MarkNativeAsOptional("curl_easy_setopt_function");
	MarkNativeAsOptional("curl_easy_setopt_handle");
	MarkNativeAsOptional("curl_easy_setopt_string");
	MarkNativeAsOptional("curl_easy_perform_thread");
	MarkNativeAsOptional("curl_easy_strerror");
	
	
	RegPluginLibrary("smacbans-block");
	
	g_bLateLoaded = late;
	return APLRes_Success;
}





public OnPluginStart()
{
	// Cache
	g_hTrie = CreateTrie();
	
	
	
	// Clear the Cache every hour if it has reached a certain size.
	CreateTimer(3600.0, Timer_CheckCache, _, TIMER_REPEAT);
	
	
	
	// Clear the Cache periodically to remove old steamids.
	CreateTimer((float(CACHE_EXPIRY) * 60.0), Timer_RefreshCache, _, TIMER_REPEAT);
	
	
	
	// Notify admins that their Pluginversion is too old and they should update
	CreateTimer(600.0, Timer_CheckVersion, _, TIMER_REPEAT);
	
	
	
	// Regex
	g_hRegex = CompileRegex("^STEAM_[0-1]{1}:[0-1]{1}:[0-9]+$");
	
	
	
	// Format the logfilepath
	BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), "logs/%s.%s", "smacbans-block", "log");
	
	
	
	// Convars
	g_HVersion             = CreateConVar("smacbans_block_version", PLUGIN_VERSION, "Plugin Version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_hLogEnabled	       = CreateConVar("smacbans_block_log_enabled", "1", "Whether or not blocks should be logged", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_hPublicMessages      = CreateConVar("smacbans_block_public_messages", "0", "Whether or not statusmessages should be written in chat to everyone", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_hRecheckUndetermined = CreateConVar("smacbans_block_recheck_undetermined", "0", "Whether or not clients should be rechecked if their status couldn't be read out properly (use with care)", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_hWelcomeMessage      = CreateConVar("smacbans_block_welcome_message", "1", "Whether or not players should receive an welcomemessage saying that your server is protected by SmacBans", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_hMessageVerbosity    = CreateConVar("smacbans_block_message_verbosity", "2", "How verbose the statusmessages should be: 0 - No messages, 1 - Only block messages, 2 - All messages", FCVAR_PLUGIN, true, 0.0, true, 2.0);
	g_hCacheMessages       = CreateConVar("smacbans_block_cache_messages", "0", "Whether or not statusmessages should be written on check even if the client was cached already", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_hPreferredExtension  = CreateConVar("smacbans_block_preferred_extension", "1", "Preferred extension: 0 - EXT_CURL, 1 - EXT_SOCKET", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	
	
	AutoExecConfig(true, "smacbans-block");
	LoadTranslations("smacbans-block.phrases");
	
	
	SetConVarString(g_HVersion, PLUGIN_VERSION, false, false);
	g_bLogEnabled          = GetConVarBool(g_hLogEnabled);
	g_bPublicMessages      = GetConVarBool(g_hPublicMessages);
	g_bRecheckUndetermined = GetConVarBool(g_hRecheckUndetermined);
	g_bWelcomeMessage      = GetConVarBool(g_hWelcomeMessage);
	g_iMessageVerbosity    = GetConVarInt(g_hMessageVerbosity);
	g_bCacheMessages       = GetConVarBool(g_hCacheMessages);
	g_iPreferredExtension  = GetConVarInt(g_hPreferredExtension);
	
	
	HookConVarChange(g_HVersion, OnCvarChanged);
	HookConVarChange(g_hLogEnabled, OnCvarChanged);
	HookConVarChange(g_hPublicMessages, OnCvarChanged);
	HookConVarChange(g_hRecheckUndetermined, OnCvarChanged);
	HookConVarChange(g_hWelcomeMessage, OnCvarChanged);
	HookConVarChange(g_hMessageVerbosity, OnCvarChanged);
	HookConVarChange(g_hCacheMessages, OnCvarChanged);
	HookConVarChange(g_hPreferredExtension, OnCvarChanged);
	
	
	
	#if DEBUG == true
	// Check the requirements, if you prefer curl we have an overhead of ~0.002 milliseconds because the check is done twice
	if(SOCKET_AVAILABLE() && !(g_iPreferredExtension == EXT_CURL && CURL_AVAILABLE()) )
	{
		SmacbansDebug(DEBUG, "Using Socket");
	}
	else if(CURL_AVAILABLE())
	{
		SmacbansDebug(DEBUG, "Using cURL");
	}
	else
	{
		SetFailState(EXTENSIONS_MISSING_ERROR);
	}
	#endif
	
	
	
	// Port
	if( (g_hPort = FindConVar("hostport")) != INVALID_HANDLE)
	{
		g_iPort = GetConVarInt(g_hPort);
		HookConVarChange(g_hPort, OnCvarChanged);
	}
	
	
	// Hostip
	if( (g_hHostIp = FindConVar("hostip")) != INVALID_HANDLE)
	{
		g_iHostIp = GetConVarInt(g_hHostIp);
		HookConVarChange(g_hHostIp, OnCvarChanged);
	}
	
	
	// Format the dynamic UserAgent
	decl String:sHostIp[16];
	SmacbansLongToIp(g_iHostIp, sHostIp, sizeof(sHostIp));
	Format(g_sDynamicUserAgent, sizeof(g_sDynamicUserAgent), "[%s] (%s) <%s:%d>", USERAGENT, PLUGIN_VERSION, sHostIp, g_iPort);
	
	SmacbansDebug(DEBUG, "Dynamic Agent: %s", g_sDynamicUserAgent);
	
	
	
	// IPC
	g_hOnReceiveForward = CreateGlobalForward("SmacBans_OnSteamIDStatusRetrieved", ET_Ignore, Param_String, Param_Cell, Param_String);
	
	
	
	// Lateload
	if(g_bLateLoaded)
	{
		LateCheckAllClients();
	}
}





public Action:Timer_CheckCache(Handle:timer)
{
	// If Trie has reached a certain size
	if(GetTrieSize(g_hTrie) >= CACHE_MAX_SIZE)
	{
		// Clear the trie
		ClearTrie(g_hTrie);
		
		// Then check again
		LateCheckAllClients();
	}
	
	return Plugin_Continue;
}





public Action:Timer_RefreshCache(Handle:timer)
{
	// Clear the trie
	ClearTrie(g_hTrie);
	
	// Then check again
	LateCheckAllClients();
	
	return Plugin_Continue;
}





public Action:Timer_CheckVersion(Handle:timer)
{
	if(g_iPluginVersionStatus == PLUGIN_VERSION_BAD)
	{
		// Notice admins that a new pluginversion is available and they should update
		SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_VersionDeprecated", COMMUNITYURL);
	}
	
	return Plugin_Continue;
}





#if UPDATER == true
public OnAllPluginsLoaded()
{
	// Add the plugin to updater
	if(LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATERURL);
	}
}




// Seems like this isn't working anymore
public OnLibraryAdded(const String:name[])
{
	if(StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATERURL);
	}
}
#endif





public OnCvarChanged(Handle:cvar, const String:oldValue[], const String:newValue[])
{
	if(cvar == g_HVersion)
	{
		SetConVarString(g_HVersion, PLUGIN_VERSION, false, false);
	}
	else if(cvar == g_hLogEnabled)
	{
		g_bLogEnabled = GetConVarBool(g_hLogEnabled);
	}
	else if(cvar == g_hPublicMessages)
	{
		g_bPublicMessages = GetConVarBool(g_hPublicMessages);
	}
	else if(cvar == g_hRecheckUndetermined)
	{
		g_bRecheckUndetermined = GetConVarBool(g_hRecheckUndetermined);
	}
	else if(cvar == g_hWelcomeMessage)
	{
		g_bWelcomeMessage = GetConVarBool(g_hWelcomeMessage);
	}
	else if(cvar == g_hMessageVerbosity)
	{
		g_iMessageVerbosity = GetConVarInt(g_hMessageVerbosity);
	}
	else if(cvar == g_hCacheMessages)
	{
		g_bCacheMessages = GetConVarBool(g_hCacheMessages);
	}
	// We use one callback for both, port and hostipchanges, because if one of these cvar changes we need to reformat the agent
	// We don't know if the hostip even changes at the moment, normally it shouldn't
	else if(cvar == g_hPort || cvar == g_hHostIp)
	{
		g_iPort   = GetConVarInt(g_hPort);
		g_iHostIp = GetConVarInt(g_hHostIp);
		
		// Format the dynamic UserAgent
		decl String:sHostIp[16];
		SmacbansLongToIp(g_iHostIp, sHostIp, sizeof(sHostIp));
		Format(g_sDynamicUserAgent, sizeof(g_sDynamicUserAgent), "[%s] (%s) <%s:%d>", USERAGENT, PLUGIN_VERSION, sHostIp, g_iPort);
		
		SmacbansDebug(DEBUG, "Dynamic Agent: %s", g_sDynamicUserAgent);
	}
	else if(cvar == g_hPreferredExtension)
	{
		g_iPreferredExtension = GetConVarInt(g_hPreferredExtension);
	}
}





// Client hast just authorized, so we check him
public OnClientAuthorized(client, const String:auth[])
{
	// Verify client and the auth
	if(!IsFakeClient(client) && MatchRegex(g_hRegex, auth) == 1)
	{
		new status;
		
		// Get the cachestatus
		GetTrieValue(g_hTrie, auth, status);
		
		SmacbansDebug(DEBUG, "%N's cache is set to %d", client, status);
		
		
		
		// Player was not checked before, or check failed
		if(status == CACHE_UNKNOWN)
		{
			LateCheckAllClients();
		}
		// Player was banned before
		else if(status == CACHE_IS_BANNED)
		{
			// Cachemessage
			if(g_bCacheMessages)
			{
				// Verbosity, block
				if(g_iMessageVerbosity > 0)
				{
					// Pubmessage
					if(!g_bPublicMessages)
					{
						SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_PositiveMatch", client);
					}
					else
					{
						PrintToChatAll("\x04[SMACBANS]\x03 %t", "Smacbans_PositiveMatch", client);
					}
				}
			}
			
			
			// Kick the client
			if(!IsClientInKickQueue(client))
			{
				KickClient(client, "%t", "Smacbans_GlobalBanned", COMMUNITYURL);
			}
		}
		// Player was not banned before
		else
		{
			// Cachemessage
			if(g_bCacheMessages)
			{
				// Verbosity, no block
				if(g_iMessageVerbosity > 1)
				{
					// Pubmessage
					if(!g_bPublicMessages)
					{
						SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_NoPositiveMatch", client);
					}
					else
					{
						PrintToChatAll("\x04[SMACBANS]\x03 %t", "Smacbans_NoPositiveMatch", client);
					}
				}
			}
			
			
			// Add the checked flag so the client will not be checked again
			g_bWasChecked[client] = true;
		}
	}
}





public OnClientPostAdminCheck(client)
{
	SmacbansDebug(DEBUG, "Client %N Joined the game", client);
	
	if(g_bWelcomeMessage)
	{
		// Bot's won't read it anyway
		if(!IsFakeClient(client))
		{
			// It starts right when the client sees the motd
			CreateTimer(10.0, Timer_WelcomeMessage, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}





public Action:Timer_WelcomeMessage(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	
	if(SmacbansIsClientValid(client))
	{
		PrintToChat(client, "\x04[SMACBANS]\x03 %t", "Smacbans_Welcome", COMMUNITYURL);
	}
	
	return Plugin_Stop;
}





public OnClientDisconnect(client)
{
	g_bWasChecked[client]     = false;
	g_bIsBeingChecked[client] = false;
}





// LateLoad, this is also used as the main checkfunction so ignore the name
LateCheckAllClients()
{
	// Because this is global we should terminate it before we use it
	g_sMultiRequestString[0] = '\0';
	
	// We need +1 for the slash
	decl String:auth[MAX_STEAMAUTH_LENGTH+1];
	
	for(new i; i <= MaxClients; i++)
	{
		if(!g_bWasChecked[i] && !g_bIsBeingChecked[i] && SmacbansIsClientUsableAuth(i) && !IsFakeClient(i))
		{
			GetClientAuthString(i, auth, sizeof(auth));
			
			// Verify the steamid
			if(MatchRegex(g_hRegex, auth) == 1)
			{
				// The client is been checked at the moment
				g_bIsBeingChecked[i] = true;
				
				
				// Add the auth to the multirequeststring, this can be done with only 1 format, but it's better to understand it like that
				Format(auth, sizeof(auth), "%s/", auth);
				Format(g_sMultiRequestString, sizeof(g_sMultiRequestString), "%s%s", g_sMultiRequestString, auth);
			}
		}
	}
	
	
	#if DEBUG == true
	StrCat(g_sMultiRequestString, sizeof(g_sMultiRequestString), "STEAM_0:0:12345/");
	#endif
	
	
	// Only if there where people we need to check
	if(g_sMultiRequestString[0] != '\0')
	{
		SmacbansDebug(DEBUG, "Multi: %s", g_sMultiRequestString);
		CheckLateClients();
	}
}






CheckLateClients()
{
	SmacbansDebug(DEBUG, "Checking Late Clients");
	
	
	// Using Socket, if you prefer curl we have an overhead of ~0.002 milliseconds because the check is done twice
	if(SOCKET_AVAILABLE() && !(g_iPreferredExtension == EXT_CURL && CURL_AVAILABLE()) )
	{
		SmacbansDebug(DEBUG, "Prepare a new check with Socket");
		
		
		// Create a new socket
		new Handle:Socket = SocketCreate(SOCKET_TCP, OnSocketError);
		
		
		// Optional tweaking stuff
		SocketSetOption(Socket, ConcatenateCallbacks, 4096);
		SocketSetOption(Socket, SocketReceiveTimeout, 3);
		SocketSetOption(Socket, SocketSendTimeout, 3);
		
		
		
		
		// ----------------- Buffer the Requeststring, because this will only be used after the socket is connected, which can take some time -----------------
		// Create a datapack
		new Handle:pack = CreateDataPack();
		
		// Write the data to the pack
		WritePackString(pack, g_sMultiRequestString);
		
		// Set the pack as argument to the callbacks, so we can read it out later
		SocketSetArg(Socket, pack);
		// ----------------- Buffer the Requeststring, because this will only be used after the socket is connected, which can take some time -----------------
		
		
		
		
		// We connect
		SocketConnect(Socket, OnSocketConnect, OnSocketReceive, OnSocketDisconnect, APIURL, APIPORT);
	}
	// Using cURL
	else if(CURL_AVAILABLE())
	{
		SmacbansDebug(DEBUG, "Prepare a new check with cURL");
		
		
		// Declare the Buffer which will be formatted as a http request
		decl String:sRequestString[sizeof(g_sMultiRequestString) + 512];
		
		
		// Request String
		Format(sRequestString, sizeof(sRequestString), "%s/xml/getbanninfo_multiple/%s", APIURL, g_sMultiRequestString);
		
		
		// Create a new curl handle
		new Handle:curl = curl_easy_init();
		
		
		// Optional tweaking stuff
		curl_easy_setopt_int(curl, CURLOPT_CONNECTTIMEOUT, 3);
		curl_easy_setopt_int(curl, CURLOPT_TIMEOUT, 3);
		
		
		// Set the callbacks and the useragent
		curl_easy_setopt_function(curl, CURLOPT_WRITEFUNCTION, OnCurlReceive);
		curl_easy_setopt_string(curl, CURLOPT_URL, sRequestString);
		curl_easy_setopt_string(curl, CURLOPT_USERAGENT, g_sDynamicUserAgent);
		
		
		// Perform
		curl_easy_perform_thread(curl, OnCurlComplete);
	}
	else
	{
		// Requirements are not met anymore (shouldn't happen normally)
		SetFailState(EXTENSIONS_MISSING_ERROR);
	}
}







// ------------------------------------------------ SOCKET -------------------------------------------------------
public OnSocketConnect(Handle:socket, any:data)
{
	SmacbansDebug(DEBUG, "Socket Connected");
	
	// If socket is connected, should be since this is the callback that is called if it is connected
	if(SocketIsConnected(socket))
	{
		// Declare the Buffer which will be formatted as a http GET request
		decl String:sRequestString[sizeof(g_sMultiRequestString) + 512];
		
		
		
		
		// ----------------- Read the Buffer of the Requeststring -----------------
		decl String:TempRequestString[sizeof(g_sMultiRequestString)];
		
		// Reset the pack
		ResetPack(data, false);
		
		// Read the pack
		ReadPackString(data, TempRequestString, sizeof(TempRequestString));
		
		
		SmacbansDebug(DEBUG, "Pack: %s", TempRequestString);
		
		
		// Close the pack
		CloseHandle(data);		
		// ----------------- Read the Buffer of the Requeststring -----------------
		
		
		
		
		// Request String
		Format(sRequestString, sizeof(sRequestString), "GET %s/%s HTTP/1.0\r\nHost: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n", "/xml/getbanninfo_multiple", TempRequestString, APIURL, g_sDynamicUserAgent);
		
		
		// Send the request
		SocketSend(socket, sRequestString);
		
		
		SmacbansDebug(DEBUG, "Socket Send");
	}
}





public OnSocketReceive(Handle:socket, String:data[], const size, any:data2) 
{
	SmacbansDebug(DEBUG, "Socket Receive");
	
	if(socket != INVALID_HANDLE)
	{
		// Process the response
		ProcessResponse(data);
		
		
		// Close the socket
		if(SocketIsConnected(socket))
		{
			SocketDisconnect(socket);
		}
	}
}





public OnSocketDisconnect(Handle:socket, any:data)
{
	SmacbansDebug(DEBUG, "Socket Disconnect");
	
	if(socket != INVALID_HANDLE)
	{
		CloseHandle(socket);
	}
}





public OnSocketError(Handle:socket, const errorType, const errorNum, any:client)
{
	SmacbansDebug(DEBUG, "Socket Error: %d, %d", errorType, errorNum);
	
	if(socket != INVALID_HANDLE)
	{
		CloseHandle(socket);
	}
}
// ------------------------------------------------ SOCKET -------------------------------------------------------







// ------------------------------------------------ CURL -------------------------------------------------------
public OnCurlReceive(Handle:hndl, String:data[], const bytes, const nmemb)
{
	SmacbansDebug(DEBUG, "Curl Receive");
	
	// Process the response
	ProcessResponse(data);
	
	return bytes*nmemb;
}





public OnCurlComplete(Handle:hndl, CURLcode: code, any:data)
{
	SmacbansDebug(DEBUG, "Request completed");
	
	if(code != CURLE_OK)
	{
		new String:error[256];
		curl_easy_strerror(code, error, sizeof(error));
		SmacbansDebug(DEBUG, "Curl Error: %d, %s", code, error);
	}
	
	CloseHandle(hndl);
}
// ------------------------------------------------ CURL -------------------------------------------------------







ProcessResponse(String:data[])
{
	SmacbansDebug(DEBUG, "Processing response");
	
	
	// This fixes an bug on windowsservers
	// The receivefunction for socket is getting called twice on these systems, once for the headers, and a second time for the body
	// Because we know that our response should begin with <?xml and contains a steamid we can quit here and don't waste resources on the first response
	// Other than that if the api is down, the request was malformed etcetera we don't waste resources for working with useless data
	if(StrContains(data, "<?xml", false) == -1 && MatchRegex(g_hRegex, data) < 1)
	{
		SmacbansDebug(DEBUG, "Something went wrong while fetching response %s:%d, Query: %s", APIURL, APIPORT, g_sMultiRequestString);
		
		return;
	}
	
	
	// We need to use MAXPLAYERS because only with that we know the actual size the array must have
	// Arraysize can be as big as we expect the input + length of the search
	// Length of SEARCH</XMLVALUE> is sufficient because the first <XMLVALUE> is split into the first slot with explode
	// This means that the first <XMLVALUE> will be in the first slot and our first result SEARCH</XMLVALUE> will be in the second slot
	// With knowing that we need to add +1 to the original count of our first arrayindex
	new String:Split[MAXPLAYERS+2][32];
	new String:Split2[MAXPLAYERS+2][12];
	new String:Split3[MAXPLAYERS+2][50];
	new String:Split4[2][24];
	
	// Split will be the authid, Split2 will be the status, Split3 will be the banreason and Split4 the versionstatus
	ExplodeString(data, "<steamID>", Split, sizeof(Split), sizeof(Split[]));
	ExplodeString(data, "<status>", Split2, sizeof(Split2), sizeof(Split2[]));
	ExplodeString(data, "<reason>", Split3, sizeof(Split3), sizeof(Split3[]));
	ExplodeString(data, "<update>", Split4, sizeof(Split4), sizeof(Split4[]));
	
	
	// Run though steamids
	new splitsize = sizeof(Split);
	new index;
	for(new i; i < splitsize; i++)
	{
		if(strlen(Split[i]) > 0)
		{
			// If we find something we split off at the searchresult, we then then only have the steamid
			if( (index = StrContains(Split[i], "</steamID>", true)) != -1)
			{
				Split[i][index] = '\0';
			}
		}
	}
	
	
	
	// Run though banstatus
	splitsize = sizeof(Split2);
	for(new i; i < splitsize; i++)
	{
		if(strlen(Split2[i]) > 0)
		{
			// If we find something we split off at the searchresult, we then then only have the banstatus
			if( (index = StrContains(Split2[i], "</status>", true)) != -1)
			{
				Split2[i][index] = '\0';
			}
		}
	}
	
	
	
	// Run though banreason
	splitsize = sizeof(Split3);
	for(new i; i < splitsize; i++)
	{
		if(strlen(Split3[i]) > 0)
		{
			// If we find something we split off at the searchresult, we then then only have the banstatus
			if( (index = StrContains(Split3[i], "</reason>", true)) != -1)
			{
				Split3[i][index] = '\0';
				
				// Most of our bans have an SMAC tag in their reason which we don't want to have here
				ReplaceString(Split3[i], splitsize, "SMAC: ", "", true);
			}
		}
	}
	
	
	
	// Run though update
	splitsize = sizeof(Split4);
	for(new i; i < splitsize; i++)
	{
		if(strlen(Split4[i]) > 0)
		{
			// If we find something we split off at the searchresult, we then then only have the pluginversion - status
			if( (index = StrContains(Split4[i], "</update>", true)) != -1)
			{
				Split4[i][index] = '\0';
			}
		}
	}
	
	
	
	// Set the Current Pluginversionstatus globally
	// We remember, it's the second slot
	// This should only contain 1 char with a number from 0-2
	if(strlen(Split4[1]) == 1)
	{
		g_iPluginVersionStatus = StringToInt(Split4[1]);
		SmacbansDebug(DEBUG, "Versionstatus: was set to %d", g_iPluginVersionStatus);
	}
	
	
	
	// Debugging arrays
	#if DEBUG == true
	splitsize = sizeof(Split);
	for(new i; i < splitsize; i++)
	{
		if((strlen(Split[i]) > 0 && MatchRegex(g_hRegex, Split[i]) == 1))
		{
			SmacbansDebug(DEBUG, "----------- INDEX %d -----------", i);
			SmacbansDebug(DEBUG, "Auth: %s", Split[i]);
			SmacbansDebug(DEBUG, "Status: %s", Split2[i]);
			SmacbansDebug(DEBUG, "Versionstatus: %s, %d", Split4[1], g_iPluginVersionStatus);
			SmacbansDebug(DEBUG, "Reason: %s", (strlen(Split3[i]) > 0 ? Split3[i] : "N/A"));
			SmacbansDebug(DEBUG, "-------------------------------");
		}
	}
	#endif
	
	
	
	// Check them
	splitsize = sizeof(Split);
	new client;
	for(new i; i < splitsize; i++)
	{
		// Verify the steamid
		if(strlen(Split[i]) > 0 && MatchRegex(g_hRegex, Split[i]) == 1)
		{
			// Search the client which matches the steamid
			client = SmacbansGetClientFromSteamId(Split[i]);
			
			
			// If client is still valid (has not left)
			if(client != -1 && SmacbansIsClientUsableAuth(client))
			{
				// Set the isbeingchecked flag to false
				g_bIsBeingChecked[client] = false;
				
				
				// Set the checked flag
				g_bWasChecked[client] = true;
				
				
				SmacbansDebug(DEBUG, "Name: %N | Id: %s | Status: %s", client, Split[i], Split2[i]);
				
				
				// Banned
				if(Split2[i][0] == 'Y')
				{
					// Save him in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_IS_BANNED, true);
					SmacbansDebug(DEBUG, "Set CACHE_IS_BANNED on client %N", client);
					
					
					// Verbosity, block
					if(g_iMessageVerbosity > 0)
					{
						// Pubmessage
						if(!g_bPublicMessages)
						{
							SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_PositiveMatch", client);
						}
						else
						{
							PrintToChatAll("\x04[SMACBANS]\x03 %t", "Smacbans_PositiveMatch", client);
						}
					}
					
					
					// Log a bit (if enabled)
					if(g_bLogEnabled)
					{
						decl String:ip[32];
						GetClientIP(client, ip, sizeof(ip), true);
						
						LogToFileEx(g_sLogFile, "%N (ID: %s | IP: %s | REASON: %s) is on the SMACBANS global banlist", client, Split[i], ip, (strlen(Split3[i]) > 0 ? Split3[i] : "N/A"));
					}
					
					
					// Kick the client
					if(!IsClientInKickQueue(client))
					{
						KickClient(client, "%t", "Smacbans_GlobalBanned", COMMUNITYURL);
					}
				}
				// Not banned
				else if(Split2[i][0] == 'N')
				{
					// Save him in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_NOT_BANNED, true);
					SmacbansDebug(DEBUG, "Set CACHE_NOT_BANNED on client %N", client);
					
					
					// Verbosity, no block
					if(g_iMessageVerbosity > 1)
					{
						// Pubmessage
						if(!g_bPublicMessages)
						{
							SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_NoPositiveMatch", client);
						}
						else
						{
							PrintToChatAll("\x04[SMACBANS]\x03 %t", "Smacbans_NoPositiveMatch", client);
						}
					}
				}
				// We don't know
				else
				{
					// Save him in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_UNKNOWN, true);
					SmacbansDebug(DEBUG, "Set CACHE_UNKNOWN on client %N", client);
					
					
					// Remove the checked flag, so the client gets rechecked next time
					if(g_bRecheckUndetermined)
					{
						g_bWasChecked[client] = false;
					}
					
					
					// Verbosity, undetermined
					if(g_iMessageVerbosity > 1)
					{
						// This will not be public, even if the public cvar is set
						SmacbansPrintAdminNotice(ADMFLAG_GENERIC, "\x04[SMACBANS]\x03 %t", "Smacbans_NoMatch", client);
					}
				}
				
				
				
				// IPC
				new status;
				GetTrieValue(g_hTrie, Split[i], status);
				
				Call_StartForward(g_hOnReceiveForward);
				Call_PushString(Split[i]);
				Call_PushCell(status);
				Call_PushString((strlen(Split3[i]) > 0 ? Split3[i] : "N/A"));
				Call_Finish();
			}
			// Client has left premature (should only happen with connectionspam or something like that), we do caching and logging only then
			else
			{
				SmacbansDebug(DEBUG, "Identity %s hast left the game premature", Split[i]);
				
				// Banned
				if(Split2[i][0] == 'Y')
				{
					// Save the identity in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_IS_BANNED, true);
					SmacbansDebug(DEBUG, "Set CACHE_IS_BANNED on identity %s", Split[i]);
					
					
					// Log a bit (if enabled)
					if(g_bLogEnabled)
					{
						LogToFileEx(g_sLogFile, "ID: %s (%s) is on the SMACBANS global banlist", Split[i], (strlen(Split3[i]) > 0 ? Split3[i] : "N/A"));
					}
				}
				// Not banned
				else if(Split2[i][0] == 'N')
				{
					// Save the identity in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_NOT_BANNED, true);
					SmacbansDebug(DEBUG, "Set CACHE_NOT_BANNED on identity %s", Split[i]);
				}
				// We don't know
				else
				{
					// Save the identity in the cache
					SetTrieValue(g_hTrie, Split[i], CACHE_UNKNOWN, true);
					SmacbansDebug(DEBUG, "Set CACHE_UNKNOWN on identity %s", Split[i]);
				}
				
				
				
				// IPC
				new status;
				GetTrieValue(g_hTrie, Split[i], status);
				
				Call_StartForward(g_hOnReceiveForward);
				Call_PushString(Split[i]);
				Call_PushCell(status);
				Call_PushString((strlen(Split3[i]) > 0 ? Split3[i] : "N/A"));
				Call_Finish();
			}
		}
	}
}
