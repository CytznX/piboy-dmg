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

If the script says the server is up with a scope attached and the app still
shows nothing, that narrows the problem to the app's own mDNS stack — which is
a much smaller place to look.
