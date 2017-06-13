module asyncsocket;

static import core.stdc.string;

import more.alloc;
import more.net;

import platformasync;

import tunnelprotocol;

struct Buffer
{
    ubyte* ptr;
    size_t capacity;
    size_t dataLength;
    @property ubyte* nextDataPtr() { return ptr + dataLength; }
    @property auto nextDataCapacity() { return capacity - dataLength; }
}

struct AsyncSocketTemplate(alias SharedBuffer)
{
    static assert(SharedBuffer.length >= MAX_COMMAND_SIZE);

    socket_t sock;
    SocketEventFlags eventFlags;
    
    ubyte* saved;
    size_t savedLength;

    void cleanup()
    {
      sock.shutdown(Shutdown.both);
      closesocket(sock);
      cfree(saved);
    }

    Buffer recvBuffer()
    {
        if(savedLength == 0)
        {
            return Buffer(SharedBuffer.ptr, MAX_COMMAND_SIZE, 0);
        }
        else
        {
            assert(saved);
            return Buffer(saved, MAX_COMMAND_SIZE, savedLength);
        }
    }
    // Returns: false if there is too much data to save
    bool finishRecvBuffer(size_t consumed, size_t totalData)
    {
        if(savedLength == 0)
        {
            auto diff = totalData - consumed;
            if(diff > 0)
            {
                if(diff > MAX_COMMAND_SIZE)
                {
                    return false; // too much data to save
                }
                saved = cmallocArray!ubyte(MAX_COMMAND_SIZE).ptr;
                saved[0..diff] = SharedBuffer.ptr[consumed..consumed+diff];
                savedLength = diff;
            }
        }
        else
        {
            if(totalData == consumed)
            {
                savedLength = 0;
            }
            else if(consumed == 0)
            {
                savedLength = totalData;
            }
            else
            {
                savedLength = totalData - consumed;
                core.stdc.string.memmove(saved, saved + consumed, savedLength);
            }
        }
        return true; // success
    }

    void respondError(ubyte[] buffer)
    {
        auto sent = send(sock, buffer.ptr, buffer.length, 0);
        if(sent != buffer.length)
	{
            // Cause the socket to be closed
            eventFlags = SocketEventFlags.none;
        }
    }
    void respond(ubyte[] buffer)
    {
        auto sent = send(sock, buffer.ptr, buffer.length, 0);
        if(sent != buffer.length)
	{
            // Cause the socket to be closed
            eventFlags = SocketEventFlags.none;
        }
    }
}
