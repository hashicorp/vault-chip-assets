output "Deployment_Tag" {
  value = random_id.deployment_tag.hex
}

output "Bastion_DNS" {
  value = "bastion"
}

output "SSH_Key" {
  value = abspath(local_sensitive_file.private_key.filename)
}

output "Primary_Vault_Cluster_LB" {
  value = module.primary_cluster.vault_load_balancer
}

output "DR_Vault_Cluster_LB" {
  value = module.dr_cluster.vault_load_balancer
}

output "EU_Vault_Cluster_LB" {
  value = module.eu_cluster.vault_load_balancer
}

output "Jump_to_Primary" {
  value = "ssh -4 -fNTMS /tmp/jump_tunnel -L 8200:${module.primary_cluster.vault_load_balancer}:8200 bastion"
}
output "Jump_to_DR" {
  value = "ssh -4 -fNTMS /tmp/jump_tunnel -L 8200:${module.dr_cluster.vault_load_balancer}:8200 bastion"
}
output "Jump_to_EU" {
  value = "ssh -4 -fNTMS /tmp/jump_tunnel -L 8200:${module.eu_cluster.vault_load_balancer}:8200 bastion"
}
output "Jump_Status" {
  value = "ssh -S /tmp/jump_tunnel -O check bastion"
}
output "Jump_Close" {
  value = "ssh -S /tmp/jump_tunnel -O exit bastion           #This closes existing connections. If there are none you will get an error message."
}

output "Jump_Instructions" {
  value = <<EOF

Use jump command to forward localhost:8200 to connect to the loadbalancer
of the cluster you would like to connect to. Then configure VAULT_ADDR to
use http://localhost:8200. When switching clusters, close out prior jump
tunnel and initiate a new tunnel.

EOF
}

output "vpc1_id" {
  value = module.primary_cluster.vpc_id
}

output "vpc1_region" {
  value = var.region1
}

output "vpc2_id" {
  value = module.dr_cluster.vpc_id
}

output "vpc2_region" {
  value = var.region2
}

output "vpc3_id" {
  value = module.eu_cluster.vpc_id
}

output "vpc3_region" {
  value = var.region3
}

