module platformasync;

import more.net;

import std.stdio : stdout, writeln, writefln;
import std.format : format;
import std.traits : hasMember;

version(Windows)
{
    public import core.sys.windows.winbase :
        OVERLAPPED;
    import core.sys.windows.winbase :
        HANDLE, INVALID_HANDLE_VALUE, CloseHandle,
        DWORD, ULONG, ULONG_PTR, ULONGLONG,
        INFINITE,
        GENERIC_READ, FILE_SHARE_READ, FILE_SHARE_WRITE,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OVERLAPPED,
        ERROR_IO_PENDING,
        GetLastError,
        CreateIoCompletionPort, GetQueuedCompletionStatus,
        CreateFileA, GetFileSize, ReadFile, ReadFileEx,
        Sleep;
    import core.sys.windows.winsock2 :
        WSAGetLastError,
        WSAEWOULDBLOCK;
    import core.sys.windows.mswsock :
        LPFN_ACCEPTEX;
    enum WSA_IO_PENDING = 997;

    enum SocketEventFlags : ubyte
    {
        none    = 0,
        read    = 0x01,
        write   = 0x02,
        error   = 0x04,
    }
}
else version(Posix)
{
    //version(Linux) 
    //{
        private enum
        {
            EPOLLIN  = 0x001,
            EPOLLOUT = 0x040,
            EPOLLERR = 0x010,
        }
        private enum EpollControl : int
        {
          add = 1,
          del = 2,
          mod = 3,
        }
        private union epoll_data
        {
          void* ptr;
          int fd;
          uint u32;
          ulong u64;
        }
        private extern(C) struct epoll_event
        {
          align(1):
          uint events;
          epoll_data data;
        }
        private extern(C) int epoll_create1(int flags);
        private extern(C) sysresult_t epoll_ctl(int epfd, EpollControl op, int fd, epoll_event* event);
        private extern(C) int epoll_wait(int epfd, epoll_event* events, int maxevents, int timeout);
    //}

        enum SocketEventFlags : uint
        {
            none    = 0,
            read    = EPOLLIN,
            write   = EPOLLOUT,
            error   = EPOLLERR,
        }
}
else
{
    static assert(0, "platform not implemented");
}


// A single threaded platform specific asynchronous implementation.
struct PlatformAsync(Hooks)
{
    static assert(Hooks.SocketEventDataType.sizeof <= size_t.sizeof, "SocketEventDataType is too large");
  
