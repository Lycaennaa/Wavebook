#!/usr/bin/env python3
import ipaddress
import re


LOCAL_SERVICE_URL_NAME = "local service URL"
LOCAL_SERVICE_URL = re.compile(
    rb"\b(?:https?|wss?)://(?P<host>(?:[^/\s\"'<>?#@]*@)?(?:\[[^\]\s\"'<>?#@]+\]|[^:/\s\"'<>?#@]+))(?::[0-9]{1,5})?(?=$|[^A-Za-z0-9_.:@-])",
    re.IGNORECASE,
)


def legacy_ipv4_address(host):
    parts = host.split(".")
    if not 1 <= len(parts) <= 4:
        return None
    values = []
    for part in parts:
        try:
            if part.lower().startswith("0x"):
                values.append(int(part[2:], 16))
            elif len(part) > 1 and part.startswith("0"):
                values.append(int(part, 8))
            else:
                values.append(int(part, 10))
        except ValueError:
            return None
    limits = {
        1: (0xFFFFFFFF,),
        2: (0xFF, 0xFFFFFF),
        3: (0xFF, 0xFF, 0xFFFF),
        4: (0xFF, 0xFF, 0xFF, 0xFF),
    }[len(values)]
    if any(value > limit for value, limit in zip(values, limits)):
        return None
    if len(values) == 1:
        packed = values[0]
    elif len(values) == 2:
        packed = (values[0] << 24) | values[1]
    elif len(values) == 3:
        packed = (values[0] << 24) | (values[1] << 16) | values[2]
    else:
        packed = (
            (values[0] << 24)
            | (values[1] << 16)
            | (values[2] << 8)
            | values[3]
        )
    return ipaddress.IPv4Address(packed)


def contains_local_service_url(data):
    for match in LOCAL_SERVICE_URL.finditer(data):
        host = match.group("host").decode("ascii", errors="ignore")
        if "@" in host:
            host = host.rsplit("@", 1)[1]
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        if host.rstrip(".").lower() == "localhost":
            return True
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = legacy_ipv4_address(host)
            if address is None:
                continue
        if address.is_loopback or address.is_unspecified:
            return True
        mapped = getattr(address, "ipv4_mapped", None)
        if mapped is not None and (mapped.is_loopback or mapped.is_unspecified):
            return True
    return False