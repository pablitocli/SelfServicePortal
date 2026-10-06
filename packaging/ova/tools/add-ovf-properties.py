#!/usr/bin/env python3
"""Add the Self-Service Portal vApp properties to an exported OVF descriptor.

Post-processes the .ovf written by the Packer vsphere-iso export:
  * inserts a product-information ProductSection (Product, Vendor, Version, FullVersion, ProductUrl)
  * inserts a ProductSection ovf:class="ssp" with the deployment properties read by
    ssp-firstboot (keys become ssp.<key> in the OVF environment), grouped in the categories
    Network / Appliance / Portal; password properties carry ovf:password="true"
  * enables the vApp OVF environment transport (ovf:transport="com.vmware.guestInfo")
  * rewrites the .mf manifest with SHA256 digests

Idempotent: existing sections created by this tool are replaced. Pure standard library.

Usage: add-ovf-properties.py <file.ovf> --version 1.2.0 [--full-version 1.2.0+build.5]
                             [--product-url https://...] [--no-manifest]
"""
import argparse
import hashlib
import os
import re
import sys
import xml.etree.ElementTree as ET

OVF = "http://schemas.dmtf.org/ovf/envelope/1"
PROPERTY_CLASS = "ssp"
PRODUCT = "Self-Service Portal Appliance"
VENDOR = "Self-Service Portal project"
PRODUCT_URL = "https://example.invalid/self-service-portal"   # placeholder - set --product-url

# (category, key, type, default, label, description, password, qualifiers)
# Types/qualifiers follow the OVF 1.1 spec as used by vSphere vApp options.
PROPERTIES = [
    ("Network", "hostname", "string", "", "Hostname",
     "Short host name of the appliance (e.g. ssp01). Empty keeps 'ssp-appliance'.", False, "MaxLen(63)"),
    ("Network", "domain", "string", "", "Domain name",
     "DNS domain (e.g. corp.example.com). The FQDN is hostname.domain.", False, "MaxLen(190)"),
    ("Network", "ip", "string", "", "IPv4 address",
     "Static IPv4 address. Leave empty to use DHCP.", False, "MaxLen(15)"),
    ("Network", "prefix", "uint8", "24", "Network prefix",
     "IPv4 prefix length (e.g. 24 = 255.255.255.0). Ignored with DHCP.", False, "MinValue(1) MaxValue(32)"),
    ("Network", "gateway", "string", "", "Default gateway",
     "IPv4 default gateway. Ignored with DHCP.", False, "MaxLen(15)"),
    ("Network", "dns", "string", "", "DNS servers",
     "Comma-separated DNS server IP addresses. With DHCP, overrides the DHCP-provided servers.", False, "MaxLen(255)"),
    ("Network", "ntp", "string", "", "NTP servers",
     "Comma-separated NTP servers (names or IPs). Empty keeps the chrony defaults.", False, "MaxLen(255)"),
    ("Appliance", "os_password", "string", "", "OS administrator password",
     "Password of the 'sspadmin' OS account (console / SSH, sudo). Without it the build-time password "
     "remains (expired) and SSH stays disabled.", True, ""),
    ("Appliance", "ssh_enabled", "boolean", "true", "Enable SSH",
     "Enable the SSH service (requires the OS administrator password).", False, ""),
    ("Portal", "portal_admin_password", "string", "", "Portal admin password",
     "Initial password of the portal 'admin' account. Empty keeps the documented default, "
     "which must be changed at first login.", True, ""),
    ("Portal", "portal_port", "uint16", "443", "Portal HTTPS port",
     "TCP port of the portal web interface.", False, "MinValue(1) MaxValue(65535)"),
]


def q(tag):
    return f"{{{OVF}}}{tag}"


def collect_namespaces(path):
    """Return [(prefix, uri)] in document order so prefixes survive re-serialisation."""
    found = []
    for _, (prefix, uri) in ET.iterparse(path, events=("start-ns",)):
        if (prefix, uri) not in found:
            found.append((prefix, uri))
    return found


def register_namespaces(namespaces):
    used_prefixes = set()
    for prefix, uri in namespaces:
        if prefix and prefix not in used_prefixes:
            ET.register_namespace(prefix, uri)
            used_prefixes.add(prefix)
    # The envelope namespace is often only the default namespace: give it the usual 'ovf' prefix.
    if not any(uri == OVF and prefix for prefix, uri in namespaces):
        ET.register_namespace("ovf", OVF)


def text_element(parent, tag, text, attrs=None):
    el = ET.SubElement(parent, q(tag), attrs or {})
    el.text = text
    return el


def build_product_info(version, full_version, product_url):
    sec = ET.Element(q("ProductSection"))
    text_element(sec, "Info", "Information about the installed software")
    text_element(sec, "Product", PRODUCT)
    text_element(sec, "Vendor", VENDOR)
    text_element(sec, "Version", version)
    text_element(sec, "FullVersion", full_version)
    text_element(sec, "ProductUrl", product_url)
    return sec


