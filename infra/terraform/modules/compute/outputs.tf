

output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
}



output "worker_public_ips" {
  value = aws_instance.workers[*].public_ip
}

output "worker_private_ips" {
  value = aws_instance.workers[*].private_ip
}

output "worker_instance_ids" {
  value = aws_instance.workers[*].id
}

output "control_plane_instance_id" {
  value = aws_instance.control_plane.id
}