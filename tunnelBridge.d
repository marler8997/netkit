static import core.stdc.stdlib;
static import core.stdc.string;

import std.stdio;
import std.format : format;
import std.typecons : Flag, Yes, No;

import more.alloc;
import more.builder;
import more.net;

import platformasync;
import asyncsocket;

import tunnelprotocol;

void log(string msg)
{
    writeln(msg);
    stdout.flush();
}
void logf(T...)(string msg, T args)
{
    writefln(msg, args);
    stdout.flush();
}

struct AsyncSocket
{
  AsyncSocketTemplate!(sharedBuffer) template_;
  alias template_ this;

  void function(AsyncSocket*) handler;
  void handleEvent()
  {
    handler(&this);
  }
  void onDestroy()
  {
    {
      auto tunnelRef = lookupTunnel(&this);
      if(tunnelRef.ptr) {
	attachedTunnels.removeAt(tunnelRef.index);
      }
    }
    template_.cleanup();
    cfree(&this);
  }
}

struct Listener
{
    inet_sockaddr endpoint;
    AsyncSocket asyncSocket;
}

struct PlatformAsyncHooks
{
    enum EpollEventSize = 100;
    alias SocketEventDataType = AsyncSocket*;
}

__gshared PlatformAsync!PlatformAsyncHooks platformAsync;
__gshared ubyte[MAX_COMMAND_SIZE] sharedBuffer;

struct AttachedTunnel
{
  AsyncSocket* async;
  string name;
  inet_sockaddr endpoint;
}
__gshared Builder!(AttachedTunnel, GCDoubler!20) attachedTunnels;


// TODO: this should be a service, NOT have a main function and NOT called from the command line.
void main()
{
    // TODO: load this from a file
    auto listeners = [
        //Listener(inet_sockaddr(htons(DEFAULT_TUNNEL_BRIDGE_PORT), in_addr.any)),
        Listener(inet_sockaddr(htons(DEFAULT_TUNNEL_BRIDGE_PORT), in6_addr.any)),
    ];

    platformAsync.initialize();

    foreach(i; 0..listeners.length)
    {
        auto listener = &listeners[i];
        //assert(listener.asyncSocket.timeout == -1);
        listener.asyncSocket.sock = createsocket(listener.endpoint.family, SocketType.stream, Protocol.tcp);
        if(listener.asyncSocket.sock.isInvalid)
        {
            logf("Error: socket function (family=%s) failed (e=%s)", listener.endpoint.family, lastError());
            return;
        }
        /*
        if(listener.endpoint.family == AddressFamily.inet6)
        {
            // TODO: maybe set IPV6_V6ONLY to false?
        }
        */
        if(failed(listener.asyncSocket.sock.bind(&listener.endpoint.sa, listener.endpoint.sizeof)))
        {
            logf("Error: bind(%s) function failed (e=%s)", listener.endpoint, lastError());
            return;
        }
        if(failed(listener.asyncSocket.sock.listen(32)))
        {
            logf("Error: listen function failed (e=%s)", lastError());
            return;
        }
        if(failed(listener.asyncSocket.sock.setMode(Blocking.no)))
        {
            logf("Error: setMode function failed (e=%s)", lastError());
            return;
        }
        listener.asyncSocket.eventFlags = SocketEventFlags.read;
        listener.asyncSocket.handler = &handleAccept;
        logf("listen socket (s=%s)", listener.asyncSocket.sock);
        platformAsync.add(&listener.asyncSocket);
    }
    
    platformAsync.run();
}

void handleAccept(AsyncSocket* async)
{
    inet_sockaddr from;
    socklen_t fromlen = from.sizeof;
    auto newSocket = async.sock.accept(&from.sa, &fromlen);
    if(newSocket.isInvalid) {
        logf("Error: accept(s=%s) failed (e=%s)", async.sock, lastError());
        assert(0, "accept failed");
    }
    writefln("(s=%s) accepted new socket (s=%s) from %s", async.sock, newSocket, from);

    auto newAsync = cmalloc!(AsyncSocket)();
    newAsync.sock = newSocket;
    assert(success(newAsync.sock.setMode(Blocking.no)), "set new socket to nonblocking failed");
    newAsync.eventFlags = SocketEventFlags.read;
    newAsync.handler = &handleData;
    platformAsync.add(newAsync);
}

struct TunnelRef
{
  AttachedTunnel* ptr;
  size_t index;
}
auto lookupTunnel(AsyncSocket* async)
{
  foreach(i; 0..attachedTunnels.dataLength) {
    auto tunnel = attachedTunnels.getRef(i);
    if(tunnel.async is async) {
      return TunnelRef(tunnel, i);
    }
  }
  return TunnelRef(null);
}

