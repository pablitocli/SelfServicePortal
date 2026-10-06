# =====================================================================================================
# Self-Service Portal appliance - Packer template (AlmaLinux 9, EFI).
#
#   vsphere-iso.almalinux9  builds on a vCenter and exports OVF (export block) - used for the OVA
#   qemu.almalinux9         optional local build without vCenter (qcow2; convert to VMDK, see docs/ova.md)
#
# Normally driven by build-ova.sh. Manual use:
#   packer init  packaging/ova
#   packer build -only='vsphere-iso.almalinux9' -var-file=my.pkrvars.hcl \
#                -var ssp_version=1.0.0 -var release_archive=... -var modules_archive=... packaging/ova
#
# Plugin option names were written against packer-plugin-vsphere 1.4.x / packer-plugin-qemu 1.1.x.
# Options marked "verify" should be checked against the plugin docs for your Packer version.
# =====================================================================================================

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = ">= 1.3.0"
    }
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

# ----------------------------------------------------------------------------------------------------
# vCenter connection and placement
# ----------------------------------------------------------------------------------------------------
variable "vcenter_server" {
  type        = string
  description = "vCenter FQDN."
  default     = ""
}
variable "vcenter_username" {
  type        = string
  description = "Build account (see docs/ova.md for the required privileges)."
  default     = ""
}
variable "vcenter_password" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vcenter_insecure" {
  type        = bool
  description = "Skip vCenter certificate validation (lab only)."
  default     = false
}
variable "vcenter_datacenter" {
  type    = string
  default = ""
}
variable "vcenter_cluster" {
  type    = string
  default = ""
}
variable "vcenter_host" {
  type        = string
  description = "Optional ESXi host inside the cluster (empty = DRS placement)."
  default     = ""
}
variable "vcenter_datastore" {
  type    = string
  default = ""
}
variable "vcenter_folder" {
  type        = string
  description = "VM folder for the build VM (empty = datacenter root)."
  default     = ""
}
variable "vcenter_network" {
  type        = string
  description = "Port group with DHCP and HTTP reachability to the Packer host (kickstart)."
  default     = ""
}

# ----------------------------------------------------------------------------------------------------
# Installation media
# ----------------------------------------------------------------------------------------------------
variable "iso_url" {
  type        = string
  description = "AlmaLinux 9 DVD or boot ISO URL/path (downloaded by Packer and uploaded to the datastore)."
  default     = ""
}
variable "iso_checksum" {
  type        = string
  description = "ISO checksum, e.g. sha256:<hex> or file:<url of CHECKSUM>."
  default     = ""
}
variable "iso_datastore_path" {
  type        = string
  description = "ISO already on a datastore, e.g. \"[iso-ds] linux/AlmaLinux-9.6-x86_64-dvd.iso\". Takes precedence over iso_url for vsphere-iso."
  default     = ""
}

# ----------------------------------------------------------------------------------------------------
# Virtual hardware
# ----------------------------------------------------------------------------------------------------
variable "vm_name" {
  type    = string
  default = "ssp-appliance"
}
variable "vm_version" {
  type        = number
  description = "Virtual hardware version (19 = ESXi 7.0 U2 and later)."
  default     = 19
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory_mb" {
  type    = number
  default = 8192
}
variable "disk_size_mb" {
  type    = number
  default = 61440
}

# ----------------------------------------------------------------------------------------------------
# Build-time account and appliance content
# ----------------------------------------------------------------------------------------------------
variable "build_username" {
  type        = string
  description = "Temporary account used by Packer over SSH; removed when the template is finalized."
  default     = "packer"
}
variable "build_password" {
  type        = string
  sensitive   = true
  description = "Temporary password of the build account (no double quotes). Lives only during the build."
}
variable "appliance_default_password" {
  type        = string
  sensitive   = true
  description = "Fallback password of 'sspadmin' when no ssp.os_password is given at deployment. Expired: must be changed at first login. Empty = account locked until ssp.os_password is set."
  default     = ""
}
variable "http_ip" {
  type        = string
  description = "IP of the Packer host the VM uses to fetch the kickstart (empty = auto-detect)."
  default     = ""
}
variable "ssp_version" {
  type = string
}
variable "release_archive" {
  type        = string
  description = "tar.gz of the portal release tree (created by build-ova.sh)."
}
variable "modules_archive" {
  type        = string
  description = "tar.gz of pre-saved PowerShell modules (may be empty = online install from PSGallery)."
}
variable "cloud_modules" {
  type    = bool
  default = true
}
variable "powercli_module" {
  type    = string
  default = "VMware.PowerCLI"
}
variable "os_update" {
  type    = bool
  default = true
}
variable "zero_free_space" {
  type    = bool
  default = true
}
variable "output_directory" {
  type    = string
  default = "output"
}

# qemu-only
variable "qemu_accelerator" {
  type    = string
  default = "kvm"
}
variable "ovmf_code" {
  type        = string
  description = "UEFI firmware for the qemu build (path differs per distribution)."
  default     = "/usr/share/OVMF/OVMF_CODE.fd"
}
variable "ovmf_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS.fd"
}

