import std.stdio;

import more.net;

import platformasync;
import asyncsocket;

import tunnelprotocol;

/*

Configuration
* command stream listen endpoints (all options, don't have to have any listen endpoints)
* command stream connect config
   - a command stream connect config should have a hostname (optional port), and a retry time
* authentication

*/

struct TunnelBridgeConfig
{
    string hostString;
    inet_sockaddr socketAddress;
}

__gshared ubyte[MAX_COMMAND_SIZE] sharedBuffer;

struct PlatformAsyncHooks
{
    enum EpollEventSize = 100;
    alias SocketEventDataType = AsyncSocket!sharedBuffer*;
}

__gshared PlatformAsync!PlatformAsyncHooks platformAsync;

// TODO: this should be a service, NOT have a main function and NOT called from the command line.
void main()
{
    auto tunnelBridgeConfigs = [
        TunnelBridgeConfig("localhost")
        ];

    platformAsync.initialize();

    foreach(i; 0..tunnelBridgeConfigs.length)
    {
        auto config = &tunnelBridgeConfigs[i];
    }






}