def build_property_section():
    sec = ET.Element(q("ProductSection"), {q("class"): PROPERTY_CLASS, q("required"): "false"})
    text_element(sec, "Info", "Self-Service Portal appliance deployment settings")
    current = None
    for category, key, typ, default, label, desc, password, qualifiers in PROPERTIES:
        if category != current:
            text_element(sec, "Category", category)
            current = category
        attrs = {q("key"): key, q("type"): typ, q("userConfigurable"): "true", q("value"): default}
        if qualifiers:
            attrs[q("qualifiers")] = qualifiers
        if password:
            attrs[q("password")] = "true"
        prop = ET.SubElement(sec, q("Property"), attrs)
        text_element(prop, "Label", label)
        text_element(prop, "Description", desc)
    return sec


def find_virtual_system(root):
    vs = root.find(f".//{q('VirtualSystem')}")
    if vs is None:
        raise SystemExit("No VirtualSystem element found in the OVF descriptor.")
    return vs


def patch_virtual_system(vs, version, full_version, product_url):
    # Remove sections from a previous run (and any unclassed product section of the export).
    for sec in list(vs.findall(q("ProductSection"))):
        if sec.get(q("class")) in (None, PROPERTY_CLASS):
            vs.remove(sec)
    hw = vs.find(q("VirtualHardwareSection"))
    if hw is None:
        raise SystemExit("No VirtualHardwareSection found in the VirtualSystem.")
    # OVF environment delivered through VMware Tools (guestinfo.ovfEnv).
    transports = set((hw.get(q("transport")) or "").split())
    transports.add("com.vmware.guestInfo")
    hw.set(q("transport"), " ".join(sorted(transports)))
    # Insert right after the VirtualHardwareSection (the order vSphere exports use).
    index = list(vs).index(hw) + 1
    vs.insert(index, build_product_info(version, full_version, product_url))
    vs.insert(index + 1, build_property_section())


def add_missing_declarations(xml_text, namespaces):
    """ElementTree drops namespace declarations it does not use; restore them on the root element
    (some OVF consumers resolve prefixes inside attribute values)."""
    match = re.search(r"<([A-Za-z_][\w.-]*:)?Envelope\b[^>]*>", xml_text)
    if not match:
        return xml_text
    start_tag = match.group(0)
    extra = []
    for prefix, uri in namespaces:
        if not prefix:
            continue
        if re.search(rf'\sxmlns:{re.escape(prefix)}="', start_tag):
            continue
        extra.append(f' xmlns:{prefix}="{uri}"')
    if not extra:
        return xml_text
    closing = "/>" if start_tag.endswith("/>") else ">"
    new_tag = start_tag[: -len(closing)] + "".join(extra) + closing
    return xml_text[: match.start()] + new_tag + xml_text[match.end():]


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def update_manifest(ovf_path, root):
    folder = os.path.dirname(os.path.abspath(ovf_path))
    stem = os.path.splitext(os.path.basename(ovf_path))[0]
    mf_path = os.path.join(folder, stem + ".mf")
    names = []
    if os.path.exists(mf_path):
        with open(mf_path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*\w+\((.+)\)\s*=\s*[0-9a-fA-F]+\s*$", line)
                if m and m.group(1) not in names:
                    names.append(m.group(1))
    else:
        names.append(os.path.basename(ovf_path))
        for ref in root.iter(q("File")):
            href = ref.get(q("href"))
            if href and href not in names:
                names.append(href)
    if os.path.basename(ovf_path) not in names:
        names.insert(0, os.path.basename(ovf_path))
    lines = []
    for name in names:
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            print(f"warning: manifest entry {name} not found - skipped", file=sys.stderr)
            continue
        lines.append(f"SHA256({name})= {sha256_file(path)}\n")
    with open(mf_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.writelines(lines)
    return mf_path, len(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ovf", help="exported .ovf descriptor (modified in place)")
    parser.add_argument("--version", required=True, help="appliance version, e.g. 1.2.0")
    parser.add_argument("--full-version", help="full version string (default: --version)")
    parser.add_argument("--product-url", default=PRODUCT_URL, help="product URL shown in vSphere")
    parser.add_argument("--no-manifest", action="store_true", help="do not rewrite the .mf manifest")
    args = parser.parse_args(argv)

    if not re.match(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$", args.version):
        raise SystemExit(f"Invalid --version: {args.version!r}")

    namespaces = collect_namespaces(args.ovf)
    register_namespaces(namespaces)
    tree = ET.parse(args.ovf)
    root = tree.getroot()
    if root.tag != q("Envelope"):
        raise SystemExit(f"Not an OVF 1.x/2.x envelope: root element is {root.tag}")

    patch_virtual_system(find_virtual_system(root), args.version, args.full_version or args.version, args.product_url)
    ET.indent(tree, space="  ")
    xml_text = ET.tostring(root, encoding="unicode")
    xml_text = add_missing_declarations(xml_text, namespaces)
    ET.fromstring(xml_text)   # sanity check: the result must be well-formed
    with open(args.ovf, "w", encoding="utf-8", newline="\n") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        fh.write(xml_text)
        fh.write("\n")
    print(f"{args.ovf}: added {len(PROPERTIES)} '{PROPERTY_CLASS}' properties, version {args.version}")

    if not args.no_manifest:
        mf_path, count = update_manifest(args.ovf, root)
        print(f"{mf_path}: {count} SHA256 entr{'y' if count == 1 else 'ies'} written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