# ----------------------------------------------------------------------------------------------------
locals {
  ks_content = templatefile("${path.root}/http/ks.cfg", {
    build_username = var.build_username
    build_password = var.build_password
  })
  # AlmaLinux 9 EFI GRUB: select "Install", edit, append the kickstart location, boot with Ctrl-X.
  boot_command = [
    "<up>",
    "e",
    "<down><down><end><wait>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<enter><wait><leftCtrlOn>x<leftCtrlOff>",
  ]
  shutdown_command = "sudo -n /usr/bin/systemctl poweroff"
}

# ----------------------------------------------------------------------------------------------------
# vSphere build (primary)
# ----------------------------------------------------------------------------------------------------
source "vsphere-iso" "almalinux9" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure
  datacenter          = var.vcenter_datacenter
  cluster             = var.vcenter_cluster
  host                = var.vcenter_host != "" ? var.vcenter_host : null
  datastore           = var.vcenter_datastore
  folder              = var.vcenter_folder != "" ? var.vcenter_folder : null

  vm_name       = var.vm_name
  vm_version    = var.vm_version
  guest_os_type = "rhel9_64Guest"
  firmware      = "efi"
  CPUs          = var.cpus
  RAM           = var.memory_mb
  notes         = "Self-Service Portal appliance ${var.ssp_version} (build VM)"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.disk_size_mb
    disk_thin_provisioned = true
  }
  network_adapters {
    network      = var.vcenter_network
    network_card = "vmxnet3"
  }
  configuration_parameters = {
    "disk.EnableUUID" = "TRUE"
  }

  # Either an ISO already on a datastore, or a URL Packer downloads and uploads.
  iso_paths    = var.iso_datastore_path != "" ? [var.iso_datastore_path] : null
  iso_url      = var.iso_datastore_path == "" ? var.iso_url : null
  iso_checksum = var.iso_datastore_path == "" ? var.iso_checksum : null
  remove_cdrom = true

  http_content = { "/ks.cfg" = local.ks_content }
  http_ip      = var.http_ip != "" ? var.http_ip : null # verify against plugin docs for your Packer version
  boot_wait    = "5s"
  boot_command = local.boot_command

  communicator     = "ssh"
  ssh_username     = var.build_username
  ssh_password     = var.build_password
  ssh_timeout      = "60m"
  shutdown_command = local.shutdown_command
  shutdown_timeout = "15m"

  convert_to_template = false

  # Exports <vm_name>.ovf + disk(s) + .mf to the output directory after shutdown.
  # verify against plugin docs for your Packer version (export block option names).
  export {
    force            = true
    output_directory = "${var.output_directory}/vsphere"
    manifest         = "sha256"
  }
}

# ----------------------------------------------------------------------------------------------------
# Local build without vCenter (optional)
# ----------------------------------------------------------------------------------------------------
source "qemu" "almalinux9" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "${var.output_directory}/qemu"
  vm_name          = "${var.vm_name}.qcow2"
  format           = "qcow2"
  accelerator      = var.qemu_accelerator
  machine_type     = "q35"
  cpus             = var.cpus
  memory           = var.memory_mb
  disk_size        = "${var.disk_size_mb}M"
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  headless         = true

  # UEFI boot - verify against plugin docs for your Packer version.
  efi_boot          = true
  efi_firmware_code = var.ovmf_code
  efi_firmware_vars = var.ovmf_vars

  http_content = { "/ks.cfg" = local.ks_content }
  boot_wait    = "5s"
  boot_command = local.boot_command

  communicator     = "ssh"
  ssh_username     = var.build_username
  ssh_password     = var.build_password
  ssh_timeout      = "60m"
  shutdown_command = local.shutdown_command
  shutdown_timeout = "15m"
}

# ----------------------------------------------------------------------------------------------------
build {
  sources = ["source.vsphere-iso.almalinux9", "source.qemu.almalinux9"]

  # Upload the release tree and the (optional) offline module bundle.
  provisioner "file" {
    sources     = [var.release_archive, var.modules_archive]
    destination = "/var/tmp/"
  }

  # /tmp is mounted noexec: Packer must stage its scripts in /var/tmp.
  provisioner "shell" {
    remote_folder   = "/var/tmp"
    execute_command = "sudo -n -E bash '{{ .Path }}'"
    environment_vars = [
      "SSP_VERSION=${var.ssp_version}",
      "SSP_RELEASE_ARCHIVE=/var/tmp/${basename(var.release_archive)}",
      "SSP_MODULES_ARCHIVE=/var/tmp/${basename(var.modules_archive)}",
      "SSP_CLOUD_MODULES=${var.cloud_modules}",
      "SSP_POWERCLI_MODULE=${var.powercli_module}",
      "SSP_OS_UPDATE=${var.os_update}",
      "SSP_SSPADMIN_INITIAL_PASSWORD=${var.appliance_default_password}",
    ]
    scripts = ["${path.root}/scripts/provision.sh"]
  }

  provisioner "shell" {
    remote_folder   = "/var/tmp"
    execute_command = "sudo -n -E bash '{{ .Path }}'"
    environment_vars = [
      "SSP_BUILD_USER=${var.build_username}",
      "SSP_ZERO_FREE_SPACE=${var.zero_free_space}",
    ]
    scripts = ["${path.root}/scripts/cleanup.sh"]
  }
}
