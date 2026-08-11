output "security_group_id" {
  description = "K3s Security Group ID"
  value       = aws_security_group.k3s_cluster.id
}