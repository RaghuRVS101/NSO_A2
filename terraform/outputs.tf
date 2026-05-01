output "proxy_public_ip" {
  description = "Public IP of the proxy node"
  value       = var.proxy_floating_ip
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = var.bastion_floating_ip
}

output "proxy_private_ip" {
  description = "Private IP of the proxy"
  value       = openstack_compute_instance_v2.proxy.access_ip_v4
}

output "bastion_private_ip" {
  description = "Private IP of the bastion"
  value       = openstack_compute_instance_v2.bastion.access_ip_v4
}

output "node_private_ips" {
  description = "Private IPs of the service nodes"
  value       = openstack_compute_instance_v2.node[*].access_ip_v4
}

output "node_names" {
  description = "Names of the service nodes"
  value       = openstack_compute_instance_v2.node[*].name
}

output "tag" {
  description = "The tag applied to all resources"
  value       = var.tag
}
