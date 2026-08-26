# Connecting a desktop client to the PiBoy's instrument servers

The PiBoy runs the servers (`Ports -> Instrument Servers`); a desktop drives
them. This directory holds the client-side plumbing.

**No GUI needs patching.** Both servers speak protocols their clients already
implement, which is worth stating plainly because it is easy to assume
otherwise and go looking for a fork to maintain:

| Server on the PiBoy | Protocol | Client support |
|---|---|---|
| `SoapySDRServer` (SoapyRemote) | SoapySDR over TCP 55132, announced as `_soapy._tcp` | `soapysdr-module-remote` — used by gqrx, SDR++, GNU Radio, rtl_433 |
| `smartscopeserver` (LabNation) | announced as `_sss._tcp` | `InterfaceManagerZeroConf` + `SmartScopeInterfaceEthernet`, already in LabNation's `DeviceInterface` |

The SmartScope case was worth verifying rather than assuming: the C++ server
built for the PiBoy publishes `_sss._tcp`, and `src/Net/Constants.cs` in the C#
client declares `SERVICE_TYPE = "_sss._tcp"` with `REPLY_DOMAIN = "local."`.
They match, so LabNation's app discovers the handheld with no configuration.

What is genuinely missing is not protocol support but the boring part — finding
the box, proving it is actually serving, and producing the device string a given
GUI wants. That is what these scripts do.

## `sdr-connect.sh [address]`

Discovers the server over mDNS, or takes an address if mDNS will not cross your
network (it does not route between subnets, and some access points drop it).
Confirms the port is genuinely accepting connections rather than assuming a
name resolving means a server answering, enumerates what radios are attached,
then prints ready-to-paste device strings for gqrx, SDR++, GNU Radio and
rtl_433.

## `smartscope-connect.sh [address]`

The equivalent for the scope. Discovery is automatic in LabNation's app, so
this exists to answer "why can it not see my scope?" — it separates *server not
running* from *server running but no scope attached* from *mDNS not reaching
you*, which the app cannot distinguish for you.