void handleData(AsyncSocket* async)
{
    // TODO: implement a maximum size
    auto buffer = async.recvBuffer();
    size_t totalData;
    {
      auto received = async.sock.recv(buffer.nextDataPtr, buffer.nextDataCapacity, 0);
      if(received <= 0) {
        if(received < 0) {
          logf("(s=%s) recv failed (e=%s)", async.sock, lastError());
        } else {
          logf("(s=%s) connection closed", async.sock);
        }
        async.eventFlags = SocketEventFlags.none; // removes it from platformasync
        return;
      }
      logf("(s=%s) Got %s bytes", async.sock, received);
      totalData = buffer.dataLength + received;
    }

    size_t consumed = 0;
    for(;;) {
      //logf("[DEBUG] consumed=%s, totalData=%s", consumed, totalData);
      auto next = buffer.ptr + consumed;
      auto found = cast(ubyte*)core.stdc.string.memchr(next, '\n', totalData - consumed);
      if(!found) {
        logf("(s=%s) corner case: did not receive newline yet", async.sock);
        break;
      }
      auto commandLength = found - next;
      consumed += commandLength + 1;

      handleCommand(async, (cast(char*)next)[0..commandLength]);
      if(consumed >= totalData) {
        break;
      }
    }

    if(!async.finishRecvBuffer(consumed, totalData))
    {
      logf("(s=%s) Error: received too much data without a newline", async.sock);
      async.eventFlags = SocketEventFlags.none; // removes it from platformasync
    }
}

bool isspace(char c)
{
  return c == ' ' || c == '\t' || c == '\r';
}

inout(char)* skipWhitespace(inout(char)* parsePtr, const(char)* limit)
{
  for(;; parsePtr++) {
    if(parsePtr >= limit) {
      break;
    }
    auto c = *parsePtr;
    if(!isspace(c)) {
      break;
    }
  }
  return parsePtr;
}

inout(char)[] peel(inout(char)** parsePtrPtr, const(char)* limit)
{
  auto parsePtr = *parsePtrPtr;
  scope(exit) {
    *parsePtrPtr = parsePtr;
  }
  
  char c;
  
  // skip whitespace
  for(;; parsePtr++) {
    if(parsePtr >= limit) {
      return null;
    }
    c = *parsePtr;
    if(!isspace(c)) {
      break;
    }
  }

  // skip until whitespace
  auto start = parsePtr;
  for(;;) {
    parsePtr++;
    if(parsePtr >= limit) {
      break;
    }
    c = *parsePtr;
    if(isspace(c)) {
      break;
    }
  }
  
  return start[0..parsePtr-start];
}

void handleCommand(AsyncSocket* async, const(char)[] fullCommand)
{
  writefln("(s=%s) got \"%s\"", async.sock, fullCommand);

  auto parsePtr = fullCommand.ptr;
  auto parseLimit = fullCommand.ptr + fullCommand.length;

  auto commandName = peel(&parsePtr, parseLimit);
  if(commandName is null) {
    logf("(s=%s) received empty command (%s bytes)", async.sock, fullCommand.length);
    return;
  }
  
  if(commandName == ATTACH_TUNNEL_COMMAND) {

    // tunnelName is optional
    auto tunnelName = peel(&parsePtr, parseLimit);
    
    parsePtr = skipWhitespace(parsePtr, parseLimit);
    if(parsePtr < parseLimit) {
      logf("(s=%s) Error: received too many arguments for "~ATTACH_TUNNEL_COMMAND~" command", async.sock);
      async.respondError(cast(ubyte[])"too many arguments\n");
      return;
    }

    logf("(s=%s) AttachTunnel (name=%s)", async.sock, tunnelName);
    inet_sockaddr tunnelAddr;
    {
      socklen_t addrlen = tunnelAddr.sizeof;
      if(failed(async.sock.getpeername(&tunnelAddr.sa, &addrlen))) {
	logf("(s=%s) Error: getpeername failed (e=%s)", async.sock, lastError());
	async.respondError(cast(ubyte[])"getpeername failed\n");
	return;
      }
    }
    
    foreach(i; 0..attachedTunnels.dataLength) {

      auto existing = attachedTunnels.getRef(i);
      if(existing.async is async) {
	logf("(s=%s) Error: tunnel has already been attached", async.sock);
	async.respondError(cast(ubyte[])"already attached\n");
	return;
      }
      if(tunnelName !is null && existing.name == tunnelName) {
	logf("(s=%s) Error: tunnel with name \"%s\" has already been attached", async.sock, tunnelAddr);
	async.respondError(cast(ubyte[])"name already exists\n");
	return;
      }
      
    }

    attachedTunnels.append(AttachedTunnel(async, tunnelName.idup, tunnelAddr));

    logf("There are %s attached tunnels", attachedTunnels.dataLength);
    /*
    foreach(i; 0..attachedTunnels.dataLength) {
      auto tunnel = attachedTunnels.getRef(i);
      logf("TUNNEL %s (name=%s, endpoint=%s)", i, tunnel.name, tunnel.endpoint);
    }
    */
  } else if(commandName == LIST_TUNNELS_COMMAND) {

    auto responseBuilder = Builder!(char, GCDoubler!400)();
    responseBuilder.appendf("%s tunnels:\n", attachedTunnels.dataLength);
    foreach(i; 0..attachedTunnels.dataLength) {
      auto tunnel = attachedTunnels.getRef(i);
      responseBuilder.appendf("%s", tunnel.endpoint);
      if(tunnel.name) {
	responseBuilder.append(" ");
	responseBuilder.append(tunnel.name);
      }
      responseBuilder.append("\n");
    }
    async.respond(cast(ubyte[])responseBuilder.finalString);
    
  } else {
    logf("(s=%s) unknown command \"%s\"", async.sock, commandName);
  }
}
