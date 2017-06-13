module tunnelprotocol;

import more.net : in_port_t;

//enum MAX_COMMAND_SIZE = 10;
enum MAX_COMMAND_SIZE = 1000;

immutable in_port_t DEFAULT_TUNNEL_BRIDGE_PORT = 2140;

enum ATTACH_TUNNEL_COMMAND = "AttachTunnel";
enum LIST_TUNNELS_COMMAND = "ListTunnels";
