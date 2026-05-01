################################################################
# variables.tf
#
# Credentials are NOT defined here — they come from the openrc
# file (sourced before terraform runs), which exports OS_AUTH_URL,
# OS_USERNAME, OS_PASSWORD, etc. The openstack provider auto-detects
# those env vars.
################################################################

variable "tag" {
  type        = string
  description = "Tag used to name and tag all resources (e.g. rev1, raghu)"
}

variable "ssh_public_key" {
  type        = string
  description = "Path to SSH public key file (e.g. ~/.ssh/nso_key.pub)"
}

variable "node_count" {
  type        = number
  description = "Number of service nodes to deploy (read from servers.conf)"
  default     = 3
}

variable "proxy_floating_ip" {
  type        = string
  description = "Floating IP address to attach to the proxy (allocated/reused by install script)"
}

variable "bastion_floating_ip" {
  type        = string
  description = "Floating IP address to attach to the bastion (allocated/reused by install script)"
}

variable "image_name" {
  type        = string
  description = "OS image name"
  default     = "Ubuntu 20.04"
}

variable "flavor_name" {
  type        = string
  description = "VM flavor/size"
  default     = "tiny"
}

variable "external_network" {
  type        = string
  description = "External network name for floating IPs"
  default     = "External"
}

variable "dns_nameserver" {
  type        = string
  description = "DNS nameserver for subnet"
  default     = "10.241.1.10"
}
