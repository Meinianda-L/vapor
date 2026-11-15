/* Shared PE <-> unix protocol for Vapor's steamclient bridge.
 *
 * steamclient64.dll (PE, Wine builtin) forwards every call through
 * __wine_unix_call to steamclient64.so, which runs inside the same process and
 * calls the native macOS steamclient.dylib (x86_64 slice) with the SysV ABI.
 * Pointers are valid on both sides because Wine's PE and unix code share one
 * address space.
 */
#pragma once
#include <stdint.h>

enum bridge_func {
    BRIDGE_INIT,          /* struct bridge_init */
    BRIDGE_CALL_EXPORT,   /* struct bridge_export */
    BRIDGE_CALL_METHOD,   /* struct bridge_method: untyped fallback for unknown interfaces */
    BRIDGE_CALL_TYPED,    /* struct bridge_typed: generated native shape */
    BRIDGE_FUNC_COUNT
};

#define BRIDGE_MAX_ARGS 7

struct bridge_init {
    char dylib_path[1024];   /* empty: default macOS Steam location */
    int32_t status;          /* 0 = ok */
    char error[256];
};

/* C exports of steamclient, in this order on both sides. */
#define BRIDGE_EXPORTS(X) \
    X(CreateInterface) X(Steam_BConnected) X(Steam_BGetCallback) X(Steam_BLoggedOn) \
    X(Steam_BReleaseSteamPipe) X(Steam_ConnectToGlobalUser) X(Steam_CreateGlobalUser) \
    X(Steam_CreateLocalUser) X(Steam_CreateSteamPipe) X(Steam_FreeLastCallback) \
    X(Steam_GSBLoggedOn) X(Steam_GSBSecure) X(Steam_GSGetSteam2GetEncryptionKeyToSendToNewClient) \
    X(Steam_GSGetSteamID) X(Steam_GSLogOff) X(Steam_GSLogOn) X(Steam_GSRemoveUserConnect) \
    X(Steam_GSSendSteam2UserConnect) X(Steam_GSSendSteam3UserConnect) X(Steam_GSSendUserDisconnect) \
    X(Steam_GSSendUserStatusResponse) X(Steam_GSSetServerType) X(Steam_GSSetSpawnCount) \
    X(Steam_GSUpdateStatus) X(Steam_GetAPICallResult) X(Steam_GetGSHandle) \
    X(Steam_InitiateGameConnection) X(Steam_LogOff) X(Steam_LogOn) X(Steam_ReleaseThreadLocalMemory) \
    X(Steam_ReleaseUser) X(Steam_SetLocalIPBinding) X(Steam_TerminateGameConnection) \
    X(Breakpad_SteamMiniDumpInit) X(Breakpad_SteamSetAppID) X(Breakpad_SteamSetSteamID) \
    X(Breakpad_SteamWriteMiniDumpSetComment) X(Breakpad_SteamWriteMiniDumpUsingExceptionInfoWithBuildId)

#define BRIDGE_ENUM(name) EXPORT_##name,
enum bridge_export_index { BRIDGE_EXPORTS(BRIDGE_ENUM) EXPORT_COUNT };
#undef BRIDGE_ENUM

struct bridge_export {
    uint32_t index;
    uint64_t args[8];
    uint64_t ret;
    uint32_t ret_is_interface;   /* ret points at a native C++ interface object */
    char ret_interface_name[64]; /* version string it was requested with, if known */
};

struct bridge_method {
    uint64_t self;               /* native object */
    uint32_t slot;               /* vtable slot */
    uint64_t args[BRIDGE_MAX_ARGS];
    uint64_t ret;
    uint32_t ret_is_interface;
    char ret_interface_name[64];
};

/* Typed call through a generated native (SysV) shape, see generated/bridge_tables.h. */
struct bridge_typed {
    uint64_t self;
    uint32_t native_slot;
    uint32_t mac_shape;
    uint64_t args[16];           /* ints, float/double as bit patterns, struct values or pointers */
    uint64_t retptr;             /* Windows hidden return pointer for struct returns */
    uint64_t ret;
    uint32_t ret_is_interface;
    char ret_interface_name[64];
};
