# SmartScope over the network

The PiBoy runs `smartscopeserver` (LabNation's own C++ implementation, built
from `labnation/DeviceInterface.CXX`). The desktop app connects to it.

## Nothing needs patching, and that is worth showing rather than asserting

The app's device layer already contains the whole client side:

- `src/Hardware/InterfaceManagerZeroConf.cs` — browses mDNS for servers
- `src/Hardware/SmartScopeInterfaceEthernet.cs` — the network transport
- `src/Net/Constants.cs` — `SERVICE_TYPE = "_sss._tcp"`, `REPLY_DOMAIN = "local."`

and the C++ server built for the handheld publishes `_sss._tcp`. The strings
match, so discovery is automatic. LabNation even ship `smartscopeserver` and
`smartscopeserverui` in the app's own Linux distribution template — running the
scope over a network is a supported mode, not a workaround.

## So what is this script for?

When the scope does not appear, the app shows you one symptom for three
unrelated causes, and cannot tell them apart:

1. the server is not running,
2. it is running but no scope is plugged into the handheld,
3. it is running with a scope, but mDNS is not reaching you.

`smartscope-connect.sh [address]` checks each in turn and says which. It also
catches the case that looks like a fault and is not: USB id `04d8:f4b5` is the
scope *loading firmware* and becomes `04d8:0052` once the server has uploaded
it, so seeing f4b5 means wait, not troubleshoot.

## Why step 2 uses ssh when the SDR helper uses a TCP probe

Because `smartscopeserver` opens no socket until a scope is attached.
`src/main.cpp` polls USB and only then constructs the server:

```cpp
scope  = new SmartScopeUsb(devices[i]);
server = new InterfaceServer(scope);
server->Start();
```

So with the server running and no scope plugged in there is nothing listening
and nothing on mDNS — identical, from the network, to the server being dead. A
port probe cannot tell those apart, and reporting "server down" when it is
merely idle would be worse than not checking. Verified on the handheld: the
process runs, `ss` shows no listener, and `avahi-browse` shows no `_sss._tcp`.

The cost is that this step needs shell access, so it takes `PI_USER` and
distinguishes an ssh failure from a verdict on the service rather than
reporting one as the other.

If the script says the server is up with a scope attached and the app still
shows nothing, that narrows the problem to the app's own mDNS stack — which is
a much smaller place to look.
