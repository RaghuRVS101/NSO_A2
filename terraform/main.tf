################################################################
# main.tf
#
# Provider credentials come from the sourced openrc file (env vars).
################################################################

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.0"
    }
  }
}

provider "openstack" {
  # Empty — provider reads OS_* env vars from the sourced openrc.
}

# ─────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────

data "openstack_networking_network_v2" "external" {
  name = var.external_network
}

# ─────────────────────────────────────────
# SSH KEY PAIR
# ─────────────────────────────────────────

resource "openstack_compute_keypair_v2" "keypair" {
  name       = "${var.tag}_key"
  public_key = file(var.ssh_public_key)
}

# ─────────────────────────────────────────
# NETWORK / SUBNET / ROUTER
# ─────────────────────────────────────────

resource "openstack_networking_network_v2" "network" {
  name           = "${var.tag}_network"
  admin_state_up = true
  tags           = [var.tag]
}

resource "openstack_networking_subnet_v2" "subnet" {
  name            = "${var.tag}_subnet"
  network_id      = openstack_networking_network_v2.network.id
  cidr            = "10.0.1.0/24"
  ip_version      = 4
  dns_nameservers = [var.dns_nameserver]
  tags            = [var.tag]
}

resource "openstack_networking_router_v2" "router" {
  name                = "${var.tag}_router"
  external_network_id = data.openstack_networking_network_v2.external.id
  tags                = [var.tag]
}

resource "openstack_networking_router_interface_v2" "router_interface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.subnet.id
}

# ─────────────────────────────────────────
# SECURITY GROUP
# ─────────────────────────────────────────

resource "openstack_networking_secgroup_v2" "secgroup" {
  name        = "${var.tag}_secgroup"
  description = "Security group for ${var.tag}"
  tags        = [var.tag]
}

# Bastion needs to ping nodes — restrict ICMP to internal subnet
resource "openstack_networking_secgroup_rule_v2" "icmp_internal" {
  description       = "Allow ICMP within internal subnet (bastion -> nodes)"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "10.0.1.0/24"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# Service.py — TCP/5000 (assignment requires this exact port on proxy)
resource "openstack_networking_secgroup_rule_v2" "service_tcp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 5000
  port_range_max    = 5000
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# SNMPd — UDP/6000 on proxy (assignment requirement)
resource "openstack_networking_secgroup_rule_v2" "snmp_udp_6000" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 6000
  port_range_max    = 6000
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# SNMP internal — UDP/161 between proxy and nodes
resource "openstack_networking_secgroup_rule_v2" "snmp_udp_161" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 161
  port_range_max    = 161
  remote_ip_prefix  = "10.0.1.0/24"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# Bastion alive checker — TCP/8080
resource "openstack_networking_secgroup_rule_v2" "bastion_check" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8080
  port_range_max    = 8080
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# HAProxy stats page (handy for the report)
resource "openstack_networking_secgroup_rule_v2" "haproxy_stats" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8011
  port_range_max    = 8011
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup.id
}

# ─────────────────────────────────────────
# BASTION
# ─────────────────────────────────────────

resource "openstack_compute_instance_v2" "bastion" {
  name            = "${var.tag}_bastion"
  image_name      = var.image_name
  flavor_name     = var.flavor_name
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_networking_secgroup_v2.secgroup.name]
  tags            = [var.tag, "bastion"]

  network {
    uuid = openstack_networking_network_v2.network.id
  }

  depends_on = [openstack_networking_router_interface_v2.router_interface]
}

# ─────────────────────────────────────────
# PROXY
# ─────────────────────────────────────────

resource "openstack_compute_instance_v2" "proxy" {
  name            = "${var.tag}_proxy"
  image_name      = var.image_name
  flavor_name     = var.flavor_name
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_networking_secgroup_v2.secgroup.name]
  tags            = [var.tag, "proxy"]

  network {
    uuid = openstack_networking_network_v2.network.id
  }

  depends_on = [openstack_networking_router_interface_v2.router_interface]
}

# ─────────────────────────────────────────
# SERVICE NODES — dynamic count
# ─────────────────────────────────────────

resource "openstack_compute_instance_v2" "node" {
  count           = var.node_count
  name            = "${var.tag}_node_${count.index + 1}"
  image_name      = var.image_name
  flavor_name     = var.flavor_name
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_networking_secgroup_v2.secgroup.name]
  tags            = [var.tag, "node"]

  network {
    uuid = openstack_networking_network_v2.network.id
  }

  depends_on = [openstack_networking_router_interface_v2.router_interface]
}

# ─────────────────────────────────────────
# FLOATING IP ASSOCIATIONS
# (Allocation/reuse handled by the install script outside Terraform)
# ─────────────────────────────────────────

# Look up the auto-created port for the proxy/bastion VMs so we can
# attach the floating IP to it (the networking_* variant is the
# recommended replacement for the deprecated compute_floatingip_associate_v2).

data "openstack_networking_port_v2" "proxy_port" {
  device_id  = openstack_compute_instance_v2.proxy.id
  network_id = openstack_networking_network_v2.network.id
}

data "openstack_networking_port_v2" "bastion_port" {
  device_id  = openstack_compute_instance_v2.bastion.id
  network_id = openstack_networking_network_v2.network.id
}

resource "openstack_networking_floatingip_associate_v2" "fip_proxy" {
  floating_ip = var.proxy_floating_ip
  port_id     = data.openstack_networking_port_v2.proxy_port.id
}

resource "openstack_networking_floatingip_associate_v2" "fip_bastion" {
  floating_ip = var.bastion_floating_ip
  port_id     = data.openstack_networking_port_v2.bastion_port.id
}