    version(Windows)
    {
        static LPFN_ACCEPTEX AcceptEx;

        HANDLE iocp = null;
        void initialize()
        {
            iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1);
            assert(iocp, format("CreateIoCompletionPort failed (e=%s)", GetLastError()));
            writefln("[DEBUG] iocp = %s", iocp);
        }
        void add(Hooks.SocketEventDataType socketEventData)
        {
            assert(0, "not implemented");
        }
        /+
        void addListenSocket(socket_t listenSocket, Hooks.SocketEventDataType socketEventData)
        {
            inet_sockaddr listenSocketAddr;
            uint listenSocketAddrLen = listenSocketAddr.sizeof;
            if(failed(getsockname(listenSocket, &listenSocketAddr.sa, &listenSocketAddrLen)))
            {
                assert(0, format("getsockname failed (e=%s)", GetLastError()));
            }

            // Associate socket with IO completion port
            {
                auto result = CreateIoCompletionPort(cast(HANDLE)listenSocket, iocp, cast(ULONG_PTR)socketEventData, 1);
                if(result != iocp)
                {
                    throw new Exception(format("CreateIoCompletionPort(socket=%s) failed (e=%s)",
                        listenSocket, GetLastError()));
                }
                writefln("[DEBUG] result = %s", result);
            }
            writefln("[DEBUG] CreateIoCompletionPort(socket=%s) success!", listenSocket);

            // TODO: this should probably done earlier, but right now I need a socket to do it
            if(AcceptEx is null)
            {
                AcceptEx = loadAcceptEx(listenSocket);
                assert(AcceptEx, format("failed to load AcceptEx (e=%s)", GetLastError()));
            }

            socket_t acceptSocket = createsocket(listenSocketAddr.family, SocketType.stream, Protocol.tcp);
            {
                uint bytesReceived;

                auto addressLength = listenSocketAddrLen + 16;
                if(AcceptEx(listenSocket, acceptSocket,
                    socketEventData.buffer.ptr,  socketEventData.buffer.length - (2*addressLength),
                    addressLength, addressLength, &bytesReceived, &socketEventData.overlapped))
                {
                    assert(0, "AcceptEx immediate success not implemented");
                }
                else
                {
                    auto error = WSAGetLastError();
                    if(error != WSA_IO_PENDING)
                    {
                        writefln("AcceptEx failed (e=%s)", WSAGetLastError());
                        assert(0);
                    }
                }
            }
        /*
            // Call accept
            while(true)
            {
                auto result = WSAAccept(listenSocket, null, null, null, null);
                writefln("Called WSAAccept (result=%s, error=%s)", result, GetLastError());
                if(result.isInvalid)
                {
                    break;
                }
                Hooks.onEvent(&socketEventData, 0);
            }
            {
                auto errorCode = WSAGetLastError();
                if(errorCode != WSAEWOULDBLOCK)
                {
                    throw new Exception(format("WSAAccept(s=%s) failed (e=%s)", listenSocket, errorCode));
                }
            }
            */
        }
        +/
        void run()
        {
            /+
            for(;;)
            {
                uint length;
                void* opdata;
                OVERLAPPED* overlapped;

                // TODO use GetQueuedCompletionStatusEx so I can dequeue multiple io packets
                writefln("GetQueuedCompletionStatus(iocp=%s,...) ...", iocp);
                stdout.flush();
                if(!GetQueuedCompletionStatus(iocp, &length, cast(ULONG_PTR*)&opdata, &overlapped, INFINITE))
                {
                    writefln("Error: GetQueuedCompletionStatus failed (e=%d)", GetLastError());
                    return;
                }
                writeln("GetQueuedCompletionStatus POPPED!");
                stdout.flush();
                Hooks.onEvent(opdata, length);
            }
            +/
        }
    }
  // TODO: should probably be version(Linux)
    else version(Posix)
    {
        int epfd;
        void initialize()
        {
            epfd = epoll_create1(0);
            assert(epfd != -1, format("epoll_create1(0) failed (e=%d)", lastError()));
        }
        void add(Hooks.SocketEventDataType socketEventData)
        {
            epoll_event event;
            event.events = socketEventData.eventFlags;
            event.data.ptr  = cast(void*)socketEventData;
            //writefln("data.ptr = %s, socketEventData = %s", event.data.ptr, cast(void*)socketEventData);
            assert(success(epoll_ctl(epfd, EpollControl.add, socketEventData.sock, &event)),
                   format("epoll_ctl(epfd=%s, ADD, fd=%s, flags=0x%x) failed (e=%s)",
                          epfd, socketEventData.sock, event.events, lastError()));
        }
        void run()
        {
            static if(hasMember!(Hooks, "EpollEventSize")) {
                enum EpollEventSize = Hooks.EpollEventSize;
            } else {
                enum EpollEventSize = 40;
            }
            epoll_event[EpollEventSize] events;
            for(;;) {
                int eventCount = epoll_wait(epfd, events.ptr, EpollEventSize, -1);
                assert(eventCount > 0, format("epoll_wait returned %s (e=%s)", eventCount, lastError()));
                //writefln("[DEBUG] got %s event(s)", eventCount);
                foreach(i; 0..eventCount) {
                  //writefln("event %s is %s", i, events[i].data.ptr);
                  auto socketEventData = cast(Hooks.SocketEventDataType)events[i].data.ptr;
                  socketEventData.handleEvent();
                  if(socketEventData.eventFlags == 0) {
		    // NOTE: onDestroy MUST close the socket
		    socketEventData.onDestroy();
		    /*
                    assert(success(epoll_ctl(epfd, EpollControl.del, socketEventData.sock, null)),
                           format("epoll_ctl(epfd=%s, DEL, fd=%s) failed (e=%s)",
                                  epfd, socketEventData.sock, lastError()));
		    */
                  }
                }
            }
        }
    }
    else
    {
        static assert(0, "platform not implemented");
    }
}
